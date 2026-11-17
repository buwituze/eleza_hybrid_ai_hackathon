import 'package:flutter/foundation.dart';

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

/// Where each step runs. Defaults below; Remote Config overrides them later.
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

  static final Map<ClinicalStep, InferenceMode> modes = {
    ClinicalStep.translation: InferenceMode.onlyInCloud,
    ClinicalStep.extraction: InferenceMode.preferOnDevice,
    ClinicalStep.question: InferenceMode.preferOnDevice,
    ClinicalStep.score: InferenceMode.preferInCloud,
    ClinicalStep.routing: InferenceMode.preferInCloud,
    ClinicalStep.guidance: InferenceMode.preferOnDevice,
    ClinicalStep.brief: InferenceMode.preferOnDevice,
  };

  /// Steps whose OUTPUT is patient-facing text in the session language.
  static const _patientLanguageSteps = {
    ClinicalStep.question,
    ClinicalStep.guidance,
  };

  static Duration onDeviceTimeout = const Duration(seconds: 12);

  static InferenceMode modeFor(ClinicalStep step, {required String language}) {
    if (language != 'english' && _patientLanguageSteps.contains(step)) {
      return InferenceMode.onlyInCloud; // Nano cannot write Kinyarwanda
    }
    return modes[step] ?? InferenceMode.preferOnDevice;
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
