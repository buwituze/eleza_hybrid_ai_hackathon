"""
routers/tts.py — Text-to-speech proxy for the kiosk.

POST /tts  {"text": "...", "language": "english" | "kinyarwanda"}
  → audio/mpeg bytes from ElevenLabs

Keeps the ElevenLabs API key on the server. Previously the Flutter web app
called ElevenLabs directly, which shipped the key inside the public web build.
"""

import asyncio
import os
from typing import Optional

import requests
from fastapi import APIRouter, HTTPException, Response
from pydantic import BaseModel, Field

router = APIRouter(prefix="/tts", tags=["tts"])

# "Benitha - Rwandan Nurse 1" — handles both Kinyarwanda and English.
_DEFAULT_VOICE_ID = "cYewvtoDtKjvFBC0o8AH"
_DEFAULT_MODEL_ID = "eleven_flash_v2_5"
_TIMEOUT_SECONDS = 30
# Kiosk prompts are short; the cap stops the endpoint being used to burn credits.
_MAX_CHARS = 1000


class TTSRequest(BaseModel):
    text: str = Field(..., min_length=1, max_length=_MAX_CHARS)
    language: Optional[str] = None  # informational; the voice is bilingual


def _synthesize(text: str) -> bytes:
    api_key = os.getenv("ELEVENLABS_API_KEY", "").strip()
    if not api_key:
        raise HTTPException(status_code=503, detail="TTS is not configured (ELEVENLABS_API_KEY missing).")

    voice_id = os.getenv("ELEVENLABS_VOICE_ID", _DEFAULT_VOICE_ID)
    model_id = os.getenv("ELEVENLABS_MODEL_ID", _DEFAULT_MODEL_ID)

    try:
        resp = requests.post(
            f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}",
            headers={
                "xi-api-key": api_key,
                "Content-Type": "application/json",
                "Accept": "audio/mpeg",
            },
            json={
                "text": text,
                "model_id": model_id,
                "voice_settings": {"stability": 0.50},
            },
            timeout=_TIMEOUT_SECONDS,
        )
    except requests.RequestException as e:
        raise HTTPException(status_code=502, detail=f"TTS provider unreachable: {type(e).__name__}")

    if resp.status_code != 200:
        # Don't forward the provider body; it can echo account details.
        print(f"[tts] ElevenLabs error {resp.status_code}: {resp.text[:300]!r}")
        raise HTTPException(status_code=502, detail=f"TTS provider error ({resp.status_code}).")

    return resp.content


@router.post("", response_class=Response)
async def text_to_speech(body: TTSRequest):
    text = body.text.strip()
    if not text:
        raise HTTPException(status_code=422, detail="text must not be blank.")
    audio = await asyncio.to_thread(_synthesize, text)
    return Response(content=audio, media_type="audio/mpeg", headers={"Cache-Control": "no-store"})
