import 'app_config.dart';

/// Prompts for the in-browser AI steps (Firebase AI Logic).
///
/// Each prompt can be replaced from Firebase console → Remote Config (Client
/// template) using the key in [keys]. The texts below are the in-app defaults
/// and are used when the console has no value, or a value that is blank or
/// too long. JSON schemas stay in code: the backend depends on their shape and
/// re-validates every result, so a prompt change cannot bypass its guardrails.
///
/// Not here: Model C's system instruction, which the backend sends with each
/// question context (routers/kiosk_hybrid.py).
class ClinicalPrompts {
  ClinicalPrompts._();

  /// Longer values are ignored (Gemini Nano's context is ~9k tokens).
  static const maxLength = 8000;

  static String _get(String key) {
    final value = AppConfig.getString(key).trim();
    if (value.isEmpty || value.length > maxLength) {
      return defaults[key]! as String;
    }
    return value;
  }

  static String get translationSystem => _get('prompt_translation_system');
  static String get extractionSystem => _get('prompt_extraction_system');
  static String get scoreSystem => _get('prompt_score_system');
  static String get triageRules => _get('prompt_triage_rules');
  static String get routingSystem => _get('prompt_routing_system');
  static String get guidanceSystem => _get('prompt_guidance_system');
  static String get guidanceExamples => _get('prompt_guidance_examples');
  static String get briefSystem => _get('prompt_brief_system');

  /// Remote Config key → default text (merged into AppConfig.defaults).
  static const Map<String, Object> defaults = {
    'prompt_translation_system': _translationSystem,
    'prompt_extraction_system': _extractionSystem,
    'prompt_score_system': _scoreSystem,
    'prompt_triage_rules': _triageRules,
    'prompt_routing_system': _routingSystem,
    'prompt_guidance_system': _guidanceSystem,
    'prompt_guidance_examples': _guidanceExamples,
    'prompt_brief_system': _briefSystem,
  };

  /// All prompt keys, for the debug page.
  static Iterable<String> get keys => defaults.keys;

  /// Prompt keys currently overridden from the console.
  static List<String> get fromConsole =>
      keys.where((k) => AppConfig.sourceOf(k) == 'remote').toList();

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

  static const _routingSystem =
      'You are a clinical routing assistant at a hospital. No diagnosis.';

  static const _guidanceSystem =
      'You are a healthcare system assistant in a hospital.\n'
      'Explain the next steps to a patient using only the system\'s decision.\n'
      'Rules:\n'
      '- No disease names. No diagnosis. No medical advice. No causes.\n'
      '- Do not change the priority level.\n'
      '- 3 to 5 short sentences. Calm and clear.\n'
      '- Output the patient message only.\n'
      '- Write entirely in the language given in the Language field.';

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

  static const _briefSystem =
      'You are a clinical documentation assistant. Write a patient brief for '
      'a doctor.\n'
      'Rules:\n'
      '- Report only what the patient said and what the system recorded.\n'
      '- No clinical interpretation, diagnosis, or advice.\n'
      '- Clinical language. Past tense. Concise.\n'
      '- Output valid JSON only matching the schema.';
}
