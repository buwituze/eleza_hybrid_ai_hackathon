import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'app_config.dart';
import 'hybrid_ai_service.dart';

/// The AI steps of the Eleza kiosk pipeline that run in the browser through
/// Firebase AI Logic (Model A — Whisper speech-to-text — stays on the server).
enum ClinicalStep {
  translation('translation'),
  extraction('extraction'), // Model B
  question('question'), // Model C
  score('score'), // Model D
  routing('routing'), // unclear-issue routing suggestion
  guidance('guidance'), // Model E (patient message)
  brief('brief'); // Model F (doctor brief)

  const ClinicalStep(this.wire);
  final String wire;
}

/// Where each step runs. Values come from Remote Config (AppConfig), with
/// in-app defaults; invalid console values fall back to those defaults.
///
/// Why this split:
/// - Gemini Nano only handles English, so anything that must read or write
///   Kinyarwanda goes to the cloud (translation; question + guidance in
///   Kinyarwanda sessions).
/// - Extraction and the doctor brief handle the most sensitive text and work
///   on English (translated) input → prefer on-device.
/// - Triage scoring is safety-critical → prefer the stronger cloud model
///   (the backend also enforces red-flag rules on any result).
class ClinicalAIConfig {
  ClinicalAIConfig._();

  /// Remote Config key for each configurable step.
  static const _modeKeys = {
    ClinicalStep.extraction: AppConfig.kModeExtraction,
    ClinicalStep.question: AppConfig.kModeQuestion,
    ClinicalStep.score: AppConfig.kModeScore,
    ClinicalStep.routing: AppConfig.kModeRouting,
    ClinicalStep.guidance: AppConfig.kModeGuidance,
    ClinicalStep.brief: AppConfig.kModeBrief,
  };

  /// Steps whose OUTPUT is patient-facing text in the session language.
  static const _patientLanguageSteps = {
    ClinicalStep.question,
    ClinicalStep.guidance,
  };

  /// How long Nano gets before the cloud answers (1 s – 2 min).
  static Duration get onDeviceTimeout => Duration(
    milliseconds: _clampedMs(AppConfig.kOnDeviceTimeoutMs, 1000, 120000),
  );

  /// How long Nano is skipped after a timeout (0 – 1 h).
  static Duration get slowDeviceCooldown => Duration(
    milliseconds: _clampedMs(AppConfig.kSlowDeviceCooldownMs, 0, 3600000),
  );

  /// The configured mode for [step], before language rules.
  static InferenceMode configuredMode(ClinicalStep step) {
    final key = _modeKeys[step];
    if (key == null) return InferenceMode.onlyInCloud; // translation
    return _parseMode(AppConfig.getString(key)) ??
        _parseMode('${AppConfig.defaults[key]}') ??
        InferenceMode.preferOnDevice;
  }

  static InferenceMode modeFor(ClinicalStep step, {required String language}) {
    // Safety rules that Remote Config cannot override:
    // translation reads Kinyarwanda, and Nano cannot write Kinyarwanda.
    if (step == ClinicalStep.translation) return InferenceMode.onlyInCloud;
    if (language != 'english' && _patientLanguageSteps.contains(step)) {
      return InferenceMode.onlyInCloud;
    }
    return configuredMode(step);
  }

  static InferenceMode? _parseMode(String raw) {
    final v = raw.trim().toLowerCase();
    for (final m in InferenceMode.values) {
      if (m.wire == v) return m;
    }
    return null;
  }

  static int _clampedMs(String key, int min, int max) {
    final v = AppConfig.getInt(key);
    if (v <= 0 && min > 0) return (AppConfig.defaults[key] as num).toInt();
    return v.clamp(min, max);
  }
}

/// Which path produced an AI result — sent to the backend with every result
/// (backend schema: routers/kiosk_hybrid.py → AiTrace).
class AiTrace {
  const AiTrace({
    required this.step,
    required this.source,
    required this.mode,
    required this.latency,
    this.fallbackReason,
  });

  factory AiTrace.fromResult(ClinicalStep step, HybridAIResult r) => AiTrace(
    step: step,
    source: r.source,
    mode: r.mode,
    latency: r.latency,
    fallbackReason: r.fallbackReason,
  );

  final ClinicalStep step;
  final InferenceSource source;
  final InferenceMode mode;
  final Duration latency;
  final FallbackReason? fallbackReason;

  Map<String, dynamic> toJson() => {
    'step': step.wire,
    'source': source.wire,
    'mode': mode.wire,
    'latency_ms': latency.inMilliseconds,
    if (fallbackReason != null) 'fallback_reason': fallbackReason!.wire,
  };
}

/// Result of one clinical AI step. [trace] is null when the step did not use
/// a model (e.g. it failed and a safe default was used).
class AiStep<T> {
  const AiStep(this.value, this.trace);
  final T value;
  final AiTrace? trace;
}

class TranslatedTurn {
  const TranslatedTurn({
    required this.answer,
    this.question,
    this.translated = true,
  });

  final String? question;
  final String answer;

  /// False when translation failed and the original text was kept.
  final bool translated;
}

/// Browser-side clinical AI steps (Firebase AI Logic hybrid inference).
class ClinicalAI {
  ClinicalAI._();

  // ── Model B: clinical extraction (on-device preferred) ──────────────────
  // Ported from backend/models/model_b.py (_FULL_SYSTEM / FULL_SCHEMA).
  // Input is always English (Kinyarwanda is translated first), so it can run
  // on Gemini Nano. The backend re-validates the result and re-checks red
  // flags on the original words.

  static const _extractionSystem =
      'You are a clinical information extraction assistant at a hospital '
      'pre-consultation kiosk.\n'
      'Extract clinical information from the patient conversation.\n'
      'Rules:\n'
      '- Extract ONLY facts the patient stated. Never diagnose or guess.\n'
      '- Use an empty string for anything not stated.\n'
      '- duration: be specific ("started yesterday", "3 days").\n'
      '- severity: exact number if given (e.g. "7/10"), else "mild", '
      '"moderate" or "severe".\n'
      '- associated_symptoms: other symptoms besides the main one, each a '
      'short phrase.\n'
      '- progression: "worsening", "improving" or "stable" if stated.\n'
      '- patient_name: only the name — drop "My name is", "I am", "Call me".\n'
      '- patient_age: digits only (e.g. "35"), never words.\n'
      '- patient_location: "Neighborhood, City" when recognisable '
      '(e.g. "Kanombe, Kigali").\n'
      '- red_flags_present: true if ANY of: difficulty breathing, chest pain '
      'or pressure, fainting or loss of consciousness, severe bleeding, '
      'coughing or vomiting blood, seizure, sudden vision loss, sudden worst-'
      'ever pain, cannot move a limb. Otherwise false.';

  static const _extractionStringFields = [
    'patient_name',
    'patient_age',
    'patient_gender',
    'patient_phone',
    'patient_location',
    'chief_complaint',
    'duration',
    'severity',
    'body_part',
    'progression',
    'triggers',
    'additional_observations',
  ];

  static final Map<String, dynamic> _extractionSchema = {
    'type': 'object',
    'properties': {
      for (final f in _extractionStringFields) f: {'type': 'string'},
      'associated_symptoms': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'red_flags_present': {'type': 'boolean'},
    },
    'required': [
      ..._extractionStringFields,
      'associated_symptoms',
      'red_flags_present',
    ],
  };

  /// Model B. [initial] is the opening complaint and [turns] the follow-up
  /// questions/answers — all in English. Returns the extraction map in the
  /// backend's FULL_SCHEMA shape.
  ///
  /// Never throws: on failure returns an empty extraction (trace null) so the
  /// backend's rules still ask the next question.
  static Future<AiStep<Map<String, dynamic>>> extract({
    required String initial,
    List<TranslatedTurn> turns = const [],
  }) async {
    final buf = StringBuffer('Initial statement: ${initial.trim()}\n');
    if (turns.isNotEmpty) {
      buf.writeln('\nFollow-up conversation:');
      for (var i = 0; i < turns.length; i++) {
        buf
          ..writeln('Q${i + 1}: ${turns[i].question ?? ''}')
          ..writeln('A${i + 1}: ${turns[i].answer}');
      }
    }
    buf.write('\nExtract the clinical information as JSON.');

    try {
      final r = await HybridAIService.generate(
        prompt: buf.toString(),
        mode: ClinicalAIConfig.modeFor(
          ClinicalStep.extraction,
          language: 'english', // input is English after translation
        ),
        systemInstruction: _extractionSystem,
        jsonSchema: _extractionSchema,
        temperature: 0,
        maxOutputTokens: 600,
        onDeviceTimeout: ClinicalAIConfig.onDeviceTimeout,
        slowDeviceCooldown: ClinicalAIConfig.slowDeviceCooldown,
      );
      final raw = (r.json as Map).cast<String, dynamic>();
      return AiStep(
        _normaliseExtraction(raw),
        AiTrace.fromResult(ClinicalStep.extraction, r),
      );
    } catch (e) {
      debugPrint('⚠️ Extraction failed, sending empty extraction: $e');
      return AiStep(_normaliseExtraction(const {}), null);
    }
  }

  // ── Model C: next question ──────────────────────────────────────────────
  // The backend asks rule-based questions itself (patient info) and decides
  // when coverage is complete; it only asks the browser for a question when
  // clinical judgement is needed, and sends the prompt inputs
  // (backend/models/model_c.py → question_context()).
  // English sessions → prefer on-device; Kinyarwanda → cloud (Nano can't
  // write Kinyarwanda).

  /// Model C. [context] is `question_context` from POST /extraction;
  /// [fallbackQuestion] is used if generation fails or returns junk.
  static Future<AiStep<String>> nextQuestion({
    required Map<String, dynamic> context,
    required String fallbackQuestion,
  }) async {
    final language = (context['language'] as String?) ?? 'kinyarwanda';
    final known = (context['known'] as Map?)?.cast<String, dynamic>() ?? {};
    final history = (context['history'] as List?) ?? const [];
    final checklist = (context['coverage_checklist'] as List?) ?? const [];
    final followups = (context['red_flag_followups'] as List?) ?? const [];

    final buf =
        StringBuffer('Patient state:\n')
          ..writeln(
            known.isEmpty
                ? '- (unknown)'
                : known.entries
                    .where((e) => e.key != 'language')
                    .map((e) => '- ${e.key}: ${e.value}')
                    .join('\n'),
          )
          ..writeln('\nConversation so far:')
          ..writeln(
            history.isEmpty
                ? '  (none)'
                : history
                    .map((t) => '  Q: ${t['question']}\n  A: ${t['answer']}')
                    .join('\n'),
          )
          ..writeln('\nStage: ${context['stage'] ?? 'mid'}');
    if (context['red_flag_active'] == true) {
      buf
        ..writeln('\nRED FLAG ACTIVE. Prioritise these:')
        ..writeln(followups.map((q) => '- $q').join('\n'));
    }
    buf
      ..writeln('\nCoverage checklist (must be addressed eventually):')
      ..writeln(checklist.map((c) => '- $c').join('\n'))
      ..writeln(
        '\nOutput the single best next question, in '
        '${language == 'english' ? 'English' : 'Kinyarwanda'}. '
        'Question text only.',
      );

    try {
      final r = await HybridAIService.generate(
        prompt: buf.toString(),
        mode: ClinicalAIConfig.modeFor(
          ClinicalStep.question,
          language: language,
        ),
        systemInstruction: context['system_instruction'] as String?,
        temperature: 0.2,
        maxOutputTokens: 100,
        onDeviceTimeout: ClinicalAIConfig.onDeviceTimeout,
        slowDeviceCooldown: ClinicalAIConfig.slowDeviceCooldown,
      );
      final question = _cleanQuestion(r.text);
      if (question == null) {
        debugPrint('⚠️ Model C returned an unusable question: "${r.text}"');
        return AiStep(fallbackQuestion, null);
      }
      return AiStep(question, AiTrace.fromResult(ClinicalStep.question, r));
    } catch (e) {
      debugPrint('⚠️ Model C failed, using fallback question: $e');
      return AiStep(fallbackQuestion, null);
    }
  }

  /// Mirrors backend model_c.clean_question(): first line only, no
  /// "Question:" prefix or quotes, ends with "?". Null if unusable.
  static String? _cleanQuestion(String raw) {
    var q = raw
        .trim()
        .split('\n')
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    q =
        q
            .replaceFirst(
              RegExp(r'^(question|q)\s*[:\-]?\s*', caseSensitive: false),
              '',
            )
            .replaceAll(RegExp(r'^["“*]+|["”*]+$'), '')
            .trim();
    if (q.isEmpty || q.length > 250) return null;
    return q.endsWith('?') ? q : '$q?';
  }

  // ── Model D: triage score (prefer cloud) ────────────────────────────────
  // Ported from backend/models/model_d.py. Safety-critical, so the stronger
  // cloud model is preferred; the backend re-normalises the result and
  // enforces red-flag rules (a red flag always means HIGH).

  static const issueCategories = [
    'cardiorespiratory-related complaint',
    'neurological-related complaint',
    'gastrointestinal-related complaint',
    'musculoskeletal-related complaint',
    'dermatological-related complaint',
    'urological-related complaint',
    'ENT-related complaint',
    'general or systemic complaint',
    'mental health-related complaint',
    'obstetric or gynaecological complaint',
    'paediatric-related complaint',
    'unclear or unclassifiable complaint',
  ];
  static const unclearIssue = 'unclear or unclassifiable complaint';

  static const _scoreSystem =
      'You are a clinical triage scoring assistant. Output a risk score for '
      'clinician review only.\n'
      'Rules:\n'
      '- No diagnosis, no treatment advice, no patient-facing language.\n'
      '- Output valid JSON only matching the schema.\n'
      '- suspected_issue must be exactly one value from the allowed list.';

  static const _triageRules =
      'HIGH: red flag present, OR severity severe/extreme/8-10, OR acute rapid '
      'onset, OR infant/elderly with moderate+ symptoms.\n'
      'MEDIUM: moderate severity (4-7/10), symptom hours to days, mild '
      'associated symptoms, no red flags.\n'
      'LOW: mild severity (1-3/10), stable for days to weeks, no associated '
      'symptoms, no red flags.\n'
      'Confidence: 0.8-1.0 if severity + duration + red flag status all known. '
      '0.5-0.79 if one missing. Below 0.5 if most missing.\n'
      'Risk factors: observable facts only. Max 4. Short phrases.';

  static const _scoreSchema = <String, dynamic>{
    'type': 'object',
    'properties': {
      'priority': {
        'type': 'string',
        'enum': ['HIGH', 'MEDIUM', 'LOW'],
      },
      'suspected_issue': {'type': 'string', 'enum': issueCategories},
      'risk_factors': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'confidence': {'type': 'number'},
    },
    'required': ['priority', 'suspected_issue', 'risk_factors', 'confidence'],
  };

  static const _severeWords = {
    'severe',
    'extreme',
    'unbearable',
    'very severe',
  };

  /// Model D. Returns {priority, suspected_issue, risk_factors, confidence}.
  /// A confirmed severe red flag is scored HIGH without calling a model (same
  /// rule as the server). On failure returns a MEDIUM/unclear score with
  /// confidence 0 — the backend still applies the red-flag rules.
  static Future<AiStep<Map<String, dynamic>>> score({
    required Map<String, dynamic> extraction,
    int? patientAge,
  }) async {
    final complaint = (extraction['chief_complaint'] ?? '').toString();
    final severity = (extraction['severity'] ?? '').toString().toLowerCase();
    final redFlag = extraction['red_flags_present'] == true;
    final symptoms = [
      for (final s in (extraction['associated_symptoms'] as List? ?? const []))
        s.toString(),
    ];

    if (redFlag && _severeWords.contains(severity)) {
      final cardio = RegExp(
        'chest|breath|heart',
      ).hasMatch(complaint.toLowerCase());
      return AiStep({
        'priority': 'HIGH',
        'suspected_issue':
            cardio
                ? 'cardiorespiratory-related complaint'
                : 'general or systemic complaint',
        'risk_factors': [complaint, ...symptoms].take(4).toList(),
        'confidence': 0.95,
      }, null);
    }

    final data = {
      'symptom': complaint.isEmpty ? 'unknown' : complaint,
      'severity': extraction['severity'] ?? 'unknown',
      'duration': extraction['duration'] ?? 'unknown',
      'body_part': extraction['body_part'] ?? 'unknown',
      'associated_symptoms': symptoms,
      'red_flags_present': extraction['red_flags_present'],
      'age': patientAge,
    };
    final prompt =
        'Patient data:\n${const JsonEncoder.withIndent('  ').convert(data)}\n\n'
        'Allowed categories:\n${issueCategories.map((c) => '- $c').join('\n')}\n\n'
        'Triage rules:\n$_triageRules\n\n'
        'Return the risk score JSON only.';

    try {
      final r = await HybridAIService.generate(
        prompt: prompt,
        mode: ClinicalAIConfig.modeFor(ClinicalStep.score, language: 'english'),
        systemInstruction: _scoreSystem,
        jsonSchema: _scoreSchema,
        temperature: 0,
        maxOutputTokens: 300,
        onDeviceTimeout: ClinicalAIConfig.onDeviceTimeout,
        slowDeviceCooldown: ClinicalAIConfig.slowDeviceCooldown,
      );
      final raw = (r.json as Map).cast<String, dynamic>();
      return AiStep(raw, AiTrace.fromResult(ClinicalStep.score, r));
    } catch (e) {
      debugPrint('⚠️ Model D failed, sending unclear/MEDIUM score: $e');
      return AiStep({
        'priority': 'MEDIUM',
        'suspected_issue': unclearIssue,
        'risk_factors': <String>[],
        'confidence': 0.0,
      }, null);
    }
  }

  // ── Routing suggestion for unclear issues (prefer cloud) ────────────────
  // Ported from backend routing/queue_routing.py suggest_unclear_issue_routing.
  // Department names must match the backend's _DEPARTMENT_CONFIG; anything
  // else is mapped to General Medicine by the backend.

  static const departments = [
    'Emergency',
    'General Medicine',
    'Orthopaedics',
    'Dermatology',
    'Urology',
    'ENT',
    'Mental Health',
    'Gynaecology',
    'Paediatrics',
    'Ophthalmology',
  ];

  static const _routingSchema = <String, dynamic>{
    'type': 'object',
    'properties': {
      'department': {'type': 'string', 'enum': departments},
      'suspected_issue': {'type': 'string'},
      'confidence': {'type': 'number'},
      'reason': {'type': 'string'},
    },
    'required': ['department', 'suspected_issue', 'confidence', 'reason'],
  };

  /// Only needed when Model D says the issue is unclear. Returns null on
  /// failure (the backend then routes to General Medicine).
  static Future<AiStep<Map<String, dynamic>?>> suggestRouting({
    required Map<String, dynamic> extraction,
    required List<TranslatedTurn> turns,
  }) async {
    final convo =
        turns.isEmpty
            ? '(no follow-up conversation)'
            : turns.map((t) => 'Q: ${t.question}\nA: ${t.answer}').join('\n');
    final prompt =
        'The triage issue label is unclear. Choose the best destination '
        'department and a short, specific issue label (e.g. '
        '"ophthalmology-related complaint").\n\n'
        'Structured extraction:\n'
        '${const JsonEncoder.withIndent('  ').convert(extraction)}\n\n'
        'Conversation:\n$convo\n\nReturn JSON only.';
    try {
      final r = await HybridAIService.generate(
        prompt: prompt,
        mode: ClinicalAIConfig.modeFor(
          ClinicalStep.routing,
          language: 'english',
        ),
        systemInstruction:
            'You are a clinical routing assistant at a hospital. No diagnosis.',
        jsonSchema: _routingSchema,
        temperature: 0,
        maxOutputTokens: 250,
        onDeviceTimeout: ClinicalAIConfig.onDeviceTimeout,
        slowDeviceCooldown: ClinicalAIConfig.slowDeviceCooldown,
      );
      return AiStep(
        (r.json as Map).cast<String, dynamic>(),
        AiTrace.fromResult(ClinicalStep.routing, r),
      );
    } catch (e) {
      debugPrint('⚠️ Routing suggestion failed: $e');
      return const AiStep(null, null);
    }
  }

  // ── Model E: patient guidance message ───────────────────────────────────
  // Ported from backend/models/model_e.py. Patient-facing, in the session
  // language: English → prefer on-device; Kinyarwanda → cloud.
  // The backend vets the result (no diagnosis/advice words, length) and
  // swaps in a safe template if needed, so the kiosk always gets a message.

  static const _guidanceSystem =
      'You are a healthcare system assistant in a hospital.\n'
      'Explain the next steps to a patient using only the system\'s decision.\n'
      'Rules:\n'
      '- No disease names. No diagnosis. No medical advice. No causes.\n'
      '- Do not change the priority level.\n'
      '- 3 to 5 short sentences. Calm and clear.\n'
      '- Output the patient message only.\n'
      '- Write entirely in the language given in the Language field.';

  // Few-shot examples folded into one prompt (on-device is single-turn only).
  static const _guidanceExamples =
      'Example:\nPriority: HIGH\nComplaint: chest pain\n'
      'Location: Emergency, Desk 3\nLanguage: english\n'
      'Response: Your symptoms need prompt medical attention. Please proceed '
      'to Emergency, Desk 3 right away. A healthcare professional will see you '
      'shortly. If you feel worse at any time, please notify a staff member '
      'immediately.\n\n'
      'Example:\nPriority: HIGH\nComplaint: ububabare bw\'igituza\n'
      'Location: Emergency, Desk 3\nLanguage: kinyarwanda\n'
      'Response: Ibimenyetso byawe bisaba ubuvuzi bwihutirwa. Nyamuneka jya '
      'kuri Emergency, Desk 3 vuba. Umuganga azakureba vuba. Niba wumvise ko '
      'ibintu birushijeho kuba bibi, menyesha umukozi uhari ako kanya.\n\n'
      'Example:\nPriority: MEDIUM\nComplaint: headache\n'
      'Location: Waiting Area B\nLanguage: english\n'
      'Response: Thank you for sharing your information. Please take a seat in '
      'Waiting Area B and a healthcare professional will see you soon. If your '
      'condition changes while you wait, please let a staff member know.\n\n'
      'Example:\nPriority: LOW\nComplaint: sore throat\n'
      'Location: General Outpatient\nLanguage: english\n'
      'Response: Thank you. Your information has been recorded. Please wait in '
      'the General Outpatient area and you will be called when it is your '
      'turn.';

  /// Model E. [score] and [locationHint] come from POST /score (after the
  /// backend's safety rules). Returns an empty message — no model call — when
  /// confidence is low or the model fails; the backend then uses its safe
  /// template for that priority.
  static Future<AiStep<String>> guidance({
    required Map<String, dynamic> extraction,
    required Map<String, dynamic> score,
    required String language,
    required String locationHint,
    bool lowConfidence = false,
  }) async {
    final priority = (score['priority'] ?? 'UNKNOWN').toString().toUpperCase();
    if (lowConfidence || !{'HIGH', 'MEDIUM', 'LOW'}.contains(priority)) {
      return const AiStep('', null); // backend: UNKNOWN template
    }
    String field(String key) {
      final v = (extraction[key] ?? '').toString().trim();
      return v.isEmpty ? 'not specified' : v;
    }

    final redFlag = extraction['red_flags_present'] == true;
    final prompt =
        '$_guidanceExamples\n\nNow generate for:\n'
        'Priority: $priority\n'
        'Complaint: ${field('chief_complaint')}\n'
        'Duration: ${field('duration')}\n'
        'Severity: ${field('severity')}\n'
        'Red flag: ${redFlag ? 'yes' : 'no'}\n'
        'Location: ${locationHint.isEmpty ? 'not specified' : locationHint}\n'
        'Language: $language\n'
        'Response:';

    try {
      final r = await HybridAIService.generate(
        prompt: prompt,
        mode: ClinicalAIConfig.modeFor(
          ClinicalStep.guidance,
          language: language,
        ),
        systemInstruction: _guidanceSystem,
        temperature: 0.3,
        maxOutputTokens: 200,
        onDeviceTimeout: ClinicalAIConfig.onDeviceTimeout,
        slowDeviceCooldown: ClinicalAIConfig.slowDeviceCooldown,
      );
      final message = r.text.trim().replaceFirst(
        RegExp(r'^response\s*:\s*', caseSensitive: false),
        '',
      );
      return AiStep(message, AiTrace.fromResult(ClinicalStep.guidance, r));
    } catch (e) {
      debugPrint('⚠️ Model E failed, backend will use the safe template: $e');
      return const AiStep('', null);
    }
  }

  // ── Model F: doctor brief (prefer on-device) ────────────────────────────
  // Ported from backend/models/model_f.py. The brief summarises the most
  // sensitive data of the session, so it prefers Gemini Nano. It works on
  // English text (translated turns for Kinyarwanda sessions). The model only
  // writes the narrative parts; the backend assembles the full brief
  // (model_f.build_brief) and falls back to a factual template if needed.

  static const _briefSystem =
      'You are a clinical documentation assistant. Write a patient brief for '
      'a doctor.\n'
      'Rules:\n'
      '- Report only what the patient said and what the system recorded.\n'
      '- No clinical interpretation, diagnosis, or advice.\n'
      '- Clinical language. Past tense. Concise.\n'
      '- Output valid JSON only matching the schema.';

  static const _briefSchema = <String, dynamic>{
    'type': 'object',
    'properties': {
      'narrative_summary': {'type': 'string'},
      'key_findings': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'red_flag_note': {'type': 'string'},
    },
    'required': ['narrative_summary', 'key_findings', 'red_flag_note'],
  };

  /// Model F. Returns {narrative_summary, key_findings, red_flag_note}.
  /// [turns] must be English (pass the translated turns for Kinyarwanda
  /// sessions). On failure returns an empty map; the backend then writes a
  /// factual template summary.
  static Future<AiStep<Map<String, dynamic>>> brief({
    required String sessionId,
    required Map<String, dynamic> extraction,
    required Map<String, dynamic> score,
    required List<TranslatedTurn> turns,
    required String language,
    int? patientAge,
  }) async {
    String field(String key) {
      final v = (extraction[key] ?? '').toString().trim();
      return v.isEmpty ? 'not recorded' : v;
    }

    final redFlag = switch (extraction['red_flags_present']) {
      true => 'YES',
      false => 'No',
      _ => 'Unknown',
    };
    final symptoms = (extraction['associated_symptoms'] as List? ?? const [])
        .join(', ');
    final riskFactors = (score['risk_factors'] as List? ?? const []).join(', ');
    final confidence = (score['confidence'] as num?)?.toDouble() ?? 0.0;
    final convo =
        turns.isEmpty
            ? '  (none)'
            : turns
                .map((t) => '  Q: ${t.question ?? ''}\n  A: ${t.answer}')
                .join('\n');

    final prompt =
        'Session: $sessionId | Language: $language | '
        'Age: ${patientAge ?? 'unknown'}\n\n'
        'Structured symptoms:\n'
        '  Chief complaint : ${field('chief_complaint')}\n'
        '  Body part       : ${field('body_part')}\n'
        '  Duration        : ${field('duration')}\n'
        '  Severity        : ${field('severity')}\n'
        '  Other symptoms  : ${symptoms.isEmpty ? 'none' : symptoms}\n'
        '  Red flag        : $redFlag\n'
        '  Observations    : ${(extraction['additional_observations'] ?? '').toString().trim().isEmpty ? 'none' : extraction['additional_observations']}\n\n'
        'Conversation (English):\n$convo\n\n'
        'Risk score:\n'
        '  Priority        : ${score['priority'] ?? 'unknown'}\n'
        '  Suspected issue : ${score['suspected_issue'] ?? 'not determined'}\n'
        '  Risk factors    : ${riskFactors.isEmpty ? 'none' : riskFactors}\n'
        '  Confidence      : ${confidence.toStringAsFixed(2)}\n\n'
        'Write narrative_summary (2-4 factual sentences), key_findings (short '
        'facts) and red_flag_note (one sentence if a red flag is present, '
        'otherwise an empty string). JSON only.';

    try {
      final r = await HybridAIService.generate(
        prompt: prompt,
        mode: ClinicalAIConfig.modeFor(ClinicalStep.brief, language: 'english'),
        systemInstruction: _briefSystem,
        jsonSchema: _briefSchema,
        temperature: 0.1,
        maxOutputTokens: 600,
        onDeviceTimeout: ClinicalAIConfig.onDeviceTimeout,
        slowDeviceCooldown: ClinicalAIConfig.slowDeviceCooldown,
      );
      return AiStep(
        (r.json as Map).cast<String, dynamic>(),
        AiTrace.fromResult(ClinicalStep.brief, r),
      );
    } catch (e) {
      debugPrint('⚠️ Model F failed, backend will write a template brief: $e');
      return const AiStep(<String, dynamic>{}, null);
    }
  }

  static Map<String, dynamic> _normaliseExtraction(Map<String, dynamic> raw) {
    final out = <String, dynamic>{
      for (final f in _extractionStringFields)
        f: (raw[f] == null) ? '' : raw[f].toString().trim(),
    };
    final symptoms = raw['associated_symptoms'];
    final symptomList = symptoms is List ? symptoms : [symptoms];
    out['associated_symptoms'] = [
      for (final s in symptomList)
        if (s != null && s.toString().trim().isNotEmpty) s.toString().trim(),
    ];
    final rf = raw['red_flags_present'];
    out['red_flags_present'] = rf is bool ? rf : null;
    return out;
  }

  // ── Translation (Kinyarwanda → English, cloud) ──────────────────────────

  static const _translationSystem =
      'You are a medical interpreter at a Rwandan hospital. Translate what a '
      'patient said (and the question they were answering) from Kinyarwanda '
      'into plain English for clinicians.\n'
      'Rules:\n'
      '- Patients often mix Kinyarwanda with English or French words; '
      'translate the meaning of the whole utterance.\n'
      '- Translate faithfully. Do not add, interpret, diagnose or summarise.\n'
      '- Keep names, numbers, ages, phone numbers, durations, places and body '
      'parts exactly.\n'
      '- If a part is already English, keep it as is.\n'
      '- If the text is empty or unintelligible, return it unchanged.';

  static const _translationSchema = <String, dynamic>{
    'type': 'object',
    'properties': {
      'question_en': {'type': 'string'},
      'answer_en': {'type': 'string'},
    },
    'required': ['question_en', 'answer_en'],
  };

  /// Translates one conversation turn (the kiosk question and the patient's
  /// answer, or just the initial complaint) to English in a single cloud call.
  /// Nano cannot read Kinyarwanda, so this always runs in the cloud.
  ///
  /// Never throws: on failure the original text is returned with
  /// [TranslatedTurn.translated] = false so the session can continue.
  static Future<AiStep<TranslatedTurn>> translateTurn({
    required String answer,
    String? question,
  }) async {
    if (answer.trim().isEmpty) {
      return AiStep(TranslatedTurn(answer: answer, question: question), null);
    }
    final prompt =
        'Question asked by the kiosk: ${question?.trim().isNotEmpty == true ? question!.trim() : '(none — this is the opening complaint)'}\n'
        'Patient said: ${answer.trim()}\n\n'
        'Return question_en (empty string if there was no question) and answer_en.';
    try {
      final r = await HybridAIService.generate(
        prompt: prompt,
        mode: ClinicalAIConfig.modeFor(
          ClinicalStep.translation,
          language: 'kinyarwanda',
        ),
        systemInstruction: _translationSystem,
        jsonSchema: _translationSchema,
        temperature: 0,
        maxOutputTokens: 400,
      );
      final data = r.json as Map<String, dynamic>;
      final answerEn = (data['answer_en'] as String?)?.trim() ?? '';
      final questionEn = (data['question_en'] as String?)?.trim() ?? '';
      return AiStep(
        TranslatedTurn(
          answer: answerEn.isNotEmpty ? answerEn : answer,
          question:
              question == null
                  ? null
                  : (questionEn.isNotEmpty ? questionEn : question),
        ),
        AiTrace.fromResult(ClinicalStep.translation, r),
      );
    } catch (e) {
      debugPrint('⚠️ Translation failed, keeping original text: $e');
      return AiStep(
        TranslatedTurn(answer: answer, question: question, translated: false),
        null,
      );
    }
  }
}
