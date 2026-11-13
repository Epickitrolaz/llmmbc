import 'package:app/app/llmmbc_app.dart';
import 'package:app/dev/fake_node_service.dart';
import 'package:app/services/bootstrap.dart';
import 'package:app/ui/shell.dart';
import 'package:app/ui/startup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_app.dart';

class _FailingService extends FakeNodeService {
  @override
  Future<void> start() async {
    throw StateError('engine bootstrap exploded');
  }
}

Future<void> _size(WidgetTester tester) async {
  tester.view.physicalSize = const Size(430, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('shows the four startup phases, then the shell', (tester) async {
    final session = await testSession(phaseDelay: const Duration(milliseconds: 120));
    await _size(tester);

    await tester.pumpWidget(
      LlmmbcApp(
        bootstrap: AppBootstrap(session: session, fake: true, degraded: false, dataDir: '/tmp/llmmbc-test'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    expect(find.byType(StartupScreen), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Hardware scan'), findsOneWidget);
    expect(find.text('Model scan'), findsOneWidget);
    expect(find.text('Node API'), findsOneWidget);
    expect(find.text('Network scan'), findsOneWidget);
    expect(find.text('Starting this node'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(StartupScreen), findsOneWidget);

    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    await tester.pumpAndSettle();

    expect(find.byType(HomeShell), findsOneWidget);
    expect(find.byType(StartupScreen), findsNothing);
    expect(find.text('Chat'), findsWidgets);
    expect(find.text('Models'), findsWidgets);
    expect(find.text('Cluster'), findsWidgets);
    expect(session.ready, isTrue);
    expect(session.phases, containsAll(['settings', 'hardware', 'models', 'api', 'discovery']));
  });

  testWidgets('startup failure shows the error and a retry action', (tester) async {
    final session = await testSessionWith(_FailingService());
    await _size(tester);

    await tester.pumpWidget(
      LlmmbcApp(
        bootstrap: AppBootstrap(session: session, fake: false, degraded: false, dataDir: '/tmp/llmmbc-test'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Startup failed'), findsOneWidget);
    expect(find.text('Retry startup'), findsOneWidget);
    expect(session.startupError, contains('engine bootstrap exploded'));
  });
}
