// Local notifications + deep links.
//
// Run completions/errors arrive over the WS. When the app is in the
// background we surface them as local notifications; tapping one deep-links
// into the session (babel://session/<id>). The foreground service keeps the
// process (and the WS) alive while the app is backgrounded.

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

class Notifications {
  static const channelId = 'babel-runs';
  static const scheme = 'babel';

  /// FNV-1a over the session id — deterministic across runs/platforms,
  /// unlike String.hashCode.
  static int _stableId(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h;
  }

  static FlutterLocalNotificationsPlugin? _plugin;
  static void Function(String? sessionId)? _onDeepLink;

  /// Must be called before runApp (initializes channels + deep-link intents).
  /// [onDeepLink] fires when a notification is tapped (warm start) with the
  /// session id from the babel:// URI.
  static Future<void> init({required void Function(String? sessionId) onDeepLink}) async {
    _onDeepLink = onDeepLink;
    _plugin = FlutterLocalNotificationsPlugin();

    await _plugin!.initialize(
      settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveNotificationResponse: _onResponse,
      onDidReceiveBackgroundNotificationResponse: _onResponse,
    );

    // Foreground service: a persistent low-key notification that keeps the
    // process alive so the WS survives doze. The task itself is a no-op —
    // the work happens in the main isolate.
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'babel-keepalive',
        channelName: 'Keep alive',
        channelDescription: 'Keeps babel watching sessions',
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
      ),
    );
    FlutterForegroundTask.setTaskHandler(const _KeepAliveTask());
  }

  /// Show a run notification that deep-links into [sessionId].
  static Future<void> showRun({
    required String title,
    required String body,
    required String sessionId,
  }) async {
    final plugin = _plugin;
    if (plugin == null) return;

    final link = 'babel://session/$sessionId';
    final details = AndroidNotificationDetails(
      channelId,
      'Run notifications',
      channelDescription: 'Agent run completions and errors',
      importance: Importance.high,
      priority: Priority.high,
    );

    // The payload carries the deep link; onDidReceiveNotificationResponse
    // resolves it and the app attaches to the session.
    await plugin.show(
      // Stable across app restarts (String.hashCode is not guaranteed to
      // be) — the same session's notification replaces the previous one.
      id: _stableId(sessionId),
      title: title,
      body: body,
      notificationDetails: NotificationDetails(android: details),
      payload: link,
    );
  }

  /// A run is blocked on a permission prompt (needs_input). Tapping
  /// deep-links into the session where the Approve/Deny card is waiting.
  /// Separate id from showRun so the two don't clobber each other.
  static Future<void> showNeedsInput({
    required String title,
    required String body,
    required String sessionId,
  }) async {
    final plugin = _plugin;
    if (plugin == null) return;

    final details = AndroidNotificationDetails(
      channelId,
      'Run notifications',
      channelDescription: 'Agent run completions and errors',
      importance: Importance.high,
      priority: Priority.high,
    );
    await plugin.show(
      id: _stableId('needs:$sessionId'),
      title: title,
      body: body,
      notificationDetails: NotificationDetails(android: details),
      payload: 'babel://session/$sessionId',
    );
  }

  /// Start the foreground service (WS keep-alive).
  static Future<void> startKeepAlive() async {
    try {
      await FlutterForegroundTask.startService(
        notificationTitle: 'babel',
        notificationText: 'watching sessions',
        notificationIcon: const NotificationIcon(metaDataName: '@mipmap/ic_launcher'),
      );
    } catch (_) {
      // Service already running or platform unavailable — non-fatal.
    }
  }

  static Future<void> stopKeepAlive() async {
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
  }

  /// Deep-link payload from a notification tap / external launch.
  /// `babel://session/<id>` — 'session' parses as the authority, <id> as path.
  static String? sessionIdFromUri(Uri? uri) {
    if (uri == null || uri.scheme != scheme) return null;
    if (uri.host != 'session') return null;
    final parts = uri.pathSegments;
    if (parts.length == 1 && parts[0].isNotEmpty) return parts[0];
    return null;
  }

  /// Cold start: was the app launched from a notification tap?
  static Future<String?> initialDeepLink() async {
    final details = await _plugin?.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    final payload = details.notificationResponse?.payload;
    return payload == null ? null : sessionIdFromUri(Uri.parse(payload));
  }

  static void _onResponse(NotificationResponse response) {
    // The payload carries the babel:// URI; resolve the session id here.
    _onDeepLink?.call(sessionIdFromUri(Uri.parse(response.payload ?? '')));
  }
}

/// Foreground-service task body: a no-op keep-alive.
class _KeepAliveTask implements TaskHandler {
  const _KeepAliveTask();

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onReceiveData(Object data) {}

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {}

  @override
  void onNotificationDismissed() {}
}
