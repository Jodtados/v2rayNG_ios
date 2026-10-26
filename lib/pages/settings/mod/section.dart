import 'package:material_ui/material_ui.dart';

import 'package:onexray/core/tools/traffic_format.dart';
import 'package:onexray/l10n/localizations/app_localizations.dart';
import 'package:onexray/pages/theme/color.dart';
import 'package:onexray/pages/theme/font.dart';
import 'package:onexray/pages/shared/widgets/setting_row.dart';
import 'package:onexray/service/mod/settings/service.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Personal-build section: traffic limit, usage and rotation controls.
///
/// Reads and writes through [ModSettingsService]; rows appear only when
/// their feature has a non-default state to keep stock builds clean.
class ModSettingsSection extends StatelessWidget {
  const ModSettingsSection({
    super.key,
    required this.rowHeight,
    required this.rowPadding,
  });

  final double rowHeight;
  final EdgeInsets rowPadding;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final palette = ColorManager.palette(context);
    final settings = ModSettingsService();
    return SettingSection(
      title: l10n.modSettingsTitle,
      icon: LucideIcons.gauge,
      padding: EdgeInsets.zero,
      dividerIndent: 0,
      children: [
        ValueListenableBuilder<int>(
          valueListenable: settings.trafficLimitMb,
          builder: (context, limitMb, _) => SettingRow(
            title: l10n.modTrafficLimit,
            value: limitMb <= 0 ? l10n.modTrafficLimitOff : '$limitMb MB',
            minHeight: rowHeight,
            contentPadding: rowPadding,
            titleStyle: AppTypography.settingsRow,
            showChevron: true,
            onTap: () => _editLimit(context, settings, limitMb),
          ),
        ),
        ValueListenableBuilder<int>(
          valueListenable: settings.trafficUsedBytes,
          builder: (context, usedBytes, _) {
            final limitBytes = settings.trafficLimitBytes;
            return ValueListenableBuilder<int>(
              valueListenable: settings.trafficLimitMb,
              builder: (context, limitMb, _) => SettingRow(
                title: l10n.modTrafficUsed,
                value: limitMb <= 0
                    ? formatTraffic(usedBytes)
                    : l10n.modTrafficUsedOf(
                        formatTraffic(usedBytes),
                        formatTraffic(limitBytes),
                      ),
                minHeight: rowHeight,
                contentPadding: rowPadding,
                titleStyle: AppTypography.settingsRow,
              ),
            );
          },
        ),
        ValueListenableBuilder<bool>(
          valueListenable: settings.trafficExhausted,
          builder: (context, exhausted, _) => SettingRow(
            title: l10n.modTrafficReset,
            titleStyle: AppTypography.settingsDanger.copyWith(
              color: palette.destructive,
            ),
            enabled: !exhausted || settings.trafficUsedBytes.value > 0,
            minHeight: rowHeight,
            contentPadding: rowPadding,
            onTap: () => settings.resetTrafficUsage(),
          ),
        ),
      ],
    );
  }

  Future<void> _editLimit(
    BuildContext context,
    ModSettingsService settings,
    int currentMb,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(
      text: currentMb <= 0 ? '' : '$currentMb',
    );
    final submitted = await showShadDialog<bool>(
      context: context,
      builder: (dialogContext) => ShadDialog(
        title: Text(l10n.modTrafficLimit),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.prototypeCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.prototypeSave),
          ),
        ],
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: l10n.modTrafficLimitField,
            hintText: '0',
          ),
        ),
      ),
    );
    if (submitted != true) return;
    final value = int.tryParse(controller.text.trim()) ?? 0;
    await settings.setTrafficLimitMb(value);
  }
}
