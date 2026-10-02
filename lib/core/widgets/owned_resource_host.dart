import 'dart:async';

import 'package:flutter/widgets.dart';

/// Creates a disposable resource once for the lifetime of this element and
/// releases it when the element is disposed.
///
/// Route builders run again whenever a route page is rebuilt, so a resource
/// built inside the closure would be recreated (and the earlier copy leaked)
/// on every rebuild. Hosting it here ties it to the screen's lifetime.
class OwnedResourceHost<T extends Object> extends StatefulWidget {
  final T Function() create;
  final Future<void> Function(T resource) release;
  final Widget Function(BuildContext context, T resource) builder;

  const OwnedResourceHost({
    required this.create,
    required this.release,
    required this.builder,
    super.key,
  });

  @override
  State<OwnedResourceHost<T>> createState() => _OwnedResourceHostState<T>();
}

class _OwnedResourceHostState<T extends Object>
    extends State<OwnedResourceHost<T>> {
  late final T _resource;

  @override
  void initState() {
    super.initState();
    _resource = widget.create();
  }

  @override
  void dispose() {
    unawaited(widget.release(_resource));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _resource);
}
