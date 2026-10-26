import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:onexray/core/tools/totp.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One-time activation gate for personal builds.
///
/// The activation flag lives in the iOS/macOS keychain through the
/// `onexray/mod` platform channel, so it survives app reinstalls. Other
/// platforms fall back to shared preferences. Builds without a
/// MOD_TOTP_SECRET dart-define skip the gate entirely.
final class ModActivationService {
  static const String secretDefine = 'MOD_TOTP_SECRET';
  static const String _channelName = 'onexray/mod';
  static const String _fallbackKey = 'mod.activation.completed';
  static const String _methodIsActivated = 'isActivated';
  static const String _methodActivate = 'activate';

  static final ModActivationService _instance = ModActivationService._(
    const String.fromEnvironment(secretDefine),
    const MethodChannel(_channelName),
    SharedPreferences.getInstance,
    Totp.verify,
  );

  factory ModActivationService() => _instance;

  ModActivationService._(
    this._secret,
    this._channel,
    this._preferences,
    this._verify,
  );

  @visibleForTesting
  ModActivationService.forTesting({
    String secret = '',
    MethodChannel channel = const MethodChannel(_channelName),
    Future<SharedPreferences> Function() preferences = _unavailablePreferences,
    bool Function(String secret, String code)? verify,
  }) : this._(secret, channel, preferences, verify ?? Totp.verify);

  static Future<SharedPreferences> _unavailablePreferences() async {
    throw UnsupportedError('preferences unavailable in tests');
  }

  final String _secret;
  final MethodChannel _channel;
  final Future<SharedPreferences> Function() _preferences;
  final bool Function(String secret, String code) _verify;

  /// The gate only arms when a build-time secret is present.
  bool get gateEnabled => _secret.isNotEmpty;

  /// Verifies a 6-digit code against the build-time secret.
  bool acceptsCode(String code) => gateEnabled && _verify(_secret, code);

  Future<bool> isActivated() async {
    try {
      return await _channel.invokeMethod<bool>(_methodIsActivated) ?? false;
    } on PlatformException {
      return _isActivatedFallback();
    } on MissingPluginException {
      return _isActivatedFallback();
    }
  }

  Future<void> activate() async {
    try {
      await _channel.invokeMethod<void>(_methodActivate);
    } on PlatformException {
      await _activateFallback();
    } on MissingPluginException {
      await _activateFallback();
    }
  }

  Future<bool> _isActivatedFallback() async {
    final preferences = await _preferences();
    return preferences.getBool(_fallbackKey) ?? false;
  }

  Future<void> _activateFallback() async {
    final preferences = await _preferences();
    await preferences.setBool(_fallbackKey, true);
  }
}
