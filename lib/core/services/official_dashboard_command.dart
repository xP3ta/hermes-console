// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

import 'hermes_setup_commands.dart';

/// The one line that makes Hermes' own Dashboard reachable from the phone:
/// `hermes dashboard` listens on 127.0.0.1:9119 unless told otherwise, and
/// `--host 0.0.0.0` opens it to the network (hermes-agent
/// `hermes_cli/subcommands/dashboard.py`). Any bind outside loopback needs a
/// sign-in; from a terminal the first start offers to create a user name and
/// a password (`hermes_cli/main_dashboard.py`, `_maybe_setup_dashboard_auth_interactively`).
///
/// Shown as text to run on the computer where Hermes lives; the app never
/// runs it. Every screen that shows or copies it reads it from here.
const String kOfficialDashboardCommand = 'hermes dashboard --host 0.0.0.0';

/// Clears the stored Dashboard password, stops a Dashboard that is already
/// running, then starts it again from a terminal so it asks for a new one.
/// `hermes config unset` needs no quoting (an empty argument is lost in some
/// shells); with no password the provider is not registered. The running
/// process keeps the old hash in memory and `hermes dashboard` exits with
/// "already running" before asking, hence `--stop`
/// (`hermes_cli/main.py` `_attach_to_host_backend`, `main_dashboard.py`,
/// `plugins/dashboard_auth/basic/__init__.py`). The session `secret` stays.
const String kOfficialDashboardResetCommand =
    'hermes config unset dashboard.basic_auth.password_hash\n'
    'hermes dashboard --stop\n'
    '$kOfficialDashboardCommand';

/// Where the one-line Dashboard setup lives. `main` for now; the release tag
/// goes here, and only here, once it exists.
const String kHermesSetupRef = 'main';
const String _setupScriptBase =
    'https://raw.githubusercontent.com/xP3ta/hermes-setup/$kHermesSetupRef/'
    'hermes-dashboard-setup';

/// The line that installs Hermes if it is missing and sets the Dashboard up
/// (nothing of the user's is touched when Hermes is already there). Same
/// shape as the new-access line below, without its flag.
const String kDashboardSetupCommandUnix =
    'curl -fsSL $_setupScriptBase.sh | sh';
const String kDashboardSetupCommandWindows =
    '& ([scriptblock]::Create((irm $_setupScriptBase.ps1)))';

String dashboardSetupCommand(SetupHostSystem system) => switch (system) {
  SetupHostSystem.unix => kDashboardSetupCommandUnix,
  SetupHostSystem.windows => kDashboardSetupCommandWindows,
};

/// The line that gives the Dashboard a new access (a new generated password;
/// sessions opened with the old one end) from the computer where Hermes
/// lives. Linux and macOS share one; Windows runs the `.ps1` from PowerShell
/// as administrator.
const String kNewAccessCommandUnix =
    'curl -fsSL $_setupScriptBase.sh | sh -s -- --new-access';
const String kNewAccessCommandWindows =
    '& ([scriptblock]::Create((irm $_setupScriptBase.ps1))) -NewAccess';

String newAccessCommand(SetupHostSystem system) => switch (system) {
  SetupHostSystem.unix => kNewAccessCommandUnix,
  SetupHostSystem.windows => kNewAccessCommandWindows,
};
