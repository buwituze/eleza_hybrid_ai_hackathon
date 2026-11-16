// Non-web platforms: Firebase AI Logic hybrid inference is only wired up for
// Chrome (web/eleza_ai.js). Eleza currently targets web only.

class RawHybridResult {
  const RawHybridResult(this.text, this.source, this.mode, this.latencyMs);
  final String text;
  final String source;
  final String mode;
  final int latencyMs;
}

const bool isSupported = false;

Never _unsupported() => throw UnsupportedError(
  'Hybrid inference is only available on Flutter web (Chrome).',
);

Future<RawHybridResult> generate(Map<String, dynamic> request) async =>
    _unsupported();

Future<String> onDeviceAvailability() async => 'unsupported';

Future<String> prepareOnDevice(void Function(double)? onProgress) async =>
    _unsupported();
