// Transcript projection: pi session entries (from `get_entries`) → babel
// contract transcript entries.
//
// Entry shapes (docs/session-format.md):
//   {type:"message", message:{role:"user"|"assistant"|"toolResult"|"system", ...}}
// Assistant content blocks: {type:"text",text} | {type:"thinking",thinking}
//   | {type:"toolCall",id,name,arguments}

import { textOf, truncate } from './project.mjs';

const DEFAULT_MAX = 4000;

/**
 * @param {object[]} entries  pi session entries (append order, any branch)
 * @param {number}   toolResultMax
 * @returns {object[]}        contract transcript entries
 */
export function projectTranscript(entries, toolResultMax = DEFAULT_MAX) {
  const out = [];
  for (const entry of entries) {
    if (entry?.type !== 'message') continue; // modelChange, label, ...
    const msg = entry.message ?? {};
    switch (msg.role) {
      case 'system':
        break; // prompt/tool declarations — not transcript content
      case 'user':
        out.push({ role: 'user', text: textOf(msg.content), ts: entry.timestamp ?? null });
        break;
      case 'assistant': {
        const e = { role: 'assistant', text: '', ts: entry.timestamp ?? null };
        const thinking = [];
        const tools = [];
        for (const b of Array.isArray(msg.content) ? msg.content : []) {
          if (b?.type === 'text' && typeof b.text === 'string') e.text += b.text;
          else if (b?.type === 'thinking' && typeof b.thinking === 'string') thinking.push(b.thinking);
          else if (b?.type === 'toolCall') tools.push({ id: b.id, name: b.name, args: b.arguments ?? {} });
        }
        if (thinking.length) e.thinking = thinking.join('\n');
        if (tools.length) e.tools = tools;
        out.push(e);
        break;
      }
      case 'toolResult': {
        const { text, truncated } = truncate(textOf(msg.content), toolResultMax);
        out.push({
          role: 'tool_result',
          tool_call_id: msg.toolCallId,
          tool: msg.toolName,
          result: text,
          truncated,
          is_error: !!msg.isError,
          ts: entry.timestamp ?? null,
        });
        break;
      }
      default:
        break;
    }
  }
  return out;
}
