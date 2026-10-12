// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

/// The system of the computer where Hermes lives, as far as its setup
/// commands go: Linux and macOS share one line, Windows has its own.
enum SetupHostSystem { unix, windows }

/// The commands of the setup helper (github.com/xP3ta/hermes-setup), which
/// runs on the computer where Hermes lives. The app only shows them, exact
/// and ready to copy; it never runs anything on that computer.
///
/// The helper prepares Hermes' own Gateway and Dashboard and shows one code
/// to scan. It installs no companion service.
abstract final class HermesSetupCommands {
  static const _raw =
      'https://raw.githubusercontent.com/xP3ta/hermes-setup/main';
  static const _unixSetup = 'curl -fsSL $_raw/hermes-mobile-setup.sh | sh';
  static const _windowsSetup =
      '& ([scriptblock]::Create((irm $_raw/hermes-mobile-setup.ps1)))';

  /// Gets the computer ready and shows the code to scan.
  static String setup(SetupHostSystem system) => switch (system) {
    SetupHostSystem.unix => _unixSetup,
    SetupHostSystem.windows => 'irm $_raw/hermes-mobile-setup.ps1 | iex',
  };

  /// Checks the services and shows the code again; changes nothing.
  static String showCodeAgain(SetupHostSystem system) => switch (system) {
    SetupHostSystem.unix => 'curl -fsSL $_raw/hermes-pair.sh | sh',
    SetupHostSystem.windows => 'irm $_raw/hermes-pair.ps1 | iex',
  };

  /// Makes a new Dashboard sign-in, ends the sessions opened with the old
  /// one and shows a new code.
  static String newAccess(SetupHostSystem system) => switch (system) {
    SetupHostSystem.unix => '$_unixSetup -s -- --new-access',
    SetupHostSystem.windows => '$_windowsSetup -NewAccess',
  };

  /// Stops and removes the Mobile Bridge an earlier setup installed, and
  /// nothing else. Idempotent; safe where there is no bridge.
  static String retireBridge(SetupHostSystem system) => switch (system) {
    SetupHostSystem.unix => '$_unixSetup -s -- --retire-bridge',
    SetupHostSystem.windows => '$_windowsSetup -RetireBridge',
  };
}
