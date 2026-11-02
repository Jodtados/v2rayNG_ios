import 'package:material_ui/material_ui.dart';

import 'package:onexray/core/tools/diag_trace.dart';
import 'package:onexray/pages/mod/activation/page.dart';
import 'package:onexray/service/mod/activation/service.dart';

/// Shows [child] only after the one-time activation gate passes.
///
/// Builds without MOD_TOTP_SECRET render [child] immediately; activated
/// builds never prompt again because the flag is stored in the keychain.
class ModActivationGate extends StatefulWidget {
  const ModActivationGate({super.key, required this.child});

  final Widget child;

  @override
  State<ModActivationGate> createState() => _ModActivationGateState();
}

class _ModActivationGateState extends State<ModActivationGate> {
  Future<bool>? _activated;
  bool _waitingLogged = false;

  @override
  void initState() {
    super.initState();
    final service = ModActivationService();
    diagTrace('GATE initState gateEnabled=${service.gateEnabled}');
    _activated = service.gateEnabled
        ? service.isActivated()
        : Future.value(true);
  }

  Future<void> _onActivationSubmitted() async {
    setState(() {
      _activated = Future.value(true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _activated,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          if (!_waitingLogged) {
            _waitingLogged = true;
            diagTrace('GATE waiting');
          }
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        diagTrace(
          'GATE done hasError=${snapshot.hasError} '
          'data=${snapshot.data}',
        );
        if (snapshot.data == true) return widget.child;
        return ModActivationPage(onActivated: _onActivationSubmitted);
      },
    );
  }
}
