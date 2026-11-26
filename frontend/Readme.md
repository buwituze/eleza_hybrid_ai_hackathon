# Eleza frontend (Flutter web)

One Flutter app with three faces, chosen on first launch (*"What will this device be used for?"*):

- **Patient kiosk** (`/#/voice-interface`): voice-only, Kinyarwanda or English. The patient presses one button and talks, and Eleza speaks back.
- **Healthcare provider** (`/#/login`): doctor dashboard (patients, structured briefs, transcript and audio, rooms) plus hospital-admin and platform-admin views.
- **AI smoke test** (`/#/ai-smoke-test`, debug builds only): runs every AI step and shows where it ran.

The hackathon build targets **Chrome desktop (139+)**, where Gemini Nano is available through Firebase AI Logic.

## How the AI is wired

```
Flutter (Dart)                         Browser (JS)                    Firebase
───────────────────────────────────    ────────────────────────────    ─────────────────────
voice_interface_page.dart
  └─ HybridKioskSession                 web/eleza_ai.js
       └─ ClinicalAI (7 steps) ──────▶  window.elezaAI.generate() ──▶  AI Logic
            └─ HybridAIService           getGenerativeModel(             ├─ Gemini Nano (on-device)
               (dart:js_interop)          {mode, onDeviceParams,         └─ Gemini (cloud)
                                           inCloudParams})               App Check · Remote Config
```

| File | Role |
|---|---|
| [`web/eleza_ai.js`](web/eleza_ai.js) | Firebase AI Logic **hybrid** calls (JS SDK): modes, on-device deadline + abort, cool-down, structured output, `inferenceSource`. Shares FlutterFire's Firebase app, so App Check applies. |
| [`lib/services/hybrid_ai_service.dart`](lib/services/hybrid_ai_service.dart) | Typed Dart API over the bridge (`generate`, Nano availability / download, results with source and latency). |
| [`lib/services/clinical_ai.dart`](lib/services/clinical_ai.dart) | The 7 clinical steps (translation, extraction, question, score, routing, patient message, doctor brief): prompts, JSON schemas, per-step mode (`ClinicalAIConfig.modeFor`). |
| [`lib/services/clinical_prompts.dart`](lib/services/clinical_prompts.dart) | Default prompts, each overridable from Remote Config. |
| [`lib/services/hybrid_kiosk_flow.dart`](lib/services/hybrid_kiosk_flow.dart) | One patient session: transcribe → translate → extract → ask … → score → message + brief → complete. Keeps an English copy of the conversation so on-device steps never see Kinyarwanda. |
| [`lib/services/app_config.dart`](lib/services/app_config.dart) | Remote Config with in-app defaults (fetch waits at most 5 s at startup). |
| [`lib/components/ai_badges.dart`](lib/components/ai_badges.dart) | On-device / Cloud badges and the Nano status chip. |
| [`lib/main.dart`](lib/main.dart) | Firebase init → **App Check** (debug provider locally, reCAPTCHA in release) → Remote Config. |

Why the JS bridge: the FlutterFire `firebase_ai` package doesn't offer hybrid/on-device inference yet; the Firebase JS SDK does.

## Setup

**Prerequisites:** Flutter (Dart ≥ 3.7), Chrome 139+, a running backend ([backend/Readme.md](../backend/Readme.md)), and a Firebase project with AI Logic (Gemini Developer API), App Check and a Web app.

1. **Config file.** Copy [`firebase.env.example.json`](firebase.env.example.json) to `firebase.env.json` (git-ignored) and fill it in:

   | Key | Value |
   |---|---|
   | `FIREBASE_API_KEY`, `FIREBASE_APP_ID`, `FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_PROJECT_ID`, `FIREBASE_AUTH_DOMAIN`, `FIREBASE_STORAGE_BUCKET`, `FIREBASE_MEASUREMENT_ID` | From Firebase console → Project settings → Your apps → Web app |
   | `APPCHECK_DEBUG_TOKEN` | A UUID you also add under App Check → Apps → three-dot menu → *Manage debug tokens* |
   | `RECAPTCHA_ENTERPRISE_SITE_KEY` | Fraud Defense (reCAPTCHA Enterprise) key, used by App Check in release (hosted) builds. Leave empty locally |
   | `RECAPTCHA_V3_SITE_KEY` | Alternative: reCAPTCHA v3 site key (only for projects that already have v3 registered in App Check) |
   | `API_BASE_URL` | Backend URL, e.g. `http://localhost:8000` or the Colab ngrok URL (no trailing `/`) |

2. **Run:**
   ```bash
   flutter pub get
   flutter run -d chrome --dart-define-from-file=firebase.env.json
   # or serve for your normal Chrome profile (the one with the Nano flag):
   flutter run -d web-server --web-port 5000 --dart-define-from-file=firebase.env.json
   ```

3. **Gemini Nano (optional):** `chrome://flags/#prompt-api-for-gemini-nano-multimodal-input` → *Enabled* → relaunch. The smoke-test page has a **Download Nano** button. Without Nano, every step uses the cloud.

4. **Release build:**
   ```bash
   flutter build web --release --dart-define-from-file=firebase.env.json
   ```

Secrets stay out of the repo: the Firebase config comes from `firebase.env.json` at build time, and text-to-speech goes through the backend's `/tts`, so the ElevenLabs key never reaches the browser.

## Remote Config parameters (client template)

| Parameter | Type | Default | Effect |
|---|---|---|---|
| `ai_mode_extraction`, `ai_mode_question`, `ai_mode_guidance`, `ai_mode_brief` | String | `prefer_on_device` | Where each step runs: `prefer_on_device` · `only_on_device` · `prefer_in_cloud` · `only_in_cloud` |
| `ai_mode_score`, `ai_mode_routing` | String | `prefer_in_cloud` | Same, for the safety-critical steps |
| `ai_on_device_timeout_ms` | Number | `12000` | How long Nano gets before the cloud answers (1 s – 2 min) |
| `ai_slow_device_cooldown_ms` | Number | `300000` | After a timeout, skip Nano for this long (0 – 1 h) |
| `kiosk_show_ai_details` | Boolean | `false` | Show On-device / Cloud indicators on the kiosk (demos, judging) |
| `prompt_*` | String | built-in | Override any of the 8 prompts (blank or > 8,000 chars → default) |
| `config_version` | String | `in-app defaults` | Shown on the smoke page to confirm the console is being read |

Locked in code, whatever the console says: translation always runs in the cloud, and in Kinyarwanda sessions the follow-up questions and patient message run in the cloud (Gemini Nano is English-only). Template: [`../firebase/remote-config/client-template.json`](../firebase/remote-config/client-template.json).

## Testing

- **`/#/ai-smoke-test`** (debug build): **Run all** executes every clinical step and shows `source: on_device / in_cloud`, latency and fallback reason, plus the active Remote Config values. The reset button resets the "device too slow" cool-down.
- **Kiosk session:** with `kiosk_show_ai_details` on, each step shows a live badge, and the completion screen lists how every step was processed.
- **Browser console:** `[elezaAI]` lines explain every fallback, e.g. `on-device took >12000ms — using cloud`. `Nano warm-up done in … ms` confirms the warm-up.
- **Static checks:** `flutter analyze`.

## Other details

- **Languages:** UI strings in [`assets/translations/`](assets/translations/) (`en.json`, `rw.json`).
- **Audio:** recorded as WAV in the browser (`record` package) and uploaded to `/kiosk/{id}/transcribe`.
- **Voice:** `lib/services/tts_service.dart` calls the backend `/tts` proxy (ElevenLabs).
- **Roles:** `doctor`, `hospital_admin`, `platform_admin`. Only the platform admin sees the per-session AI processing trace; doctors see clinical information.
