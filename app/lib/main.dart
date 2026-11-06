// babel — phone client for deepthought remote coding sessions.
//
// The app speaks a small JSON contract to the session host over
// WebSocket. It is a view: all agent logic lives in the host + pi.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connection.dart';
import 'notifications.dart';
import 'state.dart';
import 'screens/home_screen.dart';
import 'screens/session_screen.dart';

// No default host — every deployment has its own tailnet IP. The user
// enters it in Settings on first run (it is persisted in SharedPreferences).
const kDefaultHost = '';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final host = prefs.getString('host') ?? kDefaultHost;
  final token = prefs.getString('token') ?? '';
  debugPrint('[babel] main: host=$host token_len=${token.length}');

  final conn = Connection(onFrame: (f) {});
  final controller = AppController(conn);
  if (token.isNotEmpty) conn.connect(host, token);

  // Deep links: notification taps (warm) land here; the app attaches to the
  // session once connected.
  String? pendingSession;
  await Notifications.init(onDeepLink: (id) {
    pendingSession = id;
  });
  final initial = await Notifications.initialDeepLink();
  if (initial != null) pendingSession = initial;

  // Run notifications: when a run finishes/errors while the app is
  // backgrounded, surface a local notification that deep-links to the session.
  var lastRunN = 0;
  controller.addListener(() {
    final ev = controller.lastRunEvent;
    if (ev == null || ev.n == lastRunN) return;
    lastRunN = ev.n;
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused) {
      Notifications.showRun(title: ev.title, body: ev.body, sessionId: ev.sessionId);
    }
  });

  // Needs-input: a run blocked on a permission prompt while backgrounded.
  var lastNeedsN = 0;
  controller.addListener(() {
    final pi = controller.lastNeedsInput;
    if (pi == null || controller.needsInputN == lastNeedsN) return;
    lastNeedsN = controller.needsInputN;
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused) {
      Notifications.showNeedsInput(
        title: 'Needs your input',
        body: pi.title,
        sessionId: controller.activeId ?? '',
      );
    }
  });

  // Foreground service: keep the process (and WS) alive while backgrounded.
  conn.addListener(() {
    if (conn.state == ConnState.connected) {
      Notifications.startKeepAlive();
    } else if (conn.state == ConnState.disconnected) {
      Notifications.stopKeepAlive();
    }
  });

  // Global snackbar: "reconnected" on WS recovery; "host was away" when the
  // gap was long enough that the host (and its sessions) may have changed.
  final messengerKey = GlobalKey<ScaffoldMessengerState>();
  var wasConnected = conn.state == ConnState.connected;
  conn.addListener(() {
    final now = conn.state == ConnState.connected;
    if (now && !wasConnected) {
      final gap = conn.lastGap;
      conn.lastGap = null;
      if (gap != null) {
        final m = gap.inMinutes;
        messengerKey.currentState?.showSnackBar(SnackBar(
            content: Text('Host was away ${m > 0 ? '${m}m' : '${gap.inSeconds}s'} — sessions may have changed'),
            duration: const Duration(seconds: 5)));
      } else {
        messengerKey.currentState?.showSnackBar(const SnackBar(
            content: Text('Reconnected'), duration: Duration(seconds: 2)));
      }
    }
    wasConnected = now;
  });

  runApp(BabelApp(
      controller: controller,
      conn: conn,
      messengerKey: messengerKey,
      pendingSession: () => pendingSession,
      clearPendingSession: () => pendingSession = null));
}

class BabelApp extends StatelessWidget {
  final AppController controller;
  final Connection conn;
  final GlobalKey<ScaffoldMessengerState> messengerKey;
  final String? Function() pendingSession;
  final VoidCallback clearPendingSession;
  const BabelApp(
      {super.key,
      required this.controller,
      required this.conn,
      required this.messengerKey,
      required this.pendingSession,
      required this.clearPendingSession});

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      key: messengerKey,
      child: MaterialApp(
        title: 'babel',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4A6FA5), brightness: Brightness.dark),
          scaffoldBackgroundColor: const Color(0xFF0D1117),
        ),
        home: RootScreen(
          controller: controller,
          conn: conn,
          pendingSession: pendingSession,
          clearPendingSession: clearPendingSession,
        ),
      ),
    );
  }
}

class RootScreen extends StatefulWidget {
  final AppController controller;
  final Connection conn;
  final String? Function() pendingSession;
  final VoidCallback clearPendingSession;
  const RootScreen({
    super.key,
    required this.controller,
    required this.conn,
    required this.pendingSession,
    required this.clearPendingSession,
  });

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.controller, widget.conn]),
      builder: (context, _) {
        // Deep link: attach to the requested session once we're connected.
        final pending = widget.pendingSession();
        if (pending != null &&
            widget.conn.state == ConnState.connected &&
            widget.controller.activeId != pending) {
          widget.clearPendingSession();
          widget.controller.attach(pending);
        }
        final active = widget.controller.activeId;
        if (active != null) {
          return SessionScreen(
              controller: widget.controller, conn: widget.conn, sessionId: active);
        }
        return HomeScreen(controller: widget.controller, conn: widget.conn);
      },
    );
  }
}
