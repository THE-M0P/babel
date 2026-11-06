// Widget tests: home + session screens render from controller state.

import 'package:babel_app/connection.dart';
import 'package:babel_app/screens/home_screen.dart';
import 'package:babel_app/screens/transcript_widgets.dart';
import 'package:babel_app/screens/session_screen.dart';
import 'package:babel_app/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TestConnection extends Connection {
  TestConnection() : super(onFrame: (f) {});
  final List<String> connects = []; // 'host:tokenlen' per connect() call
  final List<Map<String, dynamic>> sent = [];

  @override
  void connect(String host, String token) {
    // Record instead of opening a real socket.
    connects.add('$host:${token.length}');
  }

  @override
  void send(Map<String, dynamic> frame) {
    sent.add(frame);
  }
}

Widget wrap(Widget child) {
  return MaterialApp(home: child);
}

void main() {
  group('HomeScreen', () {
    testWidgets('renders the session list when connected', (tester) async {
      final conn = TestConnection()..state = ConnState.connected;
      final c = AppController(conn);
      c.applyFrame({'v': 1, 'type': 'session_list', 'sessions': [
        {'id': 's1', 'name': 'alpha', 'cwd': '/home/a', 'status': 'idle'},
        {'id': 's2', 'name': 'beta', 'cwd': '/home/b', 'status': 'stored'},
      ]});

      await tester.pumpWidget(wrap(HomeScreen(controller: c, conn: conn)));
      await tester.pump();

      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('beta'), findsOneWidget);
      // list shows the cwd basename, not the full path
      expect(find.text('a'), findsOneWidget);
      expect(find.text('/home/a'), findsNothing);
      // stored sessions get the archive icon
      expect(find.byIcon(Icons.archive_outlined), findsOneWidget);
    });

    testWidgets('shows disconnected state when not connected', (tester) async {
      final conn = TestConnection(); // disconnected by default
      final c = AppController(conn);
      c.applyFrame({'v': 1, 'type': 'session_list', 'sessions': [
        {'id': 's1', 'name': 'alpha', 'cwd': '/home/a', 'status': 'idle'},
      ]});

      await tester.pumpWidget(wrap(HomeScreen(controller: c, conn: conn)));
      await tester.pump();

      expect(find.text('Disconnected'), findsOneWidget);
      expect(find.text('alpha'), findsNothing);
    });

    testWidgets('reconnect button re-reads settings and connects', (tester) async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({
        'host': '10.0.0.1:8790',
        'token': 'abc123',
      });
      final conn = TestConnection(); // disconnected by default
      final c = AppController(conn);

      await tester.pumpWidget(wrap(HomeScreen(controller: c, conn: conn)));
      await tester.pump();

      expect(find.text('Reconnect'), findsOneWidget);
      await tester.tap(find.text('Reconnect'));
      await tester.pump();

      expect(conn.connects, hasLength(1));
      expect(conn.connects.single, '10.0.0.1:8790:6');
    });

    testWidgets('reconnect with no saved token shows a snackbar', (tester) async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final conn = TestConnection();
      final c = AppController(conn);

      await tester.pumpWidget(wrap(HomeScreen(controller: c, conn: conn)));
      await tester.pump();

      await tester.tap(find.text('Reconnect'));
      await tester.pump();

      expect(conn.connects, isEmpty);
      expect(find.text('No token saved — set it in Settings'), findsOneWidget);
    });

    testWidgets('tapping a session attaches to it', (tester) async {
      final conn = TestConnection()..state = ConnState.connected;
      final c = AppController(conn);
      c.applyFrame({'v': 1, 'type': 'session_list', 'sessions': [
        {'id': 's1', 'name': 'alpha', 'cwd': '/home/a', 'status': 'idle'},
      ]});

      await tester.pumpWidget(wrap(HomeScreen(controller: c, conn: conn)));
      await tester.pump();

      await tester.tap(find.text('alpha'));
      await tester.pump();

      expect(c.activeId, 's1');
    });
  });

  group('SessionScreen', () {
    testWidgets('assistant markdown renders (bold + code fence)', (tester) async {
      final conn = TestConnection()..state = ConnState.connected;
      final c = AppController(conn);
      c.attach('s1');
      c.applyFrame({'v': 1, 'type': 'transcript', 'session_id': 's1', 'seq': 1, 'entries': [
        {
          'role': 'assistant',
          'text': 'Here is the fix:\n\n**bold claim** and `inline` code\n\n```python\ndef fix():\n    return 42\n```\n',
        },
      ]});

      await tester.pumpWidget(wrap(SessionScreen(
          controller: c, conn: conn, sessionId: 's1')));
      await tester.pump();

      // Prose renders as text (no raw asterisks). Selectable markdown
      // renders each paragraph as an EditableText, so match by substring.
      expect(find.textContaining('bold claim'), findsOneWidget);
      expect(find.textContaining('**bold'), findsNothing);
      // Inline code renders.
      expect(find.textContaining('inline'), findsOneWidget);
      // Code fence renders as a monospace block.
      expect(find.textContaining('def fix():'), findsOneWidget);
      final code = tester.widget<EditableText>(find.textContaining('def fix():'));
      expect(code.style?.fontFamily, 'monospace');
    });

    testWidgets('needs_input shows an Approve/Deny card; Approve answers it', (tester) async {
      final conn = TestConnection()..state = ConnState.connected;
      final c = AppController(conn);
      c.attach('s1');
      c.applyFrame({'v': 1, 'type': 'needs_input', 'session_id': 's1',
        'request_id': 'req1', 'kind': 'confirm',
        'title': 'Run bash?', 'message': 'npm test'});

      await tester.pumpWidget(wrap(AnimatedBuilder(
          animation: c,
          builder: (context, _) => SessionScreen(
              controller: c, conn: conn, sessionId: 's1'))));
      await tester.pump();

      expect(find.text('Run bash?'), findsOneWidget);
      expect(find.text('npm test'), findsOneWidget);
      expect(find.text('Approve'), findsOneWidget);
      expect(find.text('Deny'), findsOneWidget);

      await tester.tap(find.text('Approve'));
      await tester.pump();

      final sent = conn.sent.last;
      expect(sent['type'], 'respond_input');
      expect(sent['request_id'], 'req1');
      expect(sent['confirmed'], true);
      // card is gone once answered
      expect(find.text('Run bash?'), findsNothing);
    });

    testWidgets('needs_input select shows option buttons', (tester) async {
      final conn = TestConnection()..state = ConnState.connected;
      final c = AppController(conn);
      c.attach('s1');
      c.applyFrame({'v': 1, 'type': 'needs_input', 'session_id': 's1',
        'request_id': 'req2', 'kind': 'select',
        'title': 'Pick a target', 'options': ['alpha', 'beta']});

      await tester.pumpWidget(wrap(AnimatedBuilder(
          animation: c,
          builder: (context, _) => SessionScreen(
              controller: c, conn: conn, sessionId: 's1'))));
      await tester.pump();

      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('beta'), findsOneWidget);

      await tester.tap(find.text('beta'));
      await tester.pump();

      final sent = conn.sent.last;
      expect(sent['value'], 'beta');
    });

    testWidgets('renders transcript blocks', (tester) async {
      final conn = TestConnection()..state = ConnState.connected;
      final c = AppController(conn);
      c.attach('s1');
      c.applyFrame({'v': 1, 'type': 'transcript', 'session_id': 's1', 'seq': 3, 'entries': [
        {'role': 'user', 'text': 'fix the bug'},
        {
          'role': 'assistant',
          'text': 'Looking at it now.',
          'tools': [
            {'id': 'c1', 'name': 'read', 'args': {'path': 'a.py'}}
          ]
        },
        {'role': 'tool_result', 'tool_call_id': 'c1', 'tool': 'read',
            'result': 'def bug(): pass', 'truncated': false, 'is_error': false},
      ]});

      await tester.pumpWidget(wrap(SessionScreen(
          controller: c, conn: conn, sessionId: 's1')));
      await tester.pump();

      expect(find.text('fix the bug', findRichText: true), findsOneWidget);
      expect(find.text('Looking at it now.', findRichText: true), findsOneWidget);
      expect(find.text('read'), findsWidgets); // tool card + tool result label
      expect(find.text('def bug(): pass'), findsOneWidget);
    });

    testWidgets('shows abort button while running', (tester) async {
      final conn = TestConnection()..state = ConnState.connected;
      final c = AppController(conn);
      c.attach('s1');
      c.applyFrame({'v': 1, 'type': 'run_started', 'session_id': 's1', 'seq': 1, 'run_id': 'r1'});

      await tester.pumpWidget(wrap(SessionScreen(
          controller: c, conn: conn, sessionId: 's1')));
      await tester.pump();

      expect(find.byIcon(Icons.stop_circle), findsOneWidget);
    });

    testWidgets('send is disabled while disconnected', (tester) async {
      final conn = TestConnection(); // disconnected
      final c = AppController(conn);
      c.attach('s1');

      await tester.pumpWidget(wrap(SessionScreen(
          controller: c, conn: conn, sessionId: 's1')));
      await tester.pump();

      final button = tester.widget<IconButton>(
          find.ancestor(of: find.byIcon(Icons.send), matching: find.byType(IconButton)));
      expect(button.onPressed, isNull);
      expect(find.text('Disconnected — reconnecting…'), findsOneWidget);
    });

    testWidgets('day dividers appear between blocks on different days', (tester) async {
      final conn = TestConnection()..state = ConnState.connected;
      final c = AppController(conn);
      c.attach('s1');
      c.applyFrame({'v': 1, 'type': 'transcript', 'session_id': 's1', 'seq': 2, 'entries': [
        {'role': 'user', 'text': 'day one', 'ts': '2026-11-03T10:00:00Z'},
        {'role': 'user', 'text': 'day two', 'ts': '2026-11-04T10:00:00Z'},
      ]});

      await tester.pumpWidget(wrap(SessionScreen(
          controller: c, conn: conn, sessionId: 's1')));
      await tester.pump();

      expect(find.text('day one', findRichText: true), findsOneWidget);
      expect(find.text('day two', findRichText: true), findsOneWidget);
      // two blocks on different days -> at least one divider
      expect(find.byType(DayDivider), findsWidgets);
    });

    testWidgets('long-press opens the session menu with rename and delete', (tester) async {
      final conn = TestConnection()..state = ConnState.connected;
      final c = AppController(conn);
      c.applyFrame({'v': 1, 'type': 'session_list', 'sessions': [
        {'id': 's1', 'name': 'alpha', 'cwd': '/home/a', 'status': 'stored'},
      ]});

      await tester.pumpWidget(wrap(HomeScreen(controller: c, conn: conn)));
      await tester.pump();

      await tester.longPress(find.text('alpha'));
      await tester.pumpAndSettle();

      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('search filter hides non-matching sessions', (tester) async {
      final conn = TestConnection()..state = ConnState.connected;
      final c = AppController(conn);
      c.applyFrame({'v': 1, 'type': 'session_list', 'sessions': [
        {'id': 's1', 'name': 'alpha', 'cwd': '/home/a', 'status': 'stored'},
        {'id': 's2', 'name': 'beta', 'cwd': '/home/b', 'status': 'stored'},
      ]});

      await tester.pumpWidget(wrap(HomeScreen(controller: c, conn: conn)));
      await tester.pump();
      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('beta'), findsOneWidget);

      // open the search field and type a filter
      await tester.tap(find.byIcon(Icons.search));
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, 'alpha');
      await tester.pump();
      // 'alpha' appears in the text field AND the surviving list row
      expect(find.text('alpha'), findsWidgets);
      expect(find.text('beta'), findsNothing);
    });

    testWidgets('session death disables the composer', (tester) async {
      final conn = TestConnection()..state = ConnState.connected;
      final c = AppController(conn);
      c.attach('s1');
      c.applyFrame({'v': 1, 'type': 'status', 'session_id': 's1', 'seq': 1, 'state': 'dead'});

      await tester.pumpWidget(wrap(SessionScreen(
          controller: c, conn: conn, sessionId: 's1')));
      await tester.pump();

      expect(find.text('Session ended — transcript is a snapshot.'), findsOneWidget);
      final button = tester.widget<IconButton>(
          find.ancestor(of: find.byIcon(Icons.send), matching: find.byType(IconButton)));
      expect(button.onPressed, isNull);
    });
  });
}
