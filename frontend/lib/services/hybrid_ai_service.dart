import 'dart:convert';

import 'hybrid_ai_platform_stub.dart'
    if (dart.library.js_interop) 'hybrid_ai_platform_web.dart'
    as platform;

/// Where a prompt is allowed / preferred to run.
/// Values match the Firebase JS SDK `InferenceMode` strings.
enum InferenceMode {
  preferOnDevice('prefer_on_device'),
  onlyOnDevice('only_on_device'),
  preferInCloud('prefer_in_cloud'),
  onlyInCloud('only_in_cloud');

  const InferenceMode(this.wire);
  final String wire;

  static InferenceMode fromWire(String value) => InferenceMode.values
      .firstWhere((m) => m.wire == value, orElse: () => preferOnDevice);
}

/// Which path actually answered a prompt.
enum InferenceSource {
  onDevice('on_device'),
  inCloud('in_cloud');

  const InferenceSource(this.wire);
  final String wire;

  static InferenceSource fromWire(String value) =>
      value == onDevice.wire ? onDevice : inCloud;
}

/// Status of Chrome's built-in Gemini Nano model.
enum OnDeviceStatus {
  available,
  downloadable,
  downloading,
  unavailable,

  /// Browser has no Prompt API (not Chrome desktop 139+, or not web).
  unsupported;

  static OnDeviceStatus fromWire(String value) => OnDeviceStatus.values
      .firstWhere((s) => s.name == value, orElse: () => unavailable);
}

class HybridAIResult {
  const HybridAIResult({
    required this.text,
    required this.source,
    required this.mode,
    required this.latency,
  });

  final String text;
  final InferenceSource source;
  final InferenceMode mode;
  final Duration latency;

  bool get ranOnDevice => source == InferenceSource.onDevice;

  /// Decodes [text] as JSON (for prompts sent with a `jsonSchema`).
  /// Tolerates a ```json fenced block, which small models sometimes emit.
  dynamic get json {
    var raw = text.trim();
    final fence = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(raw);
    if (fence != null) raw = fence.group(1)!;
    return jsonDecode(raw);
  }

  @override
  String toString() =>
      'HybridAIResult(source: ${source.wire}, mode: ${mode.wire}, '
      'latency: ${latency.inMilliseconds}ms, text: $text)';
}

class HybridAIException implements Exception {
  HybridAIException(this.message);
  final String message;

  @override
  String toString() => 'HybridAIException: $message';
}

/// Firebase AI Logic hybrid inference (Gemini Nano on-device in Chrome,
/// cloud Gemini fallback). Backed by `web/eleza_ai.js`.
class HybridAIService {
  HybridAIService._();

  /// Whether this platform can use hybrid inference at all (web only).
  static bool get isSupported => platform.isSupported;

  /// Runs a single-turn prompt.
  ///
  /// [jsonSchema] is a JSON Schema map; when set, both the on-device and
  /// cloud model are constrained to return matching JSON (read it via
  /// [HybridAIResult.json]).
  /// [cloudModel] overrides the default cloud Gemini model.
  static Future<HybridAIResult> generate({
    required String prompt,
    InferenceMode mode = InferenceMode.preferOnDevice,
    String? systemInstruction,
    Map<String, dynamic>? jsonSchema,
    String? cloudModel,
    double? temperature,
    int? maxOutputTokens,
  }) async {
    final request = <String, dynamic>{
      'prompt': prompt,
      'mode': mode.wire,
      if (systemInstruction != null) 'systemInstruction': systemInstruction,
      if (jsonSchema != null) 'jsonSchema': jsonSchema,
      if (cloudModel != null) 'cloudModel': cloudModel,
      if (temperature != null) 'temperature': temperature,
      if (maxOutputTokens != null) 'maxOutputTokens': maxOutputTokens,
    };
    try {
      final raw = await platform.generate(request);
      return HybridAIResult(
        text: raw.text,
        source: InferenceSource.fromWire(raw.source),
        mode: InferenceMode.fromWire(raw.mode),
        latency: Duration(milliseconds: raw.latencyMs),
      );
    } on HybridAIException {
      rethrow;
    } catch (e) {
      throw HybridAIException(e.toString());
    }
  }

  /// Current status of the on-device model.
  static Future<OnDeviceStatus> onDeviceAvailability() async {
    try {
      return OnDeviceStatus.fromWire(await platform.onDeviceAvailability());
    } catch (_) {
      return OnDeviceStatus.unavailable;
    }
  }

  /// Starts the Gemini Nano download if needed. Must be called from a user
  /// gesture (e.g. a button tap). [onProgress] receives 0.0–1.0.
  static Future<OnDeviceStatus> prepareOnDevice({
    void Function(double progress)? onProgress,
  }) async {
    try {
      return OnDeviceStatus.fromWire(
        await platform.prepareOnDevice(onProgress),
      );
    } catch (e) {
      throw HybridAIException(e.toString());
    }
  }
}
