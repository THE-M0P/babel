// JSONL framing for pi RPC mode.
//
// Strict LF (0x0A) byte splitting — per docs/rpc.md, do NOT use a generic
// line reader that treats U+2028/U+2029 as boundaries (they are valid inside
// JSON strings). Splitting on the raw 0x0A byte is immune: U+2028 is
// 0xE2 0x80 0xA8 in UTF-8 and contains no 0x0A byte.

export class JsonlFramer {
  constructor() {
    this.buf = Buffer.alloc(0);
  }

  /** Feed a chunk of stdout bytes; returns complete parsed records. */
  push(chunk) {
    this.buf = Buffer.concat([this.buf, chunk]);
    const out = [];
    let idx;
    while ((idx = this.buf.indexOf(0x0a)) !== -1) {
      let line = this.buf.subarray(0, idx).toString('utf8');
      this.buf = this.buf.subarray(idx + 1);
      if (line.length === 0) continue;
      if (line.endsWith('\r')) line = line.slice(0, -1); // accept CRLF
      try {
        out.push(JSON.parse(line));
      } catch (e) {
        out.push({ __parse_error: String(e.message ?? e) });
      }
    }
    return out;
  }
}
