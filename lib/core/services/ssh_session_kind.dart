// Tipo de sesión por perfil SSH (1.4.0, F1): shell normal (siempre, por
// defecto) o, solo si el usuario lo activa a mano, Herdr o tmux.
// Herdr y tmux mantienen los procesos vivos en el servidor aunque se corte la
// red; la app solo los lanza en el pty y se reengancha al reconectar. Todas
// las órdenes remotas son constantes: nada del usuario se interpola en ellas.
// La app NUNCA ejecuta un instalador: si falta el programa, solo lo explica.

/// tmux session the app creates or reattaches. Constant on purpose.
const String sshTmuxSessionName = 'hermes-console';

/// Typed into the pty to start (or reattach) Herdr. `herdr` reattaches to
/// the running server when there is one (`ctrl+b q` detaches).
const String sshHerdrLaunchCommand = 'herdr';

/// Typed into the pty to create the tmux session or reattach to it (`-A`).
/// With `-A`, `-D` detaches any other client first: after a drop the old,
/// dead client may still be attached and shrink the window to its size.
const String sshTmuxLaunchCommand =
    'tmux new-session -A -D -s $sshTmuxSessionName';

/// An `execute` channel runs a non-login, non-interactive shell, whose PATH
/// can miss `~/.local/bin` (where Herdr's installer puts it; Debian/Ubuntu
/// only add it from `~/.profile`). The terminal itself is a login shell, so
/// probes and reads run in the user's login shell to see the same PATH.
const String _loginShell = '"\${SHELL:-/bin/sh}" -lc ';

/// [command] run in the user's login shell (see [_loginShell]). Only for
/// constant commands or ids already validated: [command] must not contain a
/// single quote.
String sshInLoginShell(String command) {
  if (command.contains("'")) {
    throw ArgumentError.value(command, 'command', 'contains a single quote');
  }
  return "$_loginShell'$command'";
}

/// Run on a separate `execute` channel before launching; exit 0 = installed.
const String sshHerdrProbeCommand = "$_loginShell'command -v herdr'";
const String sshTmuxProbeCommand = "$_loginShell'command -v tmux'";

/// Second look when the login-shell probe finds nothing. A login, non-
/// interactive shell skips `~/.bashrc`, where some installers add Herdr's
/// folder to PATH, so `command -v` can miss a Herdr that is there. Constant,
/// POSIX `sh` whatever the user's shell is, and it only looks: it prints the
/// first executable it finds in the usual install folders.
const String sshHerdrFallbackProbeCommand =
    "/bin/sh -c '"
    'for p in "\$HOME/.local/bin/herdr" "\$HOME/.cargo/bin/herdr" '
    '/usr/local/bin/herdr /opt/homebrew/bin/herdr; do '
    '[ -x "\$p" ] && { echo "\$p"; exit 0; }; done; exit 1'
    "'";

const String sshHerdrRepoUrl = 'https://github.com/herdrdev/herdr';

/// Shown (never run) when Herdr is missing. Copied from the «install»
/// section of the herdrdev/herdr README (branch master, commit 5608de06,
/// 2026-10-23). Change it only after checking the README again.
const String sshHerdrInstallCommand =
    'curl -fsSL https://herdr.dev/install.sh | sh';

/// tmux has no single installer (it comes from each distro's package
/// manager), so the app only links to the official instructions.
const String sshTmuxInstallUrl = 'https://github.com/tmux/tmux/wiki/Installing';

/// What the terminal runs once the shell is open. Stored per SSH profile;
/// [shell] is the default and behaves exactly like before 1.4.0.
enum SshSessionKind {
  shell('shell'),
  herdr('herdr'),
  tmux('tmux');

  const SshSessionKind(this.id);

  /// Value stored with the SSH profile.
  final String id;

  static SshSessionKind fromId(String? v) =>
      values.firstWhere((k) => k.id == v, orElse: () => SshSessionKind.shell);

  /// What the profile stores. Herdr and tmux are saved under their own
  /// «explicit» marker: before 1.4.0's plain terminal, the value `herdr` or
  /// `tmux` could come from the old automatic detection, and it cannot be told
  /// from a choice, so those old values count as nothing (see [fromStored]).
  String get storedId => switch (this) {
    SshSessionKind.shell => 'shell',
    SshSessionKind.herdr => 'herdr-explicit',
    SshSessionKind.tmux => 'tmux-explicit',
  };

  /// The kind a profile stored. Only the explicit markers of [storedId] give
  /// Herdr or tmux; anything else, the old `herdr`/`tmux` included, is the
  /// plain shell. The terminal never runs a program the user did not pick.
  static SshSessionKind fromStored(String? v) => values.firstWhere(
    (k) => k != SshSessionKind.shell && k.storedId == v,
    orElse: () => SshSessionKind.shell,
  );

  /// Name shown to the user; null for the plain shell (localized copy).
  String? get programName => switch (this) {
    SshSessionKind.shell => null,
    SshSessionKind.herdr => 'Herdr',
    SshSessionKind.tmux => 'tmux',
  };

  /// `command -v …` probe; null for the plain shell.
  String? get probeCommand => switch (this) {
    SshSessionKind.shell => null,
    SshSessionKind.herdr => sshHerdrProbeCommand,
    SshSessionKind.tmux => sshTmuxProbeCommand,
  };

  /// Tried when [probeCommand] finds nothing; null when there is none.
  String? get fallbackProbeCommand => switch (this) {
    SshSessionKind.herdr => sshHerdrFallbackProbeCommand,
    _ => null,
  };

  /// Line typed into the pty once the probe succeeds; null for the shell.
  String? get launchCommand => switch (this) {
    SshSessionKind.shell => null,
    SshSessionKind.herdr => sshHerdrLaunchCommand,
    SshSessionKind.tmux => sshTmuxLaunchCommand,
  };

  /// Install command to show when the program is missing, if the project
  /// publishes one; otherwise the UI shows only [installUrl].
  String? get installCommand => switch (this) {
    SshSessionKind.herdr => sshHerdrInstallCommand,
    _ => null,
  };

  String? get installUrl => switch (this) {
    SshSessionKind.shell => null,
    SshSessionKind.herdr => sshHerdrRepoUrl,
    SshSessionKind.tmux => sshTmuxInstallUrl,
  };

  /// Herdr and tmux keep the remote processes alive across a dropped
  /// connection, so a reconnect reattaches instead of starting over.
  bool get survivesDisconnect => this != SshSessionKind.shell;
}
