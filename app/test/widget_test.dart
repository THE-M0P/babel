import 'package:babel_app/contract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('clientFrame carries version, type, id', () {
    final f = clientFrame('prompt', {'session_id': 's1', 'text': 'hi'}, id: 'r1');
    expect(f['v'], 1);
    expect(f['type'], 'prompt');
    expect(f['id'], 'r1');
    expect(f['session_id'], 's1');
  });

  test('Frame parses a transcript frame', () {
    final f = Frame.fromJson(
        '{"v":1,"type":"transcript","session_id":"s1","seq":7,'
        '"entries":[{"role":"user","text":"hello"}]}');
    expect(f.type, 'transcript');
    expect(f.sessionId, 's1');
    expect(f.seq, 7);
    expect(f.entries.length, 1);
    expect(f.entries.first['text'], 'hello');
  });

  test('Frame parses a tool_end frame', () {
    final f = Frame.fromJson(
        '{"v":1,"type":"tool_end","session_id":"s1","seq":8,'
        '"tool_call_id":"c1","is_error":false,"result":"ok","truncated":false}');
    expect(f.toolCallId, 'c1');
    expect(f.isError, false);
    expect(f.result, 'ok');
    expect(f.truncated, false);
  });
}
