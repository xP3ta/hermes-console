/// Registry of every Home widget type: its sizes and instancing.
library;

import 'home_board_model.dart';

final class HomeWidgetSpec {
  final HomeWidgetKind kind;
  final List<HomeWidgetSize> sizes;
  final HomeWidgetSize defaultSize;
  final bool multiInstance;

  /// The option an instance must have before it shows anything (the bot
  /// of a Bot, the chat of a Chat). Adding one asks for it first.
  final String? requiredOption;

  /// False for a type whose data Console does not have yet («próximamente»):
  /// kept out of the gallery, and dropped from the board.
  final bool available;

  const HomeWidgetSpec({
    required this.kind,
    required this.sizes,
    required this.defaultSize,
    this.multiInstance = false,
    this.requiredOption,
    this.available = true,
  });
}

abstract final class HomeWidgetCatalog {
  static const _every = [
    HomeWidgetSize.small,
    HomeWidgetSize.wide,
    HomeWidgetSize.large,
  ];

  static const _all = <HomeWidgetSpec>[
    HomeWidgetSpec(
      kind: HomeWidgetKind.now,
      sizes: _every,
      defaultSize: HomeWidgetSize.wide,
    ),
    HomeWidgetSpec(
      kind: HomeWidgetKind.today,
      sizes: [HomeWidgetSize.small, HomeWidgetSize.wide],
      defaultSize: HomeWidgetSize.small,
    ),
    HomeWidgetSpec(
      kind: HomeWidgetKind.team,
      sizes: _every,
      defaultSize: HomeWidgetSize.wide,
      multiInstance: true,
    ),
    HomeWidgetSpec(
      kind: HomeWidgetKind.bot,
      sizes: _every,
      defaultSize: HomeWidgetSize.small,
      multiInstance: true,
      requiredOption: 'bot',
    ),
    // Without rooms chosen it follows the liveliest ones.
    HomeWidgetSpec(
      kind: HomeWidgetKind.room,
      sizes: _every,
      defaultSize: HomeWidgetSize.small,
      multiInstance: true,
    ),
    HomeWidgetSpec(
      kind: HomeWidgetKind.continueChats,
      sizes: _every,
      defaultSize: HomeWidgetSize.small,
    ),
    HomeWidgetSpec(
      kind: HomeWidgetKind.chat,
      sizes: _every,
      defaultSize: HomeWidgetSize.small,
      multiInstance: true,
      requiredOption: 'chat',
    ),
    // Several fit a board: the next run, one fixed job, the whole list.
    HomeWidgetSpec(
      kind: HomeWidgetKind.cron,
      sizes: _every,
      defaultSize: HomeWidgetSize.small,
      multiInstance: true,
    ),
    HomeWidgetSpec(
      kind: HomeWidgetKind.tasks,
      sizes: _every,
      defaultSize: HomeWidgetSize.small,
    ),
    HomeWidgetSpec(
      kind: HomeWidgetKind.planLimits,
      sizes: _every,
      defaultSize: HomeWidgetSize.wide,
    ),
    HomeWidgetSpec(
      kind: HomeWidgetKind.server,
      sizes: [HomeWidgetSize.small, HomeWidgetSize.wide],
      defaultSize: HomeWidgetSize.small,
    ),
  ];

  static HomeWidgetSpec of(HomeWidgetKind kind) =>
      _all.firstWhere((s) => s.kind == kind);

  /// Every kind «Añadir widget» offers, in its order: the six boards of
  /// a subject first, then the single-target and system ones.
  static const kinds = <HomeWidgetKind>[
    HomeWidgetKind.now,
    HomeWidgetKind.continueChats,
    HomeWidgetKind.team,
    HomeWidgetKind.room,
    HomeWidgetKind.cron,
    HomeWidgetKind.tasks,
    HomeWidgetKind.bot,
    HomeWidgetKind.chat,
    HomeWidgetKind.today,
    HomeWidgetKind.server,
    HomeWidgetKind.planLimits,
  ];

  /// Kinds «Añadir widget» can still add to [layout].
  static List<HomeWidgetKind> addable(HomeBoardLayout layout) => [
    for (final kind in kinds)
      if (of(kind).available &&
          (of(kind).multiInstance || !layout.contains(kind)))
        kind,
  ];
}
