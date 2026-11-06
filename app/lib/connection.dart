// WebSocket connection to the babel host: auth, keepalive, reconnect.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum ConnState { disconnected, connecting, connected }

class Connection extends ChangeNotifier {
  ConnState state = ConnState.disconnected;
  late void Function(Map<String, dynamic> frame) onFrame;

  WebSocketChannel? _channel;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  int _backoffMs = 1000;
  bool _wantConnected = false;
  String? _host;
  String? _token;
  DateTime? _disconnectedSince;
  /// Set on reconnect after being down for >= 30s (the host may have been
  /// away — sessions may have changed). Consumed by the UI, then cleared.
  Duration? lastGap;

  Connection({required this.onFrame});

  void connect(String host, String token) {
    _wantConnected = true;
    _host = host;
    _token = token;
    _reconnectTimer?.cancel();
    _backoffMs = 1000;
    _open();
  }

  void disconnect() {
    _wantConnected = false;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
    _setState(ConnState.disconnected);
  }

  void _setState(ConnState s) {
    if (state == s) return;
    state = s;
    notifyListeners();
  }

  void _open() {
    if (!_wantConnected) return;
    debugPrint('[babel] _open: connecting to $_host');
    _setState(ConnState.connecting);
    final uri = Uri.parse('ws://$_host/ws?token=$_token');
    // connect() returns the channel immediately; .ready completes when the
    // socket is established (or rejects on failure).
    final ch = WebSocketChannel.connect(uri);
    _channel = ch;
    var closed = false;
    void onDone([Object? err]) {
      if (closed) return;
      closed = true;
      if (_channel != ch) return; // superseded by a newer connection
      debugPrint('[babel] onDone: $err');
      _pingTimer?.cancel();
      _channel = null;
      _setState(ConnState.disconnected);
      _disconnectedSince = DateTime.now();
      if (_wantConnected) {
        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(Duration(milliseconds: _backoffMs), _open);
        _backoffMs = (_backoffMs * 2).clamp(1000, 15000);
      }
    }

    ch.ready
        .then((_) {
          debugPrint('[babel] connected to $_host');
          _backoffMs = 1000;
          _setState(ConnState.connected);
          // "Host was away" detection: how long were we down?
          final since = _disconnectedSince;
          _disconnectedSince = null;
          if (since != null) {
            final gap = DateTime.now().difference(since);
            if (gap.inSeconds >= 30) lastGap = gap;
          }
          _pingTimer?.cancel();
          _pingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
            send({'v': 1, 'type': 'ping'});
          });
        })
        .catchError((Object e) { debugPrint('[babel] ready failed: $e'); onDone(e); });

    ch.stream.listen(
      (data) {
        try {
          onFrame(jsonDecode(data as String) as Map<String, dynamic>);
        } catch (_) {
          // non-JSON frame — ignore
        }
      },
      onDone: () => onDone(),
      onError: (Object e) { debugPrint('[babel] stream error: $e'); onDone(e); },
    );
  }

  void send(Map<String, dynamic> frame) {
    final ch = _channel;
    if (ch == null || state != ConnState.connected) return;
    ch.sink.add(jsonEncode(frame));
  }
}
