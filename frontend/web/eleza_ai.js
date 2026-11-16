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
function buildModel(req = {}) {
  const mode = VALID_MODES.has(req.mode) ? req.mode : InferenceMode.PREFER_ON_DEVICE;

  const createOptions = { expectedInputs: EN_TEXT, expectedOutputs: EN_TEXT };
  if (req.systemInstruction) {
    createOptions.initialPrompts = [
      { role: 'system', content: [{ type: 'text', value: req.systemInstruction }] },
    ];
  }
  const onDeviceParams = { createOptions };
  if (req.jsonSchema) {
    // Chrome Prompt API structured output.
    onDeviceParams.promptOptions = { responseConstraint: req.jsonSchema };
  }

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

/**
 * Single-turn generation (on-device does not support chat).
 * req: { prompt, mode?, systemInstruction?, jsonSchema?, cloudModel?,
 *        temperature?, maxOutputTokens? }
 * Returns { text, source: 'on_device' | 'in_cloud', mode, latencyMs }.
 */
async function generate(req) {
  if (!req || typeof req.prompt !== 'string' || !req.prompt.trim()) {
    throw new Error('[elezaAI] generate() needs a non-empty prompt');
  }
  const model = buildModel(req);
  const started = performance.now();
  const result = await model.generateContent(req.prompt);
  return {
    text: result.response.text(),
    source: result.response.inferenceSource ?? 'in_cloud',
    mode: model.chromeAdapter?.mode ?? req.mode ?? InferenceMode.PREFER_ON_DEVICE,
    latencyMs: Math.round(performance.now() - started),
  };
}

window.elezaAI = {
  sdkVersion: SDK_VERSION,
  modes: { ...InferenceMode },
  onDeviceAvailability,
  prepareOnDevice,
  generate,
};
window.dispatchEvent(new Event('elezaai-ready'));
