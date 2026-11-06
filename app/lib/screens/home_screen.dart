// Session list + new session + connection status.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connection.dart';
import '../contract.dart';
import '../main.dart';
import '../state.dart';
import '../time_format.dart';
import 'settings_screen.dart';

// (clientFrame comes from contract.dart)

class HomeScreen extends StatefulWidget {
  final AppController controller;
  final Connection conn;
  const HomeScreen({super.key, required this.controller, required this.conn});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  String _query = '';
  bool _searchOpen = false;

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connState = widget.conn.state;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('babel', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 10),
            _ConnDot(state: connState),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Filter sessions',
            onPressed: () => _toggleSearch(),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => SettingsScreen(conn: widget.conn))),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_searchOpen || _query.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _search,
                focusNode: _searchFocus,
                autofocus: _searchOpen,
                onChanged: (v) => setState(() => _query = v.trim()),
                decoration: InputDecoration(
                  hintText: 'Filter by name or directory…',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _query.isNotEmpty
                      ? IconButton(icon: const Icon(Icons.clear),
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          })
                      : null,
                ),
              ),
            ),
          if (widget.controller.banner != null)
            Container(
              width: double.infinity,
              color: const Color(0xB58900),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(widget.controller.banner!,
                  style: const TextStyle(color: Colors.black, fontSize: 13)),
            ),
          Expanded(
            child: connState != ConnState.connected
                ? _Disconnected(onReconnect: _reconnect)
                : widget.controller.sessions.isEmpty
                    ? const Center(child: Text('No sessions.\nTap + to start one.',
                        style: TextStyle(color: Colors.grey)))
                    : RefreshIndicator(
                        onRefresh: () async {
                          // explicit refresh — the host busts its scan cache
                          // on list_sessions
                          widget.conn.send(clientFrame('list_sessions', {}));
                          await Future.delayed(const Duration(milliseconds: 600));
                        },
                        child: _SessionList(
                            controller: widget.controller,
                            conn: widget.conn,
                            query: _query),
                      ),
          ),
        ],
      ),
      // Disabled while disconnected: new_session frames would be dropped
      // silently and the dialog's Start would do nothing.
      floatingActionButton: FloatingActionButton(
        onPressed: connState == ConnState.connected
            ? () => _showNewSessionDialog(context, widget.controller)
            : null,
        child: const Icon(Icons.add),
      ),
    );
  }

  /// Manual reconnect: re-read the saved host/token and connect. Covers the
  /// case where the app launched before the token was saved (main() skips
  /// connect() on an empty token) — without this the only fix was a full
  /// app restart.
  Future<void> _reconnect() async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString('host') ?? kDefaultHost;
    final token = prefs.getString('token') ?? '';
    if (token.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No token saved — set it in Settings')));
      return;
    }
    widget.conn.connect(host, token);
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (_searchOpen) {
        // field is built this frame; focus it after
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _searchFocus.requestFocus();
        });
      } else {
        _searchFocus.unfocus();
      }
    });
  }
}

class _SessionList extends StatelessWidget {
  final AppController controller;
  final Connection conn;
  final String query;
  const _SessionList(
      {required this.controller,
      required this.conn,
      this.query = ''});

  @override
  Widget build(BuildContext context) {
    var sessions = controller.sessions;
    if (query.isNotEmpty) {
      sessions = sessions
          .where((s) =>
              s.name.toLowerCase().contains(query.toLowerCase()) ||
              s.cwd.toLowerCase().contains(query.toLowerCase()))
          .toList();
    }
    // Flatten sections + rows into one list for a single ListView.
    final sections = _groupByRecency(sessions);
    final items = <_Item>[];
    for (final (label, entries) in sections) {
      items.add(_Item.header(label));
      for (final s in entries) {
        items.add(_Item.session(s));
      }
    }
    // Edge-to-edge draws the list behind the system nav bar — keep the last
    // row (and the FAB's reach) above it.
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(0, 8, 0, 8 + bottomInset),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        if (item.isHeader) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(item.label!,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF8B949E))),
          );
        }
        final s = item.session!;
        return ListTile(
          onTap: () => controller.attach(s.id),
          onLongPress: () => _showSessionMenu(context, s, controller),
          leading: _StatusIcon(status: s.status),
          title: Row(
            children: [
              Expanded(
                child: Text(s.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              Text(
                s.updatedAt != null ? relativeTime(s.updatedAt!) : '',
                style: const TextStyle(fontSize: 11, color: Color(0xFF8B949E)),
              ),
            ],
          ),
          subtitle: Text(s.cwdBase,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12)),
        );
      },
    );
  }
}

class _Item {
  final String? label;
  final SessionInfo? session;
  const _Item.header(this.label) : session = null;
  const _Item.session(this.session) : label = null;
  bool get isHeader => session == null;
}

/// Group sessions into Today / Yesterday / This week / Older.
List<(String, List<SessionInfo>)> _groupByRecency(List<SessionInfo> sessions) {
  final now = DateTime.now();
  final today = _dayStart(now);
  final yesterday = today.subtract(const Duration(days: 1));
  final week = today.subtract(const Duration(days: 7));

  final groups = <String, List<SessionInfo>>{
    'Today': [],
    'Yesterday': [],
    'This week': [],
    'Older': [],
  };
  for (final s in sessions) {
    final t = s.updatedAt;
    if (t == null) {
      groups['Older']!.add(s);
    } else if (t.isAfter(today.subtract(const Duration(seconds: 1)))) {
      groups['Today']!.add(s);
    } else if (t.isAfter(yesterday.subtract(const Duration(seconds: 1)))) {
      groups['Yesterday']!.add(s);
    } else if (t.isAfter(week)) {
      groups['This week']!.add(s);
    } else {
      groups['Older']!.add(s);
    }
  }
  return groups.entries
      .where((e) => e.value.isNotEmpty)
      .map((e) => (e.key, e.value))
      .toList();
}

DateTime _dayStart(DateTime t) => DateTime(t.year, t.month, t.day);

void _showNewSessionDialog(BuildContext context, AppController controller) {
  final cwdCtrl = TextEditingController();
  final nameCtrl = TextEditingController();
  final promptCtrl = TextEditingController();
  // Recent cwds from the session list, most-used first.
  final cwdCounts = <String, int>{};
  for (final s in controller.sessions) {
    if (s.cwd.isNotEmpty) cwdCounts[s.cwd] = (cwdCounts[s.cwd] ?? 0) + 1;
  }
  final recentCwds = cwdCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF161B22),
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('New session',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          if (recentCwds.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in recentCwds.take(6))
                  ActionChip(
                    label: Text(e.key.split('/').last),
                    onPressed: () => cwdCtrl.text = e.key,
                  ),
              ],
            ),
          const SizedBox(height: 12),
          TextField(
            controller: cwdCtrl,
            decoration: const InputDecoration(
                labelText: 'Working directory',
                hintText: '/home/you/your-project'),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: nameCtrl,
            decoration: const InputDecoration(labelText: 'Name (optional)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: promptCtrl,
            decoration: const InputDecoration(labelText: 'First prompt (optional)'),
            maxLines: 3,
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                controller.newSession(
                  cwd: cwdCtrl.text.trim(),
                  name: nameCtrl.text.trim(),
                  firstPrompt: promptCtrl.text.trim(),
                );
              },
              child: const Text('Start'),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Long-press menu: rename / delete.
void _showSessionMenu(
    BuildContext context, SessionInfo s, AppController controller) {
  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF161B22),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Rename'),
            enabled: s.status == 'stored',
            onTap: () {
              Navigator.pop(ctx);
              _showRenameDialog(context, s, controller);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.red),
            title: const Text('Delete', style: TextStyle(color: Colors.red)),
            onTap: () {
              Navigator.pop(ctx);
              _confirmDelete(context, s, controller);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

Future<void> _showRenameDialog(
    BuildContext context, SessionInfo s, AppController controller) async {
  final ctrl = TextEditingController(text: s.name);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Rename session'),
      content: TextField(controller: ctrl, autofocus: true),
      actions: [
        TextButton(
            child: const Text('Cancel'), onPressed: () => Navigator.pop(ctx)),
        FilledButton(
          child: const Text('Rename'),
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
        ),
      ],
    ),
  );
  if (name == null || name.isEmpty) return;
  controller.renameSession(s.id, name);
}

Future<void> _confirmDelete(
    BuildContext context, SessionInfo s, AppController controller) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete session?'),
      content: Text('"${s.name}" will be removed from disk. This cannot be undone.'),
      actions: [
        TextButton(
            child: const Text('Cancel'), onPressed: () => Navigator.pop(ctx, false)),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          child: const Text('Delete'),
          onPressed: () => Navigator.pop(ctx, true),
        ),
      ],
    ),
  );
  if (ok == true) controller.deleteSession(s.id);
}

class _ConnDot extends StatelessWidget {
  final ConnState state;
  const _ConnDot({required this.state});

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (state) {
      ConnState.connected => (Colors.green, 'connected'),
      ConnState.connecting => (Colors.amber, 'connecting…'),
      ConnState.disconnected => (Colors.red, 'disconnected'),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}

class _StatusIcon extends StatelessWidget {
  final String status;
  const _StatusIcon({required this.status});

  @override
  Widget build(BuildContext context) {
    return switch (status) {
      'running' => const Icon(Icons.play_circle_fill, color: Colors.green),
      'idle' => const Icon(Icons.circle, color: Colors.grey, size: 18),
      'starting' => const Icon(Icons.hourglass_top, color: Colors.amber),
      'stored' => const Icon(Icons.archive_outlined, color: Colors.blueGrey),
      _ => const Icon(Icons.error_outline, color: Colors.red),
    };
  }
}

class _Disconnected extends StatelessWidget {
  final VoidCallback onReconnect;
  const _Disconnected({required this.onReconnect});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
          const SizedBox(height: 12),
          const Text('Disconnected', style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 4),
          const Text('Check the host is running and the token is set.',
              style: TextStyle(color: Color(0xFF8B949E), fontSize: 13),
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.refresh),
            label: const Text('Reconnect'),
            onPressed: onReconnect,
          ),
        ],
      ),
    );
  }
}
