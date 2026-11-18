import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api_service.dart';
import 'clinical_ai.dart';

// Same platform-specific multipart helper the legacy kiosk calls use.
import 'api_service_stub.dart'
    if (dart.library.io) 'api_service_io.dart'
    as multipart;

/// Client for the hybrid kiosk endpoints (backend: routers/kiosk_hybrid.py).
/// The backend only transcribes, validates, routes and persists; the AI
/// steps run in the browser (ClinicalAI → Firebase AI Logic).
class HybridKioskApi {
  HybridKioskApi._();

  static Map<String, String> get _jsonHeaders => {
    'Content-Type': 'application/json',
    if (kIsWeb) 'ngrok-skip-browser-warning': 'true',
  };

  static Never _fail(String what, http.Response r) =>
      throw HybridKioskException(what, r.statusCode, r.body);

  /// Model A (Whisper). First call: initial complaint. Later calls: the
  /// answer to [question]; [questionTrace] says how that question was made.
  static Future<TranscribeResult> transcribe({
    required String sessionId,
    required String audioFilePath,
    String? language,
    String? question,
    AiTrace? questionTrace,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${ApiService.baseUrl}/kiosk/$sessionId/transcribe'),
    );
    if (kIsWeb) request.headers['ngrok-skip-browser-warning'] = 'true';
    request.files.add(
      await multipart.createMultipartFile('audio', audioFilePath),
    );
    if (language != null) request.fields['language'] = language;
    if (question != null) request.fields['question'] = question;
    if (questionTrace != null) {
      request.fields['question_ai'] = jsonEncode(questionTrace.toJson());
    }
    final response = await http.Response.fromStream(await request.send());
    if (response.statusCode != 200) _fail('transcribe', response);
    return TranscribeResult.fromJson(jsonDecode(response.body));
  }

  /// Sends the browser's Model B extraction; the backend decides what next.
  static Future<ExtractionResult> submitExtraction({
    required String sessionId,
    required Map<String, dynamic> extraction,
    List<AiTrace> traces = const [],
  }) async {
    final response = await http.post(
      Uri.parse('${ApiService.baseUrl}/kiosk/$sessionId/extraction'),
      headers: _jsonHeaders,
      body: jsonEncode({
        'extraction': extraction,
        'ai': [for (final t in traces) t.toJson()],
      }),
    );
    if (response.statusCode != 200) _fail('extraction', response);
    return ExtractionResult.fromJson(jsonDecode(response.body));
  }

  /// Sends the browser's Model D score (+ optional routing suggestion for
  /// unclear issues). The backend applies triage safety rules and routes.
  static Future<ScoreResult> submitScore({
    required String sessionId,
    required Map<String, dynamic> score,
    Map<String, dynamic>? routingSuggestion,
    List<AiTrace> traces = const [],
  }) async {
    final response = await http.post(
      Uri.parse('${ApiService.baseUrl}/kiosk/$sessionId/score'),
      headers: _jsonHeaders,
      body: jsonEncode({
        'score': score,
        if (routingSuggestion != null) 'routing_suggestion': routingSuggestion,
        'ai': [for (final t in traces) t.toJson()],
      }),
    );
    if (response.statusCode != 200) _fail('score', response);
    return ScoreResult.fromJson(jsonDecode(response.body));
  }

  /// Sends the Model E message + Model F brief fields. The backend vets the
  /// message, assembles the brief, persists the session, queues the patient
  /// and sends the SMS. Returns the routing shown on the completion screen.
  static Future<FinishResponse> complete({
    required String sessionId,
    required String patientMessage,
    required Map<String, dynamic> brief,
    String patientName = '',
    String patientPhone = '',
    String patientLocation = '',
    List<AiTrace> traces = const [],
  }) async {
    final response = await http.post(
      Uri.parse('${ApiService.baseUrl}/kiosk/$sessionId/complete'),
      headers: _jsonHeaders,
      body: jsonEncode({
        'patient_message': patientMessage,
        'brief': brief,
        'patient_name': patientName,
        'patient_phone': patientPhone,
        'patient_location': patientLocation,
        'ai': [for (final t in traces) t.toJson()],
      }),
    );
    if (response.statusCode != 200) _fail('complete', response);
    return FinishResponse.fromJson(jsonDecode(response.body));
  }
}

class ScoreResult {
  const ScoreResult({
    required this.score,
    required this.routing,
    required this.lowConfidence,
    required this.briefContext,
  });

  factory ScoreResult.fromJson(Map<String, dynamic> json) => ScoreResult(
    score: (json['score'] as Map).cast<String, dynamic>(),
    routing: (json['routing'] as Map).cast<String, dynamic>(),
    lowConfidence: json['low_confidence'] as bool? ?? false,
    briefContext: (json['brief_context'] as Map).cast<String, dynamic>(),
  );

  /// Score after backend validation + safety rules (may differ from the
  /// model's: e.g. a red flag forces HIGH — see score['safety_override']).
  final Map<String, dynamic> score;

  /// department, queue, queue_number, location_hint, urgency_label.
  final Map<String, dynamic> routing;
  final bool lowConfidence;

  /// Inputs for Models E and F (extraction, conversation, language, ...).
  final Map<String, dynamic> briefContext;

  String get priority => score['priority'] as String? ?? 'MEDIUM';
  String get locationHint => routing['location_hint'] as String? ?? '';
}

class HybridKioskException implements Exception {
  HybridKioskException(this.step, this.statusCode, this.body);
  final String step;
  final int statusCode;
  final String body;

  @override
  String toString() => 'HybridKioskException($step): $statusCode $body';
}

class ConversationTurnText {
  const ConversationTurnText({required this.question, required this.answer});
  final String question;
  final String answer;
}

class TranscribeResult {
  const TranscribeResult({
    required this.text,
    required this.language,
    required this.confidence,
    required this.isInitial,
    required this.needsTranslation,
    required this.initial,
    required this.turns,
  });

  factory TranscribeResult.fromJson(Map<String, dynamic> json) {
    final convo = (json['conversation'] as Map?) ?? const {};
    return TranscribeResult(
      text: json['text'] as String? ?? '',
      language: json['language'] as String? ?? 'kinyarwanda',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      isInitial: json['is_initial'] as bool? ?? false,
      needsTranslation: json['needs_translation'] as bool? ?? false,
      initial: convo['initial'] as String? ?? '',
      turns: [
        for (final t in (convo['turns'] as List? ?? const []))
          ConversationTurnText(
            question: (t as Map)['question'] as String? ?? '',
            answer: t['answer'] as String? ?? '',
          ),
      ],
    );
  }

  /// What the patient just said, in the original language.
  final String text;
  final String language;
  final double confidence;
  final bool isInitial;
  final bool needsTranslation;

  /// Whole conversation so far (original language).
  final String initial;
  final List<ConversationTurnText> turns;
}

class ExtractionResult {
  const ExtractionResult({
    required this.coverageComplete,
    this.question,
    this.questionSource,
    this.needsAiQuestion = false,
    this.questionContext,
    this.fallbackQuestion,
    this.patientName = '',
    this.patientPhone = '',
  });

  factory ExtractionResult.fromJson(Map<String, dynamic> json) =>
      ExtractionResult(
        coverageComplete: json['coverage_complete'] as bool? ?? false,
        question: json['question'] as String?,
        questionSource: json['question_source'] as String?,
        needsAiQuestion: json['needs_ai_question'] as bool? ?? false,
        questionContext:
            (json['question_context'] as Map?)?.cast<String, dynamic>(),
        fallbackQuestion: json['fallback_question'] as String?,
        patientName: json['patient_name'] as String? ?? '',
        patientPhone: json['patient_phone'] as String? ?? '',
      );

  final bool coverageComplete;

  /// Rule-based question to ask next (when [questionSource] == 'rules').
  final String? question;
  final String? questionSource;

  /// True → generate the next question in the browser (Model C).
  final bool needsAiQuestion;
  final Map<String, dynamic>? questionContext;
  final String? fallbackQuestion;
  final String patientName;
  final String patientPhone;
}
