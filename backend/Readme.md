# Eleza backend (FastAPI)

The backend is the **trusted half** of Eleza. Language AI runs in the kiosk's browser through Firebase AI Logic (on-device Gemini Nano or cloud Gemini — see the [main README](../README.md)). The backend does what a browser must not be trusted with:

- **Speech-to-text** with Whisper (English + a Kinyarwanda fine-tuned model) on a GPU.
- **Session flow:** rule-based questions, coverage tracking, deciding when the browser should generate an AI question.
- **Validation and safety rules** on every AI result: field whitelisting, keyword red-flag check, forced HIGH priority for red flags and high severity, patient-message vetting.
- **Triage thresholds from Firebase Remote Config** (server template, Firebase Admin SDK).
- **Routing, queues, persistence** (PostgreSQL), **SMS** (Twilio), staff **auth** (JWT), and the **text-to-speech proxy** (ElevenLabs key stays on the server).

## Kiosk API (hybrid flow)

| Endpoint | Purpose |
|---|---|
| `POST /kiosk/start` | Create the patient + session; returns a greeting |
| `POST /kiosk/{id}/transcribe` | Upload a WAV answer → Whisper transcript (+ the question it answers, and how that question was generated) |
| `POST /kiosk/{id}/extraction` | Store the browser's extraction (validated, red flags re-checked) → next rule question, *or* the context for the browser to generate one, *or* "coverage complete" |
| `POST /kiosk/{id}/score` | Store the browser's triage score → safety rules applied → department, queue number, location |
| `POST /kiosk/{id}/complete` | Store the patient message (vetted) and doctor brief → persist, queue, SMS |
| `POST /tts` | Text-to-speech proxy (ElevenLabs) |
| `GET /startup/status` | Whisper loaded? database connected? Remote Config values and their source |

Every request that carries an AI result also carries its **trace** (`on_device` / `in_cloud`, mode, latency, fallback reason). Traces are stored with the doctor brief together with an `ai_summary`.

Staff endpoints (`/auth`, `/doctor`, `/patients`, `/doctors`, `/facilities`, `/rooms`, `/queue`) serve the doctor and admin dashboards. Full list: Swagger UI at `/docs`.

Code map: [`routers/kiosk_hybrid.py`](routers/kiosk_hybrid.py) (hybrid contract) · [`models/model_d.py`](models/model_d.py) (`apply_safety_rules`) · [`models/model_e.py`](models/model_e.py) (`vet_message`) · [`models/model_c_rules.py`](models/model_c_rules.py) (question trees) · [`server_config.py`](server_config.py) (Remote Config) · [`routing/queue_routing.py`](routing/queue_routing.py) (departments, queues) · [`models/model_a.py`](models/model_a.py) (Whisper).

## Safety rules (cannot be overridden by any model)

| Rule | Where |
|---|---|
| Keyword red-flag check on the patient's own words | `model_b._detect_red_flags` |
| Confirmed severe red flag → deterministic HIGH score | `model_d.severe_red_flag_score` |
| Any red flag → priority HIGH | `model_d.apply_safety_rules` |
| Patient-reported severity ≥ `triage_high_severity_min` (default 8) → HIGH | `model_d.apply_safety_rules` |
| Confidence < `triage_low_confidence_threshold` (default 0.4) → safe template message | `routers/kiosk_hybrid.py` |
| Patient message containing diagnosis or treatment advice → safe template | `model_e.vet_message` |

The doctor sees when a rule changed the priority ("Triage Safety Rule").

## Remote Config (server template)

| Parameter | Default | Allowed range |
|---|---|---|
| `triage_low_confidence_threshold` | 0.4 | 0 – 0.9 |
| `triage_max_turns` | `MAX_TURNS` env (8) | 3 – 15 |
| `triage_high_severity_min` | 8 | 5 – 10 |

Read with the Firebase Admin SDK when the server starts and every `REMOTE_CONFIG_REFRESH_SECONDS` (300). Without credentials, or if Firebase is unreachable, the defaults apply. Out-of-range values are clamped, so a typo can't switch a safety rule off. Template to upload: [`../firebase/remote-config/server-template.json`](../firebase/remote-config/server-template.json).

## Run it

Whisper large-v3 needs a **GPU** (on CPU one answer takes minutes) and ~6 GB of disk for the two models, downloaded on first start.

### Option A — Google Colab (free T4)
Open [`colab-test.ipynb`](colab-test.ipynb) in Colab, select a **T4 GPU**, add the secrets listed in its first cell, set `REPO_BRANCH`, then **Runtime → Run all**. It installs dependencies, prepares the database, starts the API in the background and prints a public ngrok URL. Steps 7–9 show readiness, logs, and stop the server.

### Optional — Modal (always-on hosting)
[`modal_app.py`](modal_app.py) runs the same app on a Modal T4 GPU that sleeps when idle, with the Whisper download cached between cold starts. It is not used unless you deploy it; Colab remains the default. Setup steps are at the top of the file: create a Modal secret `eleza-backend` with the same values as the Colab secrets, run `modal deploy modal_app.py`, then point the frontend's `API_BASE_URL` at the URL it prints.

### Option B — local
```bash
python -m venv venv && source venv/bin/activate      # Windows: .\venv\Scripts\Activate.ps1
cd backend
pip install -r requirements.txt
cp .env.example .env                                  # fill in the variables below
python setup_db.py                                    # tables + demo accounts (if DEMO_PASSWORD is set)
uvicorn main:app --port 8000
```
Then open `http://localhost:8000/docs` and `http://localhost:8000/startup/status`.

## Environment variables

Set them in `backend/.env` (git-ignored; template in [`.env.example`](.env.example)) or as Colab secrets. **Never commit real values.**

**Required**

| Variable | Description |
|---|---|
| `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | PostgreSQL connection. For Neon also set `PGSSLMODE=require` (the Colab notebook does this automatically). |
| `HF_TOKEN` | Hugging Face read token (Whisper downloads) |
| `JWT_SECRET_KEY` | Long random string for staff login tokens |
| `ELEVENLABS_API_KEY` | Kiosk voice via `POST /tts` (without it the kiosk is silent) |

**Optional**

| Variable | Default | Description |
|---|---|---|
| `FIREBASE_SERVICE_ACCOUNT_JSON` / `GOOGLE_APPLICATION_CREDENTIALS` | — | Service-account JSON (or a path to it) for server-side Remote Config. Without it, default thresholds. |
| `REMOTE_CONFIG_REFRESH_SECONDS` | `300` | How often to re-read Remote Config |
| `DEMO_PASSWORD` | — | Used by `setup_db.py` to create the demo accounts |
| `DEVICE` | `cpu` | `cuda` on a GPU |
| `MAX_TURNS` | `8` | Default question limit (Remote Config overrides it) |
| `SKIP_LANG_DETECTION_WHEN_HINTED` | `false` | Trust the language chosen on the kiosk |
| `USE_DB` | `true` | `false` runs without a database (kiosk sessions can't start) |
| `AUDIO_STORAGE_DIR` | `data/audio` | Where answer recordings are stored |
| `ELEVENLABS_VOICE_ID`, `ELEVENLABS_MODEL_ID` | built-in | Voice overrides |
| `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER` | — | SMS with the queue assignment (skipped if unset) |
| `EMAIL_PROVIDER` (`smtp`/`emailjs`) + `SMTP_*` / `EMAILJS_*` | — | Credential emails for new staff accounts |
| `GEMINI_API_KEY` | — | Only for the legacy server-side endpoints (`/dialogue`, `/triage`) and `evaluate_system.py`; the kiosk doesn't use it |

## Database

PostgreSQL. **Use [`setup_db.py`](setup_db.py)** rather than running `schema.sql` by hand: on an empty database it creates the tables, applies the migrations in the right order (some views depend on migrated columns), then creates the demo data if `DEMO_PASSWORD` is set:

| Account | Role |
|---|---|
| `platform.admin@eleza.demo` | platform admin (manages facilities and admins; sees AI processing per session) |
| `hospital.admin@eleza.demo` | hospital admin of *Eleza Demo Hospital* |
| `doctor@eleza.demo` | doctor at *Eleza Demo Hospital* |

It is safe to run repeatedly: existing tables and accounts are left untouched. Connections dropped by serverless databases after idle periods (e.g. Neon) are detected and replaced automatically.

Main tables: `users`, `facility`, `patient`, `session`, `conversation_message`, `symptom`, `prediction`, `examination_queue`, `audio_recording`, `room`, `healthcare_worker`. Schema: [`database/schema.sql`](database/schema.sql) + [`database/migrations/`](database/migrations/).

## Testing

| What | How |
|---|---|
| Readiness | `GET /startup/status` → `models_ready`, `database_ready`, `remote_config` |
| API by hand | Swagger UI at `/docs` |
| Database setup | `python setup_db.py` twice — second run reports "already exists" |
| Auth helpers | `python -m pytest test_unit_basic.py -v` |
| Whisper | `python test_whisper.py <audio.wav> [--language kinyarwanda]` |

**End-to-end checklist** (used before each release; run with the frontend):

1. **English session** — headache since yesterday; answer name/age/gender/phone/location; follow-up questions make sense; completion screen shows queue number, department and location.
2. **Kinyarwanda session** — questions and the final message are in Kinyarwanda; translation steps run in the cloud.
3. **Red flag** — *"I have chest pain and I can't breathe"* → Emergency / Urgent, even if the model scored lower.
4. **Severity rule** — *"seven out of ten"* with `triage_high_severity_min = 7` in Remote Config → HIGH, and the doctor page explains the rule.
5. **Doctor view** — brief, red-flag notes, transcript, audio; a returning patient (same name + phone) shows two visits.
6. **Idle database** — leave the backend unused for 10 minutes, then start a session: it works.

## Project structure

```
backend/
├── main.py              FastAPI app, startup (Whisper, database, Remote Config)
├── server_config.py     Server-side Remote Config (triage thresholds)
├── setup_db.py          Fresh-database setup + demo accounts
├── session.py           In-memory session state
├── routers/             kiosk_hybrid (hybrid kiosk flow), kiosk (start/status, persistence),
│                        tts, auth, doctor, patients, doctors, facilities, rooms, queue, …
├── models/              model_a (Whisper), model_b–f (validation, rules, templates), model_c_rules
├── routing/             Departments, queues, location hints
├── database/            Connection pool + queries, schema.sql, migrations/
├── utils/               SMS (Twilio), email, session logger
└── colab-test.ipynb     Run the backend on a free Colab GPU
```
