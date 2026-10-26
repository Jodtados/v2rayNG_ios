import 'package:material_ui/material_ui.dart';

import 'package:onexray/l10n/localizations/app_localizations.dart';
import 'package:onexray/pages/shared/widgets/page_app_bar.dart';
import 'package:onexray/pages/theme/color.dart';
import 'package:onexray/pages/theme/font.dart';
import 'package:onexray/service/mod/activation/service.dart';

/// Full-screen one-time code entry shown before any app content.
///
/// Wrong attempts lock the field briefly; a valid code persists the
/// activation flag in the keychain and never prompts again.
class ModActivationPage extends StatefulWidget {
  const ModActivationPage({super.key, required this.onActivated});

  final Future<void> Function() onActivated;

  @override
  State<ModActivationPage> createState() => _ModActivationPageState();
}

class _ModActivationPageState extends State<ModActivationPage> {
  static const int _maxAttempts = 5;
  static const int _lockoutSeconds = 30;

  final TextEditingController _code = TextEditingController();
  final FocusNode _focus = FocusNode();
  String? _error;
  bool _busy = false;
  int _attempts = 0;
  int _lockedUntil = 0;

  @override
  void dispose() {
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _locked =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000 < _lockedUntil;

  Future<void> _submit() async {
    if (_busy || _locked) return;
    setState(() => _busy = true);
    final service = ModActivationService();
    if (service.acceptsCode(_code.text)) {
      await service.activate();
      await widget.onActivated();
      return;
    }
    _attempts += 1;
    final locked = _attempts >= _maxAttempts;
    setState(() {
      _busy = false;
      _error = null;
      _attempts = locked ? 0 : _attempts;
      if (locked) {
        _lockedUntil =
            DateTime.now().millisecondsSinceEpoch ~/ 1000 + _lockoutSeconds;
      }
    });
    if (!mounted) return;
    final l = AppLocalizations.of(context)!;
    setState(() => _error = l.modActivationInvalid);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final palette = ColorManager.palette(context);
    return Scaffold(
      appBar: PageAppBar(title: Text(l.modActivationTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l.modActivationDescription),
                const SizedBox(height: 16),
                TextField(
                  controller: _code,
                  focusNode: _focus,
                  enabled: !_locked && !_busy,
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  maxLength: 6,
                  textAlign: TextAlign.center,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: l.modActivationCode,
                    counterText: '',
                    errorText: _error,
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: (_locked || _busy) ? null : _submit,
                  child: Text(l.modActivationSubmit),
                ),
                if (_locked)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      l.modActivationLocked(
                        _lockedUntil -
                            DateTime.now().millisecondsSinceEpoch ~/ 1000,
                      ),
                      style: AppTypography.settingsDetailNote.copyWith(
                        color: palette.destructive,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
