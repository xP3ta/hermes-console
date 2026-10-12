import 'package:flutter/material.dart';

/// Builds a [MenuAnchor] wired to [MenuBackGuard]: pass `controller`,
/// `onOpen` and `onClose` straight to the anchor.
typedef MenuBackGuardBuilder =
    Widget Function(
      BuildContext context,
      MenuController controller,
      VoidCallback onOpen,
      VoidCallback onClose,
    );

/// Makes system Back close an open [MenuAnchor] instead of popping the
/// route underneath it.
///
/// A [MenuAnchor] lives in the overlay, not in a route, so the Navigator
/// never sees it: Back pops the screen and the menu only disappears because
/// its anchor is disposed. While the menu is open this guard blocks the
/// enclosing route's pop and closes the menu instead; once closed, Back pops
/// as usual.
class MenuBackGuard extends StatefulWidget {
  const MenuBackGuard({required this.builder, super.key});

  final MenuBackGuardBuilder builder;

  @override
  State<MenuBackGuard> createState() => _MenuBackGuardState();
}

class _MenuBackGuardState extends State<MenuBackGuard> {
  final MenuController _controller = MenuController();
  bool _open = false;

  void _setOpen(bool open) {
    if (!mounted || _open == open) return;
    setState(() => _open = open);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: !_open,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_controller.isOpen) _controller.close();
        _setOpen(false);
      },
      child: widget.builder(
        context,
        _controller,
        () => _setOpen(true),
        () => _setOpen(false),
      ),
    );
  }
}
