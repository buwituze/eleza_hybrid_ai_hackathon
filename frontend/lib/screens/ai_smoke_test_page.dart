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
    'Model C — next question, English (prefer on-device)': () async {
      final step = await ClinicalAI.nextQuestion(
        context: _sampleQuestionContext('english'),
        fallbackQuestion: 'Can you tell me more about how you are feeling?',
      );
      return '${_traceLine(step.trace)}\n${step.value}';
    },
    'Model C — next question, Kinyarwanda (cloud)': () async {
      final step = await ClinicalAI.nextQuestion(
        context: _sampleQuestionContext('kinyarwanda'),
        fallbackQuestion: 'Mbwira byinshi ku bibazo byawe?',
      );
      return '${_traceLine(step.trace)}\n${step.value}';
    },
    'Model D — triage score (prefer cloud)': () async {
      final step = await ClinicalAI.score(
        extraction: const {
          'chief_complaint': 'headache',
          'severity': '7/10',
          'duration': 'since yesterday',
          'body_part': 'head',
          'associated_symptoms': ['fever', 'light sensitivity'],
          'red_flags_present': false,
        },
        patientAge: 28,
      );
      final s = step.value;
      return '${_traceLine(step.trace)}\n'
          'priority: ${s['priority']} • issue: ${s['suspected_issue']} • '
          'confidence: ${s['confidence']}\nrisk factors: ${s['risk_factors']}';
    },
    'Model D — severe red flag (rule, no model)': () async {
      final step = await ClinicalAI.score(
        extraction: const {
          'chief_complaint': 'chest pain',
          'severity': 'severe',
          'red_flags_present': true,
          'associated_symptoms': ['shortness of breath'],
        },
      );
      final s = step.value;
      return '${step.trace == null ? '✅ no model call (deterministic rule)' : _traceLine(step.trace)}\n'
          'priority: ${s['priority']} • issue: ${s['suspected_issue']}';
    },
    'Model E — patient message, English (prefer on-device)': () async {
      final step = await ClinicalAI.guidance(
        extraction: const {
          'chief_complaint': 'headache',
          'duration': 'since yesterday',
          'severity': '7/10',
          'red_flags_present': false,
        },
        score: const {'priority': 'MEDIUM'},
        language: 'english',
        locationHint: 'Waiting Area A — General Outpatient',
      );
      return '${_traceLine(step.trace)}\n${step.value}';
    },
    'Model E — patient message, Kinyarwanda (cloud)': () async {
      final step = await ClinicalAI.guidance(
        extraction: const {
          'chief_complaint': 'chest pain',
          'severity': 'severe',
          'red_flags_present': true,
        },
        score: const {'priority': 'HIGH'},
        language: 'kinyarwanda',
        locationHint: 'Emergency Department — present to the desk immediately',
      );
      return '${_traceLine(step.trace)}\n${step.value}';
    },
    'Model F — doctor brief (prefer on-device)': () async {
      final step = await ClinicalAI.brief(
        sessionId: 'smoke-test',
        extraction: const {
          'chief_complaint': 'headache',
          'body_part': 'head',
          'duration': 'since yesterday',
          'severity': '7/10',
          'associated_symptoms': ['fever', 'light sensitivity'],
          'red_flags_present': false,
        },
        score: const {
          'priority': 'MEDIUM',
          'suspected_issue': 'neurological-related complaint',
          'risk_factors': ['severity 7/10', 'fever'],
          'confidence': 0.85,
        },
        turns: const [
          TranslatedTurn(
            question: 'How strong is the pain from 1 to 10?',
            answer: 'About seven',
          ),
          TranslatedTurn(
            question: 'Any other symptoms?',
            answer: 'Fever at night and light hurts my eyes',
          ),
        ],
        language: 'kinyarwanda',
        patientAge: 28,
      );
      final b = step.value;
      return '${_traceLine(step.trace)}\n${b['narrative_summary']}\n'
          'findings: ${b['key_findings']}';
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

  // Shape of `question_context` returned by POST /kiosk/{id}/extraction.
  static Map<String, dynamic> _sampleQuestionContext(String language) => {
    'system_instruction':
        'You are a clinical question-selection assistant in a hospital '
        'pre-consultation system.\nOutput ONE question only. Nothing else.\n'
        'Rules:\n- One question per response.\n- No diagnosis, no medical '
        'advice, no interpretation.\n- Do not repeat a question already '
        'asked.\n- Keep it short and natural to say out loud.\n- Output the '
        'question text only.',
    'known': {
      'chief_complaint': 'headache',
      'duration': 'since yesterday',
      'patient_name': 'Aline Uwase',
      'language': language,
    },
    'history': [
      {
        'question':
            language == 'english'
                ? 'How old are you?'
                : 'Mufite imyaka ingahe?',
        'answer':
            language == 'english' ? 'Twenty eight' : 'Makumyabiri n\'umunani',
      },
    ],
    'stage': 'early',
    'red_flag_active': false,
    'red_flag_followups': const [],
    'coverage_checklist': const [
      'severity or intensity of the main symptom',
      'whether the symptom is getting better, worse, or staying the same',
      'any other symptoms alongside the main one',
    ],
    'language': language,
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
