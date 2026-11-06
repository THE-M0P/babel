// Transcript block rendering: user / assistant / tool_result.

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../state.dart';
import '../time_format.dart';

/// Markdown rendering for chat blocks (assistant prose + user messages).
/// Code fences get the same look as tool-output boxes (selectable);
/// inline code gets a monospace chip. Tool RESULTS stay plain monospace —
/// they're command/file output, not markdown.
class BabelMarkdown extends StatelessWidget {
  final String data;
  const BabelMarkdown({required this.data});

  static final _sheet = MarkdownStyleSheet(
    p: TextStyle(fontSize: 14, height: 1.35),
    strong: TextStyle(fontSize: 14, height: 1.35, fontWeight: FontWeight.w700),
    em: TextStyle(fontSize: 14, height: 1.35, fontStyle: FontStyle.italic),
    code: TextStyle(
        fontSize: 12.5,
        fontFamily: 'monospace',
        backgroundColor: Color(0xFF21262D)),
    // Fenced code blocks: boxed, matching _ExpandableCodeBox. (Not
    // selectable in flutter_markdown 0.7.x — tool-result boxes are.)
    codeblockDecoration: BoxDecoration(
      color: Color(0xFF0D1117),
      borderRadius: BorderRadius.all(Radius.circular(8)),
      border: Border.all(color: Color(0xFF30363D)),
    ),
    codeblockPadding: EdgeInsets.all(10),
    h1: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, height: 1.3),
    h2: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, height: 1.3),
    h3: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, height: 1.3),
    blockSpacing: 8,
    listBullet: TextStyle(fontSize: 14, height: 1.35),
    a: TextStyle(fontSize: 14, color: Color(0xFF58A6FF)),
  );

  @override
  Widget build(BuildContext context) {
    // MarkdownBody (not Markdown): non-scrolling, shrink-wraps its content —
    // the session view is itself a ListView, and Markdown's internal
    // ListView dies with "unbounded height" inside it.
    return MarkdownBody(
      data: data,
      selectable: true,
      styleSheet: _sheet,
    );
  }
}

class BlockView extends StatelessWidget {
  final Block block;
  const BlockView({required this.block});

  @override
  Widget build(BuildContext context) {
    return switch (block.kind) {
      'user' => _UserBlock(text: block.text, ts: block.ts),
      'assistant' => _AssistantBlock(block: block),
      _ => _ToolResultBlock(block: block),
    };
  }
}

/// Day divider between blocks whose local dates differ.
class DayDivider extends StatelessWidget {
  final DateTime day;
  const DayDivider({required this.day});

  @override
  Widget build(BuildContext context) {
    final label = day.isAtSameMomentAs(DateTime.now())
        ? 'Today'
        : day.day == DateTime.now().subtract(const Duration(days: 1)).day &&
                day.month == DateTime.now().subtract(const Duration(days: 1)).month
            ? 'Yesterday'
            : shortDate(day);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF161B22),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(label,
              style: const TextStyle(
                  fontSize: 11, color: Color(0xFF8B949E))),
        ),
      ),
    );
  }
}

class _UserBlock extends StatelessWidget {
  final String text;
  final DateTime? ts;
  const _UserBlock({required this.text, required this.ts});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 32, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1F6FEB).withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          BabelMarkdown(data: text),
          if (ts != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(timeOfDay(ts!),
                  style: const TextStyle(fontSize: 10, color: Color(0xFF8B949E))),
            ),
        ],
      ),
    );
  }
}

class _AssistantBlock extends StatelessWidget {
  final Block block;
  const _AssistantBlock({required this.block});

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    if (block.thinking != null && block.thinking!.isNotEmpty) {
      children.add(_Collapsible(
        label: 'thinking',
        child: Text(block.thinking!,
            style: const TextStyle(
                fontSize: 12, color: Colors.grey, fontStyle: FontStyle.italic)),
      ));
    }
    if (block.text.isNotEmpty) {
      children.add(BabelMarkdown(data: block.text));
    }
    for (final t in block.tools) {
      children.add(_ToolCard(tool: t));
    }
    if (children.isEmpty && block.streaming) {
      // Streaming with nothing rendered yet: distinguish "thinking" from
      // "waiting for the model".
      children.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 12, height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text(
              block.thinking != null && block.thinking!.isNotEmpty
                  ? 'thinking…'
                  : 'working…',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ));
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

class _ToolCard extends StatelessWidget {
  final ToolBlock tool;
  const _ToolCard({required this.tool});

  @override
  Widget build(BuildContext context) {
    final argsStr = tool.args.entries
        .map((e) => '${e.key}=${e.value.toString().length > 80 ? e.value.toString().substring(0, 80) + '…' : e.value}')
        .join(' ');
    final durationStr = tool.duration != null
        ? (tool.duration!.inSeconds < 1
            ? '${tool.duration!.inMilliseconds}ms'
            : '${(tool.duration!.inMilliseconds / 1000).toStringAsFixed(1)}s')
        : null;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: tool.isError == true ? Colors.red.shade700 : const Color(0xFF30363D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                tool.done
                    ? (tool.isError == true ? Icons.error : Icons.check_circle)
                    : Icons.autorenew,
                size: 16,
                color: tool.done
                    ? (tool.isError == true ? Colors.red : Colors.green)
                    : Colors.amber,
              ),
              const SizedBox(width: 8),
              Text('${tool.name}',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, fontFamily: 'monospace')),
              if (durationStr != null) ...[
                const SizedBox(width: 8),
                Text(durationStr,
                    style: const TextStyle(fontSize: 11, color: Color(0xFF8B949E))),
              ],
              if (argsStr.isNotEmpty) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(argsStr,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Colors.grey, fontFamily: 'monospace')),
                ),
              ],
            ],
          ),
          if (tool.partial != null && tool.partial!.isNotEmpty)
            _ExpandableCodeBox(text: tool.partial!),
          if (tool.result != null && tool.result!.isNotEmpty)
            _ExpandableCodeBox(
                text: tool.result! + (tool.truncated == true ? '\n…[truncated]' : '')),
        ],
      ),
    );
  }
}

class _ToolResultBlock extends StatelessWidget {
  final Block block;
  const _ToolResultBlock({required this.block});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${block.toolName ?? 'tool'} result${block.isError == true ? ' (error)' : ''}',
            style: const TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w600),
          ),
          if ((block.result ?? '').isNotEmpty)
            _ExpandableCodeBox(
                text: block.result! + (block.truncated == true ? '\n…[truncated]' : '')),
        ],
      ),
    );
  }
}

/// Code box clipped to [maxLines] by default; tap to expand/collapse.
class _ExpandableCodeBox extends StatefulWidget {
  final String text;
  const _ExpandableCodeBox({required this.text});

  static const int _maxLines = 12;

  @override
  State<_ExpandableCodeBox> createState() => _ExpandableCodeBoxState();
}

class _ExpandableCodeBoxState extends State<_ExpandableCodeBox> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => setState(() => expanded = !expanded),
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF0D1117),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        child: SelectableText(
          widget.text,
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace', height: 1.3),
          maxLines: expanded ? null : _ExpandableCodeBox._maxLines,
        ),
      ),
    );
  }
}

class _Collapsible extends StatefulWidget {
  final String label;
  final Widget child;
  const _Collapsible({required this.label, required this.child});

  @override
  State<_Collapsible> createState() => _CollapsibleState();
}

class _CollapsibleState extends State<_Collapsible> {
  bool open = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22).withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => open = !open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Icon(open ? Icons.expand_more : Icons.expand_less, size: 18, color: Colors.grey),
                  const SizedBox(width: 8),
                  Text(widget.label,
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: widget.child,
            ),
        ],
      ),
    );
  }
}
