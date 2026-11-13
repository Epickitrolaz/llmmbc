import 'package:flutter/material.dart';

import 'app/llmmbc_app.dart';

/// LLMMBC – turn LAN devices into one LLM cluster.
///
/// Run with `--dart-define=LLMMBC_FAKE=1` for the simulated cluster.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LlmmbcBootstrapApp());
}
