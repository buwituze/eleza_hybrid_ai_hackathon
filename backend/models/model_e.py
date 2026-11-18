"""
models/model_e.py — Patient-facing guidance message generator.
"""

import os
import re
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

_FALLBACK = {
    "english": {
        "HIGH":    "Your symptoms need prompt medical attention. Please proceed to the nearest staff member immediately. If you feel worse, notify a staff member right away.",
        "MEDIUM":  "Thank you for sharing your symptoms. A healthcare professional will see you shortly. Please take a seat and wait to be called. If your condition worsens, let a staff member know.",
        "LOW":     "Thank you. Your information has been recorded. Please wait and you will be called when it is your turn. If you have any concerns, speak to a staff member.",
        "UNKNOWN": "Thank you. Please wait while we complete the next step. A staff member will assist you shortly.",
    },
    "kinyarwanda": {
        "HIGH":    "Ibimenyetso byawe bisaba ubuvuzi bwihutirwa. Mwihangane, muzajya guturikirwa na muganga vuba. Niba imiterere yawe ihinduka, menyesha umukozi vuba.",
        "MEDIUM":  "Murakoze gushiraho ibimenyetso byanyu. Muganga azababona vuba. Mwicare mukomeze gutegereza. Niba hari impinduka, menyesha umukozi.",
        "LOW":     "Murakoze. Amakuru yanyu yanditswe. Mwicare mukomeze gutegereza. Niba mufite ibibazo, mubwire umukozi.",
        "UNKNOWN": "Murakoze gutanga amakuru. Mwihangane turangije intambwe ikurikira. Umukozi azabafasha vuba.",
    },
}

_FORBIDDEN = [
    "you have", "you may have", "this is", "this could be", "diagnosis",
    "heart attack", "stroke", "cancer", "infection",
    "medication", "rest", "drink water", "avoid",
    "life-threatening", "critical",
]
# Matched as whole words/phrases (plain substring matching rejected safe text,
# e.g. "rest" in "interest"). "take" alone used to reject "please take a seat"
# — the model's own example — so it is only forbidden with a medicine word.
_FORBIDDEN_RE = re.compile(
    r"\b(?:" + "|".join(re.escape(p) for p in _FORBIDDEN) + r")\b"
    r"|\btake\s+(?:\w+\s+)?(?:medicines?|medications?|pills?|tablets?|"
    r"painkillers?|paracetamol|aspirin|antibiotics?|drugs?)\b",
    re.IGNORECASE,
)


def contains_forbidden(text: str) -> bool:
    """True if a patient message contains diagnosis/advice language."""
    return bool(_FORBIDDEN_RE.search(text or ""))

_SYSTEM = """You are a healthcare system assistant in a hospital.
Explain the next steps to a patient using only the system's decision.
Rules:
- No disease names. No diagnosis. No medical advice. No causes.
- Do not change the priority level.
- 3 to 5 short sentences. Calm and clear.
- Output the patient message only.
- IMPORTANT: Output in the language specified in the Language field. If Language is kinyarwanda, respond entirely in Kinyarwanda."""

_FEW_SHOT = [
    {"role": "user",  "parts": ["Priority: HIGH\nComplaint: chest pain\nLocation: Emergency, Desk 3\nLanguage: english"]},
    {"role": "model", "parts": ["Your symptoms need prompt medical attention. Please proceed to Emergency, Desk 3 right away. A healthcare professional will see you shortly. If you feel worse at any time, please notify a staff member immediately."]},
    {"role": "user",  "parts": ["Priority: HIGH\nComplaint: ububabare bw'igituza\nLocation: Emergency, Desk 3\nLanguage: kinyarwanda"]},
    {"role": "model", "parts": ["Ibimenyetso byawe bisaba ubuvuzi bwihutirwa. Nyamuneka jya kuri Emergency, Desk 3 vuba. Umuganga azakureba vuba. Niba wumvise ko ibintu birushijeho kuba bibi, menyesha umukozi uhari ako kanya."]},
    {"role": "user",  "parts": ["Priority: MEDIUM\nComplaint: headache\nLocation: Waiting Area B\nLanguage: english"]},
    {"role": "model", "parts": ["Thank you for sharing your information. Please take a seat in Waiting Area B and a healthcare professional will see you soon. If your condition changes while you wait, please let a staff member know."]},
    {"role": "user",  "parts": ["Priority: LOW\nComplaint: sore throat\nLocation: General Outpatient\nLanguage: english"]},
    {"role": "model", "parts": ["Thank you. Your information has been recorded. Please wait in the General Outpatient area and you will be called when it is your turn."]},
]


def generate_message(extraction: dict, score: dict, language: str = "english",
                     location: str = "", low_confidence: bool = False) -> str:
    """
    Generate a patient-facing guidance message.

    Args:
        extraction    : Model B extraction dict.
        score         : Model D score dict.
        language      : 'english' or 'kinyarwanda'.
        location      : Where the patient should go (e.g. 'Emergency, Desk 3').
        low_confidence: If True, return the UNKNOWN fallback immediately.

    Returns:
        Message string ready to speak to the patient.
    """
    priority  = score.get("priority", "UNKNOWN").upper()
    templates = _FALLBACK.get(language, _FALLBACK["english"])

    if low_confidence or priority not in ("HIGH", "MEDIUM", "LOW"):
        return templates["UNKNOWN"]

    rf = score.get("red_flags_present") or extraction.get("red_flags_present")
    prompt = "\n".join([
        f"Priority: {priority}",
        f"Complaint: {extraction.get('chief_complaint') or 'not specified'}",
        f"Duration: {extraction.get('duration') or 'not specified'}",
        f"Severity: {extraction.get('severity') or 'not specified'}",
        f"Red flag: {'yes' if rf else 'no'}",
        f"Location: {location or 'not specified'}",
        f"Language: {language}",
    ])

    try:
        # Construct few-shot examples as part of the prompt
        few_shot_text = "\n\n".join([
            f"Example:\n{ex['parts'][0]}" if ex['role'] == 'user' else f"Response: {ex['parts'][0]}"
            for ex in _FEW_SHOT
        ])
        
        full_prompt = f"""{_SYSTEM}

Understood. Patient message only, no diagnosis.

{few_shot_text}

Now generate for:
{prompt}"""
        
        response = generate_with_fallback(
            _get_client(),
            contents=full_prompt,
            config={
                'temperature': 0.3,
                'max_output_tokens': 200,
                'thinking_config': {'thinking_budget': 0},
            }
        )
        message  = response.text.strip()
    except Exception:
        return templates.get(priority, templates["UNKNOWN"])

    # Safety check — fall back if forbidden content detected
    if contains_forbidden(message):
        return templates.get(priority, templates["UNKNOWN"])

    return message


def fallback_message(language: str, priority: str) -> str:
    """Safe template message for a priority (no model)."""
    templates = _FALLBACK.get(language, _FALLBACK["english"])
    return templates.get(str(priority).upper(), templates["UNKNOWN"])


def vet_message(message: str, language: str, priority: str,
                low_confidence: bool = False) -> tuple[str, bool]:
    """
    Apply the same guardrails as generate_message() to a message produced
    elsewhere (e.g. in the browser via Firebase AI Logic).
    Returns (message_to_use, used_fallback).
    """
    text = (message or "").strip()
    if (low_confidence or str(priority).upper() not in ("HIGH", "MEDIUM", "LOW")
            or not text or len(text) > 1000
            or contains_forbidden(text)):
        if low_confidence:
            return _FALLBACK.get(language, _FALLBACK["english"])["UNKNOWN"], True
        return fallback_message(language, priority), True
    return text, False

# Wrapper for notebook compatibility
def generate_guidance(extraction: dict, score: dict, language: str = "english", location: str = "") -> dict:
    """Wrapper that returns dict with 'message' key for notebook compatibility."""
    message_text = generate_message(extraction, score, language, location)
    return {"message": message_text}
