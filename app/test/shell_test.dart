import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_app.dart';

void main() {
  testWidgets('phones use a bottom navigation bar', (tester) async {
    final session = await testSession();
    await pumpApp(tester, session, size: const Size(430, 900));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.text('Chat'), findsWidgets);
  });

  testWidgets('desktop widths use a navigation rail', (tester) async {
    final session = await testSession();
    await pumpApp(tester, session, size: const Size(1280, 900));

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    // Rail navigation works too.
    await tester.tap(find.text('Cluster').last);
    await tester.pumpAndSettle();
    expect(find.text('This device'), findsOneWidget);
  });

  testWidgets('status chips summarize peers and worker mode', (tester) async {
    final session = await testSession();
    await pumpApp(tester, session, size: const Size(1280, 900));

    expect(find.text('worker'), findsOneWidget);
    expect(find.text('demo'), findsOneWidget);
    expect(find.textContaining('peer'), findsWidgets);
  });
}
