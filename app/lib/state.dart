// App state: sessions, active session transcript, live frame application.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'contract.dart';
import 'connection.dart';

// --- display blocks -------------------------------------------------------

class ToolBlock {
  final String id;
  final String name;
  final Map<String, dynamic> args;
  String? partial;
  String? result;
  bool? isError;
  bool? truncated;
  DateTime? startedAt; // live tool calls only (snapshot has no start time)
  Duration? duration;

  ToolBlock(this.id, this.name, this.args);
  bool get done => result != null;
}

/// A run completion or error, surfaced for local notifications.
class RunEvent {
  final int n; // monotonic — lets listeners detect changes
  final String sessionId;
  final String label; // session display name
  final bool aborted;
  final bool isError;
  final String? message;
  const RunEvent({
    required this.n,
    required this.sessionId,
    required this.label,
    required this.aborted,
    required this.isError,
    this.message,
  });

  String get title => isError ? 'babel: ${label} — error' : (aborted ? 'babel: ${label} — aborted' : 'babel: ${label} — finished');
  String get body => isError ? (message ?? 'unknown error') : (aborted ? 'run was aborted' : 'run completed');
}

class Block {
  final String kind; // user | assistant | tool_result
  String text = '';
  String? thinking;
  final List<ToolBlock> tools = [];
  String? toolName;
  String? result;
  bool? isError;
  bool? truncated;
  bool streaming = false;
  DateTime? ts; // entry timestamp (snapshot) or creation time (live)

  Block(this.kind);
}

/// A blocked extension dialog waiting for the user (contract v1.2).
/// The run is paused until [AppController.respondInput] answers it.
class PendingInput {
  final String requestId;
  final String kind; // confirm | select | input | editor
  final String title;
  final String? message; // confirm
  final List<String> options; // select
  final String? placeholder; // input
  final String? prefill; // editor
  final int? timeoutMs;

  PendingInput({
    required this.requestId,
    required this.kind,
    required this.title,
    this.message,
    this.options = const [],
    this.placeholder,
    this.prefill,
    this.timeoutMs,
  });
}

// --- controller -----------------------------------------------------------

class AppController extends ChangeNotifier {
  final Connection conn;

  List<SessionInfo> sessions = [];
  String? activeId;
  final List<Block> blocks = [];
  int lastSeq = 0;
  bool isRunning = false;
  /// Set on run_started: the next content frame must open a FRESH assistant
  /// block. Without this, a new run's text merges into the transcript's last
  /// (completed) assistant block — two messages render as one.
  bool _newAssistantNeeded = false;
  bool sessionDead = false; // active session's process is gone
  String? transcriptModel; // from the transcript frame metadata
  DateTime? transcriptStartedAt;
  String? banner; // transient host error / info line
  Timer? _bannerTimer;
  /// Blocked extension dialog on the active session (needs_input frame).
  /// Non-null → the run is paused waiting for the user's answer.
  PendingInput? pendingInput;
  /// Last run completion/error — main.dart watches this to fire a local
  /// notification when the app is backgrounded. Monotonic `n` so listeners
  /// can detect changes.
  RunEvent? lastRunEvent;
  int runEventN = 0;
  /// Last needs_input — same watch pattern as lastRunEvent.
  PendingInput? lastNeedsInput;
  int needsInputN = 0;

  AppController(this.conn) {
    conn.onFrame = applyFrame;
  }

  void attach(String sessionId) {
    activeId = sessionId;
    blocks.clear();
    lastSeq = 0;
    isRunning = false;
    _newAssistantNeeded = false;
    sessionDead = false;
    pendingInput = null;
    transcriptModel = null;
    transcriptStartedAt = null;
    conn.send(clientFrame('attach', {'session_id': sessionId}));
  }

  void detach() {
    activeId = null;
    blocks.clear();
    isRunning = false;
    sessionDead = false;
    pendingInput = null;
  }

  /// Answer a blocked extension dialog. Exactly one of [confirmed],
  /// [value], or [cancelled] — matching pi's extension_ui_response.
  void respondInput({bool? confirmed, String? value, bool cancelled = false}) {
    final pi = pendingInput;
    final id = activeId;
    if (pi == null || id == null) return;
    pendingInput = null;
    conn.send(clientFrame('respond_input', {
      'session_id': id,
      'request_id': pi.requestId,
      if (confirmed != null) 'confirmed': confirmed,
      if (value != null) 'value': value,
      if (cancelled) 'cancelled': true,
    }, id: 'ri${DateTime.now().millisecondsSinceEpoch}'));
    notifyListeners();
  }

  void newSession({required String cwd, String? name, String? firstPrompt}) {
    conn.send(clientFrame('new_session', {
      'cwd': cwd,
      if (name != null && name.isNotEmpty) 'name': name,
      if (firstPrompt != null && firstPrompt.isNotEmpty) 'first_prompt': firstPrompt,
    }, id: 'ns${DateTime.now().millisecondsSinceEpoch}'));
  }

  void prompt(String text) {
    final id = activeId;
    if (id == null) return;
    conn.send(clientFrame('prompt', {'session_id': id, 'text': text},
        id: 'p${DateTime.now().millisecondsSinceEpoch}'));
  }

  void abort() {
    final id = activeId;
    if (id == null) return;
    conn.send(clientFrame('abort', {'session_id': id},
        id: 'a${DateTime.now().millisecondsSinceEpoch}'));
  }

  void deleteSession(String sessionId) {
    if (activeId == sessionId) detach();
    conn.send(clientFrame('delete_session', {'session_id': sessionId},
        id: 'd${DateTime.now().millisecondsSinceEpoch}'));
  }

  void renameSession(String sessionId, String name) {
    conn.send(clientFrame('rename_session', {'session_id': sessionId, 'name': name},
        id: 'rn${DateTime.now().millisecondsSinceEpoch}'));
  }

  /// Display name for the active session (for notification text).
  String _activeName() {
    final id = activeId;
    if (id == null) return 'session';
    final s = sessions.where((x) => x.id == id).firstOrNull;
    return s?.name ?? (id.length >= 8 ? id.substring(0, 8) : id);
  }

  void _showBanner(String msg) {
    banner = msg;
    _bannerTimer?.cancel();
    _bannerTimer = Timer(const Duration(seconds: 6), () {
      banner = null;
      notifyListeners();
    });
    notifyListeners();
  }

  // --- frame application --------------------------------------------------

  /// Feed one server frame (raw map) into the state machine. Public so
  /// tests can drive it without a live socket.
  void applyFrame(Map<String, dynamic> raw) {
    final f = Frame(raw);
    switch (f.type) {
      case 'hello':
        if ((f.contract ?? 0) > kContractVersion) {
          _showBanner('host contract v${f.contract} — app speaks v$kContractVersion');
        }
        break;

      case 'session_list':
        // The host broadcasts on every status change; only rebuild the list
        // when it actually changed (rebuilding 700+ rows mid-gesture kills
        // the scroll on a phone).
        final next = f.sessions.map(SessionInfo.new).toList();
        if (!_sameSessionList(next, sessions)) {
          sessions = next;
          notifyListeners();
        }
        return;

      case 'transcript':
        if (f.sessionId != activeId) return;
        _loadTranscript(f);
        return;

      case 'status':
        if (f.sessionId == activeId && f.state == 'dead') {
          sessionDead = true;
          isRunning = false;
          pendingInput = null; // a dead session can't be answered
        }
        return;

      case 'needs_input':
        if (f.sessionId != activeId) return;
        pendingInput = PendingInput(
          requestId: f.requestId ?? '',
          kind: f.kind ?? 'confirm',
          title: f.raw['title'] as String? ?? '',
          message: f.raw['message'] as String?,
          options: f.options,
          placeholder: f.raw['placeholder'] as String?,
          prefill: f.raw['prefill'] as String?,
          timeoutMs: f.raw['timeout_ms'] as int?,
        );
        lastNeedsInput = pendingInput;
        needsInputN++;
        notifyListeners();
        return;

      case 'notice':
        if (f.sessionId != activeId) return;
        _showBanner(f.message ?? '');
        return;

      case 'session_list_response':
      case 'attach_response':
      case 'new_session_response':
      case 'prompt_response':
      case 'steer_response':
      case 'abort_response':
      case 'respond_input_response':
        if (f.ok == false) _showBanner(f.error ?? '${f.type} failed');
        return;

      default:
        // live frames below
    }

    if (f.sessionId != null && f.sessionId != activeId) return;

    final seq = f.seq;
    if (seq != null) {
      if (seq <= lastSeq) return; // duplicate/stale frame — already applied
      if (seq > lastSeq + 1) {
        // gap — we missed frames; ask for a fresh snapshot
        final id = activeId;
        if (id != null) {
          conn.send(clientFrame('resnapshot', {'session_id': id},
              id: 'rs${DateTime.now().millisecondsSinceEpoch}'));
        }
        lastSeq = seq;
        notifyListeners();
        return;
      }
      lastSeq = seq;
    }

    switch (f.type) {
      case 'run_started':
        isRunning = true;
        // Fresh assistant block on the first content frame of this run.
        _newAssistantNeeded = true;
        break;

      case 'text_delta':
        final b = _ensureAssistantBlock();
        b.text += f.delta ?? '';
        break;

      case 'thinking_delta':
        final b = _ensureAssistantBlock();
        b.thinking = (b.thinking ?? '') + (f.delta ?? '');
        break;

      case 'tool_start':
        final b = _ensureAssistantBlock();
        b.tools.add(ToolBlock(f.toolCallId ?? '', f.name ?? '?', f.args)
          ..startedAt = DateTime.now());
        break;

      case 'tool_update':
        final t = _findTool(f.toolCallId);
        if (t != null) t.partial = (t.partial ?? '') + (f.partial ?? '');
        break;

      case 'tool_end':
        final t = _findTool(f.toolCallId);
        if (t != null) {
          t.result = f.result ?? '';
          t.isError = f.isError;
          t.truncated = f.truncated;
          if (t.startedAt != null) {
            t.duration = DateTime.now().difference(t.startedAt!);
          }
        }
        break;

      case 'turn_end':
        for (final b in blocks) {
          if (b.kind == 'assistant') b.streaming = false;
        }
        break;

      case 'run_finished':
        isRunning = false;
        for (final b in blocks) {
          if (b.kind == 'assistant') b.streaming = false;
        }
        lastRunEvent = RunEvent(
          n: ++runEventN,
          sessionId: f.sessionId ?? activeId ?? '',
          label: _activeName(),
          aborted: f.aborted == true,
          isError: false,
        );
        break;

      case 'retry':
        _showBanner('retry ${f.attempt}/${f.maxAttempts}: ${f.message}');
        break;

      case 'compaction':
        _showBanner(f.state == 'started' ? 'compacting context…' : 'compaction done');
        break;

      case 'error':
        _showBanner(f.message ?? 'host error');
        lastRunEvent = RunEvent(
          n: ++runEventN,
          sessionId: f.sessionId ?? activeId ?? '',
          label: _activeName(),
          aborted: false,
          isError: true,
          message: f.message,
        );
        break;

      default:
        break; // pong, unknown — absorbed
    }
    notifyListeners();
  }

  void _loadTranscript(Frame f) {
    blocks.clear();
    lastSeq = f.seq ?? 0;
    // A fresh snapshot means the host re-read state — any pending dialog
    // we were showing is either answered or gone with the old process.
    pendingInput = null;
    transcriptModel = f.raw['model'] as String?;
    final started = f.raw['started_at'];
    transcriptStartedAt =
        started is String ? DateTime.tryParse(started) : null;
    for (final e in f.entries) {
      final ts = e['ts'] is String ? DateTime.tryParse(e['ts'] as String) : null;
      switch (e['role']) {
        case 'user':
          blocks.add(Block('user')
            ..text = (e['text'] as String?) ?? ''
            ..ts = ts);
          break;
        case 'assistant':
          final b = Block('assistant')
            ..text = (e['text'] as String?) ?? ''
            ..ts = ts;
          b.thinking = e['thinking'] as String?;
          for (final t in (e['tools'] as List? ?? const [])) {
            final tm = t is Map<String, dynamic>
                ? t
                : (t as Map).map((k, v) => MapEntry(k.toString(), v));
            final args = tm['args'] is Map<String, dynamic>
                ? tm['args'] as Map<String, dynamic>
                : (tm['args'] is Map
                    ? (tm['args'] as Map).map((k, v) => MapEntry(k.toString(), v))
                    : const <String, dynamic>{});
            b.tools.add(ToolBlock(
              (tm['id'] as String?) ?? '',
              (tm['name'] as String?) ?? '?',
              args,
            ));
          }
          blocks.add(b);
          break;
        case 'tool_result':
          blocks.add(Block('tool_result')
            ..toolName = e['tool'] as String?
            ..result = (e['result'] as String?) ?? ''
            ..isError = e['is_error'] as bool?
            ..truncated = e['truncated'] as bool?
            ..ts = ts);
          break;
      }
    }
    notifyListeners();
  }

  bool _sameSessionList(List<SessionInfo> a, List<SessionInfo> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].status != b[i].status ||
          a[i].name != b[i].name || a[i].model != b[i].model) return false;
    }
    return true;
  }

  Block _ensureAssistantBlock() {
    final last = blocks.isEmpty ? null : blocks.last;
    if (_newAssistantNeeded || last == null || last.kind != 'assistant') {
      _newAssistantNeeded = false;
      blocks.add(Block('assistant')
        ..streaming = true
        ..ts = DateTime.now());
      return blocks.last;
    }
    // Same run (multi-turn) or a mid-run attach: continue the current block.
    last.streaming = true;
    return last;
  }

  ToolBlock? _findTool(String? id) {
    if (id == null) return null;
    for (final b in blocks.reversed) {
      for (final t in b.tools) {
        if (t.id == id) return t;
      }
    }
    return null;
  }
}
