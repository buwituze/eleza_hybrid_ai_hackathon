"""
OPTIONAL: run the Eleza backend on Modal (https://modal.com) instead of Colab.

The Colab notebook (colab-test.ipynb) stays the default way to run the backend.
This file is only used if you deploy to Modal; nothing else imports it.

What it does: serves the same FastAPI app (main.py) on a T4 GPU that scales to
zero when idle, so credit is only used while someone is using the app. Whisper
downloads are cached in a Modal Volume, so later cold starts skip the ~6 GB
download (loading still takes 1-2 minutes).

One-time setup (requires a Modal account):
  1. pip install modal  &&  modal setup
  2. Create a secret named "eleza-backend" in the Modal dashboard
     (Secrets → Custom) with the same values the Colab notebook uses:
       HF_TOKEN, ELEVENLABS_API_KEY, JWT_SECRET_KEY,
       DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD, PGSSLMODE=require,
       FIREBASE_SERVICE_ACCOUNT_JSON (optional)
  3. From the backend folder:  modal deploy modal_app.py
     It prints a URL like https://<workspace>--eleza-backend-fastapi-app.modal.run
  4. Put that URL in frontend/firebase.env.prod.json as API_BASE_URL,
     rebuild and redeploy the frontend.
"""
from pathlib import Path

import modal

BACKEND_DIR = Path(__file__).parent

image = (
    modal.Image.debian_slim(python_version="3.11")
    .apt_install("ffmpeg", "libsndfile1")
    .pip_install_from_requirements(str(BACKEND_DIR / "requirements.txt"))
    .env({
        "DEVICE": "cuda",
        "USE_DB": "true",
        "MAX_TURNS": "10",
        "SKIP_LANG_DETECTION_WHEN_HINTED": "true",
        "HF_HOME": "/cache/huggingface",
    })
    # Backend source code, added last so code changes don't rebuild the image.
    .add_local_dir(
        BACKEND_DIR,
        remote_path="/root/backend",
        ignore=["**/__pycache__/**", "**/.env", "data/**", "*.ipynb", "venv/**"],
    )
)

# Whisper weights survive between containers (no 6 GB download on every cold start).
model_cache = modal.Volume.from_name("eleza-model-cache", create_if_missing=True)

app = modal.App("eleza-backend")


@app.function(
    image=image,
    gpu="T4",
    secrets=[modal.Secret.from_name("eleza-backend")],
    volumes={"/cache": model_cache},
    timeout=900,            # per request; long enough for a slow first transcription
    scaledown_window=300,   # stay warm 5 minutes after the last request, then sleep
    min_containers=0,       # scale to zero: no cost while nobody uses the app
    max_containers=1,       # one GPU at most, so spending stays predictable
)
@modal.concurrent(max_inputs=20)
@modal.asgi_app()
def fastapi_app():
    import os
    import sys

    os.chdir("/root/backend")
    sys.path.insert(0, "/root/backend")
    from main import app as web_app  # the same FastAPI app the notebook runs

    return web_app
