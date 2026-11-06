// Deep-link URI parsing tests.

import 'package:babel_app/notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sessionIdFromUri', () {
    test('parses babel://session/<id>', () {
      expect(Notifications.sessionIdFromUri(Uri.parse('babel://session/abc-123')), 'abc-123');
    });
    test('rejects other schemes', () {
      expect(Notifications.sessionIdFromUri(Uri.parse('https://session/abc')), isNull);
    });
    test('rejects malformed paths', () {
      expect(Notifications.sessionIdFromUri(Uri.parse('babel://other/abc')), isNull);
      expect(Notifications.sessionIdFromUri(Uri.parse('babel://')), isNull);
    });
    test('null uri', () {
      expect(Notifications.sessionIdFromUri(null), isNull);
    });
  });
}
