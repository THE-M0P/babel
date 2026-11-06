// Time formatting for the session list and transcript.

/// Relative time for the session list: `now` / `Xm` / `Xh` / `Xd` / `Mon d`.
String relativeTime(DateTime t, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final diff = ref.difference(t);
  if (diff.inSeconds < 60) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';
  return _shortDate(t);
}

/// `Nov 4` / `Dec 25` style date.
String shortDate(DateTime t) => _shortDate(t);

/// `13:30` style time of day.
String timeOfDay(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Day key for divider grouping (local date, no time).
String dayKey(DateTime t) =>
    '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _shortDate(DateTime t) => '${_months[t.month - 1]} ${t.day}';
