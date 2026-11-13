/// Root widget, theme wiring and the startup gate.
library;

import 'package:flutter/material.dart';

import '../services/bootstrap.dart';
import '../ui/shell.dart';
import '../ui/startup_screen.dart';
import 'app_session.dart';
import 'theme.dart';

/// Runs before the node service exists: shows the brand splash while
/// bootstrapping (directory, settings, service construction).
class LlmmbcBootstrapApp extends StatefulWidget {
  const LlmmbcBootstrapApp({super.key, this.bootstrapFuture});

  /// Overridable for tests.
  final Future<AppBootstrap> Function()? bootstrapFuture;

  @override
  State<LlmmbcBootstrapApp> createState() => _LlmmbcBootstrapAppState();
}

class _LlmmbcBootstrapAppState extends State<LlmmbcBootstrapApp> {
  late final Future<AppBootstrap> _future = (widget.bootstrapFuture ?? bootstrapApp)();
  String? _error;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppBootstrap>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError && _error == null) {
          _error = snapshot.error.toString();
        }
        if (snapshot.hasData) {
          return LlmmbcApp(bootstrap: snapshot.data!);
        }
        return MaterialApp(
          title: 'LLMMBC',
          debugShowCheckedModeBanner: false,
          theme: buildLlmmbcTheme(Brightness.light),
          darkTheme: buildLlmmbcTheme(Brightness.dark),
          home: Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const BrandMark(size: 64),
                  const SizedBox(height: 18),
                  Text('LLMMBC', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 6),
                  Text(
                    'LLM Mobile Cluster',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: 180,
                    child: _error == null
                        ? const LinearProgressIndicator(minHeight: 3)
                        : Text(
                            'Could not start the app:\n$_error',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The application once the node service has been constructed.
class LlmmbcApp extends StatefulWidget {
  const LlmmbcApp({super.key, required this.bootstrap, this.autoStart = true});

  final AppBootstrap bootstrap;
  final bool autoStart;

  @override
  State<LlmmbcApp> createState() => _LlmmbcAppState();
}

class _LlmmbcAppState extends State<LlmmbcApp> {
  AppSession get _session => widget.bootstrap.session;

  @override
  void initState() {
    super.initState();
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _session.start());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _session,
      builder: (context, _) => MaterialApp(
        title: 'LLMMBC',
        debugShowCheckedModeBanner: false,
        theme: buildLlmmbcTheme(Brightness.light),
        darkTheme: buildLlmmbcTheme(Brightness.dark),
        themeMode: _session.themeMode,
        home: AppScope(session: _session, child: const _StartupGate()),
      ),
    );
  }
}

class _StartupGate extends StatelessWidget {
  const _StartupGate();

  @override
  Widget build(BuildContext context) {
    final session = AppScope.of(context);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      child: session.ready ? const HomeShell(key: ValueKey('shell')) : const StartupScreen(key: ValueKey('startup')),
    );
  }
}

/// Square brand mark used by the splash and startup screen.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 52});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.26),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF10B981), Color(0xFF047857)],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        'L',
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.52,
          fontWeight: FontWeight.w700,
          letterSpacing: -1,
        ),
      ),
    );
  }
}
