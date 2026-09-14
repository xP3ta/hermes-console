#!/usr/bin/env python3
"""Hermes Mobile Bridge — servidor mínimo y seguro (v1).

Expone SOLO acciones allowlisted que el Gateway no cubre por HTTP:
  - escribir SOUL / persona / memoria (con backup + diff + rollback)
  - instalar / quitar skills (owner/repo validado, sin shell libre)
  - capabilities / health / audit log

Principios (ver docs/BRIDGE_SECURITY_MODEL.md):
  - allowlist, nunca shell libre; subprocess con lista de args (sin shell=True)
  - escrituras confinadas bajo HERMES_HOME; nunca .env / secretos
  - token Bearer propio + scopes; modo read-only global
  - backup automático antes de escribir; rollback; audit log append-only
  - bind a interfaz privada; rehúsa 0.0.0.0 sin flag explícito
"""
import asyncio
import base64
import difflib
import hashlib
import hmac
import json
import os
import platform
import re
import secrets
import shutil
import subprocess
import sys
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from aiohttp import web

VERSION = "1.18.0"


def _default_hermes_home():
    """Ruta usada por los instaladores oficiales en cada plataforma."""
    if os.name == "nt":
        local_app_data = os.environ.get("LOCALAPPDATA", "").strip()
        if local_app_data:
            return Path(local_app_data) / "hermes"
    return Path.home() / ".hermes"


HERMES_HOME = Path(
    os.environ.get("BRIDGE_HERMES_HOME")
    or os.environ.get("HERMES_HOME")
    or _default_hermes_home()
).resolve()
BACKUP_DIR = HERMES_HOME / "backups" / "bridge"
AUDIT_LOG = HERMES_HOME / "logs" / "bridge_audit.log"
TOKEN_FILE = HERMES_HOME / "bridge_token"
MAX_WRITE_BYTES = 256 * 1024
MAX_SELF_UPDATE_BYTES = 512 * 1024
MAX_ATTACHMENT_BYTES = 8 * 1024 * 1024
MAX_ATTACHMENT_STORE_BYTES = 100 * 1024 * 1024
ATTACHMENT_MAX_AGE_SECONDS = 7 * 24 * 60 * 60
ATTACHMENTS_DIR = (HERMES_HOME / "uploads" / "mobile").resolve()
_ATTACHMENT_NAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,160}$")
_BLOCKED_ATTACHMENT_EXTS = {
    ".apk", ".exe", ".sh", ".bat", ".bin", ".so", ".dll", ".msi", ".deb",
}
# Ventana de contexto REAL que reserva Ollama (`model.ollama_num_ctx`). Hermes
# exige `model.context_length` >= 64000 o deja el chat mudo, pero ese gate es
# lógico: lo que de verdad reserva KV-cache al cargar es ollama_num_ctx, y 64K
# ahoga la carga en la CPU de un móvil (cuelga el primer turno). Mantenemos el
# gate alto y la ventana real modesta.
LOCAL_OLLAMA_NUM_CTX = 8192
# Identificador de skill instalable por `hermes skills install`: owner/repo o
# identificadores de varios segmentos del registro de Hermes (p.ej.
# official/security/1password, skills-sh/owner/repo/skill), opcionalmente con
# @skill. 2–5 segmentos. Sin shell libre (subprocess con lista de args).
SKILL_RE = re.compile(
    r"^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+){1,4}(@[A-Za-z0-9_.-]+)?$")
SKILL_NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
SKILL_QUERY_RE = re.compile(r"^[A-Za-z0-9 _.\-]{1,60}$")
# IDs/nombres de cron aceptados por el CLI. El primer carácter alfanumérico
# evita que un valor controlado por el cliente se interprete como una opción.
# Aunque create_subprocess_exec no usa shell, mantenemos una allowlist estricta.
CRON_JOB_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
# Nombre de perfil de agente: lista blanca estricta (coincide con la validación
# de la app). Sin punto para no permitir `..`; primer carácter alfanumérico.
PROFILE_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
BRIDGE_VERSION_RE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
BRIDGE_SOURCE_VERSION_RE = re.compile(
    r'''^VERSION\s*=\s*["']((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))["']\s*(?:#.*)?$''',
    re.MULTILINE,
)
BRIDGE_SCRIPT_PATH = Path(__file__).resolve()

# Directorios donde viven las skills instaladas en disco. Se usan SOLO para el
# borrado directo de skills NO hub-installed (el CLI rehúsa desinstalarlas). El
# borrado se confina bajo estas rutas y el nombre se valida con SKILL_NAME_RE
# (sin '/', sin '..'), así que no hay escape de directorio. Configurable por env.
SKILLS_DIRS = [
    Path(p).expanduser()
    for p in os.environ.get(
        "BRIDGE_SKILLS_DIRS",
        os.pathsep.join([
            str(HERMES_HOME / "skills"),
            str(HERMES_HOME / "skills" / "installed"),
        ]),
    ).split(os.pathsep)
    if p.strip()
]
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

# Allowlist de destinos: nombre lógico -> (ruta relativa, scope, modo).
#   modo "rw"          : leer y escribir (texto/markdown/JSON)
#   modo "ro"          : solo lectura, contenido tal cual
#   modo "ro_redacted" : solo lectura con valores secretos enmascarados
# Las rutas apuntan a los archivos REALES que usa el agente (no copias).
TARGETS = {
    "soul": ("SOUL.md", "soul", "rw"),
    "persona": ("agent-persona.md", "memory", "rw"),
    "memory": ("memories/MEMORY.md", "memory", "rw"),
    "user": ("memories/USER.md", "memory", "rw"),
    "cron": ("cron/jobs.json", "cron", "rw"),
    "config": ("config.yaml", "config", "ro_redacted"),
}

READ_ONLY = os.environ.get("BRIDGE_READ_ONLY", "false").lower() in {"1", "true", "yes"}
SCOPES = {s.strip() for s in os.environ.get(
    "BRIDGE_SCOPES", "read,skills,memory,soul,cron").split(",") if s.strip()}

# Claves cuyo valor se enmascara al leer un destino ro_redacted (config.yaml
# contiene API keys/tokens del agente: nunca se exponen en crudo).
_SECRET_KEY_RE = re.compile(
    r"^(\s*[\w.-]*(?:key|token|secret|password|passwd|credential|"
    r"auth|api|webhook|dsn|bearer)[\w.-]*\s*:\s*)(['\"]?)(?!\s*$)(.+?)\2\s*$",
    re.IGNORECASE)


def _redact_secrets(text):
    """Enmascara valores de claves sensibles (heurística por nombre de clave)."""
    out = []
    for line in text.splitlines(keepends=True):
        nl = "\n" if line.endswith("\n") else ""
        m = _SECRET_KEY_RE.match(line.rstrip("\n"))
        if m and m.group(3).strip() not in ("", "''", '""', "[]", "{}", "null"):
            out.append(f"{m.group(1)}'***redacted***'{nl}")
        else:
            out.append(line)
    return "".join(out)


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


def _load_token():
    env = os.environ.get("BRIDGE_TOKEN", "").strip()
    if env:
        return env
    if TOKEN_FILE.exists():
        return TOKEN_FILE.read_text().strip()
    tok = secrets.token_urlsafe(48)
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    TOKEN_FILE.write_text(tok)
    TOKEN_FILE.chmod(0o600)
    return tok


TOKEN = _load_token()
TOKEN_FP = "sha256:" + __import__("hashlib").sha256(TOKEN.encode()).hexdigest()[:12]


def _load_gateway_key():
    """API_SERVER_KEY del gateway (mismo servidor). Solo para autoprovisión:
    quien la presenta ya tiene control total del agente, así que entregarle el
    token del bridge no amplía privilegios. Nunca se expone por los endpoints
    de archivos (.env está prohibido)."""
    env = os.environ.get("API_SERVER_KEY", "").strip()
    if env:
        return env
    dotenv = HERMES_HOME / ".env"
    if dotenv.exists():
        for line in dotenv.read_text().splitlines():
            if line.startswith("API_SERVER_KEY="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    return None


GATEWAY_KEY = _load_gateway_key()
# Autoprovisión activable/desactivable (por defecto on si hay gateway key).
PROVISION_ENABLED = os.environ.get(
    "BRIDGE_PROVISION", "true").lower() in {"1", "true", "yes"} and bool(GATEWAY_KEY)


def _err(code, message, status=400):
    return web.json_response({"error": code, "message": message}, status=status)


def _audit(op, args, result, extra=None):
    AUDIT_LOG.parent.mkdir(parents=True, exist_ok=True)
    entry = {"ts": _now_iso(), "op": op, "args": args,
             "token_fp": TOKEN_FP, "result": result}
    if extra:
        entry.update(extra)
    with AUDIT_LOG.open("a") as f:
        f.write(json.dumps(entry) + "\n")


def _check_auth(request, scope):
    """None si OK; web.Response 401/403 si no."""
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer ") or not hmac.compare_digest(
            auth[7:].strip(), TOKEN):
        return _err("invalid_token", "Token inválido", 401)
    if scope and scope not in SCOPES and "read" != scope:
        return _err("missing_scope", f"El token no tiene el scope '{scope}'", 403)
    return None


def _version_tuple(value):
    if not isinstance(value, str) or not BRIDGE_VERSION_RE.fullmatch(value):
        raise ValueError("invalid version")
    return tuple(int(part) for part in value.split("."))


def _self_update_path_allowed():
    expected = HERMES_HOME / "hermes_bridge.py"
    # BRIDGE_SCRIPT_PATH ya está resuelto al importar el módulo, por lo que
    # comprobar is_symlink() sobre él no detectaría un enlace en la ruta
    # canónica. Validamos la entrada sin resolver antes de aceptar el swap.
    return not expected.is_symlink() and BRIDGE_SCRIPT_PATH == expected.resolve()


def _stage_self_update(body):
    """Valida, compila y sustituye el script; devuelve (target, backup, version)."""
    if not isinstance(body, dict) or set(body) != {
            "version", "sha256", "source_b64"}:
        raise ValueError("bad fields")
    version = body.get("version")
    expected_hash = body.get("sha256")
    encoded = body.get("source_b64")
    if (_version_tuple(version) <= _version_tuple(VERSION)
            or not isinstance(expected_hash, str)
            or not re.fullmatch(r"[a-f0-9]{64}", expected_hash)
            or not isinstance(encoded, str)):
        raise ValueError("bad metadata")
    try:
        payload = base64.b64decode(encoded, validate=True)
        source = payload.decode("utf-8", errors="strict")
    except Exception as ex:
        raise ValueError("bad payload") from ex
    if not payload or len(payload) > MAX_SELF_UPDATE_BYTES:
        raise ValueError("bad size")
    if not hmac.compare_digest(hashlib.sha256(payload).hexdigest(),
                               expected_hash):
        raise ValueError("bad hash")
    versions = BRIDGE_SOURCE_VERSION_RE.findall(source)
    if versions != [version]:
        raise ValueError("bad source version")
    try:
        compile(source, str(BRIDGE_SCRIPT_PATH), "exec")
    except SyntaxError as ex:
        raise ValueError("bad syntax") from ex
    if not _self_update_path_allowed() or not BRIDGE_SCRIPT_PATH.is_file():
        raise ValueError("unsupported path")

    target = BRIDGE_SCRIPT_PATH
    pending = target.with_name(target.name + ".new")
    backup = target.with_name(target.name + ".rollback")
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(str(pending), flags, 0o600)
        with os.fdopen(fd, "wb") as out:
            out.write(payload)
            out.flush()
            os.fsync(out.fileno())
        shutil.copy2(target, backup)
        backup.chmod(0o600)
        os.replace(pending, target)
        target.chmod(0o600)
    except Exception:
        try:
            pending.unlink(missing_ok=True)
        except Exception:
            pass
        raise
    return target, backup, version


_SYSTEMD_UNITS = {
    "bridge": "hermes-bridge",
    "dashboard": "hermes-dashboard",
}
_LAUNCHD_LABELS = {
    "bridge": "dev.xpetalab.hermes-console.bridge",
    "dashboard": "dev.xpetalab.hermes-console.dashboard",
}
_WINDOWS_RESTART_TASKS = {
    "bridge": "HermesConsole-Restart-MobileBridge",
    "dashboard": "HermesConsole-Restart-Dashboard",
}


def _managed_service_restart_command(name, delay_seconds=0.0):
    """Comando argv para reiniciar un servicio creado por nuestros setups.

    Nunca acepta nombres controlados por la petición. En Unix sin systemd el
    instalador puede proporcionar un helper confinado bajo HERMES_HOME.
    """
    if name not in _SYSTEMD_UNITS:
        return None

    helper = os.environ.get("BRIDGE_SERVICE_HELPER", "").strip()
    if helper:
        try:
            helper_entry = Path(helper)
            if helper_entry.is_symlink():
                raise ValueError("service helper must not be a symlink")
            helper_path = helper_entry.resolve()
            helper_path.relative_to(HERMES_HOME)
            if helper_path.is_file():
                return [str(helper_path), "restart", name]
        except (OSError, ValueError):
            pass

    if os.name == "nt":
        # Un task auxiliar separado detiene y vuelve a lanzar el servicio. Si
        # el propio task del Bridge ejecutase `/End`, Windows podría matar
        # también al helper antes del `/Run` por pertenecer al mismo job.
        return [
            "schtasks.exe", "/Run", "/TN", _WINDOWS_RESTART_TASKS[name]
        ]

    if sys.platform == "darwin":
        label = _LAUNCHD_LABELS[name]
        return ["launchctl", "kickstart", "-k", f"gui/{os.getuid()}/{label}"]

    return ["systemctl", "--user", "restart", _SYSTEMD_UNITS[name]]


def _detached_popen(args):
    kwargs = {
        "stdin": subprocess.DEVNULL,
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
        "close_fds": True,
    }
    if os.name == "nt":
        kwargs["creationflags"] = (
            getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
            | getattr(subprocess, "DETACHED_PROCESS", 0)
            | getattr(subprocess, "CREATE_NO_WINDOW", 0)
        )
    else:
        kwargs["start_new_session"] = True
    return subprocess.Popen(args, **kwargs)


_SELF_UPDATE_WATCHDOG = r'''
import json, os, subprocess, sys, time, urllib.request
target, backup, version, health, restart_json = sys.argv[1:6]
restart_command = json.loads(restart_json)
for _ in range(10):
    time.sleep(2)
    try:
        with urllib.request.urlopen(health, timeout=2) as response:
            data = json.loads(response.read(65536).decode("utf-8"))
        if data.get("status") == "ok" and data.get("version") == version:
            raise SystemExit(0)
    except Exception:
        pass
if os.path.isfile(backup):
    os.replace(backup, target)
    if restart_command:
        kwargs = dict(stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL, close_fds=True)
        if os.name == "nt":
            kwargs["creationflags"] = (
                getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
                | getattr(subprocess, "DETACHED_PROCESS", 0)
                | getattr(subprocess, "CREATE_NO_WINDOW", 0))
        else:
            kwargs["start_new_session"] = True
        subprocess.Popen(restart_command, **kwargs)
'''


def _self_update_health_url():
    host = os.environ.get("BRIDGE_HOST", "127.0.0.1").strip()
    if host in {"", "0.0.0.0", "::", "localhost"}:
        host = "127.0.0.1"
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    port = int(os.environ.get("BRIDGE_PORT", "9131"))
    return f"http://{host}:{port}/bridge/health"


def _launch_self_update_watchdog(target, backup, version):
    restart = _managed_service_restart_command("bridge", delay_seconds=0.5)
    _detached_popen(
        [sys.executable, "-c", _SELF_UPDATE_WATCHDOG, str(target),
         str(backup), version, _self_update_health_url(),
         json.dumps(restart or [])],
    )


async def _restart_managed_service(name, delay_seconds=0.0):
    command = _managed_service_restart_command(name, delay_seconds)
    if not command:
        return False
    try:
        if delay_seconds:
            await asyncio.sleep(delay_seconds)
        proc = await asyncio.create_subprocess_exec(
            *command,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        return await proc.wait() == 0
    except OSError:
        return False


async def _restart_bridge_service():
    await _restart_managed_service("bridge", delay_seconds=0.5)


_SELF_UPDATE_RESTART_TASK = None


def _path_is_below(path, root):
    try:
        path.relative_to(root)
        return path != root
    except (ValueError, OSError):
        return False


def _resolve_target(name):
    """(path, scope, mode, None) del destino allowlisted, o (None,None,None,err)."""
    entry = TARGETS.get(name)
    if not entry:
        return None, None, None, _err("unknown_target",
                                      f"Destino no permitido: {name}", 400)
    rel, scope, mode = entry
    path = (HERMES_HOME / rel).resolve()
    # Confinamiento: debe quedar bajo HERMES_HOME y no ser un secreto por nombre.
    if not _path_is_below(path, HERMES_HOME):
        return None, None, None, _err("path_escape",
                                      "Ruta fuera de HERMES_HOME", 400)
    if path.name in {".env", "bridge_token"} or "secret" in path.name.lower():
        return None, None, None, _err("forbidden_path", "Ruta protegida", 403)
    return path, scope, mode, None


def _unified_diff(old, new, label):
    return "".join(difflib.unified_diff(
        old.splitlines(keepends=True), new.splitlines(keepends=True),
        fromfile=f"a/{label}", tofile=f"b/{label}"))


# ── Handlers ─────────────────────────────────────────────────────────────

async def health(request):
    return web.json_response({
        "status": "ok", "version": VERSION, "read_only": READ_ONLY,
        "provision": PROVISION_ENABLED,
    })


async def capabilities(request):
    if (e := _check_auth(request, "read")):
        return e
    can_write = not READ_ONLY

    def can_write_target(scope):
        return can_write and scope in SCOPES

    # Destinos con su modo y si son escribibles con los scopes actuales.
    targets = {}
    write_targets = []
    for nm, (rel, scope, mode) in TARGETS.items():
        writable = mode == "rw" and can_write_target(scope)
        targets[nm] = {"mode": mode, "scope": scope, "writable": writable}
        if writable:
            write_targets.append(nm)
    return web.json_response({
        "object": "hermes.bridge.capabilities",
        "version": VERSION,
        "scopes": sorted(SCOPES),
        "read_only": READ_ONLY,
        "operations": {
            "file_read": "read" in SCOPES,
            "soul_write": can_write_target("soul"),
            "memory_write": can_write_target("memory"),
            "cron_write": can_write_target("cron"),
            "cron_delete": can_write_target("cron"),
            "fallback_write": can_write and "config" in SCOPES,
            "skills_install": can_write and "skills" in SCOPES,
            "skills_remove": can_write and "skills" in SCOPES,
            "skills_toggle": can_write and "skills" in SCOPES,
            "chat": "command" in SCOPES,
            # marcador de soporte de perfil en el chat (la app lo usa para
            # decidir aislamiento completo vs personalidad).
            "chat_profile": "command" in SCOPES,
            "logs_extended": True,
            "audit_read": True,
            "self_update": can_write and "config" in SCOPES
                           and _self_update_path_allowed(),
        },
        "targets": targets,
        "write_targets": write_targets,
        "backups": {"enabled": True},
    })


async def self_update(request):
    """Actualiza solo el script canónico del Bridge, con rollback vigilado."""
    if (e := _check_auth(request, "config")):
        return e
    if READ_ONLY:
        return _err("read_only", "El bridge está en modo solo lectura", 403)
    try:
        body = await request.json()
    except Exception:
        return _err("bad_json", "Cuerpo no es JSON válido")
    try:
        target, backup, version = _stage_self_update(body)
        _launch_self_update_watchdog(target, backup, version)
    except ValueError:
        return _err("invalid_release", "Release del bridge no válida", 400)
    except Exception as ex:
        _audit("self_update", {}, "error", {"detail": type(ex).__name__})
        return _err("self_update_failed", "No se pudo preparar la actualización", 500)

    _audit("self_update", {"version": version}, "accepted")
    global _SELF_UPDATE_RESTART_TASK
    _SELF_UPDATE_RESTART_TASK = asyncio.create_task(_restart_bridge_service())
    return web.json_response({
        "ok": True,
        "version": version,
        "restarting": True,
    }, status=202)


async def provision(request):
    """Entrega el token del bridge a quien presente la API key del gateway.

    Permite que la app, ya autenticada en la instancia (gateway), obtenga el
    token del bridge automáticamente sin que el usuario lo teclee. No amplía
    privilegios: la gateway key ya da control total del agente.
    """
    if not PROVISION_ENABLED:
        return _err("provision_disabled",
                    "Autoprovisión deshabilitada en el servidor", 403)
    auth = request.headers.get("Authorization", "")
    presented = auth[7:].strip() if auth.startswith("Bearer ") else ""
    if not presented or not hmac.compare_digest(presented, GATEWAY_KEY or ""):
        return _err("invalid_gateway_key", "Clave de gateway inválida", 401)
    _audit("provision", {}, "ok")
    return web.json_response({
        "ok": True, "token": TOKEN, "scopes": sorted(SCOPES),
    })


async def read_file(request):
    """Lee el contenido actual de un destino allowlisted (solo lectura).

    No modifica nada; reutiliza el confinamiento de rutas de _resolve_target
    (bajo HERMES_HOME, nunca .env/secretos). Permite que el cliente cargue el
    archivo real para editarlo, en vez de empezar de cero y sobrescribir.
    """
    if (e := _check_auth(request, "read")):
        return e
    name = request.match_info.get("target", "")
    path, scope, mode, err = _resolve_target(str(name))
    if err:
        return err
    if not path.exists():
        return web.json_response({
            "ok": True, "file": name, "path": str(path), "mode": mode,
            "exists": False, "content": "", "size": 0,
        })
    content = path.read_text()
    redacted = mode == "ro_redacted"
    if redacted:
        content = _redact_secrets(content)
    return web.json_response({
        "ok": True, "file": name, "path": str(path), "mode": mode,
        "writable": mode == "rw" and not READ_ONLY,
        "redacted": redacted,
        "exists": True, "content": content,
        "size": len(content.encode("utf-8")),
    })


async def write_file(request):
    try:
        body = await request.json()
    except Exception:
        return _err("bad_json", "Cuerpo no es JSON válido")
    name = str(body.get("file", ""))
    content = body.get("content")
    dry_run = bool(body.get("dry_run", False))

    path, scope, mode, err = _resolve_target(name)
    if err:
        return err
    if mode != "rw":
        return _err("not_writable",
                    f"El destino '{name}' es de solo lectura", 403)
    if (e := _check_auth(request, scope)):
        return e
    if not isinstance(content, str):
        return _err("bad_content", "'content' debe ser texto")
    if len(content.encode("utf-8")) > MAX_WRITE_BYTES:
        return _err("too_large", "Contenido supera 256 KB")
    # cron/jobs.json debe ser JSON válido para no corromper el scheduler.
    if path.suffix == ".json":
        try:
            json.loads(content)
        except Exception as ex:
            return _err("bad_json_content", f"JSON inválido: {ex}")
    if READ_ONLY and not dry_run:
        return _err("bridge_read_only", "El bridge está en modo solo lectura", 403)

    old = path.read_text() if path.exists() else ""
    diff = _unified_diff(old, content, path.name)

    if dry_run:
        return web.json_response({
            "ok": True, "dry_run": True, "file": name,
            "path": str(path), "diff": diff,
            "would_backup": path.exists(),
        })

    backup_id = None
    if path.exists():
        BACKUP_DIR.mkdir(parents=True, exist_ok=True)
        ts = time.strftime("%Y%m%d-%H%M%S")
        backup_id = f"{name}-{ts}"
        shutil.copy2(path, BACKUP_DIR / f"{backup_id}{path.suffix}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    _audit("write", {"file": name}, "ok", {"backup_id": backup_id})
    return web.json_response({
        "ok": True, "file": name, "path": str(path),
        "backup_id": backup_id, "diff": diff,
    })


async def rollback(request):
    if (e := _check_auth(request, "memory")):
        return e
    if READ_ONLY:
        return _err("bridge_read_only", "Modo solo lectura", 403)
    try:
        body = await request.json()
    except Exception:
        return _err("bad_json", "Cuerpo no es JSON válido")
    backup_id = str(body.get("backup_id", ""))
    if "/" in backup_id or ".." in backup_id:
        return _err("bad_backup_id", "backup_id inválido")
    # name-ts -> destino allowlisted
    name = backup_id.rsplit("-", 2)[0]
    path, _, _, err = _resolve_target(name)
    if err:
        return err
    matches = list(BACKUP_DIR.glob(f"{backup_id}*"))
    if not matches:
        return _err("backup_not_found", "Backup no encontrado", 404)
    shutil.copy2(matches[0], path)
    _audit("rollback", {"backup_id": backup_id}, "ok")
    return web.json_response({"ok": True, "restored": str(path)})


async def _run(args, timeout=120, stdin_text=None, env=None, max_out=8000):
    if env is None:
        # Las invocaciones del venv de Hermes necesitan LD_PRELOAD/LD_LIBRARY_PATH
        # (cryptography); el resto va con el entorno mínimo seguro.
        env = _hermes_env() if (args and str(args[0]) == _VENV_PY) else _safe_env()
    proc = await asyncio.create_subprocess_exec(
        *args,
        stdin=asyncio.subprocess.PIPE if stdin_text is not None else None,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
        cwd=str(HERMES_HOME), env=env)
    inp = stdin_text.encode() if stdin_text is not None else None
    try:
        out, _ = await asyncio.wait_for(proc.communicate(input=inp), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        return 124, "timeout"
    text = (out or b"").decode("utf-8", "replace")
    # max_out=None → salida COMPLETA: obligatorio cuando el stdout es un JSON
    # a parsear. El tail-truncado por defecto decapitaba el catálogo de
    # modelos en servidores con muchos proveedores (>8KB) y el parse moría
    # con "Expecting value: char 0" (visto en produccion con 42 proveedores).
    return proc.returncode, (text if max_out is None else text[-max_out:])


def _safe_env():
    keep = ["PATH", "HOME", "LANG", "LC_ALL", "HERMES_HOME"]
    if os.name == "nt":
        # Python, PowerShell, .cmd launchers y la resolución de DLLs necesitan
        # estas variables del entorno de Windows. No contienen credenciales.
        keep += [
            "Path", "PATHEXT", "SYSTEMROOT", "SystemRoot", "WINDIR",
            "COMSPEC", "TEMP", "TMP", "USERPROFILE", "LOCALAPPDATA",
            "APPDATA", "PROGRAMDATA", "HERMES_GIT_BASH_PATH",
        ]
    env = {k: os.environ[k] for k in keep if k in os.environ}
    # HERMES_HOME del bridge es autoritativo: el agente vive ahí y HOME es su
    # padre (layout de Hermes: HERMES_HOME = $HOME/.hermes). Lo forzamos para que
    # el CLI del venv encuentre el config aunque el bridge se lanzara sin HOME
    # (si no, `hermes config set` calcula `/.hermes`, read-only, y peta con
    # Errno 30). Coincide con el HOME que fija el despliegue real → sin regresión.
    env["HERMES_HOME"] = str(HERMES_HOME)
    env["HOME"] = (
        os.environ.get("USERPROFILE", str(Path.home()))
        if os.name == "nt"
        else str(HERMES_HOME.parent)
    )
    # npx necesita `node` en PATH: añade el Node embebido de Hermes.
    node_bin = HERMES_HOME / "node"
    if os.name != "nt":
        node_bin = node_bin / "bin"
    if node_bin.is_dir():
        current_path = env.get("PATH") or env.get("Path", "")
        env["PATH"] = f"{node_bin}{os.pathsep}{current_path}"
    return env


def _npx():
    candidates = (
        [HERMES_HOME / "node" / "npx.cmd", HERMES_HOME / "node" / "npx.exe"]
        if os.name == "nt"
        else [HERMES_HOME / "node" / "bin" / "npx"]
    )
    for cand in candidates:
        if cand.exists():
            return str(cand)
    return "npx.cmd" if os.name == "nt" else "npx"


def _venv_python():
    """Intérprete del venv de Hermes (es el que tiene `hermes_cli` instalado).

    OJO: el bridge suele arrancar bajo el python de Termux ($PREFIX/bin/python3),
    que NO tiene hermes_cli en su site-packages → `sys.executable -m hermes_cli`
    falla con ModuleNotFoundError y el chat local nunca ejecuta el agente
    (verificado en emulador: ésta era la causa real del silencio en local).
    Resolvemos SIEMPRE el python del venv explícitamente."""
    base = os.environ.get("BRIDGE_HERMES_HOME") or str(HERMES_HOME)
    root = Path(base) / "hermes-agent" / "venv"
    candidates = (
        [root / "Scripts" / "python.exe", root / "Scripts" / "python3.exe"]
        if os.name == "nt"
        else [root / "bin" / "python3", root / "bin" / "python"]
    )
    for cand in candidates:
        try:
            if cand.exists():
                return str(cand)
        except OSError:
            # El venv puede existir pero no ser accesible. Como esto corre al
            # importar el módulo, nunca debe impedir que el Bridge sirva.
            continue
    return sys.executable


_VENV_PY = _venv_python()


def _ensure_ruamel():
    """Asegura que ruamel.yaml sea importable desde el Python actual.

    Cuando el bridge corre bajo el Python de Termux (sin ruamel instalado),
    añade el site-packages del venv de Hermes a sys.path. Devuelve True si
    ruamel es importable tras el intento.
    """
    try:
        import ruamel.yaml  # noqa: F401
        return True
    except ImportError:
        pass
    base = os.environ.get("BRIDGE_HERMES_HOME") or str(HERMES_HOME)
    venv_root = Path(base) / "hermes-agent" / "venv"
    try:
        candidates = list((venv_root / "lib").glob("python3*/site-packages"))
        candidates.append(venv_root / "Lib" / "site-packages")
        for sp in sorted({p for p in candidates if p.is_dir()}):
            sp_str = str(sp)
            if sp_str not in sys.path:
                sys.path.insert(0, sp_str)
            try:
                import ruamel.yaml  # noqa: F401
                return True
            except Exception:
                if sp_str in sys.path:
                    sys.path.remove(sp_str)
    except OSError:
        pass
    return False


def _hermes_env():
    """Entorno para ejecutar el venv de Hermes desde el bridge.

    El venv comparte binario con el python de Termux, así que cryptography
    (`_rust.abi3.so`) no resuelve los símbolos de Python si no se precarga
    libpython; además necesita LD_LIBRARY_PATH/TMPDIR de Termux. Sin esto el
    oneshot peta al importar y el turno termina vacío."""
    env = _safe_env()
    is_termux = bool(os.environ.get("TERMUX_VERSION")) or "com.termux" in os.environ.get(
        "PREFIX", ""
    )
    if not is_termux:
        return env
    prefix = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
    libdir = Path(prefix) / "lib"
    env["LD_LIBRARY_PATH"] = str(libdir)
    for so in sorted(libdir.glob("libpython3.*.so"), reverse=True):
        env["LD_PRELOAD"] = str(so)  # libpython precargada para cryptography
        break
    env.setdefault("TMPDIR", str(Path(prefix) / "tmp"))
    env.setdefault("LANG", "en_US.UTF-8")
    env.setdefault("LC_ALL", "en_US.UTF-8")
    return env


def _hermes(profile=None):
    """CLI de Hermes con el python del VENV (no `sys.executable`: el bridge corre
    bajo el python de Termux, que no tiene hermes_cli). install/uninstall actúan
    así sobre las skills reales de Hermes. El `npx skills` antiguo NO toca el
    almacén de skills de Hermes (falso éxito).

    Si [profile] no es None, antepone `--profile <name>` (flag global del CLI que
    resuelve HERMES_HOME al home del perfil → aísla SOUL/skills/memoria/modelo).
    Las llamadas sin argumento se comportan igual que antes."""
    base = [_VENV_PY, "-m", "hermes_cli.main"]
    if profile:
        base = base + ["--profile", profile]
    return base


def _resolve_profile(body):
    """Nombre de perfil VALIDADO para `hermes --profile`, o None (→ default).

    Defensa en profundidad: lista blanca estricta + rechazo de path-traversal +
    confinamiento del home bajo HERMES_HOME/profiles + el home debe existir. Un
    perfil ausente/inválido degrada a default (None) en vez de fallar, para no
    romper el chat ni crear homes fantasma."""
    p = body.get("profile")
    if not p or not isinstance(p, str):
        return None
    p = p.strip()
    if not p or p == "default" or len(p) > 64:
        return None
    if ".." in p or "/" in p or "\\" in p:
        return None
    if not PROFILE_NAME_RE.match(p):
        return None
    try:
        base = (HERMES_HOME / "profiles").resolve()
        home = (HERMES_HOME / "profiles" / p).resolve()
        home.relative_to(base)  # ValueError si escapa del confinamiento
    except (ValueError, OSError):
        return None
    if not home.is_dir():
        return None  # perfil inexistente → default (no crear nada)
    return p


async def _ensure_ollama_running():
    """Arranca `ollama serve` si el puerto 11434 está caído.

    El chat local va por `hermes -z`, que necesita ollama escuchando. Android
    mata ollama por App Standby/OOM y nadie lo revive entre turnos → el oneshot
    no conecta y termina en SILENCIO (rc=0, sin texto). Verificado en emulador:
    ésta es la causa nº1 del «el agente no responde, sin error». Antes de cada
    turno con proveedor ollama/custom levantamos ollama si hace falta (nohup,
    con OLLAMA_MODELS + ~/.ollama creado) y esperamos hasta ~20s a que responda.

    Devuelve True si ollama quedó disponible, False si no se pudo arrancar.
    """
    if (await _ollama_tags()) is not None:
        return True
    prefix = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
    ollama = shutil.which("ollama") or str(Path(prefix) / "bin" / "ollama")
    if not Path(ollama).exists():
        return False  # ollama no instalado: no es nuestro trabajo instalarlo aquí
    home = Path.home()
    models = home / ".ollama" / "models"
    # mkdir antes del redirect: si ~/.ollama no existe, el log falla y serve no corre.
    models.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)  # hereda el entorno Termux del bridge (LD_LIBRARY_PATH…)
    env.pop("LD_PRELOAD", None)  # ollama es Go; no quiere la libpython precargada
    env.setdefault("OLLAMA_MODELS", str(models))
    # El chat es oneshot (`hermes -z` por mensaje). Sin esto, Ollama descarga el
    # modelo de memoria entre turnos y lo RECARGA en cada mensaje (30-45s en CPU
    # de móvil). -1 = mantener residente indefinidamente → carga una vez.
    env.setdefault("OLLAMA_KEEP_ALIVE", "-1")
    # Optimización del camino CPU (fallback sin GPU): flash-attention + caché KV
    # en q8_0 (mitad de memoria, más rápido) y una sola secuencia en paralelo
    # (en móvil no compensa repartir la CPU). setdefault: respeta overrides.
    env.setdefault("OLLAMA_FLASH_ATTENTION", "1")
    env.setdefault("OLLAMA_KV_CACHE_TYPE", "q8_0")
    env.setdefault("OLLAMA_NUM_PARALLEL", "1")
    try:
        log = open(home / ".ollama" / "serve.log", "ab")
        await asyncio.create_subprocess_exec(
            ollama, "serve", stdout=log, stderr=log,
            cwd=str(home), env=env, start_new_session=True)
    except Exception:
        return False
    for _ in range(20):  # esperar a que el puerto responda (hasta ~20s)
        await asyncio.sleep(1)
        if (await _ollama_tags()) is not None:
            return True
    return False


async def _ensure_ollama_context():
    """Hermes exige `context_length` >=64K o rechaza el turno (chat mudo): ese es
    el gate lógico y lo mantenemos alto. Pero `ollama_num_ctx` es lo que Ollama
    RESERVA de KV-cache al cargar, y 64K ahoga la carga en la CPU del móvil; lo
    fijamos modesto (LOCAL_OLLAMA_NUM_CTX). Idempotente: solo escribe si falta el
    gate, o si num_ctx quedó por encima del objetivo (corrige configs viejas de 64K)."""
    cfg = HERMES_HOME / "config.yaml"
    try:
        text = cfg.read_text() if cfg.exists() else ""
    except Exception:
        return
    is_ollama = any(s in text for s in (
        'provider: "custom"', "provider: custom",
        'provider: "ollama"', "provider: ollama"))
    if not is_ollama:
        return
    if "context_length" not in text:
        await _run(_hermes() + ["config", "set", "model.context_length", "65536"], timeout=60)
    m = re.search(r"ollama_num_ctx:\s*(\d+)", text)
    cur = int(m.group(1)) if m else None
    # OlliteRT (motor GPU, base_url :8000) NO es Ollama: no le bajemos el num_ctx,
    # porque Hermes lo usa como contexto de runtime y bloquearía el tool-use. Para
    # OlliteRT lo subimos al gate (>=64000); para Ollama real lo mantenemos modesto.
    is_ollitert = ":8000" in text
    if is_ollitert:
        if cur is None or cur < 64000:
            await _run(_hermes() + ["config", "set", "model.ollama_num_ctx", "65536"],
                       timeout=60)
        return
    if cur is None or cur > LOCAL_OLLAMA_NUM_CTX:
        await _run(_hermes() + ["config", "set", "model.ollama_num_ctx",
                                str(LOCAL_OLLAMA_NUM_CTX)], timeout=60)


def _build_chat_prompt(prompt, history):
    """Construye un prompt con el contexto de la conversación para `hermes -z`.
    El oneshot no recuerda turnos anteriores, así que se le da la conversación
    previa como transcript y se le pide responder SOLO al último mensaje.
    Se limita a los últimos ~12 turnos para acotar el tamaño."""
    turns = []
    for m in (history or [])[-12:]:
        if not isinstance(m, dict):
            continue
        role = (m.get("role") or "").lower()
        content = (m.get("content") or "").strip()
        if not content or role not in ("user", "assistant"):
            continue
        who = "Usuario" if role == "user" else "Asistente"
        turns.append(f"{who}: {content}")
    if not turns:
        return prompt
    transcript = "\n".join(turns)
    return (
        "Continúa esta conversación manteniendo el contexto. Responde únicamente "
        "al ÚLTIMO mensaje del usuario, de forma natural y sin repetir el "
        "historial.\n\n"
        f"{transcript}\n"
        f"Usuario: {prompt}\n"
        "Asistente:"
    )


def _gc_mobile_attachments(keep=None):
    """Cota el almacén de uploads del móvil por edad y tamaño total."""
    try:
        files = []
        now = time.time()
        for path in ATTACHMENTS_DIR.iterdir():
            if not path.is_file() or path.name.endswith(".part"):
                continue
            try:
                stat = path.stat()
                if path != keep and now - stat.st_mtime > ATTACHMENT_MAX_AGE_SECONDS:
                    path.unlink(missing_ok=True)
                else:
                    files.append((path, stat.st_mtime, stat.st_size))
            except OSError:
                pass
        files.sort(key=lambda item: item[1], reverse=True)
        total = 0
        for path, _, size in files:
            total += size
            if total > MAX_ATTACHMENT_STORE_BYTES and path != keep:
                try:
                    path.unlink(missing_ok=True)
                except OSError:
                    pass
    except OSError:
        pass


async def attachment_upload(request):
    """Recibe un adjunto binario por streaming y devuelve una ruta confinada.

    No usa base64 ni mantiene el archivo completo en RAM. La escritura es
    atómica y el almacén tiene GC por cuota/edad para que un cliente con cortes
    no llene el servidor con parciales o uploads abandonados.
    """
    if (e := _check_auth(request, "command")):
        return e
    if READ_ONLY:
        return _err("bridge_read_only", "Modo solo lectura", 403)
    name = (request.headers.get("X-Hermes-Filename") or "").strip()
    if (not _ATTACHMENT_NAME_RE.match(name) or ".." in name
            or Path(name).suffix.lower() in _BLOCKED_ATTACHMENT_EXTS):
        return _err("bad_attachment_name", "Nombre de adjunto no válido", 400)
    declared = request.content_length
    if declared is not None and (declared <= 0 or declared > MAX_ATTACHMENT_BYTES):
        return _err("attachment_too_large", "Adjunto vacío o demasiado grande", 413)

    ATTACHMENTS_DIR.mkdir(parents=True, exist_ok=True)
    unique = f"{time.time_ns()}_{secrets.token_hex(4)}_{name}"
    target = (ATTACHMENTS_DIR / unique).resolve()
    if not _path_is_below(target, ATTACHMENTS_DIR):
        return _err("bad_attachment_name", "Nombre de adjunto no válido", 400)
    partial = target.with_name(target.name + ".part")
    total = 0
    try:
        with partial.open("xb") as out:
            async for chunk in request.content.iter_chunked(64 * 1024):
                total += len(chunk)
                if total > MAX_ATTACHMENT_BYTES:
                    raise ValueError("too_large")
                out.write(chunk)
            out.flush()
            os.fsync(out.fileno())
        if total <= 0:
            raise ValueError("empty")
        os.replace(partial, target)
    except ValueError:
        partial.unlink(missing_ok=True)
        target.unlink(missing_ok=True)
        return _err("attachment_too_large", "Adjunto vacío o demasiado grande", 413)
    except (OSError, asyncio.CancelledError) as ex:
        partial.unlink(missing_ok=True)
        target.unlink(missing_ok=True)
        if isinstance(ex, asyncio.CancelledError):
            raise
        return _err("attachment_write_failed", "No se pudo guardar el adjunto", 500)

    _gc_mobile_attachments(keep=target)
    _audit("attachment_upload", {"name": name, "bytes": total}, "ok")
    return web.json_response({"ok": True, "path": str(target), "bytes": total})


async def chat(request):
    """Ejecuta un turno del agente en oneshot (`hermes -z <prompt>`) y devuelve
    la respuesta final. Carga modelo/tools/memoria/skills como el agente normal.
    Es el camino de chat para la instancia LOCAL (el agente local no expone la
    API HTTP `/v1/runs`; su chat nativo es por WebSocket). Scope: command.
    """
    if (e := _check_auth(request, "command")):
        return e
    try:
        body = await request.json()
    except Exception:
        return _err("bad_json", "Cuerpo JSON inválido")
    prompt = (body.get("prompt") or body.get("message") or "").strip()
    if not prompt:
        return _err("empty_prompt", "Falta el prompt")
    # Para proveedor ollama/custom: arranca ollama si está caído (causa nº1 del
    # silencio) y asegura el contexto >=64K (si no, el agente rechaza el turno).
    if (_config_model().get("provider") or "").lower() in ("custom", "ollama"):
        await _ensure_ollama_running()
    await _ensure_ollama_context()
    # `-z` (oneshot) NO mantiene estado de sesión entre invocaciones (cada una
    # crea una sesión nueva), así que el contexto se inyecta en el propio prompt
    # a partir del historial que manda la app (mismo principio que el run remoto
    # con `history`). Se acotan los turnos para no pasarse del prompt.
    history = body.get("history")
    history = history if isinstance(history, list) else []

    # Rama chat-local-simple: POST directo al modelo local, SIN tools, SIN agente.
    # Evita el bucle de tool-calling que deja vacío a los modelos pequeños.
    # Solo se activa con mode=simple explícito; el default (full) usa hermes -z.
    mode = (body.get("mode") or "").lower()
    if mode == "simple":
        try:
            mt = int(body.get("max_tokens") or 1024)
        except (TypeError, ValueError):
            mt = 1024
        res = await _chat_local_simple(prompt, history, max_tokens=mt)
        _audit("chat_simple", {"prompt_len": len(prompt)},
               "ok" if res.get("ok") else "empty")
        if res.get("ok"):
            return web.json_response({"ok": True, "response": res["content"]})
        return _err("chat_simple_failed", res.get("error") or "sin texto", 502)

    # ---- ruta agente completo (full) — sin cambios ----
    full = _build_chat_prompt(prompt, history)
    if len(full.encode()) > MAX_WRITE_BYTES:
        # Recorta el historial si es muy largo (deja el mensaje actual).
        full = _build_chat_prompt(prompt, [])
    try:
        timeout = int(body.get("timeout") or 300)
    except (TypeError, ValueError):
        timeout = 300
    # Perfil de agente (opcional): aísla el turno en el home del perfil vía
    # `hermes --profile`. None → comportamiento actual (home default).
    prof = _resolve_profile(body)
    # `-z` = oneshot: imprime SOLO el texto final (sin banner/spinner). El
    # prompt va como argumento (lista de args, sin shell).
    eff_timeout = min(max(timeout, 10), 600)
    rc, out = await _run(_hermes(prof) + ["-z", full], timeout=eff_timeout)
    out = _ANSI_RE.sub("", out or "").strip()
    _audit("chat", {"prompt_len": len(prompt), "profile": prof or "default"},
           "ok" if rc == 0 else f"rc={rc}")
    if rc != 0:
        return _err("chat_failed", out[-800:] or f"rc={rc}", 500)
    # rc==0 con salida vacía = el agente "terminó bien" pero no imprimió nada
    # (caso típico: config.yaml apunta a un modelo NO descargado en ollama, o
    # ollama cargado con <64K y el turno rechazado en silencio). Antes esto
    # dejaba la burbuja vacía y el usuario veía "el agente no dice nada, sin
    # error". Intentamos auto-reparar (repuntar config.yaml a un modelo ollama
    # descargado + contexto >=64K) y reintentar el turno una vez.
    if not out:
        healed = await _heal_local_model()
        if healed:
            rc2, out2 = await _run(
                _hermes(prof) + ["-z", full], timeout=eff_timeout)
            out2 = _ANSI_RE.sub("", out2 or "").strip()
            _audit("chat_retry", {"model": healed},
                   "ok" if (rc2 == 0 and out2) else f"rc={rc2}")
            if rc2 == 0 and out2:
                return web.json_response({"ok": True, "response": out2})
        return web.json_response(
            {"ok": True, "response": await _chat_empty_diag(healed=healed)})
    return web.json_response({"ok": True, "response": out})


# Secuencias de terminal a eliminar del stream (colores, movimientos de cursor,
# borrados, OSC y CR/BEL/BS sueltos). Por PIPE el agente imprime texto plano,
# pero limpiamos por si algún resto de control se cuela, para que el TTS y la
# burbuja reciban texto puro.
_TERM_RE = re.compile(
    r"\x1b\[[0-9;?]*[ -/]*[@-~]"           # CSI: colores, cursor, borrado…
    r"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"  # OSC … BEL/ST
    r"|\x1b[@-Z\\-_]"                      # escapes de 2 caracteres
    r"|[\r\x07\x08]"                       # CR, BEL, BS sueltos
)


# Helper que corre con el python del VENV (el que tiene hermes_cli). Construye el
# AIAgent igual que `hermes -z` (vía run_oneshot) PERO deja cableado el
# stream_delta_callback, que el oneshot apaga a propósito (run_agent llama a ese
# callback con cada delta de texto YA limpio —think-blocks y contexto depurados—).
# Así obtenemos streaming de tokens REAL y limpio del agente local, sin parsear
# terminal. Emite líneas JSON por un fd CRUDO (dup de stdout) porque run_oneshot
# redirige sys.stdout a devnull durante el turno; la respuesta final entera la
# captura en un StringIO y la manda como {"done","full"}. El prompt llega por
# stdin (sin problemas de longitud/escapado).
_STREAM_HELPER = r'''
import os, sys, json, io
_OUT = os.dup(1)  # stdout REAL antes de cualquier redirect de run_oneshot
def _emit(obj):
    try:
        os.write(_OUT, (json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8"))
    except Exception:
        pass
def _on_delta(text):
    if isinstance(text, str) and text:
        _emit({"delta": text})
prompt = sys.stdin.buffer.read().decode("utf-8", "replace")
try:
    import run_agent
    # stream_delta_callback como property que NO se puede anular: el oneshot hace
    # `agent.stream_delta_callback = None` adrede; lo ignoramos para mantener el
    # streaming encendido. Un callback real (si lo hubiera) se respeta.
    def _get(self):
        return self.__dict__.get("_sd_cb", _on_delta)
    def _set(self, v):
        self.__dict__["_sd_cb"] = _on_delta if v is None else v
    run_agent.AIAgent.stream_delta_callback = property(_get, _set)
    from hermes_cli.oneshot import run_oneshot
    sys.stdout = io.StringIO()  # captura la respuesta final que escribe run_oneshot
    rc = run_oneshot(prompt)
    final = ""
    try:
        final = sys.stdout.getvalue()
    except Exception:
        pass
    sys.stdout = sys.__stdout__
    _emit({"done": True, "rc": rc, "full": final})
except BaseException as exc:
    try:
        sys.stdout = sys.__stdout__
    except Exception:
        pass
    _emit({"error": str(exc)[-300:]})
'''


async def _stream_hermes_inproc(full, timeout):
    """Streaming REAL del agente local vía [[_STREAM_HELPER]]: lee líneas JSON
    ({"delta"} en vivo, {"done","full"} al cerrar) del helper corriendo con el
    python del venv. Si el helper no puede ejecutarse o el agente no emite NADA
    útil, lanza RuntimeError y el caller cae al PIPE `hermes -z` (sin regresión)."""
    proc = await asyncio.create_subprocess_exec(
        _VENV_PY, "-c", _STREAM_HELPER,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
        env=_hermes_env(), cwd=str(HERMES_HOME),
        start_new_session=True,
    )
    try:
        proc.stdin.write(full.encode("utf-8"))
        await proc.stdin.drain()
        proc.stdin.close()
    except Exception:
        pass
    acc = ""             # texto acumulado por deltas
    buf = b""            # buffer de líneas a medias
    saw_json = False     # ¿el helper llegó a emitir JSON? (si no, está roto)
    saw_error = None
    loop = asyncio.get_event_loop()
    deadline = loop.time() + timeout
    try:
        while True:
            remaining = deadline - loop.time()
            if remaining <= 0:
                raise asyncio.TimeoutError()
            chunk = await asyncio.wait_for(
                proc.stdout.read(65536), timeout=remaining)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line.decode("utf-8", "replace"))
                except Exception:
                    continue          # ruido de fd crudo: lo ignoramos
                if not isinstance(obj, dict):
                    continue
                saw_json = True
                if isinstance(obj.get("delta"), str) and obj["delta"]:
                    acc += obj["delta"]
                    yield obj["delta"], acc
                elif obj.get("done"):
                    final = obj.get("full")
                    if isinstance(final, str) and len(final) > len(acc):
                        # cubre el caso "no hubo streaming": la respuesta entera
                        # llega de una en full → la emitimos como último delta.
                        yield final[len(acc):], final
                        acc = final
                    return
                elif "error" in obj:
                    saw_error = str(obj.get("error"))
                    break
            if saw_error is not None:
                break
    finally:
        if proc.returncode is None:
            try:
                proc.kill()
            except ProcessLookupError:
                pass
        try:
            await asyncio.wait_for(proc.wait(), timeout=5)
        except asyncio.TimeoutError:
            pass
    if saw_error is not None:
        raise RuntimeError("inproc_error: " + saw_error)
    if not saw_json:
        raise RuntimeError("inproc_unavailable")


async def _stream_hermes(full, timeout, profile=None):
    """Corre `hermes -z <full>` por PIPE y va emitiendo (delta_limpio, acumulado).

    Si [profile] no es None, el turno se ejecuta aislado en el home del perfil
    (`hermes --profile <name>`).

    Por qué PIPE y NO PTY: bajo un PTY el agente cree que es una terminal
    interactiva y dibuja su TUI —spinner braille (⠹⠸⠼, suena a "puntos") y
    paneles de caja (│ ─, suena a "barras")— que se colaba en el texto y el TTS
    lo leía como basura. Con un PIPE, isatty()=False → el agente degrada a texto
    PLANO (sin chrome). Forzamos el vaciado con PYTHONUNBUFFERED/NO_COLOR/CI para
    no esperar al final: si el agente emite por líneas, transmitimos token a
    token; si es oneshot, llega al final SIN regresión y, sobre todo, LIMPIO.
    """
    import codecs
    env = _hermes_env()
    env["TERM"] = "dumb"            # sin colores/markdown rico
    env["NO_COLOR"] = "1"          # rich/colorama: desactiva estilos
    env["CI"] = "1"               # muchas libs desactivan spinners en CI
    env["PYTHONUNBUFFERED"] = "1"  # Python vacía stdout aunque sea un pipe
    env["PYTHONIOENCODING"] = "utf-8"
    env["COLUMNS"] = "200"
    proc = await asyncio.create_subprocess_exec(
        *(_hermes(profile) + ["-z", full]),
        stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
        env=env, start_new_session=True,
    )
    dec = codecs.getincrementaldecoder("utf-8")("replace")
    acc = ""    # texto decodificado crudo (puede traer escapes a medias)
    sent = ""   # texto YA limpio y emitido
    loop = asyncio.get_event_loop()
    deadline = loop.time() + timeout
    try:
        while True:
            remaining = deadline - loop.time()
            if remaining <= 0:
                raise asyncio.TimeoutError()
            # read(n) devuelve en cuanto hay ALGO (no espera a llenar n) → streaming.
            data = await asyncio.wait_for(
                proc.stdout.read(65536), timeout=remaining)
            if not data:            # EOF: el hijo cerró stdout
                break
            acc += dec.decode(data)
            # No emitas un escape ANSI partido: retén la cola desde el último ESC.
            hold = acc.rfind("\x1b")
            head = acc if hold == -1 else acc[:hold]
            cleaned = _TERM_RE.sub("", head)
            if len(cleaned) > len(sent):
                yield cleaned[len(sent):], cleaned
                sent = cleaned
    finally:
        if proc.returncode is None:
            try:
                proc.kill()
            except ProcessLookupError:
                pass
        try:
            await asyncio.wait_for(proc.wait(), timeout=5)
        except asyncio.TimeoutError:
            pass
    # Vuelco final: limpia TODO el acumulado (incluida la cola retenida tras un ESC).
    acc += dec.decode(b"", final=True)
    cleaned = _TERM_RE.sub("", acc)
    if len(cleaned) > len(sent):
        yield cleaned[len(sent):], cleaned


async def chat_stream(request):
    """Como `chat` pero TRANSMITE la respuesta token a token por SSE corriendo
    `hermes -z` por PIPE. Camino de chat FLUIDO para la instancia LOCAL: la app
    habla/pinta cada frase según se genera, sin esperar la respuesta entera. Scope:
    command. Eventos SSE: {"delta": str} por fragmento; {"done": true,"full": str}
    al cerrar; {"error": str} si falla. Degrada a 'todo al final' (limpio) si el
    agente bufferiza su salida.
    """
    if (e := _check_auth(request, "command")):
        return e
    try:
        body = await request.json()
    except Exception:
        return _err("bad_json", "Cuerpo JSON inválido")
    prompt = (body.get("prompt") or body.get("message") or "").strip()
    if not prompt:
        return _err("empty_prompt", "Falta el prompt")
    if (_config_model().get("provider") or "").lower() in ("custom", "ollama"):
        await _ensure_ollama_running()
    await _ensure_ollama_context()
    history = body.get("history")
    history = history if isinstance(history, list) else []

    # mode=simple: no streamear; devolver texto completo en JSON (sin tools).
    # Evita _STREAM_HELPER que arranca el agente con 16 tools → bucle → vacío.
    mode = (body.get("mode") or "").lower()
    if mode == "simple":
        try:
            mt = int(body.get("max_tokens") or 1024)
        except (TypeError, ValueError):
            mt = 1024
        res = await _chat_local_simple(prompt, history, max_tokens=mt)
        _audit("chat_stream_simple", {"prompt_len": len(prompt)},
               "ok" if res.get("ok") else "empty")
        if res.get("ok"):
            return web.json_response({"ok": True, "response": res["content"]})
        return _err("chat_simple_failed", res.get("error") or "sin texto", 502)

    # Perfil de agente (opcional): aísla el turno en el home del perfil. El
    # camino in-process NO puede aislar (HERMES_HOME se fija al importar
    # hermes_cli en el proceso del bridge), así que con perfil forzamos el
    # subprocess `hermes --profile`. None → comportamiento actual.
    prof = _resolve_profile(body)

    # ---- ruta agente completo (full) + streaming SSE — sin cambios ----
    full = _build_chat_prompt(prompt, history)
    if len(full.encode()) > MAX_WRITE_BYTES:
        full = _build_chat_prompt(prompt, [])
    try:
        timeout = int(body.get("timeout") or 300)
    except (TypeError, ValueError):
        timeout = 300
    eff_timeout = min(max(timeout, 10), 600)

    resp = web.StreamResponse(status=200, headers={
        "Content-Type": "text/event-stream; charset=utf-8",
        "Cache-Control": "no-cache",
        "X-Accel-Buffering": "no",
    })
    await resp.prepare(request)

    async def _send(obj):
        await resp.write(
            b"data: "
            + json.dumps(obj, ensure_ascii=False).encode("utf-8")
            + b"\n\n")

    text = ""
    status = "ok"
    try:
        # 1) Streaming REAL in-process (stream_delta_callback). 2) Si no arranca,
        # PIPE `hermes -z` (limpio pero al final). Sin doble emisión: solo caemos
        # al PIPE si el in-process no llegó a emitir NADA.
        got_any = False
        if prof:
            # Perfil activo: el aislamiento exige un proceso nuevo
            # (`hermes --profile`); el camino in-process comparte el HERMES_HOME
            # del bridge y no puede cambiarlo. Vamos directos al PIPE aislado.
            async for delta, accumulated in _stream_hermes(full, eff_timeout, prof):
                text = accumulated
                if delta:
                    await _send({"delta": delta})
        else:
            try:
                async for delta, accumulated in _stream_hermes_inproc(full, eff_timeout):
                    text = accumulated
                    got_any = True
                    if delta:
                        await _send({"delta": delta})
            except asyncio.TimeoutError:
                raise
            except Exception:
                if not got_any:
                    async for delta, accumulated in _stream_hermes(full, eff_timeout):
                        text = accumulated
                        if delta:
                            await _send({"delta": delta})
        if not text.strip():
            # Mismo auto-heal que /bridge/chat: rc=0 sin texto ⇒ reintenta una vez
            # (config.yaml a un modelo no descargado, contexto <64K, etc.).
            healed = await _heal_local_model()
            retry = ""
            if healed:
                rc2, out2 = await _run(
                    _hermes(prof) + ["-z", full], timeout=eff_timeout)
                retry = _ANSI_RE.sub("", out2 or "").strip()
            if retry:
                await _send({"delta": retry})
                text = retry
            else:
                diag = await _chat_empty_diag(healed=healed)
                await _send({"delta": diag})
                text = diag
                status = "empty"
        await _send({"done": True, "full": text})
    except asyncio.TimeoutError:
        status = "timeout"
        await _send({"error": "Tiempo agotado esperando al agente local.",
                     "full": text})
    except Exception as ex:
        status = "error"
        await _send({"error": str(ex)[-300:], "full": text})
    _audit("chat_stream", {"prompt_len": len(prompt)}, status)
    try:
        await resp.write_eof()
    except Exception:
        pass
    return resp


def _config_model():
    """Lee provider/default/base_url del bloque `model:` de config.yaml.

    OJO: NO usar un regex global. El config tiene MUCHAS otras claves `provider:`
    (auto/edge/local/'' en secciones de voz, embeddings, etc.) y, al recorrer
    todo el fichero, la última pisaba a la del modelo dejando provider='' → el
    gate de ollama no disparaba y `ollama serve` nunca se levantaba (verificado
    en emulador: ÉSTA era la causa de que el chat local siguiera mudo). Se acota
    al bloque `model:` de nivel 0: termina en la siguiente clave sin indentar."""
    cfg = HERMES_HOME / "config.yaml"
    out = {}
    try:
        in_model = False
        for line in cfg.read_text().splitlines():
            if re.match(r"^model:\s*$", line):
                in_model = True
                continue
            if in_model:
                if line and not line[0].isspace():
                    break  # nueva clave de nivel 0 → fin del bloque model:
                m = re.match(
                    r"\s+(provider|default|base_url|context_length"
                    r"|ollama_num_ctx):\s*(.+)", line)
                if m:
                    out[m.group(1)] = m.group(2).strip().strip("\"'")
    except Exception:
        pass
    return out


def _validated_http_url(value, *, loopback_only=False, allow_query=True):
    """Acepta únicamente destinos HTTP(S) explícitos y bien formados.

    `base_url` es configurable por el operador y debe poder apuntar a su modelo
    LAN/Tailscale, por eso HTTP sigue permitido. La allowlist de esquema evita
    que urllib interprete `file:`, `ftp:` u otros handlers locales.
    """
    raw = str(value or "").strip()
    if not raw or any(ord(char) < 0x20 for char in raw):
        raise ValueError("URL vacía o con caracteres de control")
    try:
        parsed = urllib.parse.urlsplit(raw)
        port = parsed.port
    except ValueError as ex:
        raise ValueError("URL o puerto no válidos") from ex
    scheme = parsed.scheme.lower()
    if scheme not in {"http", "https"}:
        raise ValueError("el esquema debe ser http o https")
    if not parsed.hostname:
        raise ValueError("falta el host")
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("no se permiten credenciales dentro de la URL")
    if port is not None and not 1 <= port <= 65535:
        raise ValueError("puerto fuera de rango")
    if parsed.fragment:
        raise ValueError("no se permiten fragmentos en la URL")
    if parsed.query and not allow_query:
        raise ValueError("base_url no admite parámetros de consulta")
    hostname = parsed.hostname.lower().rstrip(".")
    if loopback_only and hostname not in {"127.0.0.1", "::1", "localhost"}:
        raise ValueError("el destino debe ser loopback")
    return urllib.parse.urlunsplit(
        (scheme, parsed.netloc, parsed.path, parsed.query, "")
    )


class _ValidatedRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Aplica la misma política de URL a cada salto HTTP."""

    def __init__(self, *, loopback_only=False):
        super().__init__()
        self._loopback_only = loopback_only

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        _validated_http_url(newurl, loopback_only=self._loopback_only)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _urlopen_http(target, *, timeout, loopback_only=False):
    """Abre solo HTTP(S); punto único auditado para las sondas del Bridge."""
    raw = target.full_url if isinstance(target, urllib.request.Request) else target
    _validated_http_url(raw, loopback_only=loopback_only)
    opener = urllib.request.build_opener(
        _ValidatedRedirectHandler(loopback_only=loopback_only)
    )
    return opener.open(target, timeout=timeout)


def _normalize_base_url(base_url):
    """Garantiza exactamente un sufijo /v1 (evita base_url duplicada /v1/v1)."""
    u = (base_url or "").strip().rstrip("/")
    if not u:
        u = "http://127.0.0.1:8000/v1"  # fallback local OlliteRT
    u = _validated_http_url(u, allow_query=False)
    if not u.endswith("/v1"):
        u = u + "/v1"
    return u  # luego + "/chat/completions"


async def _ollama_tags():
    """Modelos descargados en ollama (:11434), o None si no responde."""
    def _get():
        try:
            with _urlopen_http(
                    "http://127.0.0.1:11434/api/tags", timeout=3,
                    loopback_only=True) as r:
                data = json.loads(r.read().decode())
                return [m.get("name", "") for m in data.get("models", [])]
        except Exception:
            return None
    return await asyncio.get_event_loop().run_in_executor(None, _get)


async def _ollitert_models():
    """IDs de modelos que OlliteRT sirve en :8000 (/v1/models), o None si el
    servidor no responde (app cerrada o «Start Server» sin pulsar)."""
    def _go():
        try:
            with _urlopen_http(
                    "http://127.0.0.1:8000/v1/models", timeout=3,
                    loopback_only=True) as r:
                data = json.loads(r.read().decode("utf-8", "replace"))
            return [str(m.get("id") or "") for m in (data.get("data") or [])
                    if isinstance(m, dict) and m.get("id")]
        except Exception:
            return None
    return await asyncio.get_event_loop().run_in_executor(None, _go)


async def _ollitert_chat_probe(model, timeout=30):
    """Pide a OlliteRT (:8000) una respuesta de chat MÍNIMA y directa (sin
    Hermes, sin tools, sin plantilla de agente) para localizar dónde se pierde
    el texto cuando `hermes -z` termina en vacío.

    Devuelve un dict:
      {"ok": True,  "content": "<texto>", "finish": "<finish_reason>"}  si el
          endpoint respondió (content puede venir vacío → problema del modelo /
          plantilla en OlliteRT).
      {"ok": False, "error": "<motivo>"}  si el endpoint falló (HTTP/red).
    """
    payload = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": "Responde solo: hola"}],
        "max_tokens": 32,
        "temperature": 0.0,
        "stream": False,
    }).encode("utf-8")

    def _go():
        endpoint = _validated_http_url(
            "http://127.0.0.1:8000/v1/chat/completions",
            loopback_only=True,
        )
        req = urllib.request.Request(
            endpoint,
            data=payload,
            headers={"Content-Type": "application/json",
                     "Authorization": "Bearer local"},
            method="POST")
        try:
            with _urlopen_http(req, timeout=timeout, loopback_only=True) as r:
                data = json.loads(r.read().decode("utf-8", "replace"))
        except urllib.error.HTTPError as e:
            body = ""
            try:
                body = e.read().decode("utf-8", "replace")[:300]
            except Exception:
                pass
            return {"ok": False, "error": f"HTTP {e.code}: {body or e.reason}"}
        except Exception as e:
            return {"ok": False, "error": f"{type(e).__name__}: {str(e)[:200]}"}
        choices = data.get("choices") or []
        if not choices or not isinstance(choices[0], dict):
            return {"ok": True, "content": "", "finish": "(sin choices)"}
        ch = choices[0]
        msg = ch.get("message") or {}
        content = ""
        if isinstance(msg, dict):
            c = msg.get("content")
            if isinstance(c, str):
                content = c
            elif isinstance(c, list):  # formato content-parts
                content = "".join(
                    p.get("text", "") for p in c
                    if isinstance(p, dict) and p.get("type") == "text")
        return {"ok": True, "content": content.strip(),
                "finish": str(ch.get("finish_reason") or "")}

    return await asyncio.get_event_loop().run_in_executor(None, _go)


async def _chat_local_simple(prompt, history, *, max_tokens=1024, timeout=120):
    """Chat OpenAI DIRECTO contra el modelo local (OlliteRT/Ollama), SIN tools,
    SIN plantilla de agente. Evita el bucle de tool-calling que deja vacío a los
    modelos pequeños. NO usa `hermes -z`. Solo instancias locales (mode=simple)."""
    cfg = _config_model()
    model = cfg.get("default") or ""
    url = _normalize_base_url(cfg.get("base_url")) + "/chat/completions"

    messages = [
        {"role": "system",
         "content": "Eres un asistente útil. Responde de forma breve y directa."}
    ]
    for turn in (history or []):
        role = turn.get("role")
        content = turn.get("content")
        if role in ("user", "assistant") and isinstance(content, str) and content:
            messages.append({"role": role, "content": content})
    messages.append({"role": "user", "content": prompt})

    payload = json.dumps({
        "model": model,
        "messages": messages,
        "stream": False,
        "max_tokens": int(max_tokens),
        "temperature": 0.3,
        # SIN "tools", SIN "tool_choice", SIN "response_format"
    }).encode("utf-8")

    def _go():
        req = urllib.request.Request(
            url, data=payload,
            headers={"Content-Type": "application/json",
                     "Authorization": "Bearer local"},
            method="POST")
        try:
            with _urlopen_http(req, timeout=timeout) as r:
                data = json.loads(r.read().decode("utf-8", "replace"))
        except urllib.error.HTTPError as e:
            body = ""
            try:
                body = e.read().decode("utf-8", "replace")[:300]
            except Exception:
                pass
            return {"ok": False, "error": f"HTTP {e.code}: {body or e.reason}"}
        except Exception as e:
            return {"ok": False, "error": f"{type(e).__name__}: {str(e)[:200]}"}
        choices = data.get("choices") or []
        if not choices or not isinstance(choices[0], dict):
            return {"ok": False, "error": "respuesta sin choices"}
        ch = choices[0]
        msg = ch.get("message") or {}
        if isinstance(msg, dict) and msg.get("tool_calls"):
            return {"ok": False,
                    "error": "el modelo intentó usar herramientas en modo simple "
                             "(modelo pequeño): usa un modelo más capaz o el modo agente."}
        content = ""
        c = msg.get("content") if isinstance(msg, dict) else None
        if isinstance(c, str):
            content = c
        elif isinstance(c, list):
            content = "".join(
                p.get("text", "") for p in c
                if isinstance(p, dict) and p.get("type") == "text")
        content = content.strip()
        if not content:
            return {"ok": False,
                    "error": "el modelo no devolvió texto (chat simple). "
                             "finish_reason=" + str(ch.get("finish_reason") or "")}
        return {"ok": True, "content": content}

    return await asyncio.get_event_loop().run_in_executor(None, _go)


async def _heal_local_model():
    """Auto-reparación cuando el oneshot termina sin texto.

    Caso más común en local: config.yaml apunta a un modelo que NO está
    descargado en ollama (el `qwen2.5:0.5b` por defecto de la instalación, o el
    dashboard `model/set` no persistió la selección), así que ollama no puede
    cargarlo y el agente termina en silencio. Si ollama está vivo y tiene algún
    modelo, repunta config.yaml (provider/base_url/default + contexto >=64K) al
    modelo descargado disponible —vía el propio `hermes config set`, sin
    sobrescribir el fichero— para que el chat reintente.

    Devuelve el modelo fijado si cambió algo, o None si no había nada que
    reparar (ollama caído/sin modelos, o la config ya era válida → el vacío es
    por otra causa).
    """
    cfg0 = _config_model()
    if ":8000" in (cfg0.get("base_url") or ""):
        # Motor GPU OlliteRT: el modelo lo sirve su app (:8000), no Ollama. No
        # repuntar la config a Ollama o sacaríamos al usuario del motor GPU.
        return None
    tags = await _ollama_tags()
    valid = [t for t in (tags or []) if t]
    if not valid:
        return None
    cfg = _config_model()
    mdl = cfg.get("default") or ""
    model_ok = mdl in valid
    prov_ok = (cfg.get("provider") or "").lower() in ("custom", "ollama")
    burl_ok = "11434" in (cfg.get("base_url") or "")
    if model_ok and prov_ok and burl_ok:
        return None  # config ya válida; el silencio es por otra causa
    pick = mdl if model_ok else valid[0]
    await _run(_hermes() + ["config", "set", "model.provider", "custom"],
               timeout=60)
    await _run(_hermes() + ["config", "set", "model.base_url",
                            "http://127.0.0.1:11434/v1"], timeout=60)
    await _run(_hermes() + ["config", "set", "model.default", pick], timeout=60)
    # ollama necesita >=64K o el agente rechaza el turno en silencio.
    await _run(_hermes() + ["config", "set", "model.context_length", "65536"],
               timeout=60)
    await _run(_hermes() + ["config", "set", "model.ollama_num_ctx", "65536"],
               timeout=60)
    return pick


async def _chat_empty_diag(healed=None):
    cfg = _config_model()
    prov = cfg.get("provider") or "(sin definir)"
    mdl = cfg.get("default") or "(sin definir)"
    burl = cfg.get("base_url") or "(sin definir)"
    lines = [
        "⚠️ El agente terminó sin generar texto (rc=0, salida vacía).",
        f"• config.yaml → provider={prov}, modelo={mdl}, base_url={burl}",
    ]
    # Motor GPU OlliteRT (:8000): el modelo lo sirve su app, NO Ollama. Diagnosticar
    # contra :8000 en vez de :11434 (mirar Ollama aquí solo confunde al usuario).
    if ":8000" in burl:
        served = await _ollitert_models()
        if served is None:
            lines.append(
                "• OlliteRT (:8000): NO responde. Abre la app OlliteRT y pulsa "
                "«Start Server» en el modelo — reiniciar el agente Hermes NO "
                "arranca OlliteRT.")
        else:
            listed = ", ".join(served) or "(ninguno)"
            lines.append(f"• OlliteRT (:8000): OK · {len(served)} modelo(s): {listed}")
            served_match = mdl != "(sin definir)" and any(
                mdl == s or mdl in s or s in mdl for s in served)
            if mdl != "(sin definir)" and not served_match:
                lines.append(
                    f"• ⚠️ «{mdl}» no lo está sirviendo OlliteRT ahora mismo. En la "
                    "app OlliteRT pulsa «Start Server» en ese modelo (o elige uno de "
                    "los servidos).")
            else:
                # OlliteRT sirve el modelo pero `hermes -z` salió vacío. ¿Se
                # pierde el texto en OlliteRT o en Hermes? Le pedimos una
                # respuesta directa al endpoint (sin Hermes ni tools) para saberlo.
                probe = await _ollitert_chat_probe(mdl)
                if not probe.get("ok"):
                    lines.append(
                        f"• ⚠️ La petición directa a OlliteRT falló: "
                        f"{probe.get('error')}. El servidor responde a /v1/models "
                        "pero NO a /v1/chat/completions: en OlliteRT pulsa «Start "
                        "Server» (estado «running») para ese modelo y reintenta.")
                elif probe.get("content"):
                    fin = probe.get("finish") or "?"
                    lines.append(
                        "• ✅ OlliteRT SÍ genera texto directamente "
                        f"(finish_reason={fin}). El vacío viene de Hermes, no del "
                        "modelo: lo más probable es el gate de tool-use (el modelo "
                        "pequeño emite una llamada de herramienta malformada o solo "
                        "razonamiento y no queda texto final).")
                    lines.append(
                        "• Acción: prueba con un modelo más capaz en OlliteRT, o "
                        "usa el modo «Solo lectura/Conservador» para limitar tools "
                        "en el turno de voz/chat local.")
                else:
                    fin = probe.get("finish") or "(vacío)"
                    lines.append(
                        "• ⚠️ OlliteRT acepta la petición pero devuelve contenido "
                        f"VACÍO (finish_reason={fin}). Es un problema del modelo en "
                        "OlliteRT (plantilla de chat de Gemma o servidor no del todo "
                        "«running»), no de Hermes: reinicia «Start Server» para ese "
                        "modelo o prueba otro modelo en OlliteRT.")
        return "\n".join(lines)
    tags = await _ollama_tags()
    if tags is None:
        lines.append("• Ollama (:11434): NO responde — arráncalo desde Modelos.")
    else:
        listed = ", ".join(t for t in tags if t) or "(ninguno)"
        lines.append(f"• Ollama (:11434): OK · {len(tags)} modelo(s): {listed}")
        if mdl != "(sin definir)" and mdl not in tags:
            lines.append(
                f"• ⚠️ El modelo activo «{mdl}» no está entre los descargados.")
    if healed:
        lines.append(
            f"• Reparé config.yaml al modelo «{healed}» y reintenté, pero "
            "siguió sin responder. El modelo puede ser demasiado pequeño o "
            "estar dañado: prueba con otro desde Modelos → Ollama.")
    elif prov == "(sin definir)" or mdl == "(sin definir)":
        lines.append(
            "• Acción: ve a Modelos → Ollama y pulsa «Usar» en un modelo "
            "descargado para fijarlo en config.yaml.")
    return "\n".join(lines)


async def _ollama_probe(model, num_ctx, timeout=45):
    """Pide a ollama (:11434) generar 1 token con [model] y [num_ctx], y lo
    cronometra. Sirve para distinguir un problema de CONFIG (modelo ausente,
    ollama caído) de un problema de RENDIMIENTO: la primera carga de un modelo
    con contexto 64K en un móvil modesto reserva un KV-cache enorme y puede
    tardar minutos o colgarse. Devuelve {ok, ms, error?}."""
    def _go():
        body = json.dumps({
            "model": model, "prompt": "hi", "stream": False,
            "options": {"num_predict": 1, "num_ctx": int(num_ctx)},
        }).encode()
        endpoint = _validated_http_url(
            "http://127.0.0.1:11434/api/generate",
            loopback_only=True,
        )
        req = urllib.request.Request(
            endpoint, data=body,
            headers={"Content-Type": "application/json"})
        t0 = time.monotonic()
        try:
            with _urlopen_http(req, timeout=timeout, loopback_only=True) as r:
                r.read()
            return {"ok": True, "ms": int((time.monotonic() - t0) * 1000)}
        except Exception as ex:
            return {"ok": False, "ms": int((time.monotonic() - t0) * 1000),
                    "error": f"{type(ex).__name__}: {str(ex)[:200]}"}
    return await asyncio.get_event_loop().run_in_executor(None, _go)


async def diag_local(request):
    """Diagnóstico de extremo a extremo del agente LOCAL, ejecutado EN el
    dispositivo. Convierte el típico "spinner infinito sin error" en datos
    concretos del móvil del usuario: versión del bridge, modelo en config.yaml,
    si ollama responde y qué modelos tiene, y dos SONDAS de carga cronometradas
    (contexto 64K real vs 4K reducido) que localizan la causa:
      · ollama no responde      → no instalado / no arrancado
      · modelo no está en tags   → no descargado
      · 64K cuelga pero 4K rápido→ el contexto 64K ahoga este dispositivo
      · ambas rápidas            → el modelo carga bien (mirar la app/red)
    Scope: read (sin efectos secundarios, no escribe config)."""
    if (e := _check_auth(request, "read")):
        return e
    cfg = _config_model()
    prov = (cfg.get("provider") or "").lower()
    mdl = cfg.get("default") or ""
    burl = cfg.get("base_url") or ""
    tags = await _ollama_tags()
    is_local = prov in ("custom", "ollama")

    probe_big = probe_small = None
    if is_local and mdl and tags is not None:
        if mdl in tags:
            probe_big = await _ollama_probe(mdl, 65536, timeout=45)
            # Solo merece la pena la 2ª sonda si la 1ª fue lenta o falló: revela
            # si el modelo en sí carga bien con una ventana pequeña.
            if not probe_big.get("ok") or probe_big.get("ms", 0) > 8000:
                probe_small = await _ollama_probe(mdl, 4096, timeout=45)

    lines = [f"Bridge v{VERSION}"]
    lines.append(
        f"• config.yaml → provider={prov or '(sin definir)'}, "
        f"modelo={mdl or '(sin definir)'}, base_url={burl or '(sin definir)'}")
    if not is_local:
        lines.append(
            "• El proveedor activo no es local (ollama/custom). Para chat local "
            "ve a Modelos → Ollama y pulsa «Usar» en un modelo descargado.")
    if tags is None:
        lines.append(
            "• Ollama (:11434): NO responde → no está instalado o no arrancó. "
            "Instálalo/arráncalo desde Modelos → Ollama.")
    else:
        listed = ", ".join(t for t in tags if t) or "(ninguno)"
        lines.append(f"• Ollama (:11434): OK · {len(tags)} modelo(s): {listed}")
        if is_local and mdl and mdl not in tags:
            lines.append(
                f"• ⚠️ El modelo activo «{mdl}» NO está descargado. "
                "Descárgalo o elige otro de la lista.")
    if probe_big is not None:
        if probe_big.get("ok"):
            secs = probe_big["ms"] / 1000
            tag = "OK" if probe_big["ms"] <= 8000 else "LENTO"
            lines.append(
                f"• Sonda carga (contexto 64K): {tag} · {secs:.1f}s")
        else:
            lines.append(
                f"• Sonda carga (contexto 64K): FALLÓ tras "
                f"{probe_big['ms']/1000:.1f}s · {probe_big.get('error', '')}")
    if probe_small is not None:
        if probe_small.get("ok"):
            secs = probe_small["ms"] / 1000
            lines.append(
                f"• Sonda carga (contexto 4K): OK · {secs:.1f}s → el modelo "
                "carga bien; el contexto 64K es lo que ahoga este dispositivo.")
        else:
            lines.append(
                f"• Sonda carga (contexto 4K): FALLÓ tras "
                f"{probe_small['ms']/1000:.1f}s · {probe_small.get('error', '')}")
    # Veredicto accionable.
    verdict = _diag_verdict(is_local, mdl, tags, probe_big, probe_small)
    if verdict:
        lines.append("")
        lines.append(f"➤ {verdict}")

    return web.json_response({
        "ok": True,
        "version": VERSION,
        "config": {"provider": prov, "model": mdl, "base_url": burl},
        "ollama_up": tags is not None,
        "ollama_tags": tags or [],
        "probe_64k": probe_big,
        "probe_4k": probe_small,
        "summary": "\n".join(lines),
    })


def _diag_verdict(is_local, mdl, tags, big, small):
    if not is_local:
        return "Activa un modelo local en Modelos → Ollama («Usar»)."
    if tags is None:
        return "Ollama no está disponible: instálalo/arráncalo desde Modelos."
    if mdl and mdl not in tags:
        return f"Descarga el modelo «{mdl}» o elige uno ya descargado."
    if big is not None and not big.get("ok"):
        if small is not None and small.get("ok"):
            return ("El modelo carga con contexto pequeño pero NO con 64K: tu "
                    "dispositivo va justo de memoria. Conviene bajar el contexto "
                    "de ollama para este móvil.")
        return ("El modelo no carga ni con contexto pequeño: prueba con otro "
                "modelo más ligero desde Modelos → Ollama.")
    if big is not None and big.get("ok") and big.get("ms", 0) > 8000:
        return ("El modelo carga pero LENTO con 64K (primera vez). Tras la "
                "primera carga el chat debería ir más fluido; si sigue colgando, "
                "baja el contexto de ollama.")
    if big is not None and big.get("ok"):
        return ("El modelo carga bien en este dispositivo. Si el chat no "
                "responde, el problema está en la app o el enlace, no en ollama.")
    return None


def _full_env():
    """Entorno COMPLETO del proceso (PATH, LD_LIBRARY_PATH, VK_ICD_FILENAMES…).
    Necesario para que llama.cpp encuentre libvulkan y el driver de la GPU:
    `_safe_env()` recorta esas variables, así que NO sirve para binarios Vulkan."""
    e = dict(os.environ)
    prefix = e.get("PREFIX", "/data/data/com.termux/files/usr")
    binp = f"{prefix}/bin"
    if binp not in e.get("PATH", ""):
        e["PATH"] = f"{binp}:" + e.get("PATH", "")
    return e


def _which_llamacpp():
    """Localiza un binario de llama.cpp en Termux. Devuelve (nombre, ruta) o
    (None, None). Prefiere llama-bench (no interactivo) para medir tok/s."""
    prefix = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
    for name in ("llama-bench", "llama-cli", "llama"):
        p = shutil.which(name)
        if not p:
            cand = Path(prefix) / "bin" / name
            p = str(cand) if cand.exists() else None
        if p:
            return name, p
    return None, None


def _ollama_gguf_path(model):
    """Localiza el .gguf que Ollama YA descargó para [model] leyendo su manifest,
    para no descargar otra vez en el benchmark. Si falla, cae al blob más grande
    (que suele ser el modelo). Devuelve un Path o None."""
    models_dir = Path(os.environ.get(
        "OLLAMA_MODELS", str(Path.home() / ".ollama" / "models")))
    if model:
        name, _, tag = model.partition(":")
        tag = tag or "latest"
        manifests = models_dir / "manifests"
        if manifests.is_dir():
            for mani in manifests.rglob(tag):
                if not (mani.is_file() and mani.parent.name == name):
                    continue
                try:
                    data = json.loads(mani.read_text())
                except Exception:
                    continue
                for layer in data.get("layers", []):
                    if str(layer.get("mediaType", "")).endswith(".model"):
                        digest = str(layer.get("digest", "")).replace(":", "-")
                        blob = models_dir / "blobs" / digest
                        if blob.exists():
                            return blob
    blobs = models_dir / "blobs"
    if blobs.is_dir():
        cands = [(b.stat().st_size, b)
                 for b in blobs.glob("sha256-*") if b.is_file()]
        if cands:
            return max(cands, key=lambda t: t[0])[1]
    return None


def _parse_llamacpp(out):
    """Extrae métricas de la salida (cruda) de llama.cpp: capas a GPU, dispositivos
    Vulkan y tok/s. Tolerante: la build del paquete puede variar el formato."""
    out = out or ""
    res = {}
    m = re.search(r"offloaded\s+(\d+)\s*/\s*(\d+)\s+layers?", out)
    if m:
        res["gpu_layers"], res["total_layers"] = int(m.group(1)), int(m.group(2))
    m = re.search(r"Found\s+(\d+)\s+Vulkan device", out)
    if m:
        res["vulkan_devices"] = int(m.group(1))
    # Dos formatos: llama-cli imprime "X tokens per second" (la unidad pegada al
    # número), mientras que la tabla de llama-bench pone el valor como "X ± Y" y
    # la unidad (t/s) solo en la cabecera de columna. Capturamos ambos.
    raw_ts = re.findall(
        r"([\d.]+)\s*(?:tokens per second|tokens/s|tg/s|t/s)", out)
    raw_ts += re.findall(r"([\d.]+)\s*±\s*[\d.]+", out)
    vals = []
    for x in raw_ts:
        try:
            vals.append(float(x))
        except ValueError:
            pass
    if vals:
        res["tok_s"] = max(vals)
    return res


async def _llamacpp_bench(tool, binary, gguf, ngl, timeout=180):
    """Corre una generación corta con [ngl] capas a GPU y devuelve (rc, salida)."""
    if "bench" in tool:
        args = [binary, "-m", str(gguf), "-ngl", str(ngl),
                "-p", "16", "-n", "16", "-r", "1"]
        stdin_text = None
    else:
        # llama-cli: cerrar stdin (input vacío) para que NO entre en modo
        # interactivo y se cuelgue esperando teclado.
        args = [binary, "-m", str(gguf), "-ngl", str(ngl),
                "-p", "Hola", "-n", "16", "-no-cnv"]
        stdin_text = ""
    return await _run(args, timeout=timeout, env=_full_env(), stdin_text=stdin_text)


def _llamacpp_verdict(has_vulkan, g, c):
    gl, tl = g.get("gpu_layers"), g.get("total_layers")
    gt, ct = g.get("tok_s"), c.get("tok_s")
    if gl is not None and tl and gl >= tl and gl > 0:
        speed = (f" ({gt:.1f} tok/s GPU vs {ct:.1f} CPU)"
                 if gt and ct else "")
        return ("✅ La GPU ENTRA: llama.cpp descargó todas las capas a la GPU"
                f"{speed}. Merece la pena migrar el motor local a llama.cpp.")
    if gl == 0:
        return ("❌ La GPU NO entra (0 capas): el driver Vulkan de este móvil no "
                "coopera con llama.cpp. Opciones: quedarse en CPU (llama.cpp es "
                "algo más ligero que Ollama) o explorar MLC LLM.")
    if not has_vulkan:
        return ("⚠️ Sin dispositivo Vulkan: la build de llama.cpp es solo-CPU o "
                "falta el driver de la GPU. No hay aceleración por esta vía.")
    return ("Resultado ambiguo: copia la salida cruda para ver cuántas capas "
            "ofreció a la GPU y a qué velocidad.")


async def diag_llamacpp(request):
    """Benchmark on-device de llama.cpp con GPU (Vulkan) vs CPU, para decidir con
    DATOS si migrar el motor local desde Ollama (solo-CPU). Detecta/instala
    llama.cpp, comprueba si hay dispositivo Vulkan y corre una generación corta
    con -ngl 99 (GPU) y -ngl 0 (CPU) sobre el .gguf que Ollama ya descargó,
    reportando capas a GPU y tok/s. Scope: command (instala paquete + ejecuta)."""
    if (e := _check_auth(request, "command")):
        return e
    do_install = request.query.get("install", "1") not in ("0", "false", "no")
    lines = [f"Bridge v{VERSION}",
             "Benchmark llama.cpp — ¿tu GPU acelera el modelo local?"]
    tool, binary = _which_llamacpp()
    if binary is None and do_install:
        lines.append("• llama.cpp no estaba instalado → instalando "
                     "(pkg install llama-cpp)…")
        await _run(["pkg", "install", "-y", "llama-cpp"],
                   timeout=300, env=_full_env())
        tool, binary = _which_llamacpp()
    if binary is None:
        lines.append("• No pude instalar/encontrar llama.cpp. Instálalo a mano "
                     "en Termux: pkg install llama-cpp")
        return web.json_response({"ok": False, "installed": False,
                                  "summary": "\n".join(lines)})
    lines.append(f"• Binario: {tool}")
    _, devs = await _run([binary, "--list-devices"], timeout=30, env=_full_env())
    has_vulkan = bool(re.search(r"vulkan|mali|adreno|turnip", devs or "", re.I))
    if has_vulkan:
        dev_line = next((l for l in (devs or "").splitlines()
                         if re.search(r"vulkan|mali|adreno|turnip", l, re.I)), "")
        lines.append(f"• GPU/Vulkan: detectada · {dev_line.strip()[:90]}")
    else:
        lines.append("• GPU/Vulkan: NO detectada (build solo-CPU o sin driver)")
    mdl = _config_model().get("default") or ""
    gguf = _ollama_gguf_path(mdl)
    if gguf is None:
        lines.append("• No encuentro un .gguf descargado. Descarga un modelo en "
                     "Modelos → Ollama y repite el benchmark.")
        return web.json_response({"ok": False, "installed": True,
                                  "has_vulkan": has_vulkan,
                                  "summary": "\n".join(lines)})
    size_mb = gguf.stat().st_size // (1024 * 1024)
    lines.append(f"• Modelo de prueba: {mdl or gguf.name} ({size_mb} MB)")
    _, out_g = await _llamacpp_bench(tool, binary, gguf, 99)
    g = _parse_llamacpp(out_g)
    _, out_c = await _llamacpp_bench(tool, binary, gguf, 0)
    c = _parse_llamacpp(out_c)
    if "gpu_layers" in g:
        extra = f" · {g['tok_s']:.1f} tok/s" if "tok_s" in g else ""
        lines.append(f"• GPU (-ngl 99): {g['gpu_layers']}/"
                     f"{g.get('total_layers', '?')} capas a GPU{extra}")
    elif "tok_s" in g:
        lines.append(f"• GPU (-ngl 99): {g['tok_s']:.1f} tok/s "
                     "(capas no reportadas)")
    else:
        lines.append("• GPU (-ngl 99): sin métricas (ver salida cruda)")
    lines.append(f"• CPU (-ngl 0): {c['tok_s']:.1f} tok/s"
                 if "tok_s" in c else "• CPU (-ngl 0): sin métricas (ver cruda)")
    lines.append("")
    lines.append(f"➤ {_llamacpp_verdict(has_vulkan, g, c)}")
    raw = ("--- salida GPU (cola) ---\n" + (out_g or "")[-1500:] +
           "\n\n--- salida CPU (cola) ---\n" + (out_c or "")[-1500:])
    return web.json_response({
        "ok": True, "installed": True, "tool": tool, "has_vulkan": has_vulkan,
        "gpu": g, "cpu": c, "summary": "\n".join(lines), "raw": raw,
    })


def _parse_clinfo(out):
    """Nº de plataformas OpenCL y nombre del dispositivo de la salida de clinfo."""
    out = out or ""
    res = {}
    m = re.search(r"Number of platforms\s+(\d+)", out)
    if m:
        res["platforms"] = int(m.group(1))
    m = re.search(r"Device Name\s+(.+)", out)
    if m:
        res["device"] = m.group(1).strip()
    # `clinfo -l` (formato corto) lista "Platform #0: ARM Platform"
    if "platforms" not in res:
        res["platforms"] = len(re.findall(r"Platform\s+#\d+", out))
    return res


def _parse_vulkaninfo(out):
    """Nombre de GPU de vulkaninfo, e indicador de que hay una GPU real (no CPU)."""
    out = out or ""
    res = {}
    m = re.search(r"deviceName\s*=\s*(.+)", out)
    if m:
        res["device"] = m.group(1).strip()
    res["has_gpu"] = bool(
        re.search(r"mali|adreno|turnip|powervr|PHYSICAL_DEVICE_TYPE_INTEGRATED",
                  out, re.I))
    return res


def _gpu_verdict(opencl_ok, vulkan_ok):
    if opencl_ok:
        return ("La GPU es ALCANZABLE por OpenCL → la vía es el motor más ligero "
                "que la use: llama.cpp compilado con OpenCL. NO hace falta MLC "
                "(que ni siquiera corre como servidor en Termux).")
    if vulkan_ok:
        return ("La GPU es ALCANZABLE por Vulkan (no OpenCL) → la vía es "
                "llama.cpp compilado con Vulkan + benchmark real de capas.")
    return ("Android NO deja ver la GPU a Termux por ninguna vía (ni OpenCL ni "
            "Vulkan): el cargador bloquea el driver del vendor por namespace. "
            "Ningún motor (MLC, llama.cpp) puede acelerar por GPU aquí sin una "
            "app NATIVA aparte (NDK). Recomendación: CPU optimizado (ya hecho) o "
            "una app nativa como proyecto separado.")


def _termux_which(name, env=None):
    """Resuelve un binario de Termux a ruta ABSOLUTA, o None.

    `shutil.which` mira `os.environ['PATH']`, que bajo el python del SISTEMA
    (con el que corre el bridge) puede NO incluir `$PREFIX/bin` → devolvía None
    aunque el binario exista, y luego `create_subprocess_exec(['clinfo'…])`
    lanzaba FileNotFoundError → HTTP 500. Aquí buscamos también en el PATH del
    `env` dado y en `$PREFIX/bin`, y devolvemos la ruta absoluta para no depender
    de la resolución por PATH del hijo."""
    hit = shutil.which(name)
    if hit:
        return hit
    paths = []
    if env and env.get("PATH"):
        paths += env["PATH"].split(os.pathsep)
    prefix = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
    paths.append(str(Path(prefix) / "bin"))
    for d in paths:
        try:
            cand = Path(d) / name
            if cand.exists():
                return str(cand)
        except Exception:
            pass
    return None


async def diag_gpu(request):
    """Sonda de ALCANCE de la GPU desde Termux: ¿enumera OpenCL o Vulkan algún
    dispositivo? Es la pregunta que decide si CUALQUIER motor (MLC-OpenCL,
    llama.cpp-OpenCL/Vulkan) puede acelerar por GPU en este móvil. El Android
    moderno suele bloquear el acceso del linker a /vendor/lib*/libOpenCL.so
    (namespace) → 0 plataformas aunque el .so exista. Scope: command.

    NUNCA debe devolver 500: todo el cuerpo va en try/except y los binarios solo
    se ejecutan si se resuelven (si `pkg install` falla, seguirían ausentes y
    ejecutarlos lanzaría FileNotFoundError)."""
    if (e := _check_auth(request, "command")):
        return e
    env = _full_env()
    # El cargador necesita ver el driver de GPU del sistema (fuera de $PREFIX).
    extra = ":".join(["/vendor/lib64", "/vendor/lib64/egl",
                      "/system/vendor/lib64", "/system/lib64"])
    env["LD_LIBRARY_PATH"] = (env.get("LD_LIBRARY_PATH", "") + ":" + extra).strip(":")
    lines = [f"Bridge v{VERSION}",
             "Sonda de GPU — ¿tu Pixel deja ver la GPU a Termux?"]
    opencl_ok = vulkan_ok = False
    out_cl = out_vk = ""
    libs = {}
    try:
        # 1) ¿Existen las .so del vendor? (necesario, no suficiente: el linker
        #    puede bloquearlas aunque el fichero exista).
        for p in ("/vendor/lib64/libOpenCL.so",
                  "/vendor/lib64/egl/libGLES_mali.so",
                  "/system/vendor/lib64/libOpenCL.so"):
            try:
                libs[p] = Path(p).exists()
            except Exception:
                libs[p] = False
        found = [p for p, ok in libs.items() if ok]
        lines.append("• Librerías GPU del sistema: " +
                     (", ".join(found) if found else "ninguna encontrada"))

        pkg = _termux_which("pkg", env)

        # 2) OpenCL: instalar clinfo + loader del vendor y enumerar plataformas.
        if _termux_which("clinfo", env) is None and pkg:
            lines.append("• Instalando clinfo + driver OpenCL del vendor…")
            await _run([pkg, "install", "-y", "clinfo", "ocl-icd",
                        "opencl-headers", "opencl-vendor-driver"],
                       timeout=300, env=env)
        clinfo = _termux_which("clinfo", env)
        if clinfo:
            rc_cl, out_cl = await _run([clinfo, "-l"], timeout=40, env=env)
            if rc_cl != 0 or not (out_cl or "").strip():
                _, out_cl = await _run([clinfo], timeout=40, env=env)
            cl = _parse_clinfo(out_cl)
            opencl_ok = cl.get("platforms", 0) > 0
            if opencl_ok:
                lines.append(f"• OpenCL: ✅ {cl['platforms']} plataforma(s)"
                             f" · {cl.get('device', '?')}")
            else:
                lines.append("• OpenCL: ❌ 0 plataformas (Android bloquea el "
                             "acceso o no hay driver alcanzable)")
        else:
            lines.append("• OpenCL: ❌ no pude instalar clinfo (¿sin red o "
                         "paquete no disponible en este Termux?)")

        # 3) Vulkan: instalar vulkan-tools + loader y enumerar GPU.
        if _termux_which("vulkaninfo", env) is None and pkg:
            lines.append("• Instalando vulkan-tools…")
            await _run([pkg, "install", "-y", "vulkan-tools",
                        "vulkan-loader-android"], timeout=300, env=env)
        vulkaninfo = _termux_which("vulkaninfo", env)
        if vulkaninfo:
            rc_vk, out_vk = await _run([vulkaninfo, "--summary"], timeout=40,
                                       env=env)
            vk = _parse_vulkaninfo(out_vk)
            vulkan_ok = rc_vk == 0 and vk.get("has_gpu", False)
            if vulkan_ok:
                lines.append(f"• Vulkan: ✅ {vk.get('device', 'GPU detectada')}")
            else:
                lines.append("• Vulkan: ❌ sin GPU (Android bloquea el acceso o "
                             "no hay ICD del vendor)")
        else:
            lines.append("• Vulkan: ❌ no pude instalar vulkan-tools")

        lines.append("")
        lines.append("➤ " + _gpu_verdict(opencl_ok, vulkan_ok))
    except Exception as exc:  # nunca 500: devuelve lo que haya + la causa
        lines.append("")
        lines.append(f"➤ ⚠️ La sonda falló a medias: {type(exc).__name__}: {exc}")
        lines.append(traceback.format_exc()[-600:])
    raw = ("--- clinfo ---\n" + (out_cl or "")[-1500:] +
           "\n\n--- vulkaninfo ---\n" + (out_vk or "")[-1500:])
    return web.json_response({
        "ok": True, "opencl": opencl_ok, "vulkan": vulkan_ok,
        "libs": libs, "summary": "\n".join(lines), "raw": raw,
    })


async def skills_install(request):
    if (e := _check_auth(request, "skills")):
        return e
    try:
        body = await request.json()
    except Exception:
        return _err("bad_json", "Cuerpo no es JSON válido")
    source = str(body.get("source", "")).strip()
    dry_run = bool(body.get("dry_run", False))
    if not SKILL_RE.match(source):
        return _err("bad_source", "source debe ser owner/repo (sin inyección)")
    cmd = _hermes() + ["skills", "install", "--yes", source]
    if dry_run:
        return web.json_response({"ok": True, "dry_run": True,
                                  "would_run": " ".join(cmd)})
    if READ_ONLY:
        return _err("bridge_read_only", "Modo solo lectura", 403)
    rc, log = await _run(cmd, timeout=180)
    ok = rc == 0 and "installed" in log.lower()
    _audit("skills_install", {"source": source}, "ok" if ok else "fail",
           {"rc": rc})
    return web.json_response({"ok": ok, "source": source,
                              "rc": rc, "log": log})


def _cron_home(profile=None):
    return HERMES_HOME if profile is None else HERMES_HOME / "profiles" / profile


def _cron_job_present(job_id, profile=None):
    """True/False si podemos confirmar el job en jobs.json; None si no se lee.

    El archivo se usa únicamente como comprobación posterior de solo lectura.
    La mutación siempre pasa por el comando oficial de Hermes.
    """
    try:
        path = _cron_home(profile) / "cron" / "jobs.json"
        data = json.loads(path.read_text())
        jobs = data.get("jobs", []) if isinstance(data, dict) else data
        return any(
            isinstance(job, dict)
            and job_id in {str(job.get("id", "")), str(job.get("name", ""))}
            for job in (jobs or [])
        )
    except Exception:
        return None


def _cron_profile(request):
    """Perfil validado de query o error; nunca degrada uno inválido a default."""
    raw = request.query.get("profile")
    if raw is None or not str(raw).strip() or str(raw).strip() == "default":
        return None, None
    profile = _resolve_profile({"profile": str(raw)})
    if profile is None:
        return None, _err("bad_profile", "Perfil de cron inválido")
    return profile, None


async def cron_remove(request):
    """DELETE /bridge/cron/jobs/{id}: elimina un cron con el CLI oficial.

    Es idempotente: si el job ya no existe, el estado final solicitado ya se
    cumple. Requiere el scope cron y respeta el modo global de solo lectura.
    """
    if (e := _check_auth(request, "cron")):
        return e
    if READ_ONLY:
        return _err("bridge_read_only", "Modo solo lectura", 403)
    job_id = str(request.match_info.get("job_id", "")).strip()
    if not CRON_JOB_ID_RE.fullmatch(job_id):
        return _err("bad_job_id", "ID de cron inválido")
    profile, profile_error = _cron_profile(request)
    if profile_error is not None:
        return profile_error

    was_present = _cron_job_present(job_id, profile)
    rc, log = await _run(
        _hermes(profile) + ["cron", "remove", job_id], timeout=60)
    still_present = _cron_job_present(job_id, profile)
    # Hermes no propaga de forma fiable el exit code, pero tampoco basta con que
    # el job no figure en un almacén: el CLI debe confirmar que lo eliminó o que
    # ya estaba ausente. Exigimos ambas señales para no declarar éxito contra un
    # layout de jobs distinto o una invocación que falló silenciosamente.
    low_log = log.lower()
    cli_confirmed = any(
        marker in low_log for marker in ("removed", "deleted", "not found")
    )
    ok = still_present is False and cli_confirmed
    _audit("cron_remove", {"job_id": job_id, "profile": profile},
           "ok" if ok else "fail",
           {"rc": rc, "was_present": was_present,
            "still_present": still_present, "log_tail": log[-160:]})
    if not ok:
        return _err("cron_remove_failed",
                    "Hermes no confirmó la eliminación del cron", 502)
    return web.json_response({
        "ok": True,
        "job_id": job_id,
        "profile": profile or "default",
        "already_absent": was_present is False,
    })


def _find_skill_dir(name):
    """Localiza en disco el directorio de una skill instalada, confinado bajo los
    SKILLS_DIRS. Devuelve un Path validado o None. [name] ya viene validado por
    SKILL_NAME_RE, pero comprobamos el confinamiento igualmente (defensa en
    profundidad: el resultado de resolve() debe colgar del root)."""
    for root in SKILLS_DIRS:
        try:
            base = root.resolve()
        except Exception:
            continue
        if not base.is_dir():
            continue
        # Las skills viven directamente (`<root>/<name>`) o bajo una carpeta de
        # categoría (`<root>/<categoría>/<name>`, p.ej. creative/comfyui). Se
        # buscan ambos y se valida el confinamiento de cada candidato.
        candidates = [base / name] + list(base.glob(f"*/{name}"))
        for cand in candidates:
            try:
                cand = cand.resolve()
                cand.relative_to(base)  # rechaza cualquier escape del root
            except ValueError:
                continue
            except Exception:
                continue
            if cand.is_dir():
                return cand
    return None


# El CLI solo desinstala skills "hub-installed". Para una builtin/bundled o
# instalada por otro medio imprime "is not a hub-installed skill (may be a
# builtin)" y termina rc=0 SIN borrar nada. Detectamos esa firma (con o sin el
# artículo "a") para caer al borrado directo del directorio.
_NOT_HUB_RE = re.compile(r"not\s+(?:a\s+)?hub[\s-]*installed", re.IGNORECASE)


async def skills_remove(request):
    if (e := _check_auth(request, "skills")):
        return e
    try:
        body = await request.json()
    except Exception:
        return _err("bad_json", "Cuerpo no es JSON válido")
    name = str(body.get("name", "")).strip()
    dry_run = bool(body.get("dry_run", False))
    if not SKILL_NAME_RE.match(name):
        return _err("bad_name", "name inválido")
    # `hermes skills uninstall` pide confirmación [y/N] y NO tiene flag --yes;
    # le pasamos "y" por stdin. OJO: devuelve rc=0 también si se cancela o si la
    # skill no existe, y el texto de éxito varía entre versiones del CLI
    # ("Uninstalled", "Removed", "✓", …). Exigir la palabra "uninstalled" daba
    # falsos negativos (ok=false con rc=0 → "bridge rc 0" opaco en el cliente).
    # Por eso tratamos rc=0 como éxito salvo que el log muestre un fallo claro.
    cmd = _hermes() + ["skills", "uninstall", name]
    if dry_run:
        return web.json_response({"ok": True, "dry_run": True,
                                  "would_run": " ".join(cmd)})
    if READ_ONLY:
        return _err("bridge_read_only", "Modo solo lectura", 403)
    rc, log = await _run(cmd, timeout=180, stdin_text="y\n")
    low = log.lower()

    # Camino especial: la skill no es hub-installed → el CLI no la tocó. Caemos
    # al borrado directo del directorio de la skill (confinado y validado).
    if _NOT_HUB_RE.search(low):
        skill_dir = _find_skill_dir(name)
        if skill_dir is not None:
            try:
                shutil.rmtree(skill_dir)
            except Exception as ex:
                _audit("skills_remove", {"name": name}, "fail",
                       {"rc": rc, "mode": "direct", "error": str(ex)})
                return web.json_response(
                    {"ok": False, "name": name, "rc": rc,
                     "log": f"{log}\nNo se pudo borrar {skill_dir}: {ex}"})
            _audit("skills_remove", {"name": name}, "ok",
                   {"rc": rc, "mode": "direct", "dir": str(skill_dir)})
            return web.json_response(
                {"ok": True, "name": name, "rc": 0, "mode": "direct",
                 "log": f"{log}\nBorrada directamente: {skill_dir}"})
        # No es hub-installed y no encontramos su directorio: no podemos quitarla
        # desde aquí con seguridad. Mensaje claro con el comando manual.
        _audit("skills_remove", {"name": name}, "fail",
               {"rc": rc, "mode": "direct", "reason": "dir_not_found"})
        return web.json_response({
            "ok": False, "name": name, "rc": rc,
            "log": f"{log}\nLa skill «{name}» no es hub-installed y no encontré "
                   f"su directorio. Quítala en Termux: hermes skills remove {name}",
        })

    failure_markers = ("not found", "no such", "does not exist", "not installed",
                       "no existe", "cancel", "aborted", "abort", "traceback")
    failed = any(m in low for m in failure_markers)
    ok = rc == 0 and not failed
    # Guardamos la cola del log en la auditoría para diagnosticar rc raros.
    _audit("skills_remove", {"name": name}, "ok" if ok else "fail",
           {"rc": rc, "log_tail": log[-300:]})
    return web.json_response({"ok": ok, "name": name, "rc": rc, "log": log})


CONFIG_PATH = HERMES_HOME / "config.yaml"


def _backup_config():
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%Y%m%d-%H%M%S")
    backup_id = f"config-{ts}"
    shutil.copy2(CONFIG_PATH, BACKUP_DIR / f"{backup_id}.yaml")
    return backup_id


def _edit_config(mutator):
    """Edita config.yaml preservando comentarios/estructura (ruamel round-trip).

    [mutator] recibe el árbol cargado y debe devolver True si hubo cambios. Hace
    backup antes de escribir. Nunca toca claves fuera de lo que el mutator
    modifica, así que los secretos y el formato del usuario se preservan.
    """
    from ruamel.yaml import YAML
    yaml = YAML()
    yaml.preserve_quotes = True
    with CONFIG_PATH.open() as f:
        data = yaml.load(f)
    changed = mutator(data)
    backup_id = None
    if changed:
        backup_id = _backup_config()
        with CONFIG_PATH.open("w") as f:
            yaml.dump(data, f)
    return changed, backup_id, data


async def skills_set_enabled(request):
    """Activa/desactiva una skill editando `skills.disabled` en config.yaml."""
    if (e := _check_auth(request, "skills")):
        return e
    if READ_ONLY:
        return _err("bridge_read_only", "Modo solo lectura", 403)
    try:
        body = await request.json()
    except Exception:
        return _err("bad_json", "Cuerpo no es JSON válido")
    name = str(body.get("name", "")).strip()
    enable = bool(body.get("enabled", True))
    if not SKILL_NAME_RE.match(name):
        return _err("bad_name", "name inválido")

    def mutate(data):
        skills = data.get("skills")
        if skills is None:
            data["skills"] = skills = {}
        disabled = skills.get("disabled")
        if disabled is None:
            from ruamel.yaml.comments import CommentedSeq
            disabled = CommentedSeq()
            skills["disabled"] = disabled
        present = name in list(disabled)
        if enable and present:
            while name in disabled:
                disabled.remove(name)
            return True
        if not enable and not present:
            disabled.append(name)
            return True
        return False

    try:
        changed, backup_id, data = _edit_config(mutate)
    except Exception as ex:
        return _err("config_edit_failed", f"No se pudo editar config: {ex}")
    disabled = list((data.get("skills") or {}).get("disabled") or [])
    _audit("skills_enable" if enable else "skills_disable",
           {"name": name}, "ok", {"changed": changed, "backup_id": backup_id})
    return web.json_response({
        "ok": True, "name": name, "enabled": enable,
        "changed": changed, "backup_id": backup_id, "disabled": disabled,
    })


async def model_set(request):
    """Fija el modelo PRINCIPAL escribiendo el bloque `model:` de config.yaml.

    POST {"provider": "...", "model": "...", "base_url"?: "...",
          "context_length"?: int}. Edición quirúrgica con ruamel (preserva
    comentarios y el resto del config). Es la vía del agente local: el Dashboard
    (`/api/model/set`, :9119) NO corre on-device, así que la app no puede fijar
    el modelo por ahí. Para provider ollama/custom asegura context_length y
    ollama_num_ctx >= 64000 (Hermes rechaza ventanas menores y deja el chat mudo).
    """
    if (e := _check_auth(request, "config")):
        return e
    if READ_ONLY:
        return _err("bridge_read_only", "Modo solo lectura", 403)
    try:
        body = await request.json()
    except Exception:
        return _err("bad_json", "Cuerpo no es JSON válido")
    provider = str(body.get("provider", "")).strip()
    model = str(body.get("model", "")).strip()
    base_url = str(body.get("base_url", "")).strip()
    try:
        ctx = int(body.get("context_length", 0) or 0)
    except Exception:
        ctx = 0
    if not provider or not model:
        return _err("bad_args", "provider y model son obligatorios")
    if base_url:
        try:
            base_url = _validated_http_url(base_url, allow_query=False)
        except ValueError as ex:
            return _err("bad_args", f"base_url no válida: {ex}")
    is_ollama = provider in ("custom", "ollama")
    # OlliteRT (motor GPU, :8000) no es Ollama real pero Hermes lee ollama_num_ctx
    # como "contexto de runtime" y bloquea tool-use si < 64K.
    is_ollitert = is_ollama and ":8000" in base_url
    gate = (ctx if ctx >= 64000 else 65536) if is_ollama else 0

    if not _ensure_ruamel():
        return _err(
            "ruamel_unavailable",
            "ruamel.yaml no está disponible: el venv de Hermes no está instalado "
            "o es inaccesible. Usa 'Reparar agente' desde el panel de control local.",
            500,
        )

    def mutate(data):
        m = data.get("model")
        if m is None:
            data["model"] = m = {}
        updates = [("provider", provider), ("default", model)]
        if base_url:
            updates.append(("base_url", base_url))
        if is_ollama:
            updates.append(("context_length", gate))
            updates.append(("ollama_num_ctx",
                             gate if is_ollitert else LOCAL_OLLAMA_NUM_CTX))
        changed = False
        for k, v in updates:
            if m.get(k) != v:
                m[k] = v
                changed = True
        return changed

    try:
        changed, backup_id, _ = _edit_config(mutate)
    except Exception as ex:
        _audit("model_set", {"provider": provider, "model": model}, "error",
               {"error": str(ex)})
        return _err("config_edit_failed", f"No se pudo escribir config: {ex}", 500)

    _audit("model_set", {"provider": provider, "model": model}, "ok",
           {"changed": changed, "backup_id": backup_id})
    # Invalida el catálogo cacheado: sin esto, model_options() sigue sirviendo
    # hasta 60s el proveedor/modelo VIEJO justo después de fijar uno nuevo, y la
    # app (que recarga el catálogo tras aplicar) muestra el cambio como si no
    # hubiera surtido efecto.
    global _MODEL_OPTIONS_CACHE
    _MODEL_OPTIONS_CACHE = None
    return web.json_response({
        "ok": True, "provider": provider, "model": model, "base_url": base_url,
        "changed": changed,
    })


async def model_get(request):
    """Lee el modelo activo de config.yaml (rápido, sin sondear Ollama).

    La pantalla de modelos lo usa al abrir para restaurar el badge «en uso»:
    `_selectedTag` solo vivía en memoria y se perdía al recrear la pantalla
    (salir de la app / cambiar de ventana) → el modelo parecía «desmarcarse».
    La verdad está en config.yaml, no en el estado del widget.
    """
    if (e := _check_auth(request, "read")):
        return e
    m = _config_model()
    return web.json_response({
        "ok": True,
        "provider": m.get("provider", ""),
        "model": m.get("default", ""),
        "base_url": m.get("base_url", ""),
    })


# Imágenes generadas por el agente (toolset image_gen): el agente las guarda
# en este directorio y responde citando la ruta; la app las descarga por aquí.
IMAGES_DIR = (HERMES_HOME / "cache" / "images").resolve()
_IMAGE_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")
_IMAGE_EXT_TYPES = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
}
_IMAGE_MAX_BYTES = 20 * 1024 * 1024  # 20 MB


async def image_get(request):
    """Sirve UNA imagen generada por el agente (spec 030), solo lectura.

    GET /bridge/image?name=<basename>. Endurecido a propósito: `name` es solo
    un basename (sin separadores ni `..`), se re-resuelve canónico bajo
    IMAGES_DIR (symlinks incluidos), extensión en allowlist y tope de 20 MB.
    Todos los fallos de validación devuelven EL MISMO error genérico: que un
    atacante no distinga "no existe" de "fuera del directorio".
    """
    if (e := _check_auth(request, "read")):
        return e

    def _denied():
        return _err("not_found", "No disponible", 404)

    name = (request.query.get("name", "") or "").strip()
    if (not name or "/" in name or "\\" in name or ".." in name
            or not _IMAGE_NAME_RE.match(name)):
        return _denied()
    ctype = _IMAGE_EXT_TYPES.get(Path(name).suffix.lower())
    if ctype is None:
        return _denied()
    try:
        target = (IMAGES_DIR / name).resolve()
    except OSError:
        return _denied()
    if not _path_is_below(target, IMAGES_DIR):
        return _denied()
    if not target.is_file():
        return _denied()
    try:
        size = target.stat().st_size
    except OSError:
        return _denied()
    if size > _IMAGE_MAX_BYTES:
        return _denied()
    try:
        data = target.read_bytes()
    except OSError:
        return _denied()
    return web.Response(body=data, content_type=ctype)


async def skills_find(request):
    """Busca skills en el registro de Hermes proxyando `skills search` (sin shell).

    Devuelve [{source, name, installs, url, description, trust}] para que la app
    muestre una tienda. La query se valida (solo alfanum/espacios) y se pasa como
    argumento aislado, nunca por shell. `source` es el identificador instalable
    por `hermes skills install` (mismo registro).
    """
    if (e := _check_auth(request, "read")):
        return e
    query = (request.query.get("q", "") or "").strip()
    if not SKILL_QUERY_RE.match(query):
        return _err("bad_query", "Búsqueda inválida (solo letras/números)")
    # Usa el registro de Hermes (`hermes skills search --json`), el MISMO que
    # `hermes skills install`, para que los identificadores devueltos sean
    # instalables. El antiguo `npx skills find` daba formato owner/repo@skill
    # que install NO resuelve ("Could not fetch ... from any source").
    # `--source all` (el default del CLI) devuelve 0 si alguna fuente falla
    # (clawhub, etc.); fijamos `skills-sh` (la tienda skills.sh), que es fiable y
    # devuelve identificadores instalables. Verificado: all→0, skills-sh→N.
    rc, out = await _run(
        _hermes() + ["skills", "search", query, "--source", "skills-sh", "--json"],
        timeout=90)
    results = []
    if rc == 0:
        try:
            data = json.loads(_ANSI_RE.sub("", out))
        except Exception:
            data = []
        items = data if isinstance(data, list) else data.get("results", [])
        for it in items:
            if not isinstance(it, dict):
                continue
            ident = str(it.get("identifier") or "").strip()
            if not ident or not SKILL_RE.match(ident):
                continue
            desc = str(it.get("description") or "")
            im = re.search(r"([\d,]+)\s*installs", desc)
            results.append({
                "source": ident,
                "name": str(it.get("name") or ident.split("/")[-1]),
                "installs": im.group(1) if im else "",
                "url": str(it.get("url") or ""),
                "description": desc,
                "trust": str(it.get("trust_level") or it.get("trust") or ""),
            })
    return web.json_response({"ok": True, "query": query, "results": results})


# Construye el catálogo de modelos con la MISMA función que usa el Dashboard
# (`/api/model/options`), así la app recibe idéntica forma. El sentinela acota el
# JSON por si el import escribe warnings a stdout.
#
# picker_hints=True: cada fila trae el `authenticated`/`auth_type`/`key_env`/
# `warning` REALES que calcula Hermes. Antes se estampaba authenticated=True a
# todo, y la app enseñaba como "configurados" proveedores descubiertos a través
# de CLIs locales, aunque no estuvieran disponibles para el runtime; spec 028.
#
# probe_custom_providers=False: recomendación del propio upstream para pickers
# GUI — sin esto cada petición sondea por red los endpoints custom y la
# primera carga en frío superaba el timeout de la app.
_MODEL_OPTIONS_CACHE = None  # (monotonic_ts, payload) — ver model_options().

# Degradacion por version del servidor: los kwargs nuevos no existen en
# Hermes viejos (TypeError). En el modo mas viejo (sin picker_hints) no llega
# `authenticated` real: se restaura el comportamiento pre-1.11 (todo
# autenticado) para no esconder proveedores configurados en esos servidores.
_MODEL_OPTIONS_SNIPPET = (
    "import json,sys\n"
    "from hermes_cli.inventory import build_models_payload, load_picker_context\n"
    "ctx = load_picker_context()\n"
    "try:\n"
    "    d = build_models_payload(ctx, picker_hints=True, include_unconfigured=True,\n"
    "                             probe_custom_providers=False)\n"
    "except TypeError:\n"
    "    try:\n"
    "        d = build_models_payload(ctx, picker_hints=True, include_unconfigured=True)\n"
    "    except TypeError:\n"
    "        d = build_models_payload(ctx)\n"
    "        provs = d.get('providers')\n"
    "        items = provs.values() if isinstance(provs, dict) else (provs or [])\n"
    "        for p in items:\n"
    "            if isinstance(p, dict):\n"
    "                p.setdefault('authenticated', True)\n"
    "sys.stdout.write('@@JSON@@')\n"
    "json.dump(d, sys.stdout)\n"
)


async def model_options(request):
    """Catálogo completo de proveedores/modelos —misma forma que el Dashboard
    `GET /api/model/options`— construido con la función oficial de Hermes
    (`hermes_cli.inventory.build_models_payload`) vía el venv. Permite a la app
    LISTAR y ELEGIR cualquier modelo configurado usando solo el token del bridge,
    sin depender del login del Dashboard. Scope: read."""
    if (e := _check_auth(request, "read")):
        return e
    # Cache en memoria con TTL corto: construir el catalogo lanza un
    # interprete Python frio que importa todo hermes_cli (varios segundos);
    # sin cache, cada visita a la pantalla de modelos pagaba ese arranque.
    global _MODEL_OPTIONS_CACHE
    cached = _MODEL_OPTIONS_CACHE
    if cached and (time.monotonic() - cached[0]) < 60.0:
        return web.json_response(cached[1])
    rc, out = await _run([_VENV_PY, "-c", _MODEL_OPTIONS_SNIPPET], timeout=90,
                         max_out=None)
    raw = out or ""
    i = raw.rfind("@@JSON@@")
    payload = raw[i + len("@@JSON@@"):].strip() if i >= 0 else raw.strip()
    if rc != 0 or not payload:
        return _err(
            "model_options_failed",
            f"No se pudo construir el catálogo de modelos (rc={rc}): "
            f"{raw[-400:]}", 500)
    try:
        data = json.loads(payload)
    except Exception as ex:
        return _err("model_options_parse",
                    f"Catálogo de modelos no parseable: {ex}", 500)
    body = {"ok": True, **data} if isinstance(data, dict) else {
        "ok": True, "providers": data}
    _MODEL_OPTIONS_CACHE = (time.monotonic(), body)
    return web.json_response(body)


_DASH_CREDS_GET_SNIPPET = (
    "import json,sys\n"
    "from hermes_cli.config import load_config\n"
    "c = load_config()\n"
    "d = c.get('dashboard') or {}\n"
    "b = d.get('basic_auth') or {}\n"
    "ph = str(b.get('password_hash') or '').strip()\n"
    "sys.stdout.write('@@JSON@@')\n"
    "json.dump({'username': b.get('username') or '', "
    "'password_set': bool(ph), 'public_url': d.get('public_url') or ''}, "
    "sys.stdout)\n"
)

_DASH_CREDS_SET_SNIPPET = (
    "import json,sys,secrets\n"
    "data = json.loads(sys.stdin.read() or '{}')\n"
    "username = str(data.get('username') or '').strip()\n"
    "password = str(data.get('password') or '')\n"
    "if not password:\n"
    "    sys.stdout.write('@@ERR@@empty_password'); sys.exit(0)\n"
    "from plugins.dashboard_auth.basic import hash_password\n"
    "from hermes_cli.config import load_config, save_config\n"
    "cfg = load_config()\n"
    "basic = cfg.setdefault('dashboard', {}).setdefault('basic_auth', {})\n"
    "if username:\n"
    "    basic['username'] = username\n"
    "elif not str(basic.get('username') or '').strip():\n"
    "    basic['username'] = 'admin'\n"
    "basic['password_hash'] = hash_password(password)\n"
    "basic['password'] = ''\n"
    "if not str(basic.get('secret','') or '').strip():\n"
    "    basic['secret'] = secrets.token_urlsafe(32)\n"
    "save_config(cfg)\n"
    "sys.stdout.write('@@OK@@' + (basic.get('username') or ''))\n"
)


async def dashboard_credentials(request):
    """Gestiona el login del Dashboard SIN SSH (un solo token):
    - GET: {username, password_set, public_url} (NO expone secretos).
    - POST {username?, password}: fija la contraseña (hash scrypt con la misma
      función oficial que usa la CLI de Hermes) y reinicia el Dashboard para que
      el proveedor `basic` se registre. Permite a la app dar acceso al Dashboard
      —y a sus funciones avanzadas— usando solo el token del bridge.
    Scope: read (GET) / config (POST)."""
    if request.method == "GET":
        if (e := _check_auth(request, "read")):
            return e
        rc, out = await _run(
            [_VENV_PY, "-c", _DASH_CREDS_GET_SNIPPET], timeout=60)
        raw = out or ""
        i = raw.rfind("@@JSON@@")
        payload = raw[i + len("@@JSON@@"):].strip() if i >= 0 else ""
        if rc != 0 or not payload:
            return _err("dash_creds_failed",
                        f"No se pudo leer la config del Dashboard (rc={rc}): "
                        f"{raw[-300:]}", 500)
        try:
            data = json.loads(payload)
        except Exception as ex:
            return _err("dash_creds_parse", f"No parseable: {ex}", 500)
        return web.json_response({"ok": True, **data})

    # POST: fijar contraseña
    if (e := _check_auth(request, "config")):
        return e
    if READ_ONLY:
        return _err("bridge_read_only", "Modo solo lectura", 403)
    try:
        body = await request.json()
    except Exception:
        return _err("bad_json", "Cuerpo no es JSON válido")
    password = str(body.get("password") or "")
    username = str(body.get("username") or "").strip()
    if len(password) < 4:
        return _err("weak_password",
                    "La contraseña debe tener al menos 4 caracteres")
    stdin_text = json.dumps({"username": username, "password": password})
    rc, out = await _run([_VENV_PY, "-c", _DASH_CREDS_SET_SNIPPET],
                         timeout=60, stdin_text=stdin_text)
    raw = (out or "").strip()
    if "@@ERR@@" in raw:
        return _err("set_failed", raw.split("@@ERR@@", 1)[1] or "error")
    if rc != 0 or "@@OK@@" not in raw:
        return _err("dash_set_failed",
                    f"No se pudo fijar la contraseña (rc={rc}): {raw[-300:]}",
                    500)
    final_user = raw.split("@@OK@@", 1)[1].strip()
    # Reiniciar el Dashboard para que registre el proveedor `basic` recién
    # escrito. El setup elige systemd, launchd, Scheduled Tasks o su helper
    # portable; el endpoint no presupone ya un sistema operativo concreto.
    restarted = await _restart_managed_service("dashboard", delay_seconds=0.2)
    _audit("dashboard_set_password", {"username": final_user}, "ok",
           {"restarted": restarted})
    return web.json_response({
        "ok": True, "username": final_user, "restarted": restarted,
    })


async def models_fallback(request):
    """Lee (GET) o fija (POST) la cadena de fallback `fallback_providers`.

    POST body: {"providers": [{"provider": "...", "model": "..."}, ...]}.
    Edición quirúrgica con ruamel (preserva comentarios/secretos del config).
    """
    if request.method == "GET":
        if (e := _check_auth(request, "read")):
            return e
        try:
            from ruamel.yaml import YAML
            with CONFIG_PATH.open() as f:
                data = YAML().load(f)
            fb = data.get("fallback_providers") or []
            out = [
                {"provider": str(x.get("provider", "")),
                 "model": str(x.get("model", ""))}
                for x in fb if isinstance(x, dict)
            ]
        except Exception as ex:
            return _err("config_read_failed", f"No se pudo leer config: {ex}")
        return web.json_response({"ok": True, "fallback_providers": out})

    # POST
    if (e := _check_auth(request, "config")):
        return e
    if READ_ONLY:
        return _err("bridge_read_only", "Modo solo lectura", 403)
    try:
        body = await request.json()
    except Exception:
        return _err("bad_json", "Cuerpo no es JSON válido")
    providers = body.get("providers")
    if not isinstance(providers, list):
        return _err("bad_providers", "'providers' debe ser una lista")
    clean = []
    name_re = re.compile(r"^[A-Za-z0-9_.:@/-]{1,120}$")
    for item in providers:
        if not isinstance(item, dict):
            return _err("bad_item", "cada elemento debe ser un objeto")
        prov = str(item.get("provider", "")).strip()
        model = str(item.get("model", "")).strip()
        if not name_re.match(prov) or not name_re.match(model):
            return _err("bad_value", f"provider/model inválido: {prov}/{model}")
        clean.append({"provider": prov, "model": model})

    def mutate(data):
        data["fallback_providers"] = clean
        return True

    try:
        _, backup_id, _ = _edit_config(mutate)
    except Exception as ex:
        return _err("config_edit_failed", f"No se pudo editar config: {ex}")
    _audit("models_fallback", {"count": len(clean)}, "ok",
           {"backup_id": backup_id})
    return web.json_response({
        "ok": True, "fallback_providers": clean, "backup_id": backup_id,
    })


async def skills_state(request):
    """Lista de skills desactivadas (skills.disabled) del config real."""
    if (e := _check_auth(request, "read")):
        return e
    try:
        from ruamel.yaml import YAML
        with CONFIG_PATH.open() as f:
            data = YAML().load(f)
        disabled = list((data.get("skills") or {}).get("disabled") or [])
    except Exception as ex:
        return _err("config_read_failed", f"No se pudo leer config: {ex}")
    return web.json_response({"ok": True, "disabled": disabled})


async def logs(request):
    if (e := _check_auth(request, "read")):
        return e
    which = request.query.get("file", "audit")
    lines = min(int(request.query.get("lines", "200") or 200), 5000)
    if which != "audit":
        return _err("unknown_log", "Solo 'audit' soportado en v1")
    if not AUDIT_LOG.exists():
        return web.json_response({"file": "audit", "lines": []})
    tail = AUDIT_LOG.read_text().splitlines()[-lines:]
    return web.json_response({"file": "audit", "lines": tail})


def build_app():
    app = web.Application(client_max_size=MAX_ATTACHMENT_BYTES + 1024)
    app.router.add_get("/bridge/health", health)
    app.router.add_get("/bridge/capabilities", capabilities)
    app.router.add_post("/bridge/self-update", self_update)
    app.router.add_post("/bridge/provision", provision)
    app.router.add_post("/bridge/chat", chat)
    app.router.add_post("/bridge/chat/stream", chat_stream)
    app.router.add_post("/bridge/attachments", attachment_upload)
    app.router.add_get("/bridge/read/{target}", read_file)
    app.router.add_post("/bridge/memory/write", write_file)
    app.router.add_post("/bridge/soul/write", write_file)
    app.router.add_post("/bridge/rollback", rollback)
    app.router.add_delete("/bridge/cron/jobs/{job_id}", cron_remove)
    app.router.add_post("/bridge/skills/install", skills_install)
    app.router.add_post("/bridge/skills/remove", skills_remove)
    app.router.add_get("/bridge/skills/state", skills_state)
    app.router.add_get("/bridge/skills/find", skills_find)
    app.router.add_post("/bridge/skills/enabled", skills_set_enabled)
    app.router.add_get("/bridge/models/fallback", models_fallback)
    app.router.add_post("/bridge/models/fallback", models_fallback)
    app.router.add_post("/bridge/model/set", model_set)
    app.router.add_get("/bridge/model/get", model_get)
    app.router.add_get("/bridge/model/options", model_options)
    app.router.add_get("/bridge/image", image_get)
    app.router.add_get("/bridge/dashboard/credentials", dashboard_credentials)
    app.router.add_post("/bridge/dashboard/credentials", dashboard_credentials)
    app.router.add_get("/bridge/diag/local", diag_local)
    app.router.add_get("/bridge/diag/llamacpp", diag_llamacpp)
    app.router.add_get("/bridge/diag/gpu", diag_gpu)
    app.router.add_get("/bridge/logs", logs)
    return app


def main():
    host = os.environ.get("BRIDGE_HOST", "127.0.0.1")
    port = int(os.environ.get("BRIDGE_PORT", "9131"))
    if host == "0.0.0.0" and "--i-know-what-im-doing" not in os.sys.argv:
        raise SystemExit("Rehúso bind a 0.0.0.0 sin --i-know-what-im-doing")
    print(f"Hermes Mobile Bridge v{VERSION} en http://{host}:{port}  "
          f"scopes={sorted(SCOPES)} read_only={READ_ONLY} token_fp={TOKEN_FP}")
    web.run_app(build_app(), host=host, port=port, print=None)


if __name__ == "__main__":
    main()
