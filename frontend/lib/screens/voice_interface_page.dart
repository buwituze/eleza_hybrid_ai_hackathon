import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:gif_view/gif_view.dart';
import '../services/api_service.dart';
import '../services/audio_service.dart';
import '../services/hybrid_ai_service.dart';
import '../services/hybrid_kiosk_flow.dart';
import '../services/clinical_ai.dart' show AiTrace;
import '../components/ai_badges.dart';
import '../services/tts_service.dart';

enum SessionState {
  idle,
  waitingForInitialComplaint,
  waitingForAnswer,
  recordingAnswer,
}

class VoiceInterfacePage extends StatefulWidget {
  const VoiceInterfacePage({super.key});

  @override
  State<VoiceInterfacePage> createState() => _VoiceInterfacePageState();
}

class _VoiceInterfacePageState extends State<VoiceInterfacePage> {
  // Session state
  String? _sessionId;
  // AI steps run in the browser (Firebase AI Logic hybrid inference).
  HybridKioskSession? _hybrid;
  AiTrace? _lastAiTrace; // drives the live On-device / Cloud badge
  bool _isSessionActive = false;
  SessionState _sessionState = SessionState.idle;
  String? _currentQuestion;

  // Patient info (displayed during session for confirmation)
  String _patientName = '';
  String _patientPhone = '';
  bool _patientInfoConfirmed = false;

  // UI state
  bool _isRecording = false;
  bool _isProcessing = false;
  String get _statusMessage {
    if (_isProcessing) return 'processing'.tr();
    if (_isRecording) return 'listening'.tr();
    if (_ttsService.isSpeaking) return 'speaking'.tr();
    if (_isSessionActive) return 'status_end_hint'.tr();
    return 'status_start_hint'.tr();
  }

  // Services
  final ApiService _apiService = ApiService();
  final AudioService _audioService = AudioService();
  final TTSService _ttsService = TTSService();

  static const Color _buttonGreen = Color(0xFFB2B24B);
  static const bool _showGifArea = true;

  // On-device model (Gemini Nano via Firebase AI Logic). null = not checked yet.
  OnDeviceStatus? _onDeviceStatus;
  double? _onDeviceDownloadProgress;

  @override
  void initState() {
    super.initState();
    _updateStatusMessage();
    _refreshOnDeviceStatus();
  }

  // ==================== ON-DEVICE MODEL ====================

  Future<void> _refreshOnDeviceStatus() async {
    if (!HybridAIService.isSupported) {
      setState(() => _onDeviceStatus = OnDeviceStatus.unsupported);
      return;
    }
    final status = await HybridAIService.onDeviceAvailability();
    debugPrint('On-device model status: ${status.name}');
    if (mounted) setState(() => _onDeviceStatus = status);
  }

  /// Starts the Gemini Nano download in the background. Chrome only allows
  /// this right after a user gesture, so it is called first thing from the
  /// Start button. Never blocks the session: until Nano is ready, hybrid
  /// prompts fall back to the cloud.
  void _warmUpOnDeviceModel() {
    if (!HybridAIService.isSupported ||
        _onDeviceStatus == OnDeviceStatus.available ||
        _onDeviceStatus == OnDeviceStatus.unsupported ||
        _onDeviceStatus == OnDeviceStatus.unavailable ||
        _onDeviceDownloadProgress != null) {
      return;
    }
    HybridAIService.prepareOnDevice(
          onProgress: (progress) {
            if (!mounted) return;
            setState(() {
              _onDeviceDownloadProgress = progress;
              if (progress >= 1.0) _onDeviceStatus = OnDeviceStatus.available;
            });
          },
        )
        .then((status) {
          debugPrint('On-device model after prepare: ${status.name}');
          if (mounted && _onDeviceStatus != OnDeviceStatus.available) {
            setState(() => _onDeviceStatus = status);
          }
        })
        .catchError((Object e) {
          debugPrint('On-device model warm-up failed (cloud will be used): $e');
        });
  }

  @override
  void dispose() {
    _audioService.dispose();
    _ttsService.dispose();
    super.dispose();
  }

  String get _currentLanguage =>
      context.locale.languageCode == 'rw' ? 'kinyarwanda' : 'english';

  void _updateStatusMessage() {
    setState(() {});
  }

  // ==================== SESSION MANAGEMENT ====================

  Future<void> _startSession() async {
    setState(() => _isProcessing = true);
    _updateStatusMessage();

    try {
      // Request microphone permission
      final hasPermission = await _audioService.requestPermission();
      if (!hasPermission) {
        _showError('microphone_permission_denied'.tr());
        setState(() => _isProcessing = false);
        return;
      }

      // Start session with backend
      final language = _currentLanguage;
      debugPrint('Starting session with language: $language');
      final response = await _apiService.startSession(language: language);
      debugPrint('Session started: ${response.sessionId}');

      setState(() {
        _sessionId = response.sessionId;
        _hybrid = HybridKioskSession(
          response.sessionId,
          onTrace: (t) {
            if (mounted) setState(() => _lastAiTrace = t);
          },
        );
        _lastAiTrace = null;
        _isSessionActive = true;
        _sessionState = SessionState.waitingForInitialComplaint;
        _isProcessing = false;
      });

      // Speak greeting
      await _speakText(response.greeting);

      // Automatically start recording for initial complaint
      await _startRecording();
    } catch (e) {
      debugPrint('Error starting session: $e');
      _showError('Failed to start session: $e');
      setState(() {
        _isProcessing = false;
        _isSessionActive = false;
      });
    }
  }

  Future<void> _endSession() async {
    // Cancel any ongoing recording
    if (_audioService.isRecording) {
      await _audioService.cancelRecording();
    }

    // Stop speaking
    await _ttsService.stop();

    setState(() {
      _isSessionActive = false;
      _sessionState = SessionState.idle;
      _sessionId = null;
      _hybrid = null;
      _lastAiTrace = null;
      _currentQuestion = null;
      _isRecording = false;
      _isProcessing = false;
      _patientName = '';
      _patientPhone = '';
    });

    _updateStatusMessage();
  }

  // ==================== AUDIO RECORDING ====================

  Future<void> _startRecording() async {
    try {
      debugPrint('🎙️ Attempting to start recording...');
      await _audioService.startRecording();
      setState(() => _isRecording = true);
      _updateStatusMessage();
      debugPrint('Recording started successfully');
    } catch (e) {
      debugPrint('❌ Recording failed: $e');
      _showError('Recording failed: $e');
      setState(() => _isRecording = false);
    }
  }

  Future<void> _stopRecordingAndSubmit() async {
    if (!_audioService.isRecording || _sessionId == null) {
      debugPrint('Cannot stop recording - not recording or no session');
      return;
    }

    debugPrint('Stopping recording...');
    setState(() {
      _isRecording = false;
      _isProcessing = true;
    });
    _updateStatusMessage();

    try {
      final audioFile = await _audioService.stopRecording();
      debugPrint('Audio file received: ${audioFile?.path}');

      if (audioFile == null) {
        _showError('no_audio_recorded'.tr());
        setState(() => _isProcessing = false);
        return;
      }

      if (_sessionState == SessionState.waitingForInitialComplaint) {
        await _submitInitialComplaint(audioFile.path);
      } else if (_sessionState == SessionState.recordingAnswer &&
          _currentQuestion != null) {
        await _submitAnswer(audioFile.path);
      }
    } catch (e) {
      debugPrint('❌ Error during stop/submit: $e');
      _showError('submission_failed'.tr());
      setState(() {
        _isProcessing = false;
        _sessionState = SessionState.waitingForAnswer;
      });
    }
  }

  Future<void> _submitInitialComplaint(String audioFilePath) async {
    try {
      debugPrint('Hybrid flow: initial complaint for session $_sessionId');
      final next = await _hybrid!.submitInitial(
        audioFilePath: audioFilePath,
        languageHint: _currentLanguage,
      );
      await _applyNextStep(next);
    } catch (e) {
      debugPrint('Error submitting initial complaint: $e');
      _showError('Failed to submit audio: $e');
      setState(() {
        _isProcessing = false;
        _sessionState = SessionState.waitingForInitialComplaint;
      });
      rethrow;
    }
  }

  Future<void> _submitAnswer(String audioFilePath) async {
    try {
      debugPrint('Hybrid flow: answer to "${_hybrid!.currentQuestion}"');
      final next = await _hybrid!.submitAnswer(audioFilePath: audioFilePath);
      await _applyNextStep(next);
    } catch (e) {
      debugPrint('Error submitting answer: $e');
      _showError('Failed to submit answer: $e');
      setState(() {
        _isProcessing = false;
        _sessionState = SessionState.waitingForAnswer;
      });
      rethrow;
    }
  }

  /// Shows/speaks the next question, or finishes when coverage is complete.
  Future<void> _applyNextStep(KioskNextStep next) async {
    if (next.coverageComplete) {
      debugPrint('Coverage complete, finishing session...');
      await _finishSession();
      return;
    }
    final question = next.question ?? '';
    setState(() {
      _currentQuestion = question;
      _sessionState = SessionState.waitingForAnswer;
      _isProcessing = false;
      if (next.patientName.isNotEmpty) _patientName = next.patientName;
      if (next.patientPhone.isNotEmpty) _patientPhone = next.patientPhone;
    });

    // Confirm name + phone once, then still ask the actual question (the
    // answer is recorded against the question the session really asked).
    if (_patientName.isNotEmpty &&
        _patientPhone.isNotEmpty &&
        !_patientInfoConfirmed) {
      _patientInfoConfirmed = true;
      final confirmText =
          _currentLanguage == 'kinyarwanda'
              ? 'Twashyize amazina yawe na nimero ya telefone kuri ecran. Reba ko aribyo. Amazina yawe ni $_patientName na nimero yawe ni $_patientPhone.'
              : 'We have displayed your name and phone number on the screen. Please check that they are correct. Your name is $_patientName and your phone number is $_patientPhone.';
      await _speakText(confirmText);
    }
    await _speakText(question);
  }

  Future<void> _finishSession() async {
    if (_sessionId == null || _hybrid == null) return;

    setState(() => _isProcessing = true);
    _updateStatusMessage();

    try {
      final response = await _hybrid!.finish(
        patientName: _patientName,
        patientPhone: _patientPhone,
      );

      // Speak the patient guidance message
      await _speakText(response.patientMessage);

      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder:
                (context) => CompletionScreen(
                  finishResponse: response,
                  aiTraces: [
                    for (final t in _hybrid?.traces ?? const <AiTrace>[])
                      t.toJson(),
                  ],
                  onDone: () {
                    Navigator.of(context).pop();
                    _endSession();
                  },
                ),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error finishing session: $e');
      _showError('finish_failed'.tr());
      setState(() => _isProcessing = false);
    }
  }

  // ==================== TTS ====================

  Future<void> _speakText(String text) async {
    debugPrint('🔊 Speaking: "$text"');
    setState(() => _currentQuestion = text);
    _updateStatusMessage();

    await _ttsService.speak(text, language: _currentLanguage);

    _updateStatusMessage();
  }

  // ==================== UI HELPERS ====================

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  void _handleButtonPress() {
    // Allow canceling if stuck processing
    if (_isProcessing) {
      _cancelAndReset();
      return;
    }

    if (!_isSessionActive) {
      _warmUpOnDeviceModel(); // must run inside the click (user gesture)
      _startSession();
    } else if (_isRecording) {
      _stopRecordingAndSubmit();
    } else if (_sessionState == SessionState.waitingForAnswer) {
      setState(() => _sessionState = SessionState.recordingAnswer);
      _startRecording();
    } else {
      _endSession();
    }
  }

  void _cancelAndReset() {
    debugPrint('Canceling stuck session');
    _audioService.cancelRecording();
    _ttsService.stop();
    setState(() {
      _isProcessing = false;
      _isRecording = false;
      _isSessionActive = false;
      _sessionState = SessionState.idle;
      _sessionId = null;
      _hybrid = null;
      _lastAiTrace = null;
      _currentQuestion = null;
      _patientName = '';
      _patientPhone = '';
    });
    _updateStatusMessage();
  }

  String _getButtonLabel() {
    if (_isProcessing) {
      return 'processing'.tr();
    } else if (!_isSessionActive) {
      return 'start_speaking'.tr();
    } else if (_isRecording) {
      return 'tap_when_done'.tr();
    } else if (_sessionState == SessionState.waitingForAnswer) {
      return 'tap_to_answer'.tr();
    } else {
      return 'tap_to_end'.tr();
    }
  }

  Color _getButtonColor() {
    if (_isProcessing) return const Color.fromARGB(255, 180, 180, 96);
    if (_isRecording) return const Color.fromARGB(255, 243, 188, 48);
    return _buttonGreen;
  }

  // ==================== BUILD UI ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Column(
                    children: [
                      const SizedBox(height: 32),

                      // Welcome message
                      Text(
                        'welcome'.tr(),
                        style: const TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                          color: Color.fromARGB(255, 0, 0, 0),
                        ),
                      ),
                      const SizedBox(height: 8),

                      if (constraints.maxWidth > 700)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 200),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Opacity(
                                opacity: 0,
                                child: IgnorePointer(
                                  child: LanguageDropdown(
                                    currentLanguage:
                                        context.locale.languageCode,
                                    onLanguageChange: (_) {},
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  'instruction'.tr(),
                                  style: const TextStyle(
                                    fontSize: 19,
                                    color: Color.fromARGB(255, 0, 0, 0),
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                              LanguageDropdown(
                                currentLanguage: context.locale.languageCode,
                                onLanguageChange: (String languageCode) {
                                  context.setLocale(Locale(languageCode));
                                },
                              ),
                            ],
                          ),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Column(
                            children: [
                              Text(
                                'instruction'.tr(),
                                style: const TextStyle(
                                  fontSize: 19,
                                  color: Color.fromARGB(255, 0, 0, 0),
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 12),
                              LanguageDropdown(
                                currentLanguage: context.locale.languageCode,
                                onLanguageChange: (String languageCode) {
                                  context.setLocale(Locale(languageCode));
                                },
                              ),
                            ],
                          ),
                        ),

                      if (_isSessionActive &&
                          (_patientName.isNotEmpty || _patientPhone.isNotEmpty))
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 32,
                            vertical: 8,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (_patientName.isNotEmpty)
                                Text(
                                  'Your name / Amazina yawe: $_patientName',
                                  style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFFB8860B),
                                  ),
                                ),
                              if (_patientPhone.isNotEmpty)
                                Text(
                                  'Your phone number / Nimero yawe: $_patientPhone',
                                  style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFFB8860B),
                                  ),
                                ),
                            ],
                          ),
                        ),

                      const Spacer(flex: 1),

                      // Microphone indicator
                      MicrophoneIndicator(
                        isRecording: _isRecording,
                        isSpeaking: _ttsService.isSpeaking,
                      ),
                      const SizedBox(height: 16),

                      // Dynamic question card (visible during session)
                      if (_isSessionActive && _currentQuestion != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color.fromARGB(
                                192,
                                178,
                                178,
                                75,
                              ).withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: const Color(
                                  0xFFB2B24B,
                                ).withValues(alpha: 0.2),
                              ),
                            ),
                            child: Text(
                              _currentQuestion!,
                              style: const TextStyle(
                                fontSize: 16,
                                color: Color.fromARGB(255, 0, 0, 0),
                                height: 1.4,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      if (_isSessionActive && _currentQuestion != null)
                        const SizedBox(height: 12),

                      // Status text with down arrow
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              _statusMessage,
                              style: TextStyle(
                                fontSize: 14,
                                color: const Color.fromARGB(255, 0, 0, 0),
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 4),
                            Icon(
                              Icons.arrow_downward_rounded,
                              color: const Color.fromARGB(255, 0, 0, 0),
                              size: 14,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),

                      // Hybrid AI indicator: Nano status + where the last
                      // AI step ran (Firebase AI Logic hybrid inference).
                      Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 10,
                        runSpacing: 6,
                        children: [
                          OnDeviceModelChip(
                            status: _onDeviceStatus,
                            downloadProgress: _onDeviceDownloadProgress,
                          ),
                          if (_isSessionActive && _lastAiTrace != null)
                            AiSourceBadge.fromTrace(_lastAiTrace!.toJson()),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // Main action button (wide rectangle)
                      Center(
                        child: SizedBox(
                          width: 400,
                          height: 40,
                          child: ElevatedButton(
                            onPressed: _handleButtonPress,
                            style: ButtonStyle(
                              backgroundColor: WidgetStatePropertyAll(
                                _getButtonColor(),
                              ),
                              overlayColor: const WidgetStatePropertyAll(
                                Colors.transparent,
                              ),
                              shape: WidgetStatePropertyAll(
                                RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              elevation: const WidgetStatePropertyAll(0),
                            ),
                            child:
                                _isProcessing
                                    ? const SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(
                                        color: Color.fromARGB(255, 0, 0, 0),
                                        strokeWidth: 1,
                                      ),
                                    )
                                    : Text(
                                      _getButtonLabel(),
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: Color.fromARGB(255, 0, 0, 0),
                                      ),
                                    ),
                          ),
                        ),
                      ),

                      if (_showGifArea) ...[
                        const SizedBox(height: 12),
                        Center(
                          child: SizedBox(
                            width: constraints.maxWidth > 700 ? 260 : 300,
                            height: constraints.maxWidth > 700 ? 150 : 185,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: GifView.asset(
                                'assets/voice-interface.gif',
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],

                      // Health-only disclaimer
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 40),
                        child: Text(
                          'health_disclaimer'.tr(),
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                            height: 1.4,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ==================== LANGUAGE DROPDOWN ====================

class LanguageDropdown extends StatelessWidget {
  final String currentLanguage;
  final Function(String) onLanguageChange;

  const LanguageDropdown({
    super.key,
    required this.currentLanguage,
    required this.onLanguageChange,
  });

  String _getLanguageName(String code) {
    return code == 'rw' ? 'Kinyarwanda' : 'English';
  }

  Widget _buildLanguageBadge(String code) {
    // Flag emojis work offline (rendered by device font system).
    // Fallback text labels are used if the flag emoji is unavailable.
    final flagEmoji = code == 'rw' ? '🇷🇼' : '🇬🇧';
    final fallbackLabel = code == 'rw' ? 'RW' : 'EN';
    return Container(
      width: 34,
      height: 32,
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFF1F3F5),
        borderRadius: BorderRadius.circular(27),
      ),
      child: Text(
        flagEmoji,
        style: const TextStyle(fontSize: 18),
        semanticsLabel: fallbackLabel,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 12, top: 0, bottom: 0, right: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade400, width: 1),
      ),
      child: DropdownButton<String>(
        value: currentLanguage,
        underline: const SizedBox(),
        icon: Padding(
          padding: const EdgeInsets.only(left: 4, right: 4),
          child: Icon(
            Icons.keyboard_arrow_down_rounded,
            color: Colors.grey.shade600,
            size: 22,
          ),
        ),
        isDense: false,
        borderRadius: BorderRadius.circular(16),
        dropdownColor: Colors.white,
        selectedItemBuilder: (BuildContext context) {
          return ['rw', 'en'].map((code) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildLanguageBadge(code),
                const SizedBox(width: 10),
                Text(
                  _getLanguageName(code),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.black87,
                  ),
                ),
              ],
            );
          }).toList();
        },
        items:
            ['rw', 'en'].map((code) {
              return DropdownMenuItem(
                value: code,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildLanguageBadge(code),
                      const SizedBox(width: 10),
                      Text(
                        _getLanguageName(code),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
        onChanged: (String? newLanguage) {
          if (newLanguage != null) {
            onLanguageChange(newLanguage);
          }
        },
      ),
    );
  }
}

// ==================== MICROPHONE INDICATOR ====================

class MicrophoneIndicator extends StatefulWidget {
  final bool isRecording;
  final bool isSpeaking;

  const MicrophoneIndicator({
    super.key,
    required this.isRecording,
    required this.isSpeaking,
  });

  @override
  State<MicrophoneIndicator> createState() => _MicrophoneIndicatorState();
}

class _MicrophoneIndicatorState extends State<MicrophoneIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dotController;
  int _dotCount = 1;

  @override
  void initState() {
    super.initState();
    _dotController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() {
          _dotCount = (_dotCount % 3) + 1;
        });
        _dotController.forward(from: 0);
      }
    });
  }

  @override
  void didUpdateWidget(MicrophoneIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool isActive = widget.isRecording || widget.isSpeaking;
    if (isActive && !_dotController.isAnimating) {
      _dotCount = 1;
      _dotController.forward(from: 0);
    } else if (!isActive && _dotController.isAnimating) {
      _dotController.stop();
    }
  }

  @override
  void dispose() {
    _dotController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isActive = widget.isRecording || widget.isSpeaking;
    const Color circleColor = Color(0xFFEDEBEB);

    return Container(
      width: 160,
      height: 160,
      decoration: const BoxDecoration(
        color: circleColor,
        shape: BoxShape.circle,
      ),
      child:
          isActive
              ? Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Icon(
                      Icons.record_voice_over_outlined,
                      color: Colors.black,
                      size: 48,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '.' * _dotCount,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
              )
              : const Icon(
                Icons.mic_none_outlined,
                color: Colors.black,
                size: 60,
              ),
    );
  }
}

// ==================== COMPLETION SCREEN ====================
class CompletionScreen extends StatelessWidget {
  final FinishResponse finishResponse;
  final VoidCallback onDone;

  /// Where each AI step of this session ran (On-device / Cloud).
  final List<Map<String, dynamic>> aiTraces;

  const CompletionScreen({
    super.key,
    required this.finishResponse,
    required this.onDone,
    this.aiTraces = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 48,
                ),
                child: Column(
                  children: [
                    // Success icon
                    Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        color: Colors.green.shade100,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.check_circle,
                        color: Colors.green.shade700,
                        size: 60,
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Completion message
                    Text(
                      'consultation_complete'.tr(),
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF003366),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),

                    // Patient message
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF003366).withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: const Color(0xFF003366).withValues(alpha: 0.2),
                          width: 2,
                        ),
                      ),
                      child: Text(
                        finishResponse.patientMessage,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade800,
                          height: 1.4,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Queue information
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: _getUrgencyColor(
                          finishResponse.urgencyLabel,
                        ).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _getUrgencyColor(finishResponse.urgencyLabel),
                          width: 2,
                        ),
                      ),
                      child: Column(
                        children: [
                          Text(
                            'your_queue_number'.tr(),
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey.shade700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${finishResponse.queueNumber}',
                            style: TextStyle(
                              fontSize: 48,
                              fontWeight: FontWeight.bold,
                              color: _getUrgencyColor(
                                finishResponse.urgencyLabel,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            finishResponse.department,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey.shade800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            finishResponse.urgencyLabel,
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Location hint
                    Row(
                      children: [
                        const Icon(
                          Icons.location_on,
                          color: Color(0xFF003366),
                          size: 24,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            finishResponse.locationHint,
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey.shade700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (aiTraces.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'How your answers were processed',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF003366),
                              ),
                            ),
                            const SizedBox(height: 8),
                            AiTraceSummary(traces: aiTraces, dense: true),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),

                    // Done button
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton(
                        onPressed: onDone,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF003366),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          'done'.tr(),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Color _getUrgencyColor(String urgency) {
    switch (urgency.toLowerCase()) {
      case 'urgent':
        return Colors.red;
      case 'standard':
        return Colors.orange;
      case 'routine':
        return Colors.green;
      default:
        return Colors.blue;
    }
  }
}
