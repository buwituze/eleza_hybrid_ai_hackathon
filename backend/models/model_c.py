"""
models/model_c.py — Next-question selection wrapper.
"""

import os, re
from typing import Optional
from google import genai
from .gemini_utils import generate_with_fallback

# Lazy client: the hybrid kiosk flow runs this model in the browser via
# Firebase AI Logic, so the backend must start without GEMINI_API_KEY.
_client = None


def _get_client():
    global _client
    if _client is None:
        _client = genai.Client(api_key=os.getenv("GEMINI_API_KEY"))
    return _client

COVERAGE_CHECKLIST = [
    "severity or intensity of the main symptom",
    "when the symptom started or how long it has been present",
    "whether the symptom is getting better, worse, or staying the same",
    "any other symptoms alongside the main one",
    "whether the symptom affects the patient's daily activities",
    "any relevant medical history or known conditions",
]

RED_FLAG_FOLLOWUPS = [
    "Is the patient currently able to breathe comfortably?",
    "Has the patient lost consciousness or felt faint?",
    "Is there any unusual bleeding?",
    "Is the patient able to move all limbs normally?",
]

_SYSTEM = """You are a clinical question-selection assistant in a hospital pre-consultation system.
Output ONE question only. Nothing else.
Rules:
- One question per response. No exceptions.
- No diagnosis, no medical advice, no interpretation.
- Do not repeat a question already asked.
- Keep it short and natural to say out loud.
- Output the question text only — no labels, no prefix.
- IMPORTANT: Output the question in the SAME language as the conversation below. If the conversation is in Kinyarwanda, ask in Kinyarwanda. If in English, ask in English."""


def _stage(num_turns: int) -> str:
    if num_turns <= 2:  return "early"
    if num_turns <= 6:  return "mid"
    return "escalation"


def next_rule_question(extraction: dict, questions_asked: list[str]) -> Optional[str]:
    """
    Rule-based part of question selection (no LLM): the next patient-info
    question (name, age, ...) that is neither filled nor already asked.
    Returns None when the AI should choose the next clinical question.
    """
    from .model_c_rules import PATIENT_INFO_QUESTIONS
    lang = extraction.get("language", "kinyarwanda")
    info_questions = PATIENT_INFO_QUESTIONS.get(lang, PATIENT_INFO_QUESTIONS["kinyarwanda"])
    for q in info_questions:
        # Skip if already filled OR already asked (don't repeat even if extraction lost the value)
        if not extraction.get(q["targets"]) and q["question"] not in questions_asked:
            return q["question"]
    return None


def fallback_question(language: str) -> str:
    """Generic question used when the AI question cannot be generated."""
    if language == "kinyarwanda":
        return "Mbwira byinshi ku bibazo byawe?"
    return "Can you tell me more about how you are feeling?"


def question_context(extraction: dict, questions_asked: list[str],
                     patient_answers: list[str]) -> dict:
    """
    Everything a client needs to build the Model C prompt itself
    (hybrid flow: the question is generated in the browser).
    """
    return {
        "system_instruction": _SYSTEM,
        "known": {k: v for k, v in extraction.items() if v},
        "history": [{"question": q, "answer": a} for q, a in zip(questions_asked, patient_answers)],
        "stage": _stage(len(questions_asked)),
        "red_flag_active": bool(extraction.get("red_flags_present")),
        "red_flag_followups": RED_FLAG_FOLLOWUPS,
        "coverage_checklist": COVERAGE_CHECKLIST,
        "language": extraction.get("language", "kinyarwanda"),
    }


def clean_question(raw: str) -> str:
    """Normalise a generated question: strip 'Question:' prefixes, ensure '?'."""
    question = re.sub(r"^(question|q)[:\-]?\s*", "", (raw or "").strip(), flags=re.IGNORECASE)
    question = question.strip().strip('"').strip()
    if question and not question.endswith("?"):
        question += "?"
    return question


def select_next_question(extraction: dict, questions_asked: list[str],
                         patient_answers: list[str]) -> str:
    """
    Select the single best next question given the current session state.

    Args:
        extraction      : Model B extraction dict.
        questions_asked : Questions already asked this session.
        patient_answers : Corresponding patient answers.

    Returns:
        Question string ready to speak to the patient.
    """
    # Always ask patient info first if missing
    rule_question = next_rule_question(extraction, questions_asked)
    if rule_question:
        return rule_question

    # After patient info, proceed as before
    system_prompt = _SYSTEM
    known = [f"{k}: {v}" for k, v in extraction.items() if v]

    history_lines = "\n".join(
        f"  Q: {q}\n  A: {a}"
        for q, a in zip(questions_asked, patient_answers)
    ) or "  (none)"

    red_flag_block = ""
    if extraction.get("red_flags_present"):
        followups      = "\n".join(f"- {q}" for q in RED_FLAG_FOLLOWUPS)
        red_flag_block = f"\nRED FLAG ACTIVE. Prioritise these:\n{followups}\n"

    coverage = "\n".join(f"- {c}" for c in COVERAGE_CHECKLIST)

    prompt = f"""Patient state:
{chr(10).join(f'- {k}' for k in known) or '- (unknown)'}

Conversation so far:
{history_lines}

Stage: {_stage(len(questions_asked))}
{red_flag_block}
Coverage checklist (must be addressed eventually):
{coverage}

Output the single best next question."""

    full_prompt = f"""{system_prompt}

Understood. One question only.

{prompt}"""
    
    try:
        response = generate_with_fallback(
            _get_client(),
            contents=full_prompt,
            config={
                'temperature': 0.2,
                'max_output_tokens': 100,
                'thinking_config': {'thinking_budget': 0},
            }
        )
        return clean_question(response.text)
    except Exception as e:
        print(f"Warning: All Gemini models failed in model_c: {e}. Using fallback question.")
        return fallback_question(extraction.get("language", "kinyarwanda"))


def is_coverage_complete(extraction: dict, num_turns: int, max_turns: int) -> bool:
    """
    Return True when the session has collected enough information to proceed.
    Coverage is complete when all key fields are filled OR max_turns is reached.
    """
    key_fields = ["chief_complaint", "severity", "duration", "associated_symptoms"]
    all_filled  = all(extraction.get(f) for f in key_fields)
    return all_filled or num_turns >= max_turns
