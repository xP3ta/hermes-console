// Colores del terminal SSH según el tema de la app (1.4.0, huecos). Copia de
// Hermes Desktop (`app/right-sidebar/terminal/selection.ts:11-57`): las
// paletas por defecto del terminal de VS Code, clara u oscura según el modo
// que se ve, y el fondo pintado con la superficie de la app
// (`use-terminal-session.ts:293-296`, `withSurface`). xterm.dart solo trae
// temas oscuros, así que en tema claro el terminal quedaba negro entre
// barras claras.
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import 'app_theme.dart';

/// Desktop's light palette (VS Code light terminal).
const TerminalTheme _desktopLight = TerminalTheme(
  cursor: Color(0xFF333333),
  selection: Color(0x80ADD6FF),
  foreground: Color(0xFF333333),
  background: Color(0xFFFFFFFF),
  black: Color(0xFF000000),
  red: Color(0xFFCD3131),
  green: Color(0xFF00BC00),
  yellow: Color(0xFF949800),
  blue: Color(0xFF0451A5),
  magenta: Color(0xFFBC05BC),
  cyan: Color(0xFF0598BC),
  white: Color(0xFF555555),
  brightBlack: Color(0xFF666666),
  brightRed: Color(0xFFCD3131),
  brightGreen: Color(0xFF14CE14),
  brightYellow: Color(0xFFB5BA00),
  brightBlue: Color(0xFF0451A5),
  brightMagenta: Color(0xFFBC05BC),
  brightCyan: Color(0xFF0598BC),
  brightWhite: Color(0xFFA5A5A5),
  // Not in Desktop's palette (xterm.js styles search itself): xterm.dart's
  // defaults.
  searchHitBackground: Color(0xFFFFFF2B),
  searchHitBackgroundCurrent: Color(0xFF31FF26),
  searchHitForeground: Color(0xFF000000),
);

/// Desktop's dark palette (VS Code dark terminal).
const TerminalTheme _desktopDark = TerminalTheme(
  cursor: Color(0xFFCCCCCC),
  selection: Color(0x66264F78),
  foreground: Color(0xFFCCCCCC),
  background: Color(0xFF1E1E1E),
  black: Color(0xFF000000),
  red: Color(0xFFCD3131),
  green: Color(0xFF0DBC79),
  yellow: Color(0xFFE5E510),
  blue: Color(0xFF2472C8),
  magenta: Color(0xFFBC3FBC),
  cyan: Color(0xFF11A8CD),
  white: Color(0xFFE5E5E5),
  brightBlack: Color(0xFF666666),
  brightRed: Color(0xFFF14C4C),
  brightGreen: Color(0xFF23D18B),
  brightYellow: Color(0xFFF5F543),
  brightBlue: Color(0xFF3B8EEA),
  brightMagenta: Color(0xFFD670D6),
  brightCyan: Color(0xFF29B8DB),
  brightWhite: Color(0xFFE5E5E5),
  searchHitBackground: Color(0xFFFFFF2B),
  searchHitBackgroundCurrent: Color(0xFF31FF26),
  searchHitForeground: Color(0xFF000000),
);

/// The terminal's colours for [theme]: Desktop's light or dark palette by
/// the app's brightness, on the app's surface colour (so the terminal, the
/// key row and the bars around it are one surface).
TerminalTheme hermesTerminalTheme(ThemeData theme) {
  final base = theme.brightness == Brightness.light
      ? _desktopLight
      : _desktopDark;
  final background = theme.hermes.surface;
  return TerminalTheme(
    cursor: base.cursor,
    selection: base.selection,
    foreground: base.foreground,
    background: background,
    black: base.black,
    red: base.red,
    green: base.green,
    yellow: base.yellow,
    blue: base.blue,
    magenta: base.magenta,
    cyan: base.cyan,
    white: base.white,
    brightBlack: base.brightBlack,
    brightRed: base.brightRed,
    brightGreen: base.brightGreen,
    brightYellow: base.brightYellow,
    brightBlue: base.brightBlue,
    brightMagenta: base.brightMagenta,
    brightCyan: base.brightCyan,
    brightWhite: base.brightWhite,
    searchHitBackground: base.searchHitBackground,
    searchHitBackgroundCurrent: base.searchHitBackgroundCurrent,
    searchHitForeground: base.searchHitForeground,
  );
}
