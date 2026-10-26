import 'package:material_ui/material_ui.dart';

import 'package:onexray/core/tools/traffic_format.dart';
import 'package:onexray/l10n/localizations/app_localizations.dart';
import 'package:onexray/pages/theme/color.dart';
import 'package:onexray/pages/theme/font.dart';
import 'package:onexray/service/mod/settings/service.dart';

/// Shows [child] unless the traffic limit is exhausted.
///
/// Disabled builds (limit 0) and builds below the limit render [child];
/// exhaustion swaps in the full-screen block until the counter is reset.
class ModTrafficGate extends StatelessWidget {
  const ModTrafficGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final settings = ModSettingsService();
    return ValueListenableBuilder<int>(
      valueListenable: settings.trafficLimitMb,
      builder: (context, limitMb, _) {
        if (limitMb <= 0) return child;
        return ValueListenableBuilder<bool>(
          valueListenable: settings.trafficExhausted,
          builder: (context, exhausted, __) {
            if (!exhausted) return child;
            return ValueListenableBuilder<int>(
              valueListenable: settings.trafficUsedBytes,
              builder: (context, usedBytes, ___) => ModTrafficBlockPage(
                usedBytes: usedBytes,
                limitBytes: settings.trafficLimitBytes,
              ),
            );
          },
        );
      },
    );
  }
}

/// Full-screen block shown while the traffic limit is exhausted.
///
/// Offers the only way out: resetting the usage counter (or raising the
/// limit in settings after reset).
class ModTrafficBlockPage extends StatelessWidget {
  const ModTrafficBlockPage({
    super.key,
    required this.usedBytes,
    required this.limitBytes,
  });

  final int usedBytes;
  final int limitBytes;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final palette = ColorManager.palette(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l.modTrafficExhaustedTitle,
                  style: AppTypography.pageTitle.copyWith(
                    color: palette.destructive,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  l.modTrafficExhaustedDescription(
                    formatTraffic(usedBytes),
                    formatTraffic(limitBytes),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => ModSettingsService().resetTrafficUsage(),
                  child: Text(l.modTrafficReset),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
