import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Personal-build mod settings backed by shared preferences.
///
/// Kept out of the drift connection configuration on purpose: mod state is
/// orthogonal to Xray configuration and must survive upstream rebases
/// without schema churn.
final class ModSettingsService {
  static const String _limitMbKey = 'mod.traffic.limitMb';
  static const String _usedBytesKey = 'mod.traffic.usedBytes';
  static const String _exhaustedKey = 'mod.traffic.exhausted';

  static const int megabyte = 1024 * 1024;

  static final ModSettingsService _instance = ModSettingsService._(
    SharedPreferences.getInstance,
  );

  factory ModSettingsService() => _instance;

  ModSettingsService._(this._preferences);

  @visibleForTesting
  ModSettingsService.forTesting(this._preferences);

  final Future<SharedPreferences> Function() _preferences;

  final trafficLimitMb = ValueNotifier<int>(0);
  final trafficUsedBytes = ValueNotifier<int>(0);
  final trafficExhausted = ValueNotifier<bool>(false);

  /// Total bytes allowed by the limit; 0 means unlimited.
  int get trafficLimitBytes => trafficLimitMb.value * megabyte;

  bool get trafficUnlimited => trafficLimitMb.value <= 0;

  Future<void> load() async {
    final preferences = await _preferences();
    trafficLimitMb.value = preferences.getInt(_limitMbKey) ?? 0;
    trafficUsedBytes.value = preferences.getInt(_usedBytesKey) ?? 0;
    trafficExhausted.value = preferences.getBool(_exhaustedKey) ?? false;
  }

  Future<void> setTrafficLimitMb(int value) async {
    final clamped = value < 0 ? 0 : value;
    trafficLimitMb.value = clamped;
    final preferences = await _preferences();
    await preferences.setInt(_limitMbKey, clamped);
    if (clamped > 0 && !trafficExhausted.value) {
      _evaluate(trafficUsedBytes.value);
    }
  }

  Future<void> addTrafficUsed(int bytes) async {
    if (bytes <= 0) return;
    trafficUsedBytes.value += bytes;
    final preferences = await _preferences();
    await preferences.setInt(_usedBytesKey, trafficUsedBytes.value);
    _evaluate(trafficUsedBytes.value);
  }

  /// Clears the counter and lifts the exhaustion block.
  Future<void> resetTrafficUsage() async {
    trafficUsedBytes.value = 0;
    trafficExhausted.value = false;
    final preferences = await _preferences();
    await preferences.setInt(_usedBytesKey, 0);
    await preferences.setBool(_exhaustedKey, false);
  }

  void _evaluate(int usedBytes) {
    if (trafficUnlimited) return;
    if (usedBytes >= trafficLimitBytes && !trafficExhausted.value) {
      trafficExhausted.value = true;
      _preferences().then(
        (preferences) => preferences.setBool(_exhaustedKey, true),
      );
    }
  }
}
