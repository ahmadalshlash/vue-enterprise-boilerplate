import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'app/app.dart';
import 'app/bootstrap.dart';

SemanticsHandle? _semantics;

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    // Web-Demo: Semantik-Baum aktivieren, damit Screenreader und
    // UI-Automatisierung die Oberfläche lesen können.
    _semantics = binding.ensureSemantics();
  }
  final appContext = await bootstrap();
  runApp(UmkreisApp(context: appContext));
}

/// Nur für Tests/Debugging sichtbar: ob Semantik aktiv ist.
bool get semanticsEnabledForWeb => _semantics != null;
