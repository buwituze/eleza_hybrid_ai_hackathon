"""
Server-side Firebase Remote Config for thresholds the backend enforces.

Triage thresholds are safety rules, so they are read here (Firebase Admin SDK,
Remote Config *server* template) and never taken from the browser.

Every parameter has a default in DEFAULTS. Without Firebase credentials, or if
the fetch fails, the backend runs on those defaults. Values are clamped to safe
ranges, so a typo in the console cannot disable a guardrail.

Credentials (never commit them; see .env.example):
  FIREBASE_SERVICE_ACCOUNT_JSON   the service-account JSON itself (Kaggle/Colab secret)
  GOOGLE_APPLICATION_CREDENTIALS  or a path to the JSON file (local)
"""
import asyncio
import json
import os
import time
from typing import Optional

LOW_CONFIDENCE_THRESHOLD = "triage_low_confidence_threshold"
MAX_TURNS = "triage_max_turns"
HIGH_SEVERITY_MIN = "triage_high_severity_min"

# Remote Config server templates take string defaults.
DEFAULTS: dict[str, str] = {
    # Model D confidence below this → patient gets the safe template message
    # and the doctor brief is flagged as low confidence.
    LOW_CONFIDENCE_THRESHOLD: "0.4",
    # Maximum questions the kiosk asks before scoring.
    MAX_TURNS: os.getenv("MAX_TURNS", "8"),
    # Patient-reported severity (0-10) at or above this forces priority HIGH.
    HIGH_SEVERITY_MIN: "8",
}

# (min, max) allowed for each value.
_LIMITS = {
    LOW_CONFIDENCE_THRESHOLD: (0.0, 0.9),
    MAX_TURNS: (3, 15),
    HIGH_SEVERITY_MIN: (5, 10),
}

_config = None          # firebase_admin.remote_config.ServerConfig once loaded
_status = "defaults (not loaded yet)"
_loaded_at: Optional[float] = None


def _init_firebase_app() -> bool:
    """Initialise the default Firebase Admin app once. False if no credentials."""
    import firebase_admin
    from firebase_admin import credentials

    if firebase_admin._apps:
        return True
    raw_json = os.getenv("FIREBASE_SERVICE_ACCOUNT_JSON", "").strip()
    if raw_json:
        cred = credentials.Certificate(json.loads(raw_json))
    elif os.getenv("GOOGLE_APPLICATION_CREDENTIALS"):
        cred = credentials.Certificate(os.environ["GOOGLE_APPLICATION_CREDENTIALS"])
    else:
        return False
    firebase_admin.initialize_app(cred)
    return True


async def load() -> None:
    """Fetch the server template. Never raises; keeps the last good values."""
    global _config, _status, _loaded_at
    try:
        if not _init_firebase_app():
            _status = "defaults (no Firebase credentials)"
            return
        from firebase_admin import remote_config

        template = await asyncio.wait_for(
            remote_config.get_server_template(default_config=DEFAULTS), timeout=10
        )
        _config = template.evaluate()
        _loaded_at = time.time()
        _status = "loaded"
        print(f"Remote Config (server) loaded: {snapshot()['values']}")
    except Exception as e:  # network, permissions, bad JSON …
        _status = f"{'last good values' if _config else 'defaults'} (load failed: {type(e).__name__})"
        print(f"Remote Config (server) not loaded, using {_status}: {e}")


async def refresh_forever(interval_seconds: int) -> None:
    """Background task: reload every interval so console changes apply without a restart."""
    while True:
        await asyncio.sleep(interval_seconds)
        await load()


def _raw(key: str) -> str:
    if _config is not None:
        try:
            return _config.get_string(key)
        except Exception:
            pass
    return DEFAULTS[key]


def _source(key: str) -> str:
    if _config is None:
        return "default"
    try:
        return str(_config.get_value_source(key))
    except Exception:
        return "default"


def _number(key: str) -> float:
    low, high = _LIMITS[key]
    try:
        value = float(_raw(key))
    except (TypeError, ValueError):
        value = float(DEFAULTS[key])
    return min(max(value, low), high)


# ── typed accessors used by the routers ────────────────────────────────────

def low_confidence_threshold() -> float:
    return _number(LOW_CONFIDENCE_THRESHOLD)


def max_turns() -> int:
    return int(_number(MAX_TURNS))


def high_severity_min() -> int:
    return int(_number(HIGH_SEVERITY_MIN))


def snapshot() -> dict:
    """Current values and where they came from (for /startup/status)."""
    return {
        "status": _status,
        "loaded_at": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(_loaded_at)) if _loaded_at else None,
        "values": {
            LOW_CONFIDENCE_THRESHOLD: low_confidence_threshold(),
            MAX_TURNS: max_turns(),
            HIGH_SEVERITY_MIN: high_severity_min(),
        },
        "sources": {k: _source(k) for k in DEFAULTS},
    }
