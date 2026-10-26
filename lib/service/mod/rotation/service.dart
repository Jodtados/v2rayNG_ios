import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:onexray/core/db/database/database.dart';
import 'package:onexray/core/db/database/enum.dart';
import 'package:onexray/core/tools/logger.dart';
import 'package:onexray/service/connect/coordinator.dart';
import 'package:onexray/service/connect/runtime.dart';
import 'package:onexray/service/connect/settings.dart';
import 'package:onexray/service/mod/settings/service.dart';

/// Periodically switches to the next node of the current selection scope.
///
/// Rotation keeps the user's subscription scope: a selected server rotates
/// inside its subscription, a selected source inside that source, and
/// automatic selection rotates across every active outbound. The switch
/// reuses coordinator.apply so validation, reconnection and persistence
/// follow the app's normal configuration path.
final class ModRotationService {
  static final ModRotationService _instance = ModRotationService._();

  factory ModRotationService() => _instance;

  ModRotationService._();

  @visibleForTesting
  ModRotationService.forTesting();

  Timer? _timer;
  bool _rotating = false;

  Future<void> start() async {
    final settings = ModSettingsService();
    settings.rotationEnabled.addListener(_syncTimer);
    settings.rotationMinutes.addListener(_syncTimer);
    _syncTimer();
  }

  void _syncTimer() {
    _timer?.cancel();
    _timer = null;
    final settings = ModSettingsService();
    if (!settings.rotationEnabled.value) return;
    final minutes = settings.rotationMinutes.value;
    _timer = Timer.periodic(Duration(minutes: minutes), (_) => rotate());
  }

  @visibleForTesting
  Future<void> rotate() async {
    if (_rotating) return;
    _rotating = true;
    try {
      await _rotateOnce();
    } catch (error, stackTrace) {
      ygLogger('mod rotation failed: $error\n$stackTrace');
    } finally {
      _rotating = false;
    }
  }

  Future<void> _rotateOnce() async {
    final coordinator = ConnectionCoordinator.instance;
    final view = coordinator.state.value;
    if (view.phase != ConnectionPhase.connected) return;
    final settings = ModSettingsService();
    if (settings.trafficExhausted.value) return;
    final current = await coordinator.configuration;
    if (current.connection.expert) return;

    final rows = await AppDatabase().coreConfigDao.allActiveServerRows();
    final outbounds = rows
        .where((row) => row.type == CoreConfigType.outbound.name)
        .toList();
    final scope = _scopeSubId(current.connection.selection, outbounds);
    final candidates = outbounds
        .where((row) => scope == null || row.subId == scope)
        .toList();
    if (candidates.length < 2) return;

    final selection = current.connection.selection;
    var index = -1;
    if (selection.kind == SelectionKind.server && selection.id != null) {
      index = candidates.indexWhere((row) => row.id == selection.id);
    }
    final next = candidates[(index + 1) % candidates.length];
    final nextSettings = ConnectionSettings.fromJson({
      ...current.connection.toJson(),
      'selection': ServerSelection.server(next.id).toJson(),
    });
    await coordinator.apply(
      ConnectionConfiguration(connection: nextSettings, policy: current.policy),
      expectedConfiguration: current.encode(),
      allowReconnect: true,
    );
    ygLogger('mod rotation switched to node ${next.id}');
  }

  /// The subscription scope the rotation stays inside, null for all nodes.
  int? _scopeSubId(ServerSelection selection, List<CoreConfigData> outbounds) {
    switch (selection.kind) {
      case SelectionKind.server:
        final row = outbounds
            .where((row) => row.id == selection.id)
            .firstOrNull;
        return row?.subId;
      case SelectionKind.source:
        return selection.id;
      case SelectionKind.automatic:
        return null;
    }
  }

  @visibleForTesting
  void disposeForTesting() {
    final settings = ModSettingsService();
    settings.rotationEnabled.removeListener(_syncTimer);
    settings.rotationMinutes.removeListener(_syncTimer);
    _timer?.cancel();
    _timer = null;
  }
}
