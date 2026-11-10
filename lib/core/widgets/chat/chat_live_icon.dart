import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/motion.dart';

/// The ten icons of the live chat (row, header pill, queue chip): outline,
/// weight 2, «light» motion, from the MIT-licensed Generative Icons library.
/// Licence and provenance: assets/chat_icons/LICENSE.txt, ASSET_PROVENANCE.md.
///
/// Each glyph is a pre-rendered frame strip (tool/chat_icons/build_atlas.py):
/// white on transparent, tinted with the theme at paint time. No player
/// dependency: the strip is cut with `drawImageRect`.
enum ChatLiveGlyph {
  reasoning('reasoning', Icons.account_tree_outlined, 19),
  terminalAgent('terminal-agent', Icons.account_tree_outlined, 28),
  toolCall('tool-call', Icons.account_tree_outlined, 16),
  delegateTask('delegate-task', Icons.account_tree_outlined, 26),
  parallelTools('parallel-tools', Icons.account_tree_outlined, 24),
  responseStream('response-stream', Icons.account_tree_outlined, 18),
  check('check', Icons.check_rounded, 12),
  error('error', Icons.error_outline_rounded, 16),
  queued('queued', Icons.playlist_add_rounded, 21),
  agentTeam('agent-team', Icons.account_tree_outlined, 12);

  const ChatLiveGlyph(this.id, this.fallback, this.frames);

  /// Catalogue id; the strip lives at `assets/chat_icons/<id>.webp`.
  final String id;

  /// What paints while the strip loads, or when it cannot be read: what each
  /// place showed before these icons (the row's tree, the check, the error...).
  final IconData fallback;

  /// Frames in the strip; `assets/chat_icons/atlas.json` says the same and a
  /// test keeps both in step.
  final int frames;

  String get asset => 'assets/chat_icons/$id.webp';
}

const Set<String> _terminalTools = {
  'terminal',
  'execute_code',
  'process',
  'process_manage',
  'read_terminal',
  'close_terminal',
  'bash',
  'shell',
};

/// The icon of a running tool: the terminal's prompt for command-like tools,
/// the wrench for any other.
ChatLiveGlyph chatLiveGlyphForTool(String? tool) =>
    _terminalTools.contains(tool?.trim().toLowerCase())
    ? ChatLiveGlyph.terminalAgent
    : ChatLiveGlyph.toolCall;

/// Edge, in pixels, of one frame of every strip.
const int kChatLiveIconFramePx = 64;

/// 30 fps of the 60 fps source.
const Duration kChatLiveIconFrame = HermesMotion.liveIconFrame;

/// How long the pose rests between two plays.
const Duration kChatLiveIconHold = HermesMotion.liveIconHold;

/// The frame the strip rests on once the thing it says is done: its last.
int chatLiveIconRestFrame(ChatLiveGlyph glyph) => glyph.frames - 1;

/// Which frame a looping icon shows [elapsed] after it started: forward,
/// hold, back, hold. A pure function so a test can read it.
@visibleForTesting
int chatLiveIconFrameAt(ChatLiveGlyph glyph, Duration elapsed) {
  final play = kChatLiveIconFrame * (glyph.frames - 1);
  final cycle = (play + kChatLiveIconHold) * 2;
  final t = Duration(
    microseconds: elapsed.inMicroseconds % cycle.inMicroseconds,
  );
  if (t < play) return t.inMicroseconds ~/ kChatLiveIconFrame.inMicroseconds;
  if (t < play + kChatLiveIconHold) return glyph.frames - 1;
  final back = t - play - kChatLiveIconHold;
  if (back < play) {
    return glyph.frames -
        1 -
        back.inMicroseconds ~/ kChatLiveIconFrame.inMicroseconds;
  }
  return 0;
}

/// Decodes a strip; null when the asset is missing or unreadable.
typedef ChatLiveIconLoader = Future<ui.Image?> Function(ChatLiveGlyph glyph);

Future<ui.Image?> _bundleLoader(ChatLiveGlyph glyph) async {
  try {
    final data = await rootBundle.load(glyph.asset);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  } catch (_) {
    return null;
  }
}

/// Strips are decoded once per process and shared by every icon on screen.
class ChatLiveIconCache {
  ChatLiveIconCache._();

  static final Map<ChatLiveGlyph, Future<ui.Image?>> _images = {};

  /// Tests swap the loader to feed generated strips or to fail on purpose.
  @visibleForTesting
  static ChatLiveIconLoader loader = _bundleLoader;

  static Future<ui.Image?> of(ChatLiveGlyph glyph) =>
      _images.putIfAbsent(glyph, () => loader(glyph));

  @visibleForTesting
  static void reset() => _images.clear();
}

/// One live-chat icon. [live] loops it (forward, hold, back, hold) while the
/// thing it stands for runs; settled it rests on its last frame; with the
/// system's «reduce motion» it never moves. Decorative: the row or pill it
/// sits in carries the words for assistive tech.
class ChatLiveIcon extends StatefulWidget {
  const ChatLiveIcon(
    this.glyph, {
    required this.color,
    this.size = 18,
    this.live = false,
    super.key,
  });

  final ChatLiveGlyph glyph;
  final Color color;
  final double size;
  final bool live;

  @override
  State<ChatLiveIcon> createState() => _ChatLiveIconState();
}

class _ChatLiveIconState extends State<ChatLiveIcon>
    with SingleTickerProviderStateMixin {
  ui.Image? _image;
  AnimationController? _controller;
  bool _reduced = false;
  int _loadEpoch = 0;

  @visibleForTesting
  int get debugFrame => _frame();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = HermesMotion.reduced(context);
    _syncController();
  }

  @override
  void didUpdateWidget(ChatLiveIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.glyph != widget.glyph) {
      _image = null;
      _load();
    }
    _syncController();
  }

  Future<void> _load() async {
    final epoch = ++_loadEpoch;
    final image = await ChatLiveIconCache.of(widget.glyph);
    if (!mounted || epoch != _loadEpoch) return;
    setState(() => _image = image);
    _syncController();
  }

  void _syncController() {
    // Nothing moves until there is a strip to move: the fallback is still.
    final animate = widget.live && !_reduced && _image != null;
    if (!animate) {
      _controller?.dispose();
      _controller = null;
      return;
    }
    if (_controller != null) return;
    final play = kChatLiveIconFrame * (widget.glyph.frames - 1);
    _controller = AnimationController(
      vsync: this,
      duration: (play + kChatLiveIconHold) * 2,
    )..repeat();
  }

  int _frame() {
    final controller = _controller;
    if (controller == null) return chatLiveIconRestFrame(widget.glyph);
    final span = controller.duration!;
    return chatLiveIconFrameAt(
      widget.glyph,
      Duration(microseconds: (span.inMicroseconds * controller.value).round()),
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final size = widget.size;
    if (image == null) {
      return ExcludeSemantics(
        child: Icon(widget.glyph.fallback, size: size, color: widget.color),
      );
    }
    final controller = _controller;
    final paint = controller == null
        ? CustomPaint(
            size: Size.square(size),
            painter: _StripPainter(image, _frame(), widget.color),
          )
        : AnimatedBuilder(
            animation: controller,
            builder: (context, _) => CustomPaint(
              size: Size.square(size),
              painter: _StripPainter(image, _frame(), widget.color),
            ),
          );
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: SizedBox.square(dimension: size, child: paint),
      ),
    );
  }
}

class _StripPainter extends CustomPainter {
  _StripPainter(this.image, this.frame, this.color);

  final ui.Image image;
  final int frame;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final edge = kChatLiveIconFramePx.toDouble();
    final source = Rect.fromLTWH(frame * edge, 0, edge, edge);
    canvas.drawImageRect(
      image,
      source,
      Offset.zero & size,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..colorFilter = ColorFilter.mode(color, BlendMode.srcIn),
    );
  }

  @override
  bool shouldRepaint(_StripPainter old) =>
      old.image != image || old.frame != frame || old.color != color;
}
