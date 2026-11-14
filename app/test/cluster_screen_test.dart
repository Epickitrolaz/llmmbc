import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_app.dart';

void main() {
  testWidgets('cluster screen shows the hardware profile of this device', (tester) async {
    final session = await testSession();
    await pumpApp(tester, session);
    await openTab(tester, 'Cluster');

    expect(find.text('This device'), findsOneWidget);
    expect(find.text('TOTAL RAM'), findsOneWidget);
    expect(find.text('12.0 GiB'), findsWidgets);
    expect(find.text('Cortex-X3 + A715 + A510'), findsOneWidget);
    expect(find.text('Adreno 740'), findsOneWidget);
    // Tags come from the hardware profile.
    expect(find.text('demo'), findsOneWidget);
    expect(find.text('Engine and session'), findsOneWidget);
  });

  testWidgets('peers are listed with status, models and memory', (tester) async {
    final session = await testSession();
    await pumpApp(tester, session);
    await openTab(tester, 'Cluster');

    expect(find.text('Studio PC'), findsOneWidget);
    expect(find.text('192.168.1.20:47101'), findsOneWidget);
    expect(find.text('Pixel 8'), findsOneWidget);
    expect(find.text('worker mode'), findsWidgets);
    expect(find.text('client only'), findsWidgets);
    expect(find.textContaining('qwen3:30b-a3b'), findsWidgets);
    expect(find.text('4 peers known · 4 reachable'), findsOneWidget);
  });

  testWidgets('refresh runs discovery and keeps the directory', (tester) async {
    final session = await testSession();
    await pumpApp(tester, session);
    await openTab(tester, 'Cluster');

    expect(find.text('Rescan network'), findsOneWidget);
    await tapVisible(tester, find.byKey(const Key('cluster-refresh')));
    await tester.pump();
    expect(find.text('Scanning…'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Scanning…'), findsNothing);
    expect(find.text('Studio PC'), findsOneWidget);
  });

  testWidgets('peer list follows live peersChanged events while open and after returning', (tester) async {
    final session = await testSession();
    await pumpApp(tester, session);
    await openTab(tester, 'Cluster');

    expect(find.text('4 peers known · 4 reachable'), findsOneWidget);

    // Liveness changes while the tab is open update the list immediately.
    fakeOf(session).debugSetPeerReachable(
      'studio-pc-7d21c4a0',
      lastSeenAgo: const Duration(seconds: 45),
    );
    await tester.pumpAndSettle();

    expect(find.text('4 peers known · 3 reachable'), findsOneWidget);
    expect(find.text('offline'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && RegExp(r'^last seen \d+s ago$').hasMatch(widget.data ?? ''),
      ),
      findsOneWidget,
    );

    // A recovery refreshes lastSeen and reachability without a manual scan.
    fakeOf(session).debugSetPeerReachable(
      'studio-pc-7d21c4a0',
      reachable: true,
      lastSeenAgo: const Duration(seconds: 1),
    );
    await tester.pumpAndSettle();
    expect(find.text('4 peers known · 4 reachable'), findsOneWidget);
    expect(find.textContaining('last seen'), findsNothing);

    // Leave the tab, let discovery report the peer offline, then come back.
    await openTab(tester, 'Chat');
    fakeOf(session).debugSetPeerReachable(
      'studio-pc-7d21c4a0',
      lastSeenAgo: const Duration(seconds: 50),
    );
    await tester.pumpAndSettle();
    await openTab(tester, 'Cluster');

    expect(find.text('4 peers known · 3 reachable'), findsOneWidget);
    expect(find.textContaining('last seen'), findsOneWidget);
    expect(find.byKey(const Key('cluster-live-copy')), findsOneWidget);
  });

  testWidgets('add peer reports unreachable addresses and adds reachable ones', (tester) async {
    final session = await testSession();
    await pumpApp(tester, session);
    await openTab(tester, 'Cluster');

    await tapVisible(tester, find.byKey(const Key('cluster-add-peer')));
    await tester.pumpAndSettle();
    expect(find.text('Add a peer'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('add-peer-field')), 'bad-host:1');
    await tester.tap(find.byKey(const Key('add-peer-submit')));
    await tester.pumpAndSettle();
    expect(find.text('No node answered on that address.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('add-peer-field')), '192.168.1.99:47101');
    await tester.tap(find.byKey(const Key('add-peer-submit')));
    await tester.pumpAndSettle();

    expect(find.text('Manual peer'), findsOneWidget);
    expect(find.text('192.168.1.99:47101'), findsOneWidget);
    expect(session.service.settings.manualPeers, contains('192.168.1.99:47101'));
  });
}
