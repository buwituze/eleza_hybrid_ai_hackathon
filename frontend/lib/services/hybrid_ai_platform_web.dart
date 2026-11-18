// Web: calls window.elezaAI, defined by web/eleza_ai.js (Firebase JS SDK).
import 'dart:js_interop';

class RawHybridResult {
  const RawHybridResult(
    this.text,
    this.source,
    this.mode,
    this.latencyMs,
    this.fallbackReason,
  );
  final String text;
  final String source;
  final String mode;
  final int latencyMs;
  final String? fallbackReason;
}

const bool isSupported = true;

@JS('elezaAI')
external _ElezaAI? get _bridge;

extension type _ElezaAI._(JSObject _) implements JSObject {
  external JSPromise<JSString> onDeviceAvailability();
  external JSPromise<JSString> prepareOnDevice(JSFunction? onProgress);
  external JSPromise<_GenerateResult> generate(JSAny request);
  external void resetDeviceHealth();
}

extension type _GenerateResult._(JSObject _) implements JSObject {
  external JSString get text;
  external JSString get source;
  external JSString get mode;
  external JSNumber get latencyMs;
  external JSString? get fallbackReason;
}

/// eleza_ai.js is an ES module that imports the Firebase SDK from gstatic, so
/// it can finish loading after Dart starts. Wait briefly for it.
Future<_ElezaAI> _ready() async {
  const step = Duration(milliseconds: 100);
  for (var waited = Duration.zero;
      waited < const Duration(seconds: 15);
      waited += step) {
    final bridge = _bridge;
    if (bridge != null) return bridge;
    await Future<void>.delayed(step);
  }
  throw StateError(
    'window.elezaAI not found — is <script type="module" src="eleza_ai.js"> '
    'in web/index.html, and did the Firebase SDK load?',
  );
}

Future<RawHybridResult> generate(Map<String, dynamic> request) async {
  final bridge = await _ready();
  final result = await bridge.generate(request.jsify()!).toDart;
  return RawHybridResult(
    result.text.toDart,
    result.source.toDart,
    result.mode.toDart,
    result.latencyMs.toDartInt,
    result.fallbackReason?.toDart,
  );
}

Future<void> resetDeviceHealth() async {
  final bridge = await _ready();
  bridge.resetDeviceHealth();
}

Future<String> onDeviceAvailability() async {
  final bridge = await _ready();
  return (await bridge.onDeviceAvailability().toDart).toDart;
}

Future<String> prepareOnDevice(void Function(double)? onProgress) async {
  final bridge = await _ready();
  final callback =
      onProgress == null
          ? null
          : ((JSNumber loaded) => onProgress(loaded.toDartDouble)).toJS;
  return (await bridge.prepareOnDevice(callback).toDart).toDart;
}
