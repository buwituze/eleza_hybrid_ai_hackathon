import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api_service.dart';

// Web-only import for Blob URL playback
import 'tts_service_web.dart' if (dart.library.io) 'tts_service_io.dart'
    as platform;

/// Text-to-speech via the Eleza backend (POST /tts), which calls ElevenLabs
/// ("Benitha - Rwandan Nurse 1" voice, handles Kinyarwanda and English).
///
/// The ElevenLabs API key lives only on the server; the app never sees it.
class TTSService {
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isSpeaking = false;

  bool get isSpeaking => _isSpeaking;

  Future<Uint8List?> _synthesize(String text, String language) async {
    try {
      final response = await http.post(
        Uri.parse('${ApiService.baseUrl}/tts'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'audio/mpeg',
          // Required for ngrok free domains to skip the HTML warning page.
          if (kIsWeb) 'ngrok-skip-browser-warning': 'true',
        },
        body: jsonEncode({'text': text, 'language': language}),
      );

      if (response.statusCode == 200) {
        return response.bodyBytes;
      }
      debugPrint('❌ TTS backend error ${response.statusCode}: ${response.body}');
      return null;
    } catch (e) {
      debugPrint('❌ TTS request failed: $e');
      return null;
    }
  }

  /// Speak text. Falls back to a silent pause if TTS is unavailable so the
  /// kiosk flow keeps moving.
  Future<void> speak(String text, {String language = 'english'}) async {
    if (text.isEmpty) return;

    _isSpeaking = true;
    debugPrint('🔊 TTS ($language): "$text"');

    try {
      final audioBytes = await _synthesize(text, language);
      if (audioBytes != null) {
        await platform.playAudioBytes(_audioPlayer, audioBytes);
        await _audioPlayer.onPlayerComplete.first;
      } else {
        // Fallback: simulate speaking duration
        await Future.delayed(Duration(milliseconds: text.length * 50));
      }
    } catch (e) {
      debugPrint('❌ TTS error: $e');
    }

    _isSpeaking = false;
  }

  /// Stop currently playing audio
  Future<void> stop() async {
    await _audioPlayer.stop();
    _isSpeaking = false;
  }

  /// Release resources
  void dispose() {
    _audioPlayer.dispose();
  }
}
