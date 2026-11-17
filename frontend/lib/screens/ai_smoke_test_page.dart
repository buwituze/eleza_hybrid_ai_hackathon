import 'package:flutter/material.dart';

import '../services/clinical_ai.dart';
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
  const _SmokeCase(
    this.label,
    this.mode,
    this.prompt, {
    this.jsonSchema,
    this.onDeviceTimeout,
  });
  final String label;
  final InferenceMode mode;
  final String prompt;
  final Map<String, dynamic>? jsonSchema;
  final Duration? onDeviceTimeout;
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
    _SmokeCase(
      'Hybrid, 3 s on-device deadline (cloud fallback on slow devices)',
      InferenceMode.preferOnDevice,
      'In one sentence, what should a patient with chest pain do?',
      onDeviceTimeout: Duration(seconds: 3),
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
        onDeviceTimeout: c.onDeviceTimeout,
      );
      final body = c.jsonSchema != null ? r.json.toString() : r.text.trim();
      final fallback =
          r.fallbackReason == null
              ? ''
              : '  •  fallback: ${r.fallbackReason!.wire}';
      out =
          '✅ source: ${r.source.wire}$fallback  •  '
          '${r.latency.inMilliseconds} ms\n$body';
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

  // ── Clinical pipeline steps (lib/services/clinical_ai.dart) ─────────────

  static String _traceLine(AiTrace? t) {
    if (t == null) return '❌ model failed — safe default used';
    final fb =
        t.fallbackReason == null
            ? ''
            : '  •  fallback: ${t.fallbackReason!.wire}';
    return '✅ source: ${t.source.wire}$fb  •  ${t.latency.inMilliseconds} ms';
  }

  late final Map<String, Future<String> Function()> _clinicalTests = {
    'Translation (Kinyarwanda → English, cloud)': () async {
      final step = await ClinicalAI.translateTurn(
        question: 'Ni ryari ububabare bwatangiye?',
        answer: 'Ndababara umutwe cyane kuva ejo, kandi mfite fièvre nijoro.',
      );
      return '${_traceLine(step.trace)}\n'
          'Q: ${step.value.question}\nA: ${step.value.answer}';
    },
    'Model B — extraction (prefer on-device)': () async {
      final step = await ClinicalAI.extract(
        initial: 'I have had a bad headache since yesterday and some fever.',
        turns: const [
          TranslatedTurn(
            question: 'What is your name?',
            answer: 'My name is Aline Uwase',
          ),
          TranslatedTurn(
            question: 'How old are you?',
            answer: 'I am twenty eight',
          ),
          TranslatedTurn(
            question: 'How strong is the pain from 1 to 10?',
            answer: 'About seven, and light hurts my eyes',
          ),
        ],
      );
      final e = step.value;
      return '${_traceLine(step.trace)}\n'
          'complaint: ${e['chief_complaint']} • severity: ${e['severity']} • '
          'duration: ${e['duration']}\nname: ${e['patient_name']} • age: '
          '${e['patient_age']} • other: ${e['associated_symptoms']} • '
          'red flags: ${e['red_flags_present']}';
    },
  };

  Future<void> _runClinical(String label) async {
    setState(() {
      _running.add(label);
      _results.remove(label);
    });
    String out;
    try {
      out = await _clinicalTests[label]!();
    } catch (e) {
      out = '❌ $e';
    }
    debugPrint('[AI smoke] $label: $out');
    if (mounted) {
      setState(() {
        _running.remove(label);
        _results[label] = out;
      });
    }
  }

  Future<void> _runAll() async {
    for (final c in _cases) {
      await _run(c);
    }
    for (final label in _clinicalTests.keys) {
      await _runClinical(label);
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
                  IconButton(
                    tooltip: 'Reset "device too slow" cool-down',
                    icon: const Icon(Icons.restart_alt),
                    onPressed: () async {
                      await HybridAIService.resetDeviceHealth();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Nano will be tried again'),
                        ),
                      );
                    },
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
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 16, 4, 4),
            child: Text(
              'Clinical pipeline steps',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          for (final label in _clinicalTests.keys)
            Card(
              child: ListTile(
                title: Text(label),
                subtitle: SelectableText(
                  _running.contains(label)
                      ? 'running…'
                      : (_results[label] ?? 'not run yet'),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.play_circle_outline),
                  onPressed:
                      _running.contains(label)
                          ? null
                          : () => _runClinical(label),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
