import 'dart:async';

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';

/// Firebase Remote Config with in-app defaults.
///
/// Every value has a default compiled into the app ([defaults]), so the kiosk
/// works offline, before the first fetch, and when a fetch fails. Values set
/// in Firebase console → Remote Config override those defaults after the next
/// successful fetch.
///
/// Call [init] once at startup, after Firebase and App Check are initialised.
/// Read values with [getString], [getInt], [getDouble], [getBool].
class AppConfig {
  AppConfig._();

  /// Parameter keys. Add new parameters here AND to [defaults].
  static const kConfigVersion = 'config_version';

  // Hybrid inference (read by ClinicalAIConfig in clinical_ai.dart).
  // Mode values: prefer_on_device | only_on_device | prefer_in_cloud |
  // only_in_cloud. Translation is not configurable (always cloud).
  static const kModeExtraction = 'ai_mode_extraction';
  static const kModeQuestion = 'ai_mode_question';
  static const kModeScore = 'ai_mode_score';
  static const kModeRouting = 'ai_mode_routing';
  static const kModeGuidance = 'ai_mode_guidance';
  static const kModeBrief = 'ai_mode_brief';
  static const kOnDeviceTimeoutMs = 'ai_on_device_timeout_ms';
  static const kSlowDeviceCooldownMs = 'ai_slow_device_cooldown_ms';

  /// In-app defaults. A parameter that is not in this map has no default and
  /// reads as ''/0/false until the console provides it, so keep every key here.
  static const Map<String, Object> defaults = {
    // Shows which config the kiosk is running: 'in-app defaults' until the
    // console publishes a value for it (e.g. 'v1 · 2026-11-20').
    kConfigVersion: 'in-app defaults',

    kModeExtraction: 'prefer_on_device',
    kModeQuestion: 'prefer_on_device',
    kModeScore: 'prefer_in_cloud',
    kModeRouting: 'prefer_in_cloud',
    kModeGuidance: 'prefer_on_device',
    kModeBrief: 'prefer_on_device',
    // How long Nano gets before the cloud answers instead.
    kOnDeviceTimeoutMs: 12000,
    // After a timeout, skip Nano for this long (slow kiosk hardware).
    kSlowDeviceCooldownMs: 300000,
  };

  /// How long startup waits for the network before using cached/default values.
  static const _startupFetchTimeout = Duration(seconds: 5);

  static FirebaseRemoteConfig? _rc;
  static bool _initialised = false;

  /// True once [init] has run (even if the fetch failed).
  static bool get isInitialised => _initialised;

  /// Sets defaults, activates any cached config, then fetches the latest one.
  /// Never throws: on any failure the app keeps the in-app defaults.
  static Future<void> init() async {
    if (_initialised) return;
    try {
      final rc = FirebaseRemoteConfig.instance;
      await rc.setConfigSettings(
        RemoteConfigSettings(
          fetchTimeout: const Duration(seconds: 10),
          // Debug: fetch on every start so console changes show up at once.
          // Release: Firebase recommends at most a few fetches per hour.
          minimumFetchInterval:
              kDebugMode ? Duration.zero : const Duration(hours: 1),
        ),
      );
      await rc.setDefaults(defaults);
      _rc = rc;

      final updated = await rc.fetchAndActivate().timeout(
        _startupFetchTimeout,
        onTimeout: () {
          debugPrint('Remote Config: fetch slow, using cached/default values');
          return false;
        },
      );
      debugPrint(
        'Remote Config ready (${updated ? 'new values activated' : 'no change'}; '
        '$kConfigVersion=${getString(kConfigVersion)})',
      );
    } catch (e) {
      debugPrint('Remote Config unavailable, using in-app defaults: $e');
    } finally {
      _initialised = true;
    }
  }

  // ── typed getters (fall back to [defaults] if Remote Config never loaded) ──

  static String getString(String key) =>
      _rc?.getString(key) ?? (defaults[key]?.toString() ?? '');

  static int getInt(String key) {
    if (_rc != null) return _rc!.getInt(key);
    final v = defaults[key];
    return v is num ? v.toInt() : int.tryParse('$v') ?? 0;
  }

  static double getDouble(String key) {
    if (_rc != null) return _rc!.getDouble(key);
    final v = defaults[key];
    return v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
  }

  static bool getBool(String key) {
    if (_rc != null) return _rc!.getBool(key);
    final v = defaults[key];
    return v is bool ? v : '$v'.toLowerCase() == 'true';
  }

  /// Where a value came from: 'remote', 'default' or 'static' (no default).
  static String sourceOf(String key) => switch (_rc?.getValue(key).source) {
    ValueSource.valueRemote => 'remote',
    ValueSource.valueDefault => 'default',
    ValueSource.valueStatic => 'static',
    null => 'default',
  };

  /// Last fetch result, for the debug page.
  static String get lastFetchStatus {
    final rc = _rc;
    if (rc == null) return 'not loaded (using in-app defaults)';
    final when = rc.lastFetchTime;
    final at =
        when.millisecondsSinceEpoch == 0
            ? 'never'
            : when.toLocal().toString().split('.').first;
    return '${rc.lastFetchStatus.name} · last fetch: $at';
  }
}
