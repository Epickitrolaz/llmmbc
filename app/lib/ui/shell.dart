/// Responsive app shell: bottom navigation on phones, navigation rail on desktop.
library;

import 'package:flutter/material.dart';

import '../app/app_session.dart';
import '../util/format.dart';
import 'chat_screen.dart';
import 'cluster_screen.dart';
import 'models_screen.dart';
import 'settings_screen.dart';
import 'widgets/common.dart';
import 'widgets/runtime_failure_banner.dart';

class _Tab {
  final String label;
  final String title;
  final String subtitle;
  final IconData icon;
  final IconData selectedIcon;

  const _Tab(this.label, this.title, this.subtitle, this.icon, this.selectedIcon);
}

const List<_Tab> _tabs = [
  _Tab('Chat', 'Chat', 'Ask the cluster', Icons.forum_outlined, Icons.forum),
  _Tab('Models', 'Models', 'Catalog and local store', Icons.inventory_2_outlined, Icons.inventory_2),
  _Tab('Cluster', 'Cluster', 'This device and its peers', Icons.hub_outlined, Icons.hub),
  _Tab('Settings', 'Settings', 'Worker mode and preferences', Icons.settings_outlined, Icons.settings),
];

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final session = AppScope.of(context);
    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final desktop = width >= 840;

    final screens = const [ChatScreen(), ModelsScreen(), ClusterScreen(), SettingsScreen()];
    final body = IndexedStack(index: _index, children: screens);
    final notices = _Notices(session: session);

    if (desktop) {
      return Scaffold(
        body: SafeArea(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NavigationRail(
                extended: width >= 1180,
                selectedIndex: _index,
                onDestinationSelected: (index) => setState(() => _index = index),
                leading: Padding(
                  padding: EdgeInsets.fromLTRB(width >= 1180 ? 16 : 12, 16, width >= 1180 ? 16 : 12, 22),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _RailMark(),
                      if (width >= 1180) ...[
                        const SizedBox(width: 10),
                        Text('LLMMBC', style: theme.textTheme.titleMedium),
                      ],
                    ],
                  ),
                ),
                destinations: [
                  for (final tab in _tabs)
                    NavigationRailDestination(
                      icon: Icon(tab.icon),
                      selectedIcon: Icon(tab.selectedIcon),
                      label: Text(tab.label),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: [
                    _DesktopHeader(tab: _tabs[_index], session: session),
                    _NoticeArea(child: notices),
                    Expanded(child: body),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            const _RailMark(size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _tabs[_index].title,
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _tabs[_index].subtitle,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [StatusChips(session: session, compact: true), const SizedBox(width: 8)],
      ),
      body: Column(
        children: [
          // Error banners can grow (details); let them scroll instead of eating
          // the screen content or overflowing on short displays.
          _NoticeArea(child: notices),
          Expanded(child: body),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: [
          for (final tab in _tabs)
            NavigationDestination(icon: Icon(tab.icon), selectedIcon: Icon(tab.selectedIcon), label: tab.label),
        ],
      ),
    );
  }
}

class _RailMark extends StatelessWidget {
  const _RailMark({this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.26),
        gradient: const LinearGradient(colors: [Color(0xFF10B981), Color(0xFF047857)]),
      ),
      alignment: Alignment.center,
      child: Text(
        'L',
        style: TextStyle(color: Colors.white, fontSize: size * 0.5, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _DesktopHeader extends StatelessWidget {
  const _DesktopHeader({required this.tab, required this.session});

  final _Tab tab;
  final AppSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tab.title, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 2),
                Text(
                  tab.subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          StatusChips(session: session),
        ],
      ),
    );
  }
}

/// Peer/worker/session summary shown in the app bars.
class StatusChips extends StatelessWidget {
  const StatusChips({super.key, required this.session, this.compact = false});

  final AppSession session;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final peers = session.peers.where((peer) => peer.reachable).length;
    final worker = session.service.settings.workerEnabled && !session.clientOnly;
    final sessionInfo = session.service.currentSession;
    if (compact) {
      // Phones have no room for text chips in the app bar: icons + tooltips.
      final scheme = Theme.of(context).colorScheme;
      Widget icon(IconData data, String tooltip, {bool active = false}) => Tooltip(
            message: tooltip,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Icon(data, size: 18, color: active ? scheme.primary : scheme.onSurfaceVariant),
            ),
          );
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon(
            worker ? Icons.memory : Icons.phone_iphone,
            worker ? 'Worker mode on' : 'Client only',
            active: worker,
          ),
          if (sessionInfo != null) icon(Icons.hub, session.isCoordinator ? 'Coordinator' : 'In a session', active: true),
          if (session.fake) icon(Icons.science_outlined, 'Simulated cluster'),
          if (session.degraded) icon(Icons.warning_amber_outlined, 'No engine in this build'),
        ],
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      alignment: WrapAlignment.end,
      children: [
        MetaChip(label: pluralize(peers, 'peer'), icon: Icons.hub_outlined),
        MetaChip(
          label: worker ? 'worker' : 'client only',
          icon: worker ? Icons.memory : Icons.phone_iphone,
          highlighted: worker,
        ),
        if (sessionInfo != null)
          MetaChip(
            label: session.isCoordinator ? 'coordinator' : 'session',
            icon: Icons.hub,
            highlighted: true,
          ),
        if (session.fake) MetaChip(label: 'demo', icon: Icons.science_outlined),
        if (session.degraded)
          MetaChip(label: 'no engine', icon: Icons.warning_amber_outlined, highlighted: false),
      ],
    );
  }
}

/// Caps the height of the notice/banner stack (40% of the window) so a tall
/// error details panel cannot squeeze or overflow the active screen.
class _NoticeArea extends StatelessWidget {
  const _NoticeArea({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.4;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight, minHeight: 0),
      child: SingleChildScrollView(child: child),
    );
  }
}

class _Notices extends StatelessWidget {
  const _Notices({required this.session});

  final AppSession session;

  @override
  Widget build(BuildContext context) {
    final notices = <Widget>[];
    final failure = session.runtimeFailure;
    if (failure != null) {
      notices.add(
        RuntimeFailureBanner(
          failure: failure,
          retrying: session.retryingRuntime,
          onRetry: session.retryRuntime,
        ),
      );
    }
    if (failure == null && session.notice != null) {
      notices.add(
        NoticeBanner(
          message: session.notice!,
          tone: Theme.of(context).colorScheme.error,
          icon: Icons.warning_amber_outlined,
        ),
      );
    } else if (failure == null && session.fake) {
      notices.add(
        const NoticeBanner(
          message: 'Simulated cluster: peers, downloads and answers are generated locally '
              '(launch without --dart-define=LLMMBC_FAKE=1 to use a real node).',
          icon: Icons.science_outlined,
        ),
      );
    }
    if (notices.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Column(
        children: [
          for (final notice in notices) ...[notice, if (notice != notices.last) const SizedBox(height: 8)],
        ],
      ),
    );
  }
}
