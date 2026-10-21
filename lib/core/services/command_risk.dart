/// Heurística local de riesgo para comandos que el agente quiere ejecutar
/// (aprobaciones del agente). NO es un sandbox: solo ayuda al usuario a
/// decidir resaltando patrones peligrosos conocidos. La decisión final
/// siempre es del usuario.
///
/// IMPORTANTE: `low` habilita el auto-aprobado de solo lectura (ver
/// [ApprovalPolicyService.autoApproveReadOnly]). Por eso las listas de
/// medio/alto deben ser CONSERVADORAS: marcar de más como medio/alto solo
/// hace que se pida permiso (inocuo); marcar de menos como `low`
/// auto-aprobaría algo destructivo (peligroso). Ante la duda, sube el riesgo.
/// Los patrones cubren tanto shell plano como scripts de `execute_code`
/// (heredocs de Python/bash), donde el agente envuelve los comandos.
enum CommandRisk {
  low,
  medium,
  high;

  String get label => switch (this) {
    CommandRisk.low => 'riesgo bajo',
    CommandRisk.medium => 'riesgo medio',
    CommandRisk.high => 'riesgo alto',
  };
}

/// Patrones destructivos o irreversibles → riesgo alto.
const _highRiskPatterns = <String>[
  'rm -rf',
  'rm -fr',
  'rm -r',
  'mkfs',
  'dd ',
  ':(){',
  'shutdown',
  'reboot',
  'init 0',
  'init 6',
  '> /dev/',
  'chmod -r 777',
  'chmod 777 /',
  'chown -r',
  'curl', // curl|bash y descargas ejecutables
  'wget',
  'sudo',
  'doas',
  'iptables',
  'systemctl stop',
  'systemctl disable',
  'kill -9',
  'pkill',
  'killall',
  'truncate',
  'shred',
  'crontab -r',
  'git push --force',
  'git push -f',
  'drop table',
  'drop database',
  'delete from',
  // Apagado / reinicio del sistema (más variantes).
  'poweroff',
  'halt',
  'systemctl poweroff',
  'systemctl halt',
  'systemctl reboot',
  // Particionado / formateo / discos.
  'fdisk',
  'parted',
  'sgdisk',
  'wipefs',
  'mkswap',
  'blkdiscard',
  // Usuarios / privilegios / sudoers.
  'userdel',
  'usermod',
  'groupdel',
  'passwd ',
  'chpasswd',
  'visudo',
  // Firewall / red.
  'nft ',
  'ufw ',
  'firewall-cmd',
  // Borrado destructivo en scripts (Python / find).
  'rmtree',
  'os.remove',
  'os.unlink',
  'os.rmdir',
  '.unlink(',
  'send2trash',
  '-delete',
  '-exec rm',
  'git clean -f',
  // Escritura a rutas del sistema.
  '> /etc',
  '> /boot',
  'tee /etc',
  'tee /boot',
];

/// Cambios de estado relevantes pero recuperables → riesgo medio.
const _mediumRiskPatterns = <String>[
  'rm ',
  'mv ',
  'git push',
  'git reset --hard',
  'git checkout',
  'npm install',
  'npm i ',
  'pip install',
  'apt install',
  'apt-get install',
  'pacman -s',
  'docker',
  'systemctl restart',
  'systemctl start',
  'chmod',
  'chown',
  'tee ',
  '>>',
  '> ',
  'touch ',
  'mkdir',
  'cp ',
  'ln ',
  // Escritura de ficheros en scripts (Python). El modo de apertura no se
  // puede inferir por subcadena con fiabilidad, así que cualquier indicio de
  // escritura sube a medio (pide permiso) en vez de auto-aprobarse.
  ".write_text(",
  ".write_bytes(",
  'writelines',
  ",'w'",
  ',"w"',
  ", 'w'",
  ', "w"',
  "'wb'",
  '"wb"',
  ",'a'",
  ',"a"',
  "'ab'",
  "mode='w'",
  'mode="w"',
  "mode='a'",
  'systemctl reload',
  'git commit',
  'git add',
  'git rm',
  'git mv',
];

/// Evalúa el riesgo de un comando de shell. Coincidencia por subcadena en
/// minúsculas; el primer patrón de alto riesgo gana.
CommandRisk assessCommandRisk(String? command) {
  if (command == null || command.trim().isEmpty) return CommandRisk.low;
  final c = command.toLowerCase();
  for (final p in _highRiskPatterns) {
    if (c.contains(p)) return CommandRisk.high;
  }
  for (final p in _mediumRiskPatterns) {
    if (c.contains(p)) return CommandRisk.medium;
  }
  return CommandRisk.low;
}
