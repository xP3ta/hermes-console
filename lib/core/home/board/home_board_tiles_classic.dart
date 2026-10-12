part of 'home_board_tiles.dart';

// The widgets about one thing: one bot, one chat, today, the server and
// the plan limits. Same content as before the fixed grid; each one now
// declares its pieces so it holds in its cell at any text size.

// ── Bot ────────────────────────────────────────────────────────────────

class _BotTile extends StatelessWidget {
  const _BotTile(this.t);
  final HomeTileContext t;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = SoftPalette.ofContext(context);
    final bot = t.data.bot(t.item.stringOption('bot'));
    if (bot == null) {
      if (!t.data.botsLoaded) return _loading(t, context);
      return _Missing(t);
    }
    final name = HomeType.row(p).copyWith(fontSize: 14.5, height: 19 / 14.5);
    final meta = HomeType.meta(p);
    final stateLine = Text(
      bot.state == HomeBotState.idle
          ? _botState(s, bot.state)
          : ([?bot.step, ?bot.room].firstOrNull ?? _botState(s, bot.state)),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: meta.copyWith(color: _botStateColor(p, bot.state)),
    );
    final nameLine = _title(context, bot.displayName, style: name);
    final textH = HomeType.line(context, name) + HomeType.line(context, meta);
    final small = t.size == HomeWidgetSize.small;
    final faceSize = small ? 30.0 : 38.0;
    final face = HomeFace(
      profileName: bot.profileName,
      data: t.data,
      state: bot.state,
      size: faceSize,
    );
    final reply = bot.lastReply;
    final body = HomeType.body(p).copyWith(fontSize: 13, height: 17 / 13);
    _Piece replyPiece(int lines) => _Piece(
      HomeType.line(context, body) * lines,
      Text(
        reply ?? '',
        maxLines: lines,
        overflow: TextOverflow.ellipsis,
        style: body.copyWith(color: p.textMuted),
      ),
      gap: 8,
    );
    return _Tap(
      onTap: _act(t, () => t.actions.openBot(bot)),
      label: bot.displayName,
      child: small
          ? _Body(
              t: t,
              gap: 9,
              pieces: [_Piece(faceSize, face)],
              footer: _Piece(
                textH,
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [nameLine, stateLine],
                ),
              ),
            )
          : _Body(
              t: t,
              gap: 9,
              pieces: [
                _Piece(
                  math.max(faceSize, textH),
                  Row(
                    children: [
                      face,
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [nameLine, stateLine],
                        ),
                      ),
                    ],
                  ),
                  center: true,
                ),
                if (reply != null)
                  switch (t.size) {
                    HomeWidgetSize.large => _Piece(
                      replyPiece(8).height,
                      replyPiece(8).child,
                      gap: 8,
                      or: replyPiece(3),
                    ),
                    _ => _Piece(
                      replyPiece(2).height,
                      replyPiece(2).child,
                      gap: 8,
                      or: replyPiece(1),
                    ),
                  },
              ],
            ),
    );
  }
}

// ── Chat ───────────────────────────────────────────────────────────────

class _ChatTile extends StatelessWidget {
  const _ChatTile(this.t);
  final HomeTileContext t;

  @override
  Widget build(BuildContext context) {
    final p = SoftPalette.ofContext(context);
    final chat = t.data.chat(t.item.stringOption('chat'));
    if (chat == null) return _Missing(t);
    final title = HomeType.row(p).copyWith(height: 18.5 / 14);
    final meta = HomeType.meta(p);
    final big = _bigText(context);
    final small = t.size == HomeWidgetSize.small;
    final titleLines = small ? (big ? 2 : 3) : (big ? 1 : 2);
    // The canonical list preview only (as Conversations and Desktop's
    // sidebar paint it), never a reconstructed last turn.
    final preview = chat.preview.isEmpty ? null : chat.preview;
    _Piece previewPiece(int lines) => _Piece(
      HomeType.line(context, meta) * lines,
      Text(
        preview ?? '',
        maxLines: lines,
        overflow: TextOverflow.ellipsis,
        style: meta,
      ),
      gap: 4,
    );
    return _Tap(
      onTap: _act(t, () => t.actions.openChat(chat)),
      label: chat.title,
      child: _Body(
        key: ValueKey('home-chat-${chat.key}'),
        t: t,
        gap: 8,
        pieces: [
          _Piece(
            HomeType.line(context, title) * titleLines,
            _title(context, chat.title, lines: titleLines, style: title),
          ),
          if (!small && preview != null)
            t.size == HomeWidgetSize.large
                ? _Piece(
                    previewPiece(8).height,
                    previewPiece(8).child,
                    gap: 4,
                    or: previewPiece(3),
                  )
                : previewPiece(1),
        ],
        footer: _Piece(
          HomeType.line(context, meta),
          _chatFoot(context, t, chat),
        ),
      ),
    );
  }
}

// ── Límites del plan ───────────────────────────────────────────────────

/// Calm by default; the soft attention tone from 80 %, the soft failure
/// tone at 100 % (the model sheet's thresholds).
Color _limitColor(SoftPalette p, SoftTint tint, HomeLimitRow row) => row.reached
    ? p.failure
    : row.near
    ? p.attention
    : tint.ink.withValues(alpha: 0.8);

/// Whose limits follow: the provider's own mark, its name and, when it
/// reports one, the plan («Anthropic · Max 5x»). A long name gives up its
/// plan first.
class _LimitWho extends StatelessWidget {
  const _LimitWho(this.who, this.t, {this.style});
  final HomeLimitIdentity who;
  final HomeTileContext t;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final p = SoftPalette.ofContext(context);
    final base = (style ?? HomeType.meta(p)).copyWith(color: p.text);
    final plan = who.plan;
    return Semantics(
      container: true,
      label: [who.name, ?plan].join(', '),
      excludeSemantics: true,
      child: Row(
        key: const ValueKey('home-limit-who'),
        children: [
          ProviderLogo(
            provider: who.provider,
            providerName: who.name,
            size: 15,
            color: t.tint.ink,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: who.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (plan != null)
                    TextSpan(
                      text: ' · $plan',
                      style: TextStyle(color: p.textMuted),
                    ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: base,
            ),
          ),
        ],
      ),
    );
  }
}

class _LimitsTile extends StatelessWidget {
  const _LimitsTile(this.t);
  final HomeTileContext t;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = SoftPalette.ofContext(context);
    final limits = t.data.limits;
    final rows = limits == null
        ? const <HomeLimitRow>[]
        : homeLimitRows(
            limits,
            s,
            languageCode: Localizations.localeOf(context).languageCode,
          );
    if (rows.isEmpty) return _quiet(t, context, s.hwLimitsEmpty);
    final groups = homeLimitGroups(rows);
    final body = HomeType.body(p).copyWith(fontSize: 13.5, height: 18 / 13.5);
    final note = HomeType.meta(p).copyWith(fontSize: 12, height: 16 / 12);
    if (t.size == HomeWidgetSize.small) {
      // The fullest window of the account in use, and whose it is.
      final inUse = groups.first;
      final row = inUse.rows.reduce((a, b) => b.used > a.used ? b : a);
      final who = inUse.who;
      final label = Text(
        homeLimitLabel(s, row),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: body,
      );
      final whoLine = who == null ? null : _LimitWho(who, t, style: note);
      final labelPiece = _Piece(HomeType.line(context, body), label);
      return _Body(
        t: t,
        gap: 9,
        pieces: [
          _Piece(
            44,
            SoftRing(
              value: row.used / 100,
              color: _limitColor(p, t.tint, row),
              track: p.track,
              size: 44,
              stroke: 5,
              child: Text(
                '${row.used.round()}',
                textScaler: _capped(context, 1.2),
                style: HomeType.label(p).copyWith(
                  color: p.text,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ],
        // Whose it is comes first; the window under it. The reset time is
        // in the wider sizes.
        footer: whoLine == null
            ? labelPiece
            : _Piece(
                HomeType.line(context, note) + HomeType.line(context, body),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [whoLine, label],
                ),
                or: _Piece(HomeType.line(context, note), whoLine),
              ),
      );
    }
    return _Body(
      t: t,
      gap: 8,
      pieces: [
        for (final (g, group) in groups.indexed) ...[
          if (group.who case final who?)
            _Piece(
              HomeType.line(context, note),
              _LimitWho(who, t, style: note),
              gap: g == 0 ? 0 : 12,
              withNext: g > 0,
            ),
          for (final (i, row) in group.rows.indexed)
            _Piece(
              HomeType.line(context, body) +
                  6 +
                  6 +
                  (homeLimitNote(s, row) == null
                      ? 0
                      : 4 + HomeType.line(context, note)),
              _LimitRowView(row: row, index: rows.indexOf(row), t: t),
              gap: i == 0 && group.who != null ? 6 : 10,
              center: true,
              row: true,
            ),
        ],
      ],
    );
  }
}

class _LimitRowView extends StatelessWidget {
  const _LimitRowView({
    required this.row,
    required this.index,
    required this.t,
  });
  final HomeLimitRow row;
  final int index;
  final HomeTileContext t;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = SoftPalette.ofContext(context);
    final note = homeLimitNote(s, row);
    final color = _limitColor(p, t.tint, row);
    final body = HomeType.body(p).copyWith(fontSize: 13.5, height: 18 / 13.5);
    return Column(
      key: ValueKey('home-limit-${row.window.name}-$index'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Ends(
          share: 0.6,
          start: Text(
            homeLimitLabel(s, row),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: body.copyWith(fontWeight: FontWeight.w500),
          ),
          end: Text(
            s.hwLimitsUsed(row.used.round()),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.fade,
            style: body.copyWith(
              fontSize: 13,
              color: row.near ? color : p.textMuted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(height: 6),
        SoftCapsuleBar(
          key: ValueKey('home-limit-bar-$index'),
          value: row.used / 100,
          color: color,
          track: p.track,
        ),
        if (note != null) ...[
          const SizedBox(height: 4),
          Text(
            note,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HomeType.meta(p).copyWith(fontSize: 12, height: 16 / 12),
          ),
        ],
      ],
    );
  }
}

// ── Servidor ───────────────────────────────────────────────────────────

class _ServerTile extends StatelessWidget {
  const _ServerTile(this.t);
  final HomeTileContext t;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = SoftPalette.ofContext(context);
    final server = t.data.server;
    if (server == null) return _loading(t, context);
    final color = server.checking
        ? p.textMuted
        : server.online
        ? p.ok
        : p.failure;
    final status = server.checking
        ? s.hwServerChecking
        : server.online
        ? s.hwServerOnline
        : s.hwServerOffline;
    final facts = [
      if (server.version case final v?) 'Hermes $v',
      if (server.latencyMs case final ms? when server.online && ms > 0)
        s.hwServerLatency(ms),
    ];
    final update = server.updateAvailable;
    final head = HomeType.row(p).copyWith(fontSize: 15, height: 20 / 15);
    final meta = HomeType.meta(p);
    final lines = _bigText(context) ? 1 : 2;
    return _Tap(
      onTap: _act(t, t.actions.openServer),
      label: '${server.label}, $status',
      child: _Body(
        key: const ValueKey('home-server'),
        t: t,
        gap: 8,
        pieces: [
          _Piece(
            HomeType.line(context, head),
            Row(
              children: [
                _Dot(color, size: 8),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: head,
                  ),
                ),
              ],
            ),
            center: true,
          ),
          _Piece(
            HomeType.line(context, meta) * lines,
            Text(
              [
                // «Hermes · Hermes 0.12.3» says the name twice.
                if (server.label.trim().toLowerCase() != 'hermes' ||
                    facts.isEmpty)
                  server.label,
                ...facts,
              ].join(' · '),
              maxLines: lines,
              overflow: TextOverflow.ellipsis,
              style: meta,
            ),
            gap: 2,
          ),
        ],
        footer: update == true
            ? _Piece(
                HomeType.line(context, meta),
                _Status(s.hwServerUpdate, mark: _Mark.live, ink: true),
              )
            : update == false && t.size == HomeWidgetSize.wide
            ? _Piece(HomeType.line(context, meta), _Status(s.hwServerUpToDate))
            : null,
      ),
    );
  }
}

// ── Hoy ────────────────────────────────────────────────────────────────

class _TodayTile extends StatelessWidget {
  const _TodayTile(this.t);
  final HomeTileContext t;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = SoftPalette.ofContext(context);
    final today = t.data.today;
    if (today == null) return _loading(t, context);
    if (today.chats == 0) return _quiet(t, context, s.hwTodayNone);
    final extras = [
      if (today.messages > 0) s.hwTodayMessages(today.messages),
      if (today.tools > 0) s.hwTodayTools(today.tools),
    ];
    final big = HomeType.figure(p, size: 27);
    final meta = HomeType.meta(p);
    final wide = t.size == HomeWidgetSize.wide;
    return _Tap(
      onTap: _act(t, t.actions.openSessions),
      child: _Body(
        key: const ValueKey('home-today'),
        t: t,
        gap: 6,
        pieces: [
          _Piece(
            HomeType.line(context, big),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                SoftCounter(today.chats, style: big),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    s.hwTodayChats(today.chats),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HomeType.body(p).copyWith(fontSize: 14.5),
                  ),
                ),
              ],
            ),
          ),
          if (wide && extras.isNotEmpty)
            _Piece(
              HomeType.line(context, meta),
              Text(
                extras.join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: meta,
              ),
              gap: 4,
            )
          else
            for (final (i, extra) in extras.indexed)
              _Piece(
                HomeType.line(context, meta),
                Text(
                  extra,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: meta,
                ),
                gap: i == 0 ? 4 : 0,
              ),
        ],
      ),
    );
  }
}
