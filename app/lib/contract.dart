// The JSON contract with the session host, v1.
//
// Frames are plain maps on the wire; this file gives them structure:
// typed constructors for client frames, and accessors for server frames.

import 'dart:convert';

const int kContractVersion = 1;

/// Build a client frame.
Map<String, dynamic> clientFrame(String type, Map<String, dynamic> fields,
    {String? id}) {
  final f = <String, dynamic>{'v': kContractVersion, 'type': type, ...fields};
  if (id != null) f['id'] = id;
  return f;
}

class Frame {
  final Map<String, dynamic> raw;

  Frame(this.raw);

  factory Frame.fromJson(String json) => Frame(jsonDecode(json) as Map<String, dynamic>);

  String get type => raw['type'] as String? ?? '';
  String? get id => raw['id'] as String?;
  String? get sessionId => raw['session_id'] as String?;
  int? get seq => raw['seq'] as int?;
  bool? get ok => raw['ok'] as bool?;
  String? get error => raw['error'] as String?;

  // --- typed field accessors (server frames) ---
  String? get text => raw['text'] as String?;
  String? get delta => raw['delta'] as String?;
  String? get name => raw['name'] as String?;
  String? get toolCallId => raw['tool_call_id'] as String?;
  String? get tool => raw['tool'] as String?;
  String? get result => raw['result'] as String?;
  String? get partial => raw['partial'] as String?;
  String? get message => raw['message'] as String?;
  String? get state => raw['state'] as String?;
  bool? get isError => raw['is_error'] as bool?;
  bool? get aborted => raw['aborted'] as bool?;
  bool? get truncated => raw['truncated'] as bool?;
  String? get runId => raw['run_id'] as String?;
  String? get hostVersion => raw['host_version'] as String?;
  int? get contract => raw['contract'] as int?;
  int? get attempt => raw['attempt'] as int?;
  int? get maxAttempts => raw['max_attempts'] as int?;

  // needs_input / notice (contract v1.2)
  String? get requestId => raw['request_id'] as String?;
  String? get kind => raw['kind'] as String?;
  String? get level => raw['level'] as String?;
  List<String> get options =>
      (raw['options'] as List? ?? const []).map((o) => o.toString()).toList();

  List<Map<String, dynamic>> get sessions =>
      (raw['sessions'] as List? ?? const []).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get entries =>
      (raw['entries'] as List? ?? const []).cast<Map<String, dynamic>>();
  Map<String, dynamic> get args {
    final a = raw['args'];
    if (a is Map<String, dynamic>) return a;
    if (a is Map) return a.map((k, v) => MapEntry(k.toString(), v));
    return const {};
  }
}

/// One session from a `session_list` frame.
class SessionInfo {
  final String id;
  final String name;
  final String cwd;
  final String status;
  final String? model;
  final DateTime? updatedAt;

  SessionInfo(Map<String, dynamic> m)
      : id = m['id'] as String,
        name = (m['name'] as String?) ?? '',
        cwd = (m['cwd'] as String?) ?? '',
        status = (m['status'] as String?) ?? 'unknown',
        model = m['model'] as String?,
        updatedAt = _parseTime(m['updated_at']);

  static DateTime? _parseTime(dynamic v) {
    if (v is! String || v.isEmpty) return null;
    return DateTime.tryParse(v);
  }

  /// Last path segment — `deepthought`, not `/home/you/src/deepthought`.
  String get cwdBase {
    final parts = cwd.split('/').where((p) => p.isNotEmpty).toList();
    return parts.isEmpty ? cwd : parts.last;
  }
}
