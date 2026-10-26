import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:onexray/core/tools/logger.dart';
import 'package:onexray/service/connect/coordinator.dart';
import 'package:onexray/service/mod/settings/service.dart';

/// Accumulates tunnel traffic and enforces the mod traffic limit.
///
/// The Xray metrics counters are cumulative for one core session, so the
/// guard tracks the last sample per runtime identity and adds the delta to
/// the persistent total. Reaching the limit disconnects the VPN and blocks
/// further connections until the counter is reset.
final class ModTrafficGuard {
  static final ModTrafficGuard _instance = ModTrafficGuard._();

  factory ModTrafficGuard() => _instance;

  ModTrafficGuard._();

  @visibleForTesting
  ModTrafficGuard.forTesting();

  String? _lastRuntimeIdentity;
  int _lastSampleBytes = 0;
  VoidCallback? _listener;
  bool _started = false;
  bool _applying = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await ModSettingsService().load();
    _listener = () => _onView();
    ConnectionCoordinator.instance.state.addListener(_listener!);
  }

  void _onView() {
    if (_applying) return;
    _applying = true;
    Future<void>(() async {
      try {
        await _handleView(ConnectionCoordinator.instance.state.value);
      } catch (error, stackTrace) {
        ygLogger('mod traffic guard failed: $error\n$stackTrace');
      } finally {
        _applying = false;
      }
    });
  }

  Future<void> _handleView(ConnectionView view) async {
    final settings = ModSettingsService();
    if (settings.trafficExhausted.value) {
      if (view.phase == ConnectionPhase.connecting ||
          view.phase == ConnectionPhase.connected) {
        await ConnectionCoordinator.instance.disconnect();
      }
      _forgetSample();
      return;
    }
    if (settings.trafficUnlimited ||
        view.phase != ConnectionPhase.connected ||
        view.runtime == null ||
        view.traffic == null) {
      _forgetSample();
      return;
    }
    final runtime = view.runtime!;
    final traffic = view.traffic!;
    final current = traffic.uplink + traffic.downlink;
    final identity = runtime.identity;
    final delta = identity != _lastRuntimeIdentity || current < _lastSampleBytes
        ? current
        : current - _lastSampleBytes;
    _lastRuntimeIdentity = identity;
    _lastSampleBytes = current;
    if (delta > 0) {
      await settings.addTrafficUsed(delta);
      if (settings.trafficExhausted.value) {
        await ConnectionCoordinator.instance.disconnect();
      }
    }
  }

  void _forgetSample() {
    _lastRuntimeIdentity = null;
    _lastSampleBytes = 0;
  }

  @visibleForTesting
  void disposeForTesting() {
    if (_listener != null) {
      ConnectionCoordinator.instance.state.removeListener(_listener!);
    }
    _listener = null;
    _started = false;
    _forgetSample();
  }
}
