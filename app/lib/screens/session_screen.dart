// Session view: live transcript + composer (prompt / abort).

import 'package:flutter/material.dart';

import '../connection.dart';
import '../state.dart';
import '../time_format.dart';
import 'transcript_widgets.dart';

class SessionScreen extends StatefulWidget {
  final AppController controller;
  final Connection conn;
  final String sessionId;
  const SessionScreen(
      {super.key, required this.controller, required this.conn, required this.sessionId});

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  final _scroll = ScrollController();
  final _input = TextEditingController();
  bool _pinned = true;

  @override
  void dispose() {
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  /// Scroll to the latest message. With a reversed list the newest item is
  /// at offset 0, so "bottom" is 0.
  void _scrollToLatest() {
    if (!_pinned || !_scroll.hasClients) return;
    _scroll.jumpTo(0);
  }

  /// Flatten blocks + day dividers into render items, newest first (the list
  /// is reversed, so index 0 renders at the bottom = the latest message).
  List<Widget> _buildItems(AppController c) {
    final chrono = <Widget>[];
    String? lastDay;
    for (final b in c.blocks) {
      final day = b.ts != null ? dayKey(b.ts!) : null;
      if (day != null && day != lastDay) {
        chrono.add(DayDivider(day: b.ts!));
        lastDay = day;
      }
      chrono.add(BlockView(block: b));
    }
    return chrono.reversed.toList();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final session = c.sessions.where((s) => s.id == widget.sessionId).firstOrNull;
    final items = _buildItems(c);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => c.detach(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(session?.name ?? 'session',
                maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              [
                if (session != null) session.cwd,
                if (c.transcriptModel != null) c.transcriptModel!,
                if (c.transcriptStartedAt != null)
                  'started ${shortDate(c.transcriptStartedAt!)} ${timeOfDay(c.transcriptStartedAt!)}',
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 11, color: Colors.grey, fontWeight: FontWeight.normal),
            ),
          ],
        ),
        actions: [
          if (c.isRunning)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: IconButton(
                icon: const Icon(Icons.stop_circle, color: Colors.red),
                tooltip: 'Abort run',
                onPressed: c.abort,
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          if (c.banner != null)
            Container(
              width: double.infinity,
              color: const Color(0xB58900),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(c.banner!,
                  style: const TextStyle(color: Colors.black, fontSize: 13)),
            ),
          if (c.sessionDead)
            Container(
              width: double.infinity,
              color: const Color(0x99B5484D),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: const Text('Session ended — transcript is a snapshot.',
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
            ),
          if (c.pendingInput != null)
            _NeedsInputCard(
              input: c.pendingInput!,
              onRespond: c.respondInput,
            ),
          Expanded(
            child: Stack(
              children: [
                NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n is ScrollUpdateNotification) {
                      // Reversed list: offset 0 is the latest (bottom).
                      // "Pinned" = within 80px of the newest message.
                      // Only setState on a pin-state change — a rebuild per
                      // scroll tick re-allocates the whole item list and
                      // janks long transcripts.
                      final pinned = n.metrics.pixels <= 80;
                      if (pinned != _pinned) {
                        _pinned = pinned;
                        if (mounted) setState(() {});
                      }
                    }
                    return true;
                  },
                  child: c.blocks.isEmpty
                      ? const Center(
                          child: Text('Empty session — send a prompt below.',
                              style: TextStyle(color: Colors.grey)),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          // reversed: index 0 (newest) renders at the bottom.
                          // Starts at offset 0 = latest, no jump-to-bottom
                          // needed on load, and renders lazily upward.
                          reverse: true,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          itemCount: items.length,
                          itemBuilder: (context, i) => items[i],
                        ),
                ),
                // Jump-to-latest while reading history
                if (!_pinned && _scroll.hasClients)
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: FloatingActionButton.small(
                      onPressed: () {
                        _pinned = true;
                        _scroll.animateTo(
                          0,
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOut,
                        );
                      },
                      child: const Icon(Icons.arrow_downward),
                    ),
                  ),
              ],
            ),
          ),
          _Composer(
            controller: c,
            conn: widget.conn,
            input: _input,
            onSent: _scrollToLatest,
          ),
        ],
      ),
    );
  }
}

/// A blocked extension dialog: the run is paused until the user answers.
/// confirm → Approve/Deny · select → option buttons · input/editor → field.
class _NeedsInputCard extends StatefulWidget {
  final PendingInput input;
  final void Function({bool? confirmed, String? value, bool cancelled}) onRespond;
  const _NeedsInputCard({required this.input, required this.onRespond});

  @override
  State<_NeedsInputCard> createState() => _NeedsInputCardState();
}

class _NeedsInputCardState extends State<_NeedsInputCard> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.text = widget.input.prefill ?? widget.input.placeholder ?? '';
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.input;
    final isField = i.kind == 'input' || i.kind == 'editor';
    return Container(
      width: double.infinity,
      color: const Color(0xFF1C2733),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.help_outline, size: 16, color: Colors.amber),
              const SizedBox(width: 8),
              Expanded(
                child: Text(i.title,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              // Dismiss = answer "cancelled" (the dialog still gets an answer).
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 16),
                tooltip: 'Dismiss',
                onPressed: () => widget.onRespond(cancelled: true),
              ),
            ],
          ),
          if (i.message != null && i.message!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(i.message!,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          if (i.kind == 'select' && i.options.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final opt in i.options)
                    FilledButton.tonal(
                      onPressed: () => widget.onRespond(value: opt),
                      child: Text(opt),
                    ),
                ],
              ),
            ),
          if (isField) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                controller: _controller,
                autofocus: true,
                maxLines: i.kind == 'editor' ? 4 : 1,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: i.placeholder,
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () =>
                    widget.onRespond(value: _controller.text),
                child: const Text('Submit'),
              ),
            ),
          ],
          if (i.kind == 'confirm')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => widget.onRespond(confirmed: false),
                    child: const Text('Deny'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => widget.onRespond(confirmed: true),
                    child: const Text('Approve'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Composer extends StatefulWidget {
  final AppController controller;
  final Connection conn;
  final TextEditingController input;
  final VoidCallback onSent;
  const _Composer(
      {required this.controller, required this.conn, required this.input, required this.onSent});

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    // Rebuild on both the controller (run state) and the connection state
    // (send is disabled while disconnected — frames would be dropped).
    return AnimatedBuilder(
      animation: Listenable.merge([c, widget.conn]),
      builder: (context, _) {
        final connected = widget.conn.state == ConnState.connected;
        final disabled = !connected || c.sessionDead;
        // Edge-to-edge (default on modern Android) draws the body behind the
        // system nav bar — lift the composer above it.
        final bottomInset = MediaQuery.of(context).padding.bottom;
        return Container(
          padding: EdgeInsets.fromLTRB(12, 8, 12, 8 + bottomInset),
          decoration: const BoxDecoration(color: Color(0xFF161B22)),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: widget.input,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.newline,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: c.sessionDead
                        ? 'Session ended'
                        : !connected
                            ? 'Disconnected — reconnecting…'
                            : c.isRunning
                                ? 'Send to steer the running agent…'
                                : 'Prompt the agent…',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: const BorderSide(color: Color(0xFF30363D)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: const BorderSide(color: Color(0xFF30363D)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: const BorderSide(color: Color(0xFF4A6FA5)),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                icon: Icon(c.isRunning ? Icons.north_west : Icons.send),
                tooltip: c.sessionDead
                    ? 'Session ended'
                    : !connected
                        ? 'Disconnected'
                        : (c.isRunning ? 'Steer' : 'Send'),
                onPressed: disabled
                    ? null
                    : () {
                        final text = widget.input.text.trim();
                        if (text.isEmpty) return;
                        widget.input.clear();
                        c.prompt(text);
                        widget.onSent();
                      },
              ),
            ],
          ),
        );
      },
    );
  }
}
