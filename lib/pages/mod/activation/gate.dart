import 'package:flutter/material.dart' show FutureBuilder;
import 'package:material_ui/material_ui.dart';

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

  @override
  void initState() {
    super.initState();
    final service = ModActivationService();
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
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.data == true) return widget.child;
        return ModActivationPage(onActivated: _onActivationSubmitted);
      },
    );
  }
}
