// Eleza ⇄ Firebase AI Logic hybrid inference bridge.
//
// The Flutter `firebase_ai` package only supports cloud inference. Hybrid
// (on-device Gemini Nano in Chrome + cloud Gemini fallback) is only available
// in the Firebase JS SDK, so Dart calls this module through `window.elezaAI`.
//
// The SDK version MUST match the one FlutterFire loads
// (firebase_core_web → supportedFirebaseJsSdkVersion). Importing the same
// gstatic URLs makes the browser reuse FlutterFire's module instances, so
// getApp() returns the app initialized by Firebase.initializeApp() in
// main.dart, and App Check (once activated) covers these calls too.

import { getApp } from 'https://www.gstatic.com/firebasejs/13.1.0/firebase-app.js';
import {
  getAI,
  getGenerativeModel,
  GoogleAIBackend,
  InferenceMode,
} from 'https://www.gstatic.com/firebasejs/13.1.0/firebase-ai.js';

const SDK_VERSION = '13.1.0';
const DEFAULT_CLOUD_MODEL = 'gemini-3.5-flash-lite';

// Smart fallback for PREFER_ON_DEVICE (on top of the SDK's own "Nano not
// available → cloud" fallback): if Nano is too slow on this machine, cancel it
// and answer from the cloud, then skip Nano for a cool-down period so a slow
// device doesn't add the timeout to every step of a session.
const DEFAULT_ON_DEVICE_TIMEOUT_MS = 12000;
const DEFAULT_SLOW_DEVICE_COOLDOWN_MS = 5 * 60 * 1000;
let _deviceSlowUntil = 0;

// Gemini Nano is used for English only; Kinyarwanda is translated in the cloud
// before it reaches an on-device step.
const EN_TEXT = [{ type: 'text', languages: ['en'] }];

const VALID_MODES = new Set(Object.values(InferenceMode));

let _ai = null;

function ai() {
  if (!_ai) {
    // Throws "No Firebase App '[DEFAULT]'" if Firebase.initializeApp() has not
    // run yet (or if the SDK versions above drift from FlutterFire's).
    _ai = getAI(getApp(), { backend: new GoogleAIBackend() });
  }
  return _ai;
}

/**
 * Builds a hybrid GenerativeModel.
 * Cloud and on-device options must be configured separately: the SDK ignores
 * top-level config when a hybrid `mode` is set.
 */
function buildModel(req = {}, signal) {
  const mode = VALID_MODES.has(req.mode) ? req.mode : InferenceMode.PREFER_ON_DEVICE;

  const createOptions = { expectedInputs: EN_TEXT, expectedOutputs: EN_TEXT };
  if (req.systemInstruction) {
    createOptions.initialPrompts = [
      { role: 'system', content: [{ type: 'text', value: req.systemInstruction }] },
    ];
  }
  const promptOptions = {};
  if (req.jsonSchema) promptOptions.responseConstraint = req.jsonSchema; // Prompt API structured output
  if (signal) {
    // Lets a timed-out on-device prompt be cancelled (frees the CPU/GPU).
    createOptions.signal = signal;
    promptOptions.signal = signal;
  }
  const onDeviceParams = { createOptions, promptOptions };

  const generationConfig = {};
  if (req.jsonSchema) {
    generationConfig.responseMimeType = 'application/json';
    generationConfig.responseJsonSchema = req.jsonSchema;
  }
  if (typeof req.temperature === 'number') generationConfig.temperature = req.temperature;
  if (typeof req.maxOutputTokens === 'number') generationConfig.maxOutputTokens = req.maxOutputTokens;

  const inCloudParams = { model: req.cloudModel || DEFAULT_CLOUD_MODEL, generationConfig };
  if (req.systemInstruction) inCloudParams.systemInstruction = req.systemInstruction;

  return getGenerativeModel(ai(), { mode, onDeviceParams, inCloudParams });
}

/**
 * Status of the Chrome on-device model:
 * 'available' | 'downloadable' | 'downloading' | 'unavailable' | 'unsupported'
 * ('unsupported' = this browser has no Prompt API at all).
 */
async function onDeviceAvailability() {
  if (typeof globalThis.LanguageModel === 'undefined') return 'unsupported';
  try {
    return await globalThis.LanguageModel.availability({
      expectedInputs: EN_TEXT,
      expectedOutputs: EN_TEXT,
    });
  } catch (e) {
    console.warn('[elezaAI] availability check failed', e);
    return 'unavailable';
  }
}

/**
 * Starts downloading Gemini Nano if needed. Chrome requires this to be
 * triggered from a user gesture (e.g. the kiosk Start button).
 * onProgress receives a fraction 0..1.
 */
async function prepareOnDevice(onProgress) {
  const model = buildModel({ mode: InferenceMode.PREFER_ON_DEVICE });
  await model.initializeDeviceModel((loaded) => {
    if (typeof onProgress === 'function') onProgress(loaded);
  });
  return onDeviceAvailability();
}

async function runModel(req, mode, signal) {
  const model = buildModel({ ...req, mode }, signal);
  try {
    const result = await model.generateContent(req.prompt);
    return {
      text: result.response.text(),
      source: result.response.inferenceSource ?? 'in_cloud',
    };
  } finally {
    // The SDK keeps the last Prompt API session on its (per-model) adapter and
    // never destroys it; we build a model per call, so release it here to
    // avoid holding Nano sessions in memory for the whole kiosk session.
    try {
      model.chromeAdapter?.oldSession?.destroy?.();
    } catch (_) {
      /* already destroyed / aborted */
    }
  }
}

const TIMED_OUT = Symbol('timed_out');

/**
 * PREFER_ON_DEVICE with a deadline: Nano gets `timeoutMs` to answer; after
 * that (or on any Nano error) the same prompt goes to the cloud.
 * Returns { text, source, fallbackReason }.
 */
async function preferOnDeviceWithDeadline(req) {
  if (Date.now() < _deviceSlowUntil) {
    return { ...(await runModel(req, InferenceMode.ONLY_IN_CLOUD)), fallbackReason: 'device_slow' };
  }
  const availability = await onDeviceAvailability();
  if (availability !== 'available') {
    return { ...(await runModel(req, InferenceMode.ONLY_IN_CLOUD)), fallbackReason: 'device_unavailable' };
  }

  const timeoutMs = Number.isFinite(req.onDeviceTimeoutMs) ? req.onDeviceTimeoutMs : DEFAULT_ON_DEVICE_TIMEOUT_MS;
  const abort = new AbortController();
  let timer;
  const onDevice = runModel(req, InferenceMode.ONLY_ON_DEVICE, abort.signal);
  onDevice.catch(() => {}); // a late rejection after the timeout is expected
  const deadline = new Promise((resolve) => {
    timer = setTimeout(() => resolve(TIMED_OUT), timeoutMs);
  });

  let fallbackReason;
  try {
    const winner = await Promise.race([onDevice, deadline]);
    if (winner !== TIMED_OUT) return { ...winner, fallbackReason: null };
    fallbackReason = 'timeout';
    abort.abort();
    const cooldown = Number.isFinite(req.slowDeviceCooldownMs) ? req.slowDeviceCooldownMs : DEFAULT_SLOW_DEVICE_COOLDOWN_MS;
    _deviceSlowUntil = Date.now() + cooldown;
    console.warn(`[elezaAI] on-device took >${timeoutMs}ms — using cloud; skipping Nano for ${Math.round(cooldown / 1000)}s`);
  } catch (e) {
    fallbackReason = 'device_error';
    console.warn('[elezaAI] on-device failed — using cloud', e);
  } finally {
    clearTimeout(timer);
  }
  return { ...(await runModel(req, InferenceMode.ONLY_IN_CLOUD)), fallbackReason };
}

/**
 * Single-turn generation (on-device does not support chat).
 * req: { prompt, mode?, systemInstruction?, jsonSchema?, cloudModel?,
 *        temperature?, maxOutputTokens?, onDeviceTimeoutMs?, slowDeviceCooldownMs? }
 * Returns { text, source: 'on_device' | 'in_cloud', mode, latencyMs,
 *           fallbackReason: null | 'timeout' | 'device_error' | 'device_slow' | 'device_unavailable' }.
 * fallbackReason is only set for prefer_on_device requests that ended up in the cloud.
 */
async function generate(req) {
  if (!req || typeof req.prompt !== 'string' || !req.prompt.trim()) {
    throw new Error('[elezaAI] generate() needs a non-empty prompt');
  }
  const mode = VALID_MODES.has(req.mode) ? req.mode : InferenceMode.PREFER_ON_DEVICE;
  const started = performance.now();
  const result =
    mode === InferenceMode.PREFER_ON_DEVICE
      ? await preferOnDeviceWithDeadline(req)
      : { ...(await runModel(req, mode)), fallbackReason: null };
  return { ...result, mode, latencyMs: Math.round(performance.now() - started) };
}

/** Forget a previous "device too slow" verdict (e.g. after Nano warms up). */
function resetDeviceHealth() {
  _deviceSlowUntil = 0;
}

window.elezaAI = {
  sdkVersion: SDK_VERSION,
  modes: { ...InferenceMode },
  onDeviceAvailability,
  prepareOnDevice,
  generate,
  resetDeviceHealth,
};
window.dispatchEvent(new Event('elezaai-ready'));
