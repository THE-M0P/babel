// Projection: pi RPC session events → babel contract frames.
//
// The host is a pure projection layer — no agent logic lives here.

const DEFAULT_MAX = 4000;

export function truncate(text, max = DEFAULT_MAX) {
  if (typeof text !== 'string') return { text: String(text ?? ''), truncated: false };
  if (text.length <= max) return { text, truncated: false };
  return { text: text.slice(0, max), truncated: true };
}

/** Join the text of a content value (string or block array). */
export function textOf(content) {
  if (content == null) return '';
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .filter((b) => b && b.type === 'text' && typeof b.text === 'string')
      .map((b) => b.text)
      .join('');
  }
  return String(content);
}

/**
 * Project one pi RPC event into 0..n contract frames.
 *
 * @param {object} ev      pi RPC event record (type: agent_start, message_update, ...)
 * @param {object} ctx     { session_id, nextRunId, nextSeq, toolResultMax }
 *                          — mutated: counters advance as frames are emitted
 * @returns {object[]}     contract frames (without the "v" field; the server adds it)
 */
export function projectEvent(ev, ctx) {
  const sid = ctx.session_id;
  const frames = [];
  const emit = (frame) => frames.push({ session_id: sid, seq: ctx.nextSeq++, ...frame });

  switch (ev.type) {
    case 'agent_start':
      ctx.runId = `run_${ctx.nextRunId++}`;
      emit({ type: 'run_started', run_id: ctx.runId });
      emit({ type: 'status', state: 'running' });
      return frames;

    case 'message_update': {
      const aev = ev.assistantMessageEvent ?? {};
      if (aev.type === 'text_delta' && typeof aev.delta === 'string') {
        emit({ type: 'text_delta', run_id: ctx.runId, delta: aev.delta });
      } else if (aev.type === 'thinking_delta' && typeof aev.delta === 'string') {
        emit({ type: 'thinking_delta', run_id: ctx.runId, delta: aev.delta });
      }
      // toolcall_start and other block events: the tool_execution_* family
      // carries those; message boundaries are absorbed.
      return frames;
    }

    case 'tool_execution_start':
      emit({
        type: 'tool_start',
        run_id: ctx.runId,
        tool_call_id: ev.toolCallId,
        name: ev.toolName,
        args: ev.args ?? {},
      });
      return frames;

    case 'tool_execution_update': {
      const partial = textOf(ev.partialResult?.content);
      if (partial) emit({ type: 'tool_update', run_id: ctx.runId, tool_call_id: ev.toolCallId, partial });
      return frames;
    }

    case 'tool_execution_end': {
      const { text, truncated } = truncate(textOf(ev.result?.content), ctx.toolResultMax);
      emit({
        type: 'tool_end',
        run_id: ctx.runId,
        tool_call_id: ev.toolCallId,
        is_error: !!ev.isError,
        result: text,
        truncated,
      });
      return frames;
    }

    case 'bash_execution_update':
      // Direct RPC bash command output (v1: no host-side bash commands; keep the mapping).
      if (typeof ev.delta === 'string') {
        emit({ type: 'tool_update', run_id: ctx.runId, tool_call_id: `bash:${ev.id ?? ''}`, partial: ev.delta });
      }
      return frames;

    case 'turn_end':
      emit({ type: 'turn_end', run_id: ctx.runId });
      return frames;

    case 'agent_settled':
      emit({ type: 'run_finished', run_id: ctx.runId, aborted: !!ev.aborted });
      emit({ type: 'status', state: 'idle' });
      return frames;

    case 'compaction_start':
      emit({ type: 'compaction', state: 'started' });
      return frames;

    case 'compaction_end':
      emit({ type: 'compaction', state: 'finished' });
      return frames;

    case 'auto_retry_start':
      emit({
        type: 'retry',
        attempt: ev.attempt,
        max_attempts: ev.maxAttempts,
        message: ev.errorMessage ?? '',
      });
      return frames;

    case 'extension_error':
      emit({ type: 'error', message: ev.error ?? 'extension error' });
      return frames;

    case 'session_info_changed':
      // pi named the session (auto-title after first run, /name, /rename).
      if (ev.name) emit({ type: 'session_renamed', name: ev.name });
      return frames;

    case 'extension_ui_request': {
      // An extension wants user input (confirm/select/input/editor) — the
      // run is BLOCKED until the client answers with extension_ui_response.
      // notify/setStatus/setWidget are fire-and-forget: notify becomes a
      // banner, the rest are absorbed.
      const { method, id, title, message, options, placeholder, prefill, timeout, notifyType } = ev;
      if (method === 'notify') {
        emit({ type: 'notice', level: notifyType ?? 'info', message: message ?? '' });
        return frames;
      }
      if (method === 'setStatus' || method === 'setWidget') return frames;
      const frame = { type: 'needs_input', request_id: id, kind: method, title: title ?? '' };
      if (message != null) frame.message = message;
      if (Array.isArray(options)) frame.options = options;
      if (placeholder != null) frame.placeholder = placeholder;
      if (prefill != null) frame.prefill = prefill;
      if (typeof timeout === 'number') frame.timeout_ms = timeout;
      emit(frame);
      return frames;
    }

    default:
      // message_start / message_end / turn_start / session header / unknown:
      // absorbed. Add frames explicitly when a feature needs them.
      return frames;
  }
}
