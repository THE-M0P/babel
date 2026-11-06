// Time formatting tests.

import 'package:babel_app/time_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 11, 4, 15, 0, 0);

  group('relativeTime', () {
    test('now for <60s', () {
      expect(relativeTime(now.subtract(const Duration(seconds: 30)), now: now), 'now');
    });
    test('minutes', () {
      expect(relativeTime(now.subtract(const Duration(minutes: 5)), now: now), '5m');
    });
    test('hours', () {
      expect(relativeTime(now.subtract(const Duration(hours: 3)), now: now), '3h');
    });
    test('days', () {
      expect(relativeTime(now.subtract(const Duration(days: 2)), now: now), '2d');
    });
    test('short date beyond a week', () {
      expect(relativeTime(now.subtract(const Duration(days: 10)), now: now), 'Oct 25');
    });
  });

  group('dayKey', () {
    test('same day, same key', () {
      expect(dayKey(DateTime(2026, 11, 4, 1, 0)), dayKey(DateTime(2026, 11, 4, 23, 59)));
    });
    test('different day, different key', () {
      expect(dayKey(DateTime(2026, 11, 4)), isNot(dayKey(DateTime(2026, 11, 5))));
    });
  });

  group('timeOfDay', () {
    test('zero-pads', () {
      expect(timeOfDay(DateTime(2026, 11, 4, 9, 5)), '09:05');
    });
  });
}
