import 'package:flutter/material.dart';

import '../services/hybrid_ai_service.dart';

/// Debug-only page (route: /ai-smoke-test) that proves Firebase AI Logic
/// hybrid inference works: one on-device call, one cloud call, one hybrid
/// structured-output call. Each result shows which path answered it.
class AiSmokeTestPage extends StatefulWidget {
  const AiSmokeTestPage({super.key});

  @override
  State<AiSmokeTestPage> createState() => _AiSmokeTestPageState();
}

class _SmokeCase {
  const _SmokeCase(this.label, this.mode, this.prompt, {this.jsonSchema});
  final String label;
  final InferenceMode mode;
  final String prompt;
  final Map<String, dynamic>? jsonSchema;
}

class _AiSmokeTestPageState extends State<AiSmokeTestPage> {
  static const _cases = [
    _SmokeCase(
      'On-device only',
      InferenceMode.onlyOnDevice,
      'Reply with exactly: on-device OK',
    ),
    _SmokeCase(
      'Cloud only',
      InferenceMode.onlyInCloud,
      'Reply with exactly: cloud OK',
    ),
    _SmokeCase(
      'Hybrid + JSON (prefer on-device)',
      InferenceMode.preferOnDevice,
      'Patient says: "I have had a headache and fever for two days." '
          'Extract the chief complaint and symptoms.',
      jsonSchema: {
        'type': 'object',
        'properties': {
          'chief_complaint': {'type': 'string'},
          'symptoms': {
            'type': 'array',
            'items': {'type': 'string'},
          },
        },
        'required': ['chief_complaint', 'symptoms'],
      },
    ),
  ];

  OnDeviceStatus? _status;
  double? _progress;
  final Map<String, String> _results = {};
  final Set<String> _running = {};

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  Future<void> _checkStatus() async {
    final s = await HybridAIService.onDeviceAvailability();
    if (mounted) setState(() => _status = s);
  }

  Future<void> _prepare() async {
    try {
      final s = await HybridAIService.prepareOnDevice(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (mounted) setState(() => _status = s);
    } catch (e) {
      if (mounted) setState(() => _results['prepare'] = 'ERROR: $e');
    }
  }

  Future<void> _run(_SmokeCase c) async {
    setState(() {
      _running.add(c.label);
      _results.remove(c.label);
    });
    String out;
    try {
      final r = await HybridAIService.generate(
        prompt: c.prompt,
        mode: c.mode,
        jsonSchema: c.jsonSchema,
      );
      final body = c.jsonSchema != null ? r.json.toString() : r.text.trim();
      out =
          '✅ source: ${r.source.wire}  •  ${r.latency.inMilliseconds} ms\n$body';
    } catch (e) {
      out = '❌ $e';
    }
    debugPrint('[AI smoke] ${c.label}: $out');
    if (mounted) {
      setState(() {
        _running.remove(c.label);
        _results[c.label] = out;
      });
    }
  }

  Future<void> _runAll() async {
    for (final c in _cases) {
      await _run(c);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Firebase AI Logic — smoke test')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              title: Text('On-device model: ${_status?.name ?? 'checking…'}'),
              subtitle: Text(
                _progress == null
                    ? 'Needs Chrome desktop 139+ with '
                        'chrome://flags/#prompt-api-for-gemini-nano-multimodal-input enabled'
                    : 'Download: ${(_progress! * 100).toStringAsFixed(0)}%',
              ),
              trailing: Wrap(
                spacing: 8,
                children: [
                  IconButton(
                    tooltip: 'Refresh',
                    icon: const Icon(Icons.refresh),
                    onPressed: _checkStatus,
                  ),
                  FilledButton(
                    onPressed: _prepare,
                    child: const Text('Download Nano'),
                  ),
                ],
              ),
            ),
          ),
          if (_results['prepare'] != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_results['prepare']!),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _running.isEmpty ? _runAll : null,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Run all'),
          ),
          const SizedBox(height: 8),
          for (final c in _cases)
            Card(
              child: ListTile(
                title: Text(c.label),
                subtitle: SelectableText(
                  _running.contains(c.label)
                      ? 'running…'
                      : (_results[c.label] ?? 'mode: ${c.mode.wire}'),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.play_circle_outline),
                  onPressed: _running.contains(c.label) ? null : () => _run(c),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
