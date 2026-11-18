import 'package:flutter/foundation.dart';

import 'api_service.dart' show FinishResponse;
import 'clinical_ai.dart';
import 'hybrid_kiosk_api.dart';

/// What the kiosk should do after a patient utterance.
class KioskNextStep {
  const KioskNextStep({
    required this.coverageComplete,
    this.question,
    this.patientName = '',
    this.patientPhone = '',
  });

  final bool coverageComplete;

  /// Question to speak next (null when coverage is complete).
  final String? question;
  final String patientName;
  final String patientPhone;
}

/// One patient session in the hybrid flow:
///
///   Whisper (server) → translate rw→en (cloud) → Model B (on-device)
///   → backend rules → Model C (on-device / cloud for rw) → … →
///   Model D (cloud) → backend safety rules + routing →
///   Model E + Model F → backend persist / queue / SMS.
///
/// Keeps the English translation of the conversation so on-device steps never
/// see Kinyarwanda, and the question that was really asked (independent of
/// what the UI happens to be speaking).
class HybridKioskSession {
  HybridKioskSession(this.sessionId, {this.onTrace});

  final String sessionId;

  /// Called as soon as each AI step finishes (drives the live kiosk badge).
  final void Function(AiTrace trace)? onTrace;

  String _language = 'kinyarwanda';
  String _initialEn = '';
  final List<TranslatedTurn> _turnsEn = [];
  Map<String, dynamic> _extraction = {};

  String? _currentQuestion;
  AiTrace? _currentQuestionTrace;

  String get language => _language;
  String? get currentQuestion => _currentQuestion;

  /// Every AI step of this session in order (for the On-device/Cloud badges).
  final List<AiTrace> traces = [];

  void _keep(AiTrace? t) {
    if (t == null) return;
    traces.add(t);
    onTrace?.call(t);
  }

  /// The patient's opening complaint.
  Future<KioskNextStep> submitInitial({
    required String audioFilePath,
    required String languageHint,
  }) async {
    final t = await HybridKioskApi.transcribe(
      sessionId: sessionId,
      audioFilePath: audioFilePath,
      language: languageHint,
    );
    _language = t.language;
    final translated = await _toEnglish(
      answer: t.text,
      needs: t.needsTranslation,
    );
    _initialEn = translated.value.answer;
    return _extractAndDecide(translationTrace: translated.trace);
  }

  /// The patient's answer to [currentQuestion].
  Future<KioskNextStep> submitAnswer({required String audioFilePath}) async {
    final question = _currentQuestion;
    if (question == null) {
      throw StateError('No question is pending for this session.');
    }
    final t = await HybridKioskApi.transcribe(
      sessionId: sessionId,
      audioFilePath: audioFilePath,
      question: question,
      questionTrace: _currentQuestionTrace,
    );
    final translated = await _toEnglish(
      question: question,
      answer: t.text,
      needs: t.needsTranslation,
    );
    _turnsEn.add(translated.value);
    return _extractAndDecide(translationTrace: translated.trace);
  }

  /// Scores, routes, writes the patient message and doctor brief, and
  /// completes the session on the backend.
  Future<FinishResponse> finish({
    String patientName = '',
    String patientPhone = '',
  }) async {
    // Model D (+ routing suggestion when the issue is unclear)
    final scoreStep = await ClinicalAI.score(
      extraction: _extraction,
      patientAge: int.tryParse('${_extraction['patient_age'] ?? ''}'),
    );
    _keep(scoreStep.trace);
    AiStep<Map<String, dynamic>?>? routingStep;
    if (scoreStep.value['suspected_issue'] == ClinicalAI.unclearIssue &&
        scoreStep.value['priority'] != 'HIGH') {
      routingStep = await ClinicalAI.suggestRouting(
        extraction: _extraction,
        turns: _turnsEn,
      );
      _keep(routingStep.trace);
    }
    final scored = await HybridKioskApi.submitScore(
      sessionId: sessionId,
      score: scoreStep.value,
      routingSuggestion: routingStep?.value,
      traces: [
        if (scoreStep.trace != null) scoreStep.trace!,
        if (routingStep?.trace != null) routingStep!.trace!,
      ],
    );
    if (scored.score['safety_override'] != null) {
      debugPrint('🛡️ Backend safety rule: ${scored.score['safety_override']}');
    }

    // Model E (patient message) and Model F (doctor brief) are independent.
    final context = scored.briefContext;
    final extraction =
        (context['extraction'] as Map?)?.cast<String, dynamic>() ?? _extraction;
    final results = await Future.wait([
      ClinicalAI.guidance(
        extraction: extraction,
        score: scored.score,
        language: _language,
        locationHint: scored.locationHint,
        lowConfidence: scored.lowConfidence,
      ),
      ClinicalAI.brief(
        sessionId: sessionId,
        extraction: extraction,
        score: scored.score,
        turns: _turnsEn,
        language: _language,
        patientAge: context['patient_age'] as int?,
      ),
    ]);
    final guidance = results[0] as AiStep<String>;
    final brief = results[1] as AiStep<Map<String, dynamic>>;
    _keep(guidance.trace);
    _keep(brief.trace);

    return HybridKioskApi.complete(
      sessionId: sessionId,
      patientMessage: guidance.value,
      brief: brief.value,
      patientName: patientName,
      patientPhone: patientPhone,
      traces: [
        if (guidance.trace != null) guidance.trace!,
        if (brief.trace != null) brief.trace!,
      ],
    );
  }

  // ── internals ──────────────────────────────────────────────────────────

  Future<AiStep<TranslatedTurn>> _toEnglish({
    String? question,
    required String answer,
    required bool needs,
  }) async {
    if (!needs) {
      return AiStep(TranslatedTurn(question: question, answer: answer), null);
    }
    final step = await ClinicalAI.translateTurn(
      question: question,
      answer: answer,
    );
    _keep(step.trace);
    return step;
  }

  Future<KioskNextStep> _extractAndDecide({AiTrace? translationTrace}) async {
    final b = await ClinicalAI.extract(initial: _initialEn, turns: _turnsEn);
    _keep(b.trace);
    _extraction = b.value;

    final next = await HybridKioskApi.submitExtraction(
      sessionId: sessionId,
      extraction: b.value,
      traces: [
        if (translationTrace != null) translationTrace,
        if (b.trace != null) b.trace!,
      ],
    );

    if (next.coverageComplete) {
      _currentQuestion = null;
      _currentQuestionTrace = null;
      return KioskNextStep(
        coverageComplete: true,
        patientName: next.patientName,
        patientPhone: next.patientPhone,
      );
    }

    if (next.needsAiQuestion && next.questionContext != null) {
      final c = await ClinicalAI.nextQuestion(
        context: next.questionContext!,
        fallbackQuestion: next.fallbackQuestion ?? _defaultFallbackQuestion,
      );
      _keep(c.trace);
      _currentQuestion = c.value;
      _currentQuestionTrace = c.trace; // sent with the answer's /transcribe
    } else {
      _currentQuestion =
          next.question ?? next.fallbackQuestion ?? _defaultFallbackQuestion;
      _currentQuestionTrace = null; // rule-based, no model involved
    }

    return KioskNextStep(
      coverageComplete: false,
      question: _currentQuestion,
      patientName: next.patientName,
      patientPhone: next.patientPhone,
    );
  }

  String get _defaultFallbackQuestion =>
      _language == 'english'
          ? 'Can you tell me more about how you are feeling?'
          : 'Mbwira byinshi ku bibazo byawe?';
}
