// AppController state machine tests: frame application, seq tracking,
// resnapshot on gaps, tool lifecycle.

import 'package:babel_app/connection.dart';
import 'package:babel_app/state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records sent frames instead of writing to a socket.
class TestConnection extends Connection {
  final List<Map<String, dynamic>> sent = [];
  TestConnection() : super(onFrame: (f) {});

  @override
  void send(Map<String, dynamic> frame) {
    sent.add(frame);
  }
}

void main() {
  late TestConnection conn;
  late AppController c;

  setUp(() {
    conn = TestConnection();
    c = AppController(conn);
  });

  void frame(String type, Map<String, dynamic> fields) {
    c.applyFrame({'v': 1, 'type': type, ...fields});
  }

  group('session list', () {
    test('session_list populates sessions', () {
      frame('session_list', {
        'sessions': [
          {'id': 's1', 'name': 'alpha', 'cwd': '/a', 'status': 'idle'},
          {'id': 's2', 'name': 'beta', 'cwd': '/b', 'status': 'running'},
        ]
      });
      expect(c.sessions, hasLength(2));
      expect(c.sessions[0].id, 's1');
      expect(c.sessions[1].status, 'running');
    });

    test('identical session_list does not notify (scroll fix)', () {
      final list = {
        'sessions': [
          {'id': 's1', 'name': 'alpha', 'cwd': '/a', 'status': 'idle'}
        ]
      };
      var notifies = 0;
      c.addListener(() => notifies++);
      c.applyFrame({'v': 1, 'type': 'session_list', ...list});
      final first = notifies;
      expect(first, greaterThan(0));
      c.applyFrame({'v': 1, 'type': 'session_list', ...list});
      expect(notifies, first, reason: 'unchanged list must not notify');
    });
  });

  group('transcript', () {
    test('attach sends the attach frame', () {
      c.attach('s1');
      expect(c.activeId, 's1');
      expect(conn.sent.last['type'], 'attach');
      expect(conn.sent.last['session_id'], 's1');
    });

    test('transcript loads user, assistant+tools, tool_result blocks', () {
      c.attach('s1');
      frame('transcript', {
        'session_id': 's1',
        'seq': 10,
        'entries': [
          {'role': 'user', 'text': 'fix it'},
          {
            'role': 'assistant',
            'text': 'looking',
            'thinking': 'hmm',
            'tools': [
              {'id': 'c1', 'name': 'read', 'args': {'path': 'a.py'}}
            ]
          },
          {'role': 'tool_result', 'tool_call_id': 'c1', 'tool': 'read',
              'result': 'code', 'truncated': false, 'is_error': false},
        ],
      });
      expect(c.blocks, hasLength(3));
      expect(c.blocks[0].kind, 'user');
      expect(c.blocks[0].text, 'fix it');
      expect(c.blocks[1].kind, 'assistant');
      expect(c.blocks[1].tools, hasLength(1));
      expect(c.blocks[1].tools.first.name, 'read');
      expect(c.blocks[2].kind, 'tool_result');
      expect(c.blocks[2].result, 'code');
      expect(c.lastSeq, 10);
    });

    test('transcript for another session is ignored', () {
      c.attach('s1');
      frame('transcript', {'session_id': 's2', 'seq': 5, 'entries': [
        {'role': 'user', 'text': 'other'}
      ]});
      expect(c.blocks, isEmpty);
    });
  });

  group('live frames', () {
    setUp(() => c.attach('s1'));

    test('text_delta accumulates into a new assistant block', () {
      frame('run_started', {'session_id': 's1', 'seq': 1, 'run_id': 'r1'});
      expect(c.isRunning, isTrue);
      frame('text_delta', {'session_id': 's1', 'seq': 2, 'delta': 'Hel'});
      frame('text_delta', {'session_id': 's1', 'seq': 3, 'delta': 'lo'});
      expect(c.blocks, hasLength(1));
      expect(c.blocks.first.kind, 'assistant');
      expect(c.blocks.first.text, 'Hello');
    });

    test('thinking_delta accumulates separately', () {
      frame('run_started', {'session_id': 's1', 'seq': 1, 'run_id': 'r1'});
      frame('thinking_delta', {'session_id': 's1', 'seq': 2, 'delta': 'hmm '});
      frame('text_delta', {'session_id': 's1', 'seq': 3, 'delta': 'out'});
      expect(c.blocks.first.thinking, 'hmm ');
      expect(c.blocks.first.text, 'out');
    });

    test('tool lifecycle: start → update → end', () {
      frame('run_started', {'session_id': 's1', 'seq': 1, 'run_id': 'r1'});
      frame('tool_start', {
        'session_id': 's1', 'seq': 2, 'tool_call_id': 'c9', 'name': 'bash',
        'args': {'command': 'ls'}
      });
      expect(c.blocks.first.tools, hasLength(1));
      expect(c.blocks.first.tools.first.done, isFalse);

      frame('tool_update', {'session_id': 's1', 'seq': 3, 'tool_call_id': 'c9', 'partial': 'par'});
      expect(c.blocks.first.tools.first.partial, 'par');

      frame('tool_end', {
        'session_id': 's1', 'seq': 4, 'tool_call_id': 'c9',
        'is_error': true, 'result': 'boom', 'truncated': false
      });
      final t = c.blocks.first.tools.first;
      expect(t.done, isTrue);
      expect(t.result, 'boom');
      expect(t.isError, isTrue);
    });

    test('run_finished clears running state', () {
      frame('run_started', {'session_id': 's1', 'seq': 1, 'run_id': 'r1'});
      frame('text_delta', {'session_id': 's1', 'seq': 2, 'delta': 'x'});
      frame('run_finished', {'session_id': 's1', 'seq': 3, 'aborted': false});
      expect(c.isRunning, isFalse);
      expect(c.blocks.first.streaming, isFalse);
    });

    test('frames for a non-active session are ignored', () {
      frame('text_delta', {'session_id': 's2', 'seq': 1, 'delta': 'x'});
      expect(c.blocks, isEmpty);
    });
  });

  group('assistant block boundaries', () {
    setUp(() => c.attach('s1'));

    test('a new run does NOT merge into the transcript\'s last assistant block', () {
      // transcript ends with a completed assistant message
      frame('transcript', {
        'session_id': 's1',
        'seq': 10,
        'entries': [
          {'role': 'user', 'text': 'first question'},
          {'role': 'assistant', 'text': 'first answer'},
        ],
      });
      expect(c.blocks, hasLength(2));

      // next run: its text must open a FRESH block
      frame('run_started', {'session_id': 's1', 'seq': 11, 'run_id': 'r1'});
      frame('text_delta', {'session_id': 's1', 'seq': 12, 'delta': 'second answer'});

      expect(c.blocks, hasLength(3), reason: 'new run opens a new block');
      expect(c.blocks[1].text, 'first answer', reason: 'old block untouched');
      expect(c.blocks[2].text, 'second answer');
    });

    test('multi-turn run stays in one block across turn_end', () {
      frame('run_started', {'session_id': 's1', 'seq': 1, 'run_id': 'r1'});
      frame('text_delta', {'session_id': 's1', 'seq': 2, 'delta': 'turn one '});
      frame('tool_start', {'session_id': 's1', 'seq': 3, 'tool_call_id': 'c1', 'name': 'bash', 'args': {}});
      frame('tool_end', {'session_id': 's1', 'seq': 4, 'tool_call_id': 'c1', 'is_error': false, 'result': 'ok', 'truncated': false});
      frame('turn_end', {'session_id': 's1', 'seq': 5});
      frame('text_delta', {'session_id': 's1', 'seq': 6, 'delta': 'turn two'});

      expect(c.blocks, hasLength(1), reason: 'one run = one assistant block');
      expect(c.blocks.first.text, 'turn one turn two');
    });

    test('attaching mid-run continues the in-flight assistant block', () {
      // transcript captured mid-run: last block is the in-flight assistant
      frame('transcript', {
        'session_id': 's1',
        'seq': 5,
        'entries': [
          {'role': 'user', 'text': 'q'},
          {'role': 'assistant', 'text': 'partial '},
        ],
      });
      // deltas for the SAME in-flight message (no new run_started)
      frame('text_delta', {'session_id': 's1', 'seq': 6, 'delta': 'more'});
      expect(c.blocks, hasLength(2), reason: 'mid-run deltas continue the block');
      expect(c.blocks.last.text, 'partial more');
    });
  });

  group('seq tracking', () {
    setUp(() => c.attach('s1'));

    test('gap triggers resnapshot', () {
      frame('text_delta', {'session_id': 's1', 'seq': 1, 'delta': 'a'});
      conn.sent.clear();
      frame('text_delta', {'session_id': 's1', 'seq': 5, 'delta': 'b'});
      expect(conn.sent, hasLength(1));
      expect(conn.sent.first['type'], 'resnapshot');
      expect(c.lastSeq, 5);
    });

    test('stale/duplicate seq is ignored (no rewind, no resnapshot)', () {
      frame('text_delta', {'session_id': 's1', 'seq': 1, 'delta': 'a'});
      conn.sent.clear();
      frame('text_delta', {'session_id': 's1', 'seq': 1, 'delta': 'dup'});
      frame('text_delta', {'session_id': 's1', 'seq': 1, 'delta': 'stale'});
      expect(conn.sent, isEmpty, reason: 'no resnapshot for stale frames');
      expect(c.lastSeq, 1, reason: 'lastSeq must not rewind');
      expect(c.blocks.first.text, 'a', reason: 'stale frames must not apply');
    });
  });

  group('needs_input', () {
    setUp(() => c.attach('s1'));

    test('needs_input frame sets pendingInput', () {
      frame('needs_input', {
        'session_id': 's1',
        'request_id': 'req1',
        'kind': 'confirm',
        'title': 'Run bash?',
        'message': 'npm test',
        'timeout_ms': 30000,
      });
      expect(c.pendingInput, isNotNull);
      expect(c.pendingInput!.requestId, 'req1');
      expect(c.pendingInput!.kind, 'confirm');
      expect(c.pendingInput!.title, 'Run bash?');
      expect(c.pendingInput!.message, 'npm test');
      expect(c.lastNeedsInput, isNotNull);
      expect(c.needsInputN, 1);
    });

    test('needs_input for another session is ignored', () {
      frame('needs_input', {
        'session_id': 's2',
        'request_id': 'req1',
        'kind': 'confirm',
        'title': 'other',
      });
      expect(c.pendingInput, isNull);
    });

    test('respondInput(confirmed) sends respond_input and clears pendingInput', () {
      frame('needs_input', {
        'session_id': 's1', 'request_id': 'req1', 'kind': 'confirm', 'title': 't',
      });
      c.respondInput(confirmed: true);
      expect(c.pendingInput, isNull);
      final sent = conn.sent.last;
      expect(sent['type'], 'respond_input');
      expect(sent['session_id'], 's1');
      expect(sent['request_id'], 'req1');
      expect(sent['confirmed'], true);
    });

    test('respondInput value and cancelled forms', () {
      frame('needs_input', {
        'session_id': 's1', 'request_id': 'req2', 'kind': 'select', 'title': 't',
        'options': ['a', 'b'],
      });
      c.respondInput(value: 'a');
      expect(conn.sent.last['value'], 'a');
      expect(conn.sent.last.containsKey('cancelled'), isFalse);

      frame('needs_input', {
        'session_id': 's1', 'request_id': 'req3', 'kind': 'confirm', 'title': 't',
      });
      c.respondInput(cancelled: true);
      expect(conn.sent.last['cancelled'], true);
      expect(conn.sent.last.containsKey('confirmed'), isFalse);
    });

    test('respondInput with no pending is a no-op', () {
      c.respondInput(confirmed: true);
      expect(conn.sent.where((f) => f['type'] == 'respond_input'), isEmpty);
    });

    test('transcript snapshot clears pendingInput', () {
      frame('needs_input', {
        'session_id': 's1', 'request_id': 'req1', 'kind': 'confirm', 'title': 't',
      });
      expect(c.pendingInput, isNotNull);
      frame('transcript', {'session_id': 's1', 'seq': 5, 'entries': []});
      expect(c.pendingInput, isNull);
    });

    test('status dead clears pendingInput', () {
      frame('needs_input', {
        'session_id': 's1', 'request_id': 'req1', 'kind': 'confirm', 'title': 't',
      });
      frame('status', {'session_id': 's1', 'state': 'dead'});
      expect(c.pendingInput, isNull);
    });

    test('notice frame shows a banner', () {
      frame('notice', {'session_id': 's1', 'level': 'warning', 'message': 'heating up'});
      expect(c.banner, 'heating up');
    });
  });

  group('banners', () {
    setUp(() => c.attach('s1'));

    test('error frame shows a banner', () {
      frame('error', {'session_id': 's1', 'message': 'host exploded'});
      expect(c.banner, 'host exploded');
    });

    test('retry frame shows attempt info', () {
      frame('retry', {'session_id': 's1', 'attempt': 2, 'max_attempts': 3, 'message': '529'});
      expect(c.banner, contains('2/3'));
    });

    test('failed response shows its error', () {
      frame('prompt_response', {'id': 'x', 'ok': false, 'error': 'session is dead'});
      expect(c.banner, 'session is dead');
    });
  });

  group('timestamps and durations', () {
    setUp(() => c.attach('s1'));

    test('transcript entries carry ts onto blocks', () {
      c.applyFrame({'v': 1, 'type': 'transcript', 'session_id': 's1', 'seq': 1, 'entries': [
        {'role': 'user', 'text': 'hi', 'ts': '2026-11-04T12:00:00Z'},
      ]});
      expect(c.blocks.first.ts, isNotNull);
      expect(c.blocks.first.ts!.toIso8601String(), '2026-11-04T12:00:00.000Z');
    });

    test('live assistant blocks get a creation timestamp', () {
      c.applyFrame({'v': 1, 'type': 'run_started', 'session_id': 's1', 'seq': 1, 'run_id': 'r1'});
      c.applyFrame({'v': 1, 'type': 'text_delta', 'session_id': 's1', 'seq': 2, 'delta': 'x'});
      expect(c.blocks.first.ts, isNotNull);
    });

    test('tool duration is measured from start to end', () {
      c.applyFrame({'v': 1, 'type': 'run_started', 'session_id': 's1', 'seq': 1, 'run_id': 'r1'});
      c.applyFrame({'v': 1, 'type': 'tool_start', 'session_id': 's1', 'seq': 2,
          'tool_call_id': 'c1', 'name': 'bash', 'args': {}});
      c.applyFrame({'v': 1, 'type': 'tool_end', 'session_id': 's1', 'seq': 3,
          'tool_call_id': 'c1', 'is_error': false, 'result': 'ok', 'truncated': false});
      final t = c.blocks.first.tools.first;
      expect(t.duration, isNotNull);
      expect(t.duration!.isNegative, isFalse);
    });

    test('snapshot tools have no duration', () {
      c.applyFrame({'v': 1, 'type': 'transcript', 'session_id': 's1', 'seq': 1, 'entries': [
        {
          'role': 'assistant',
          'text': '',
          'tools': [
            {'id': 'c1', 'name': 'read', 'args': {}}
          ]
        },
      ]});
      expect(c.blocks.first.tools.first.duration, isNull);
    });

    test('status dead sets sessionDead for the active session', () {
      c.applyFrame({'v': 1, 'type': 'status', 'session_id': 's1', 'seq': 1, 'state': 'dead'});
      expect(c.sessionDead, isTrue);
      expect(c.isRunning, isFalse);
    });

    test('status dead for another session is ignored', () {
      c.applyFrame({'v': 1, 'type': 'status', 'session_id': 's2', 'seq': 1, 'state': 'dead'});
      expect(c.sessionDead, isFalse);
    });

    test('attach clears sessionDead', () {
      c.applyFrame({'v': 1, 'type': 'status', 'session_id': 's1', 'seq': 1, 'state': 'dead'});
      c.attach('s1');
      expect(c.sessionDead, isFalse);
    });

    test('transcript metadata (model, started_at) is captured', () {
      c.applyFrame({'v': 1, 'type': 'transcript', 'session_id': 's1', 'seq': 1,
          'model': 'your-llm/your-model', 'started_at': '2026-11-04T13:30:00Z',
          'entries': []});
      expect(c.transcriptModel, 'your-llm/your-model');
      expect(c.transcriptStartedAt, isNotNull);
    });
  });

  group('run events (notifications)', () {
    setUp(() => c.attach('s1'));

    test('run_finished sets lastRunEvent', () {
      c.applyFrame({'v': 1, 'type': 'run_started', 'session_id': 's1', 'seq': 1, 'run_id': 'r1'});
      c.applyFrame({'v': 1, 'type': 'run_finished', 'session_id': 's1', 'seq': 2, 'run_id': 'r1', 'aborted': false});
      final ev = c.lastRunEvent!;
      expect(ev.sessionId, 's1');
      expect(ev.isError, isFalse);
      expect(ev.aborted, isFalse);
      expect(ev.n, 1);
      expect(ev.title, contains('finished'));
    });

    test('aborted run_finished marks aborted', () {
      c.applyFrame({'v': 1, 'type': 'run_finished', 'session_id': 's1', 'seq': 1, 'run_id': 'r1', 'aborted': true});
      expect(c.lastRunEvent!.aborted, isTrue);
      expect(c.lastRunEvent!.title, contains('aborted'));
    });

    test('error frame sets lastRunEvent with the message', () {
      c.applyFrame({'v': 1, 'type': 'error', 'session_id': 's1', 'seq': 1, 'message': 'boom'});
      final ev = c.lastRunEvent!;
      expect(ev.isError, isTrue);
      expect(ev.message, 'boom');
      expect(ev.title, contains('error'));
    });

    test('runEventN is monotonic across events', () {
      c.applyFrame({'v': 1, 'type': 'run_finished', 'session_id': 's1', 'seq': 1, 'run_id': 'r1', 'aborted': false});
      c.applyFrame({'v': 1, 'type': 'run_finished', 'session_id': 's1', 'seq': 2, 'run_id': 'r2', 'aborted': false});
      expect(c.runEventN, 2);
      expect(c.lastRunEvent!.n, 2);
    });
  });

  group('session management', () {
    test('deleteSession sends the command', () {
      c.attach('s1');
      c.deleteSession('s1');
      expect(conn.sent, hasLength(2)); // attach + delete
      expect(conn.sent[1]['type'], 'delete_session');
      expect(conn.sent[1]['session_id'], 's1');
    });

    test('deleteSession detaches if it is the active session', () {
      c.attach('s1');
      c.deleteSession('s1');
      expect(c.activeId, isNull);
    });

    test('renameSession sends the command with the name', () {
      c.renameSession('s1', 'new name');
      expect(conn.sent.last['type'], 'rename_session');
      expect(conn.sent.last['name'], 'new name');
    });
  });

  group('commands', () {
    setUp(() => c.attach('s1'));

    test('prompt sends to the active session', () {
      c.prompt('do the thing');
      final f = conn.sent.last;
      expect(f['type'], 'prompt');
      expect(f['session_id'], 's1');
      expect(f['text'], 'do the thing');
    });

    test('abort sends to the active session', () {
      c.abort();
      expect(conn.sent.last['type'], 'abort');
      expect(conn.sent.last['session_id'], 's1');
    });

    test('prompt with no active session is a no-op', () {
      c.detach();
      conn.sent.clear();
      c.prompt('x');
      expect(conn.sent, isEmpty);
    });
  });
}
