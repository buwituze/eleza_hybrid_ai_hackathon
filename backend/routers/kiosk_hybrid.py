"""
routers/kiosk_hybrid.py — Kiosk flow where the AI runs in the browser.

Models B–F run on the client through Firebase AI Logic hybrid inference
(Gemini Nano on-device in Chrome, cloud Gemini fallback). The backend keeps
what cannot or should not run in the browser:

  - Model A (Whisper speech-to-text)
  - session state, rule-based questions and coverage checks
  - validation of every AI result posted by the browser + triage safety rules
  - routing, persistence, queue and SMS

Flow (same session stages as /kiosk/*):

  POST /kiosk/start                     (unchanged, routers/kiosk.py)
  POST /kiosk/{id}/transcribe           audio → text            [AWAITING_AUDIO|QUESTIONING → EXTRACTING]
      client: translate (rw → en, cloud) + Model B extraction
  POST /kiosk/{id}/extraction           store + next step       [EXTRACTING → QUESTIONING|SCORING]
      client (if needs_ai_question): Model C question, sent with the next /transcribe
  POST /kiosk/{id}/score                validate + route        [SCORING]
      client: Model E patient message + Model F brief
  POST /kiosk/{id}/complete             persist, queue, SMS     [SCORING → COMPLETE]

Every AI result may carry an `ai` trace (which path served it: on_device /
in_cloud, fallback reason, latency); it is stored on the session and in the
doctor brief.
"""

import asyncio
import json
from typing import Any, Literal, Optional

from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from pydantic import BaseModel, Field, ValidationError

from session import ConversationTurn, SessionStage, get_session
from routing import assign_routing
from routing.queue_routing import _sanitize_department
from models import model_a, model_b, model_c, model_d, model_e, model_f
from routers.kiosk import (
    MAX_TURNS,
    FinishRequest,
    FinishResponse,
    _apply_extraction,
    _build_full_transcript,
    _capture_patient_info_from_answer,
    _persist_session,
    _save_audio_file,
)

router = APIRouter(prefix="/kiosk", tags=["kiosk-hybrid"])

_SUPPORTED_LANGUAGES = {"kinyarwanda", "english"}
_MAX_TEXT = 500


# ---------------------------------------------------------------------------
# Schemas
# ---------------------------------------------------------------------------

class AiTrace(BaseModel):
    """Which inference path produced an AI result (for badges + the brief)."""
    step: Literal["translation", "extraction", "question", "score", "routing", "guidance", "brief"]
    source: Literal["on_device", "in_cloud"]
    mode: Optional[str] = Field(default=None, max_length=40)
    fallback_reason: Optional[str] = Field(default=None, max_length=40)
    latency_ms: Optional[int] = Field(default=None, ge=0, le=600_000)
    model: Optional[str] = Field(default=None, max_length=100)


class TranscribeResponse(BaseModel):
    session_id: str
    text: str                      # what the patient just said (original language)
    language: str                  # detected session language
    confidence: float
    is_initial: bool               # True for the first complaint, False for an answer
    needs_translation: bool        # True → translate to English before on-device steps
    conversation: dict             # {"initial": str, "turns": [{"question", "answer"}]}


class ExtractionRequest(BaseModel):
    extraction: dict[str, Any]
    ai: list[AiTrace] = Field(default_factory=list, max_length=10)


class ExtractionResponse(BaseModel):
    session_id: str
    coverage_complete: bool
    question: Optional[str] = None           # set when a rule-based question applies
    question_source: Optional[str] = None    # "rules" when question is set
    needs_ai_question: bool = False          # True → client generates Model C question
    question_context: Optional[dict] = None  # prompt inputs for Model C
    fallback_question: Optional[str] = None  # use if the AI question fails
    patient_name: str = ""
    patient_phone: str = ""


class ScoreRequest(BaseModel):
    score: dict[str, Any]
    # Optional client-side suggestion for "unclear" issues (department + label).
    routing_suggestion: Optional[dict[str, Any]] = None
    ai: list[AiTrace] = Field(default_factory=list, max_length=10)


class ScoreResponse(BaseModel):
    session_id: str
    score: dict
    routing: dict
    low_confidence: bool
    brief_context: dict


class CompleteRequest(BaseModel):
    patient_message: str = Field(default="", max_length=2000)
    brief: dict[str, Any] = Field(default_factory=dict)  # narrative_summary, key_findings, red_flag_note
    patient_name: str = Field(default="", max_length=120)
    patient_phone: str = Field(default="", max_length=40)
    patient_location: str = Field(default="", max_length=200)
    ai: list[AiTrace] = Field(default_factory=list, max_length=10)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_STRING_FIELDS = (
    "patient_name", "patient_age", "patient_gender", "patient_phone", "patient_location",
    "chief_complaint", "duration", "severity", "body_part", "progression", "triggers",
    "additional_observations",
)


def _get_session_or_404(session_id: str):
    session = get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found.")
    return session


def _require_stage(session, *stages: SessionStage) -> None:
    if session.stage not in stages:
        expected = " or ".join(s.value for s in stages)
        raise HTTPException(
            status_code=409,
            detail=f"Session is in stage '{session.stage.value}', expected {expected}.",
        )


def _session_language(session) -> str:
    return session.language if session.language in _SUPPORTED_LANGUAGES else "kinyarwanda"


def _record_traces(session, traces: list[AiTrace]) -> None:
    for t in traces:
        session.ai_trace.append(t.model_dump())


def _conversation(session) -> dict:
    return {
        "initial": session.transcript,
        "turns": [{"question": t.question, "answer": t.answer} for t in session.turns],
    }


def _patient_text(session) -> str:
    return " ".join([session.transcript] + [t.answer for t in session.turns])


def _sanitize_extraction(raw: dict) -> dict:
    """
    Keep only known Model B fields with sane types/sizes. The browser is not a
    trusted source, so nothing it sends is stored verbatim.
    """
    clean: dict[str, Any] = {}
    for key in _STRING_FIELDS:
        value = raw.get(key)
        if value is None:
            continue
        text = str(value).strip()[:_MAX_TEXT]
        if text:
            clean[key] = text

    symptoms = raw.get("associated_symptoms") or []
    if not isinstance(symptoms, list):
        symptoms = [symptoms]
    clean_symptoms: list[Any] = []
    for s in symptoms[:20]:
        if isinstance(s, dict):
            item = {k: str(s[k]).strip()[:_MAX_TEXT] for k in ("name", "duration", "description") if s.get(k)}
            if item.get("name"):
                clean_symptoms.append(item)
        elif str(s).strip():
            clean_symptoms.append(str(s).strip()[:_MAX_TEXT])
    clean["associated_symptoms"] = clean_symptoms

    red_flags = raw.get("red_flags_present")
    clean["red_flags_present"] = red_flags if isinstance(red_flags, bool) else None
    return clean


def _parse_question_trace(raw: Optional[str]) -> Optional[AiTrace]:
    if not raw:
        return None
    try:
        data = json.loads(raw)
        data.setdefault("step", "question")
        return AiTrace.model_validate(data)
    except (ValueError, ValidationError):
        return None  # a bad trace must never block the patient


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@router.post("/{session_id}/transcribe", response_model=TranscribeResponse)
async def kiosk_transcribe(
    session_id: str,
    audio: UploadFile = File(...),
    language: Optional[str] = Form(None),
    question: Optional[str] = Form(None),
    question_ai: Optional[str] = Form(None),
):
    """
    Model A only. First call: the initial complaint. Later calls: the answer
    to `question` (the question the kiosk just asked — rule-based or generated
    in the browser; `question_ai` is its JSON trace).
    """
    session = _get_session_or_404(session_id)
    _require_stage(session, SessionStage.AWAITING_AUDIO, SessionStage.QUESTIONING)
    is_initial = session.stage == SessionStage.AWAITING_AUDIO

    if not is_initial:
        question = model_c.clean_question(question or "")
        if not question:
            raise HTTPException(status_code=422, detail="question is required when answering.")

    audio_bytes = await audio.read()
    if not audio_bytes:
        raise HTTPException(status_code=422, detail="Empty audio.")

    if is_initial or not hasattr(session, "audio_files"):
        session.audio_files = []
    sequence = len(session.audio_files)
    audio_path = _save_audio_file(session_id, audio_bytes, sequence, "patient")
    session.audio_files.append((sequence, "patient", audio_path, len(audio_bytes)))

    if is_initial:
        hint = language.lower() if language else (session.language if session.language != "unknown" else None)
    else:
        hint = session.language

    try:
        a_result = await asyncio.to_thread(model_a.transcribe, audio_bytes, language_hint=hint)
    except Exception as e:  # noqa: BLE001 — surface any STT failure to the kiosk
        raise HTTPException(status_code=500, detail=f"Transcription error: {type(e).__name__}: {e}")

    text = a_result["full_text"]
    if is_initial:
        session.transcript = text
        session.transcript_conf = a_result["mean_confidence"]
        session.language = a_result["dominant_language"]
    else:
        session.turns.append(ConversationTurn(question=question, answer=text))
        _capture_patient_info_from_answer(session, question, text)
        trace = _parse_question_trace(question_ai)
        if trace:
            _record_traces(session, [trace])

    session.stage = SessionStage.EXTRACTING
    lang = _session_language(session)
    return TranscribeResponse(
        session_id=session.id,
        text=text,
        language=lang,
        confidence=float(a_result.get("mean_confidence", 0.0)),
        is_initial=is_initial,
        needs_translation=lang == "kinyarwanda",
        conversation=_conversation(session),
    )


@router.post("/{session_id}/extraction", response_model=ExtractionResponse)
async def kiosk_extraction(session_id: str, body: ExtractionRequest):
    """
    Store the browser's Model B extraction and decide the next step:
    coverage complete → SCORING; otherwise a rule-based question, or ask the
    client to generate one (Model C) with the returned context.
    """
    session = _get_session_or_404(session_id)
    _require_stage(session, SessionStage.EXTRACTING)

    extraction = _sanitize_extraction(body.extraction)
    # Safety net: keyword red-flag check on what the patient actually said,
    # independent of any model output.
    if model_b._detect_red_flags(_patient_text(session)):
        extraction["red_flags_present"] = True
    extraction["language"] = _session_language(session)

    _apply_extraction(session, extraction)
    _record_traces(session, body.ai)

    if session.turns and model_c.is_coverage_complete(session.extraction, len(session.turns), MAX_TURNS):
        session.stage = SessionStage.SCORING
        return ExtractionResponse(
            session_id=session.id,
            coverage_complete=True,
            patient_name=session.patient_name,
            patient_phone=session.patient_phone,
        )

    session.stage = SessionStage.QUESTIONING
    rule_question = model_c.next_rule_question(session.extraction, session.questions_asked)
    if rule_question:
        return ExtractionResponse(
            session_id=session.id,
            coverage_complete=False,
            question=rule_question,
            question_source="rules",
            patient_name=session.patient_name,
            patient_phone=session.patient_phone,
        )

    return ExtractionResponse(
        session_id=session.id,
        coverage_complete=False,
        needs_ai_question=True,
        question_context=model_c.question_context(
            session.extraction, session.questions_asked, session.patient_answers
        ),
        fallback_question=model_c.fallback_question(_session_language(session)),
        patient_name=session.patient_name,
        patient_phone=session.patient_phone,
    )


@router.post("/{session_id}/score", response_model=ScoreResponse)
async def kiosk_score(session_id: str, body: ScoreRequest):
    """
    Validate the browser's Model D score, enforce triage safety rules, and
    assign routing. Returns what the client needs for Models E and F.
    """
    session = _get_session_or_404(session_id)
    _require_stage(session, SessionStage.SCORING)

    score = model_d.normalize_score(body.score)
    score = model_d.apply_safety_rules(score, session.extraction)

    department_override = None
    suggestion = body.routing_suggestion or {}
    if (score["priority"] != "HIGH"
            and score["suspected_issue"] == "unclear or unclassifiable complaint"
            and suggestion.get("department")):
        department_override = _sanitize_department(str(suggestion.get("department")).strip())
        issue = str(suggestion.get("suspected_issue") or "").strip()[:120]
        if issue:
            score["suspected_issue"] = issue
        score["routing_fallback"] = {
            "department": department_override,
            "suspected_issue": score["suspected_issue"],
            "reason": str(suggestion.get("reason") or "").strip()[:300],
        }

    routing = assign_routing(
        priority=score["priority"],
        suspected_issue=score["suspected_issue"],
        department_override=department_override,
    )
    session.score = score
    session.routing = routing
    _record_traces(session, body.ai)

    return ScoreResponse(
        session_id=session.id,
        score=score,
        routing={
            "department": routing.department,
            "queue": routing.queue,
            "queue_number": routing.queue_number,
            "location_hint": routing.location_hint,
            "urgency_label": routing.urgency_label,
        },
        low_confidence=score.get("confidence", 1.0) < 0.4,
        brief_context={
            "session_id": session.id,
            "extraction": session.extraction,
            "conversation": _conversation(session),
            "full_transcript": _build_full_transcript(session),
            "language": _session_language(session),
            "patient_age": session.patient_age,
            "location_hint": routing.location_hint,
        },
    )


@router.post("/{session_id}/complete", response_model=FinishResponse)
async def kiosk_complete(session_id: str, body: CompleteRequest):
    """
    Accept the browser's Model E message and Model F brief fields, apply the
    same guardrails as the server models, then persist, queue and notify.
    """
    session = _get_session_or_404(session_id)
    _require_stage(session, SessionStage.SCORING)
    if session.routing is None:
        raise HTTPException(status_code=409, detail="Score the session (POST /score) before completing it.")

    routing = session.routing
    language = _session_language(session)
    low_confidence = session.score.get("confidence", 1.0) < 0.4
    _record_traces(session, body.ai)

    message, used_template = model_e.vet_message(
        body.patient_message, language, session.score.get("priority", "UNKNOWN"), low_confidence
    )
    full_transcript = _build_full_transcript(session)
    brief = model_f.build_brief(
        session_id=session.id,
        extraction=session.extraction,
        score=session.score,
        questions_asked=session.questions_asked,
        patient_answers=session.patient_answers,
        transcript=full_transcript,
        language=language,
        patient_age=session.patient_age,
        ai_fields=body.brief,
    )
    brief["ai_trace"] = list(session.ai_trace)
    brief["patient_message_from_template"] = used_template

    session.patient_message = message
    session.doctor_brief = brief
    session.location = routing.location_hint
    session.stage = SessionStage.COMPLETE

    finish = FinishRequest(
        patient_name=body.patient_name,
        patient_phone=body.patient_phone,
        patient_location=body.patient_location,
    )
    queue_entry = _persist_session(session, finish, routing, full_transcript)

    return FinishResponse(
        session_id=session.id,
        patient_message=message,
        department=routing.department,
        queue=routing.queue,
        queue_number=queue_entry.get("queue_number", 0),
        location_hint=routing.location_hint,
        urgency_label=routing.urgency_label,
    )
