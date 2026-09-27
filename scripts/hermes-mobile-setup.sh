#!/bin/sh
# Hermes Console — verified Unix setup (Linux, macOS, Termux and explicit WSL).
# Native Windows uses hermes-mobile-setup.ps1 from the same public repository.
set -eu

REPO_RAW="${HERMES_REPO_RAW:-https://raw.githubusercontent.com/xP3ta/hermes-setup/main}"
WINDOWS_COMMAND="irm $REPO_RAW/hermes-mobile-setup.ps1 | iex"

case "$(uname -s 2>/dev/null || echo unknown)" in
  Linux*) PLATFORM="linux" ;;
  Darwin*) PLATFORM="macos" ;;
  CYGWIN*|MINGW*|MSYS*)
    echo "Windows native detected. Run this command in PowerShell:"
    echo "  $WINDOWS_COMMAND"
    exit 2
    ;;
  *) PLATFORM="unix" ;;
esac

# WSL normally exposes a NAT address that an Android phone cannot reach.
# Native PowerShell can also configure Windows Firewall and persistent tasks,
# so it is the reliable default. Routed WSL installations may opt in with an
# explicit address.
if [ "$PLATFORM" = "linux" ] && { [ -n "${WSL_INTEROP:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; }; then
  if [ -z "${HERMES_PAIR_HOST:-}" ]; then
    echo "WSL detected. Its automatic IP is not reliably reachable from a phone."
    echo "Run the native Windows installer in PowerShell instead:"
    echo "  $WINDOWS_COMMAND"
    echo "Advanced routed WSL setups may set HERMES_PAIR_HOST explicitly."
    exit 2
  fi
fi

HH="${HERMES_HOME:-$HOME/.hermes}"
SERVICES="$HH/console-services"
LOGS="$HH/logs"
PROBE="$SERVICES/hermes-service-probe.py"
PAIR_ENV="$SERVICES/pairing.env"
mkdir -p "$HH" "$SERVICES" "$LOGS"

SETUP_STEP=0
SETUP_TOTAL=7
setup_step() {
  SETUP_STEP=$((SETUP_STEP + 1))
  case "$SETUP_STEP" in
    1) bar="#......" ;;
    2) bar="##....." ;;
    3) bar="###...." ;;
    4) bar="####..." ;;
    5) bar="#####.." ;;
    6) bar="######." ;;
    *) bar="#######" ;;
  esac
  printf '\n[%s] %s/%s %s\n' "$bar" "$SETUP_STEP" "$SETUP_TOTAL" "$1"
}

setup_step "Inspecting platform and service manager"

port_listening() {
  port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tlnH 2>/dev/null | grep -q ":$port "
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | grep -q .
  else
    netstat -an 2>/dev/null | grep -E "[.:]$port[[:space:]].*LISTEN" >/dev/null
  fi
}

show_port_owner() {
  port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sed -n '1,4p' || true
  elif command -v ss >/dev/null 2>&1; then
    ss -ltnp "sport = :$port" 2>/dev/null | sed -n '1,4p' || true
  fi
}

service_failure() {
  name="$1"
  port="$2"
  log_name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  echo "ERROR: $name did not pass its authenticated Hermes health checks on TCP $port."
  if port_listening "$port"; then
    echo "TCP $port is occupied, but it is not the expected healthy $name service:"
    show_port_owner "$port"
    echo "The installer did not kill that process. Stop the conflict and run setup again."
  else
    echo "Nothing is listening on TCP $port."
  fi
  echo "Inspect $LOGS/$log_name.log or the platform service logs, then retry."
  exit 1
}

# Resolve the best available per-user service manager. A portable supervisor
# keeps the current session working on containers, Termux and WSL without
# systemd; its warning below makes the reboot limitation explicit.
SERVICE_MANAGER="portable"
if [ "$PLATFORM" = "linux" ] && command -v systemctl >/dev/null 2>&1; then
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  if command -v loginctl >/dev/null 2>&1; then
    LINGER_USER="$(id -un)"
    LINGER_STATE="$(loginctl show-user "$LINGER_USER" -p Linger --value 2>/dev/null || true)"
    if [ "$LINGER_STATE" != "yes" ]; then
      LINGER_ENABLED=0
      if [ "$(id -u)" -eq 0 ]; then
        if loginctl enable-linger "$LINGER_USER" >/dev/null 2>&1; then
          LINGER_ENABLED=1
        fi
      elif command -v sudo >/dev/null 2>&1 && \
           sudo -n loginctl enable-linger "$LINGER_USER" >/dev/null 2>&1; then
        LINGER_ENABLED=1
      fi
      if [ "$LINGER_ENABLED" -ne 1 ]; then
        echo "WARNING: user lingering is not enabled; services may stop after logout."
        echo "Run once as an administrator, then rerun setup:"
        echo "  sudo loginctl enable-linger $LINGER_USER"
      fi
    fi
  fi
  i=0
  while [ "$i" -lt 10 ]; do
    [ -S "$XDG_RUNTIME_DIR/bus" ] && break
    sleep 1
    i=$((i + 1))
  done
  if systemctl --user show-environment >/dev/null 2>&1; then
    SERVICE_MANAGER="systemd"
  fi
elif [ "$PLATFORM" = "macos" ] && command -v launchctl >/dev/null 2>&1; then
  if launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
    SERVICE_MANAGER="launchd"
  fi
fi

setup_step "Checking Hermes Agent"

# Hermes Agent. A launcher only counts when it responds; stale shims from a
# half-finished uninstall must not produce three crash-looping services.
# Prefer the launcher Hermes publishes for source installs: it follows the
# managed Python/dependency generation across updates. The legacy venv entry
# point is only a fallback for older installs.
HB="$HH/hermes-agent/.hermes/bin/hermes"
if ! { [ -x "$HB" ] && "$HB" --version >/dev/null 2>&1; }; then
  HB="$HH/hermes-agent/venv/bin/hermes"
fi
if ! { [ -x "$HB" ] && "$HB" --version >/dev/null 2>&1; }; then
  HB="$(command -v hermes 2>/dev/null || true)"
  if [ -z "$HB" ] || ! "$HB" --version >/dev/null 2>&1; then
    echo "Installing Hermes Agent for $PLATFORM..."
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | \
      bash -s -- --skip-setup --non-interactive --skip-browser \
      --hermes-home "$HH" --dir "$HH/hermes-agent"
    HB="$HH/hermes-agent/.hermes/bin/hermes"
    [ -x "$HB" ] || HB="$HH/hermes-agent/venv/bin/hermes"
    [ -x "$HB" ] || HB="$(command -v hermes 2>/dev/null || true)"
  fi
fi
if [ -z "$HB" ] || [ ! -x "$HB" ] || ! "$HB" --version >/dev/null 2>&1; then
  echo "ERROR: Hermes Agent was not installed correctly."
  exit 1
fi

# Python that owns the Hermes environment (and therefore aiohttp).
VP="$HH/hermes-agent/venv/bin/python3"
[ -x "$VP" ] || VP="$HH/hermes-agent/venv/bin/python"
if [ ! -x "$VP" ]; then
  HB_REAL="$HB"
  if command -v realpath >/dev/null 2>&1; then
    HB_REAL="$(realpath "$HB" 2>/dev/null || printf '%s' "$HB")"
  fi
  HB_DIR="$(CDPATH= cd -- "$(dirname -- "$HB_REAL")" 2>/dev/null && pwd -P || dirname -- "$HB_REAL")"
  VP="$HB_DIR/python3"
  [ -x "$VP" ] || VP="$HB_DIR/python"
fi
[ -x "$VP" ] || VP="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
if [ -z "$VP" ] || [ ! -x "$VP" ]; then
  echo "ERROR: no Python interpreter is available for the Mobile Bridge."
  exit 1
fi
"$VP" -c 'import aiohttp' 2>/dev/null || {
  echo "ERROR: $VP does not provide aiohttp; repair the Hermes installation first."
  exit 1
}

# Preserve one usable existing API key. Blank, placeholder or too-short legacy
# values cannot start modern Hermes, so those are repaired atomically.
# Conflicting duplicate strong values fail closed instead of guessing.
KEY="$("$VP" - "$HH/.env" <<'PY'
import os, pathlib, secrets, sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
values = []
for line in lines:
    if line.startswith("API_SERVER_KEY="):
        values.append(line.split("=", 1)[1].strip().strip('"').strip("'"))
placeholders = {"changeme", "change-me", "your-api-key", "replace-me", "secret"}
strong = [v for v in values if len(v) >= 16 and v.lower() not in placeholders]
if len(set(strong)) > 1:
    raise SystemExit(
        "ERROR: conflicting API_SERVER_KEY entries exist in .env; "
        "keep exactly one and retry"
    )
key = strong[0] if strong else secrets.token_hex(32)
out, inserted = [], False
for line in lines:
    if line.startswith("API_SERVER_KEY="):
        if not inserted:
            out.append("API_SERVER_KEY=" + key)
            inserted = True
        continue
    out.append(line)
if not inserted:
    out.append("API_SERVER_KEY=" + key)
tmp = path.with_name(path.name + ".new")
tmp.write_text("\n".join(out) + "\n", encoding="utf-8")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
print(key)
PY
)"
chmod 600 "$HH/.env" 2>/dev/null || true

# Reachable host: mesh VPN > private LAN. Public HTTP and loopback never
# produce a QR because the Android release rejects or cannot reach them.
IPS=""
if command -v ip >/dev/null 2>&1; then
  IPS="$(ip -o -4 addr show 2>/dev/null | awk '$2 !~ /^(lo|docker|br-|veth|virbr|podman|cni|lxc)/ {if ($4 !~ /^(127\.|169\.254\.)/) print $4}' || true)"
elif command -v ifconfig >/dev/null 2>&1; then
  IPS="$(ifconfig 2>/dev/null | awk '/^[[:alnum:]]/ {iface=$1; sub(":$","",iface)} /inet / && iface !~ /^(lo|bridge|vmenet|docker|utun|awdl|llw)/ {ip=$2; sub(/^addr:/,"",ip); if (ip !~ /^(127\.|169\.254\.)/) print ip "/"}' || true)"
elif command -v hostname >/dev/null 2>&1; then
  IPS="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -Ev '^(127\.|169\.254\.)' | sed 's|$|/|' || true)"
fi

HOST="${HERMES_PAIR_HOST:-}"
NETWORK_KIND="override"
HOST_RECORD=""
if [ -z "$HOST" ]; then
  HOST="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  if [ -n "$HOST" ]; then
    NETWORK_KIND="mesh"
  else
    HOST_RECORD="$(printf '%s\n' "$IPS" | grep -E '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.' | head -1 || true)"
    if [ -n "$HOST_RECORD" ]; then
      HOST="${HOST_RECORD%%/*}"
      NETWORK_KIND="mesh"
    else
      HOST_RECORD="$(printf '%s\n' "$IPS" | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' | head -1 || true)"
      if [ -n "$HOST_RECORD" ]; then
        HOST="${HOST_RECORD%%/*}"
        NETWORK_KIND="lan"
      fi
    fi
  fi
fi

PAIR_SCHEME="${HERMES_PAIR_SCHEME:-http}"
case "$PAIR_SCHEME" in
  http|https) ;;
  *) echo "ERROR: HERMES_PAIR_SCHEME must be http or https."; exit 1 ;;
esac
PAIR_PORT="${HERMES_PAIR_PORT:-}"
if [ -z "$PAIR_PORT" ]; then
  if [ "$PAIR_SCHEME" = "https" ]; then PAIR_PORT=443; else PAIR_PORT=8642; fi
fi
case "$PAIR_PORT" in
  *[!0-9]*|'') echo "ERROR: HERMES_PAIR_PORT must be a TCP port."; exit 1 ;;
esac
if [ "$PAIR_PORT" -lt 1 ] || [ "$PAIR_PORT" -gt 65535 ]; then
  echo "ERROR: HERMES_PAIR_PORT is out of range."
  exit 1
fi
if [ -z "$HOST" ]; then
  echo "ERROR: no private LAN or Tailscale address was found, so no safe mobile QR can be created."
  echo "Connect Tailscale or join the phone to this LAN. For a public server, configure HTTPS"
  echo "and rerun with HERMES_PAIR_HOST=<name> HERMES_PAIR_SCHEME=https."
  exit 1
fi
case "$HOST" in
  *[!A-Za-z0-9._:-]*|*/*|*://*)
    echo "ERROR: HERMES_PAIR_HOST is not a valid host name or IP address."
    exit 1
    ;;
esac

HOST_INFO="$("$VP" - "$HOST" "$PAIR_SCHEME" "$HOST_RECORD" <<'PY'
import ipaddress, socket, sys

host, scheme, record = sys.argv[1:]
try:
    ip = ipaddress.ip_address(host)
except ValueError:
    try:
        ip = ipaddress.ip_address(socket.gethostbyname(host))
    except Exception:
        ip = None
private_name = (
    host.lower().endswith((".local", ".ts.net"))
    or "." not in host
    or host.lower().endswith((".test", ".example"))
)
cgnat = bool(
    ip and ip.version == 4
    and ipaddress.ip_address("100.64.0.0") <= ip
    <= ipaddress.ip_address("100.127.255.255")
)
allowed_http = bool(ip and (ip.is_private or ip.is_loopback or cgnat)) or private_name
if host.lower() == "localhost" or (ip and ip.is_loopback):
    raise SystemExit(
        "ERROR: loopback is not reachable from a phone; use a LAN/Tailscale address"
    )
if scheme == "http" and not allowed_http:
    raise SystemExit(
        "ERROR: public HTTP is blocked; use Tailscale/LAN or HERMES_PAIR_SCHEME=https"
    )
kind = "mesh" if cgnat else "lan"
source = "100.64.0.0/10" if cgnat else ""
if not source and ip and ip.version == 4:
    prefix = None
    if record and "/" in record:
        try:
            prefix = int(record.rsplit("/", 1)[1])
        except ValueError:
            pass
    if prefix is not None:
        source = str(ipaddress.ip_network(f"{ip}/{prefix}", strict=False))
    elif ip in ipaddress.ip_network("10.0.0.0/8"):
        source = "10.0.0.0/8"
    elif ip in ipaddress.ip_network("172.16.0.0/12"):
        source = "172.16.0.0/12"
    elif ip in ipaddress.ip_network("192.168.0.0/16"):
        source = "192.168.0.0/16"
if scheme == "http" and not source:
    raise SystemExit(
        "ERROR: could not determine a private firewall source for this host; use HTTPS"
    )
print(kind + "|" + source)
PY
)"
[ "$NETWORK_KIND" = "override" ] && NETWORK_KIND="${HOST_INFO%%|*}"
FIREWALL_SOURCE="${HOST_INFO#*|}"

BASE_HOST="$HOST"
case "$BASE_HOST" in *:*) BASE_HOST="[$BASE_HOST]" ;; esac
GATEWAY_BASE="$PAIR_SCHEME://$BASE_HOST:$PAIR_PORT"
if [ "$PAIR_SCHEME" = "http" ]; then
  DASHBOARD_BASE="${HERMES_DASHBOARD_URL:-http://$BASE_HOST:9119}"
  BRIDGE_BASE="${HERMES_BRIDGE_URL:-http://$BASE_HOST:9131}"
  BIND_HOST="${HERMES_SERVICE_BIND_HOST:-0.0.0.0}"
else
  DASHBOARD_BASE="${HERMES_DASHBOARD_URL:-$GATEWAY_BASE}"
  BRIDGE_BASE="${HERMES_BRIDGE_URL:-$GATEWAY_BASE}"
  BIND_HOST="${HERMES_SERVICE_BIND_HOST:-127.0.0.1}"
fi
case "$BIND_HOST" in
  0.0.0.0|127.0.0.1) ;;
  *) echo "ERROR: HERMES_SERVICE_BIND_HOST must be 0.0.0.0 or 127.0.0.1."; exit 1 ;;
esac

# Setup and the pair-only command share this installed, fail-closed verifier.
# It validates JSON identity and authentication instead of an open TCP socket.
cat > "$PROBE" <<'PY'
#!/usr/bin/env python3
import ipaddress
import json
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request

kind, base, token = sys.argv[1:4]
expected = sys.argv[4] if len(sys.argv) > 4 else ""
phone_facing = len(sys.argv) > 5 and sys.argv[5] == "phone"
base = base.rstrip("/")


def private_address(value):
    try:
        ip = ipaddress.ip_address(value)
    except ValueError:
        return False
    if ip.is_loopback:
        return False
    if ip.version == 6:
        return ip in ipaddress.ip_network("fc00::/7")
    return any(
        ip in network
        for network in (
            ipaddress.ip_network("10.0.0.0/8"),
            ipaddress.ip_network("172.16.0.0/12"),
            ipaddress.ip_network("192.168.0.0/16"),
            ipaddress.ip_network("100.64.0.0/10"),
        )
    )


def assert_phone_url():
    try:
        parsed = urllib.parse.urlsplit(base)
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
    except ValueError:
        raise RuntimeError("invalid phone-facing service URL") from None
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise RuntimeError("invalid phone-facing service URL")
    host = parsed.hostname.lower()
    try:
        literal = ipaddress.ip_address(host)
    except ValueError:
        literal = None
    if host == "localhost" or (literal and literal.is_loopback):
        raise RuntimeError("loopback is not reachable from the phone")
    if parsed.scheme == "https":
        return
    private_name = host.endswith((".local", ".ts.net")) or "." not in host
    if literal is not None:
        addresses = [literal]
    else:
        try:
            addresses = {
                ipaddress.ip_address(item[4][0])
                for item in socket.getaddrinfo(
                    host,
                    port,
                    type=socket.SOCK_STREAM,
                )
            }
        except OSError:
            addresses = set()
    if addresses and all(private_address(str(address)) for address in addresses):
        return
    if not addresses and private_name:
        return
    raise RuntimeError("public HTTP is blocked; use LAN/Tailscale or HTTPS")


def fetch(path, auth=False):
    headers = {"Accept": "application/json"}
    if auth:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(base + path, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=6) as response:
            status = response.status
            raw = response.read(1024 * 1024)
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"{path} returned HTTP {exc.code}") from None
    except Exception as exc:
        raise RuntimeError(
            f"{path} is unreachable ({type(exc).__name__})"
        ) from None
    if status != 200:
        raise RuntimeError(f"{path} returned HTTP {status}")
    try:
        value = json.loads(raw.decode("utf-8"))
    except Exception:
        raise RuntimeError(f"{path} did not return JSON") from None
    if not isinstance(value, dict):
        raise RuntimeError(f"{path} returned the wrong JSON shape")
    return value


try:
    if phone_facing:
        assert_phone_url()
    if kind == "gateway":
        health = fetch("/health")
        if health.get("status") != "ok" or health.get("platform") != "hermes-agent":
            raise RuntimeError("/health is not Hermes Gateway")
        sessions = fetch("/api/sessions", auth=True)
        if sessions.get("object") != "list" or not isinstance(
            sessions.get("data"), list
        ):
            raise RuntimeError(
                "/api/sessions is not the authenticated Hermes API"
            )
    elif kind == "bridge":
        health = fetch("/bridge/health")
        if health.get("status") != "ok" or not isinstance(
            health.get("version"), str
        ):
            raise RuntimeError("/bridge/health is not Hermes Mobile Bridge")
        if expected and health.get("version") != expected:
            raise RuntimeError(
                f"Bridge version is {health.get('version')}, expected {expected}"
            )
        caps = fetch("/bridge/capabilities", auth=True)
        operations = caps.get("operations")
        scopes = caps.get("scopes")
        if (
            caps.get("object") != "hermes.bridge.capabilities"
            or not isinstance(operations, dict)
            or operations.get("self_update") is not True
            or not isinstance(scopes, list)
            or "read" not in scopes
            or "config" not in scopes
        ):
            raise RuntimeError(
                "Bridge auth/config/self-update capability check failed"
            )
    elif kind == "dashboard":
        status = fetch("/api/status")
        if not isinstance(status.get("version"), str) or not isinstance(
            status.get("gateway_running"), bool
        ):
            raise RuntimeError("/api/status is not Hermes Dashboard")
        if status.get("gateway_running") is not True:
            raise RuntimeError("Dashboard reports that Hermes Gateway is stopped")
    else:
        raise RuntimeError("unknown service kind")
except RuntimeError as exc:
    print(f"{kind}: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
chmod 700 "$PROBE"

wait_probe() {
  kind="$1"
  base="$2"
  seconds="$3"
  expected="${4:-}"
  mode="${5:-}"
  i=0
  while [ "$i" -lt "$seconds" ]; do
    if "$VP" "$PROBE" "$kind" "$base" "$KEY" "$expected" "$mode" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  "$VP" "$PROBE" "$kind" "$base" "$KEY" "$expected" "$mode" || true
  return 1
}

setup_step "Verifying Mobile Bridge release"

# Verified Bridge release: closed manifest, exact size/hash/version, compile,
# backup and atomic swap. No bytes execute before every check passes.
TARGET="$HH/hermes_bridge.py"
NEW="$TARGET.new"
BACKUP="$TARGET.rollback"
MANIFEST="$HH/bridge-release.json.new"
SYSTEMD_STAGE=""
SYSTEMD_GATEWAY_PENDING=0
SYSTEMD_GATEWAY_HAD_UNIT=0
SYSTEMD_GATEWAY_HAD_DROPIN=0
SYSTEMD_USER_DIR=""
SYSTEMD_GATEWAY_DROPIN_DIR=""
rollback_pending_systemd_gateway() {
  [ "$SYSTEMD_GATEWAY_PENDING" -eq 1 ] || return 0
  rm -f \
    "$SYSTEMD_USER_DIR/hermes-gateway.service.new" \
    "$SYSTEMD_GATEWAY_DROPIN_DIR/10-hermes-console-network.conf.new"
  if [ "$SYSTEMD_GATEWAY_HAD_UNIT" -eq 1 ]; then
    cp -p "$SYSTEMD_STAGE/hermes-gateway.service.previous" \
      "$SYSTEMD_USER_DIR/hermes-gateway.service"
  else
    rm -f "$SYSTEMD_USER_DIR/hermes-gateway.service"
  fi
  if [ "$SYSTEMD_GATEWAY_HAD_DROPIN" -eq 1 ]; then
    cp -p "$SYSTEMD_STAGE/hermes-gateway-network.conf.previous" \
      "$SYSTEMD_GATEWAY_DROPIN_DIR/10-hermes-console-network.conf"
  else
    rm -f "$SYSTEMD_GATEWAY_DROPIN_DIR/10-hermes-console-network.conf"
    rmdir "$SYSTEMD_GATEWAY_DROPIN_DIR" 2>/dev/null || true
  fi
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  SYSTEMD_GATEWAY_PENDING=0
}
cleanup_systemd_stage() {
  [ -n "$SYSTEMD_STAGE" ] || return 0
  rm -f \
    "$SYSTEMD_STAGE/hermes-gateway.service.d/10-hermes-console-network.conf" \
    "$SYSTEMD_STAGE/hermes-gateway.service" \
    "$SYSTEMD_STAGE/hermes-dashboard.service" \
    "$SYSTEMD_STAGE/hermes-bridge.service" \
    "$SYSTEMD_STAGE/hermes-gateway.service.previous" \
    "$SYSTEMD_STAGE/hermes-gateway-network.conf.previous"
  rmdir "$SYSTEMD_STAGE/hermes-gateway.service.d" 2>/dev/null || true
  rmdir "$SYSTEMD_STAGE" 2>/dev/null || true
  SYSTEMD_STAGE=""
}
cleanup_downloads() {
  rm -f "$NEW" "$MANIFEST"
  rollback_pending_systemd_gateway
  cleanup_systemd_stage
}
trap cleanup_downloads EXIT HUP INT TERM
curl -fsSL "$REPO_RAW/bridge-release.json" -o "$MANIFEST"
curl -fsSL "$REPO_RAW/hermes_bridge.py" -o "$NEW"
BRIDGE_VERSION="$("$VP" - "$MANIFEST" "$NEW" <<'PY'
import hashlib, json, pathlib, re, sys
manifest_path, bridge_path = map(pathlib.Path, sys.argv[1:])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
if set(manifest) != {"schema", "version", "min_app_build", "sha256", "size"}:
    raise SystemExit("Invalid Bridge release manifest fields")
version = manifest.get("version")
digest = manifest.get("sha256")
size = manifest.get("size")
if (manifest.get("schema") != 1
        or not isinstance(version, str)
        or not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version)
        or not isinstance(manifest.get("min_app_build"), int)
        or manifest["min_app_build"] <= 0
        or not isinstance(digest, str)
        or not re.fullmatch(r"[a-f0-9]{64}", digest)
        or not isinstance(size, int) or size <= 0 or size > 512 * 1024):
    raise SystemExit("Invalid Bridge release manifest")
payload = bridge_path.read_bytes()
if len(payload) != size or hashlib.sha256(payload).hexdigest() != digest:
    raise SystemExit("Bridge release integrity check failed")
source = payload.decode("utf-8", errors="strict")
versions = re.findall(
    r'''^VERSION\s*=\s*["']((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))["']\s*(?:#.*)?$''',
    source, re.MULTILINE)
if versions != [version]:
    raise SystemExit("Bridge source VERSION mismatch")
compile(source, str(bridge_path), "exec")
print(version)
PY
)"
chmod 600 "$NEW"
"$VP" -m py_compile "$NEW"
HAD_BRIDGE_TARGET=0
if [ -f "$TARGET" ]; then
  HAD_BRIDGE_TARGET=1
  cp -p "$TARGET" "$BACKUP"
else
  rm -f "$BACKUP"
fi
mv "$NEW" "$TARGET"

ENV_FILE="$HH/bridge.env"
printf 'BRIDGE_HOST=%s\nBRIDGE_PORT=9131\nBRIDGE_SCOPES=read,memory,soul,skills,cron,config,command\nBRIDGE_READ_ONLY=false\nBRIDGE_TOKEN=%s\n' "$BIND_HOST" "$KEY" > "$ENV_FILE"
chmod 600 "$ENV_FILE"

GATEWAY_RUNNER="$SERVICES/hermes-gateway.sh"
DASHBOARD_RUNNER="$SERVICES/hermes-dashboard.sh"
BRIDGE_RUNNER="$SERVICES/hermes-bridge.sh"
HELPER="$SERVICES/service-manager.sh"

cat > "$GATEWAY_RUNNER" <<EOF
#!/bin/sh
export HERMES_HOME="$HH"
export API_SERVER_HOST="$BIND_HOST"
export API_SERVER_PORT=8642
cd "$HH"
exec "$HB" gateway run --replace
EOF
cat > "$DASHBOARD_RUNNER" <<EOF
#!/bin/sh
export HERMES_HOME="$HH"
cd "$HH"
exec "$HB" dashboard --host "$BIND_HOST" --port 9119 --no-open
EOF
HELPER_EXPORT=""
[ "$SERVICE_MANAGER" = "portable" ] && HELPER_EXPORT="export BRIDGE_SERVICE_HELPER=\"$HELPER\""
cat > "$BRIDGE_RUNNER" <<EOF
#!/bin/sh
set -a
. "$ENV_FILE"
set +a
export HERMES_HOME="$HH"
export BRIDGE_HERMES_HOME="$HH"
$HELPER_EXPORT
cd "$HH"
exec "$VP" "$TARGET" --i-know-what-im-doing
EOF
chmod 700 "$GATEWAY_RUNNER" "$DASHBOARD_RUNNER" "$BRIDGE_RUNNER"

# Portable lifecycle helper. It only accepts three allowlisted service names,
# validates PID ownership against the exact runner path and never uses pkill.
cat > "$HELPER" <<EOF
#!/bin/sh
set -eu
ACTION="\${1:-}"
NAME="\${2:-}"
case "\$NAME" in
  gateway) RUNNER="$GATEWAY_RUNNER"; EXPECTED_EXE="$HB"; EXPECTED_ARGS="gateway run --replace" ;;
  dashboard) RUNNER="$DASHBOARD_RUNNER"; EXPECTED_EXE="$HB"; EXPECTED_ARGS="dashboard --host" ;;
  bridge) RUNNER="$BRIDGE_RUNNER"; EXPECTED_EXE="$TARGET"; EXPECTED_ARGS="--i-know-what-im-doing" ;;
  *) exit 2 ;;
esac
PIDFILE="$SERVICES/\$NAME.pid"
LOGFILE="$LOGS/\$NAME.log"
stop_service() {
  [ -f "\$PIDFILE" ] || return 0
  PID="\$(sed -n '1p' "\$PIDFILE" 2>/dev/null || true)"
  case "\$PID" in *[!0-9]*|'') rm -f "\$PIDFILE"; return 0 ;; esac
  if kill -0 "\$PID" 2>/dev/null; then
    CMD="\$(ps -p "\$PID" -o command= 2>/dev/null || true)"
    case "\$CMD" in
      *"\$EXPECTED_EXE"*"\$EXPECTED_ARGS"*) kill "\$PID" 2>/dev/null || true ;;
      *) echo "Refusing to stop PID \$PID: it is not the expected Hermes \$NAME service." >&2; exit 3 ;;
    esac
    i=0; while kill -0 "\$PID" 2>/dev/null && [ "\$i" -lt 5 ]; do sleep 1; i=\$((i + 1)); done
    if kill -0 "\$PID" 2>/dev/null; then
      echo "Hermes \$NAME did not stop cleanly; refusing to start a duplicate." >&2
      return 1
    fi
  fi
  rm -f "\$PIDFILE"
}
start_service() {
  nohup "\$RUNNER" >> "\$LOGFILE" 2>&1 </dev/null &
  echo "\$!" > "\$PIDFILE"
}
case "\$ACTION" in
  start) start_service ;;
  stop) stop_service ;;
  restart) stop_service; start_service ;;
  *) exit 2 ;;
esac
EOF
chmod 700 "$HELPER"

install_systemd_unit() {
  name="$1"
  runner="$2"
  unit_dir="$3"
  unit="$unit_dir/hermes-$name.service"
  # The dashboard launches `hermes update` (Console's "Update Hermes") as a
  # child, and that updater restarts this very unit at the end. With the
  # default KillMode=control-group systemd would kill the updater together
  # with the old dashboard before it records its receipt. KillMode=process
  # stops only the dashboard's main process: detached actions it launched
  # (update, gateway restart) finish on their own, and its stdio MCP servers
  # are reaped by Hermes' parent-death supervisor when the dashboard exits.
  kill_mode=""
  [ "$name" = "dashboard" ] && kill_mode="KillMode=process"
  mkdir -p "$unit_dir"
  cat > "$unit" <<EOF
[Unit]
Description=Hermes Console $name
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=$runner
WorkingDirectory=$HH
Restart=on-failure
RestartSec=2
$kill_mode
[Install]
WantedBy=default.target
EOF
}

stage_gateway_systemd_unit() {
  if ! "$VP" - "$SYSTEMD_STAGE/hermes-gateway.service" <<'PY'
import pathlib, sys

from hermes_cli.gateway import generate_systemd_unit

path = pathlib.Path(sys.argv[1])
unit = generate_systemd_unit(system=False)
if not unit.startswith("[Unit]\n") or "hermes_cli.main" not in unit:
    raise SystemExit("Hermes generated an invalid gateway user unit")
path.write_text(unit, encoding="utf-8")
PY
  then
    echo "ERROR: Hermes could not generate its canonical gateway user unit."
    return 1
  fi
  mkdir -p "$SYSTEMD_STAGE/hermes-gateway.service.d"
  cat > "$SYSTEMD_STAGE/hermes-gateway.service.d/10-hermes-console-network.conf" <<EOF
[Service]
Environment="API_SERVER_HOST=$BIND_HOST"
Environment="API_SERVER_PORT=8642"
EOF
  chmod 644 \
    "$SYSTEMD_STAGE/hermes-gateway.service" \
    "$SYSTEMD_STAGE/hermes-gateway.service.d/10-hermes-console-network.conf"
}

install_verified_systemd_units() {
  SYSTEMD_STAGE="$(mktemp -d "$SERVICES/systemd-units.XXXXXX")"
  stage_gateway_systemd_unit
  install_systemd_unit dashboard "$DASHBOARD_RUNNER" "$SYSTEMD_STAGE"
  install_systemd_unit bridge "$BRIDGE_RUNNER" "$SYSTEMD_STAGE"

  if command -v systemd-analyze >/dev/null 2>&1; then
    if ! systemd-analyze --user verify \
      "$SYSTEMD_STAGE/hermes-gateway.service" \
      "$SYSTEMD_STAGE/hermes-dashboard.service" \
      "$SYSTEMD_STAGE/hermes-bridge.service"; then
      echo "ERROR: generated systemd user units are invalid; existing units were not replaced."
      rollback_pending_systemd_gateway
      cleanup_systemd_stage
      exit 1
    fi
  else
    echo "WARNING: systemd-analyze is unavailable; skipping the unit-file preflight."
  fi

  SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
  SYSTEMD_GATEWAY_DROPIN_DIR="$SYSTEMD_USER_DIR/hermes-gateway.service.d"
  mkdir -p "$SYSTEMD_USER_DIR" "$SYSTEMD_GATEWAY_DROPIN_DIR"
  SYSTEMD_GATEWAY_HAD_UNIT=0
  if [ -f "$SYSTEMD_USER_DIR/hermes-gateway.service" ]; then
    SYSTEMD_GATEWAY_HAD_UNIT=1
    cp -p "$SYSTEMD_USER_DIR/hermes-gateway.service" \
      "$SYSTEMD_STAGE/hermes-gateway.service.previous"
  fi
  SYSTEMD_GATEWAY_HAD_DROPIN=0
  if [ -f "$SYSTEMD_GATEWAY_DROPIN_DIR/10-hermes-console-network.conf" ]; then
    SYSTEMD_GATEWAY_HAD_DROPIN=1
    cp -p "$SYSTEMD_GATEWAY_DROPIN_DIR/10-hermes-console-network.conf" \
      "$SYSTEMD_STAGE/hermes-gateway-network.conf.previous"
  fi
  SYSTEMD_GATEWAY_PENDING=1

  cp "$SYSTEMD_STAGE/hermes-gateway.service" \
    "$SYSTEMD_USER_DIR/hermes-gateway.service.new"
  chmod 644 "$SYSTEMD_USER_DIR/hermes-gateway.service.new"
  mv "$SYSTEMD_USER_DIR/hermes-gateway.service.new" \
    "$SYSTEMD_USER_DIR/hermes-gateway.service"
  cp "$SYSTEMD_STAGE/hermes-gateway.service.d/10-hermes-console-network.conf" \
    "$SYSTEMD_GATEWAY_DROPIN_DIR/10-hermes-console-network.conf.new"
  chmod 644 "$SYSTEMD_GATEWAY_DROPIN_DIR/10-hermes-console-network.conf.new"
  mv "$SYSTEMD_GATEWAY_DROPIN_DIR/10-hermes-console-network.conf.new" \
    "$SYSTEMD_GATEWAY_DROPIN_DIR/10-hermes-console-network.conf"

  for name in dashboard bridge; do
    cp "$SYSTEMD_STAGE/hermes-$name.service" \
      "$SYSTEMD_USER_DIR/hermes-$name.service.new"
    chmod 644 "$SYSTEMD_USER_DIR/hermes-$name.service.new"
    mv "$SYSTEMD_USER_DIR/hermes-$name.service.new" \
      "$SYSTEMD_USER_DIR/hermes-$name.service"
  done
  SYSTEMD_GATEWAY_PENDING=0
  cleanup_systemd_stage
}

install_launchd_job() {
  name="$1"
  label="$2"
  runner="$3"
  run_at_load="$4"
  start_now="$5"
  plist="$HOME/Library/LaunchAgents/$label.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  "$VP" - "$plist" "$label" "$runner" "$HH" "$LOGS/$name.log" "$run_at_load" <<'PY'
import pathlib, plistlib, sys
path, label, runner, workdir, log, run_at_load = sys.argv[1:]
payload = {
    "Label": label,
    "ProgramArguments": [runner],
    "WorkingDirectory": workdir,
    "RunAtLoad": run_at_load == "yes",
    "KeepAlive": {"SuccessfulExit": False},
    "ProcessType": "Background",
    "StandardOutPath": log,
    "StandardErrorPath": log,
}
with pathlib.Path(path).open("wb") as out:
    plistlib.dump(payload, out, sort_keys=True)
PY
  chmod 600 "$plist"
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  launchctl enable "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  [ "$start_now" != "yes" ] || launchctl kickstart -k "gui/$(id -u)/$label"
}

start_named_service() {
  name="$1"
  case "$SERVICE_MANAGER" in
    systemd) systemctl --user restart "hermes-$name" ;;
    launchd)
      case "$name" in
        gateway) label="dev.xpetalab.hermes-console.gateway" ;;
        dashboard) label="dev.xpetalab.hermes-console.dashboard" ;;
        bridge) label="dev.xpetalab.hermes-console.bridge" ;;
      esac
      launchctl kickstart -k "gui/$(id -u)/$label"
      ;;
    portable) "$HELPER" restart "$name" ;;
  esac
}

setup_step "Installing hidden persistent services"

case "$SERVICE_MANAGER" in
  systemd)
    install_verified_systemd_units
    systemctl --user daemon-reload
    systemctl --user enable hermes-gateway hermes-dashboard hermes-bridge >/dev/null 2>&1
    systemctl --user restart hermes-gateway
    systemctl --user restart hermes-bridge
    ;;
  launchd)
    install_launchd_job gateway dev.xpetalab.hermes-console.gateway "$GATEWAY_RUNNER" yes yes
    install_launchd_job dashboard dev.xpetalab.hermes-console.dashboard "$DASHBOARD_RUNNER" yes no
    install_launchd_job bridge dev.xpetalab.hermes-console.bridge "$BRIDGE_RUNNER" yes yes
    ;;
  portable)
    "$HELPER" restart gateway
    "$HELPER" restart bridge
    echo "WARNING: no supported persistent service manager is available."
    echo "Services work in this session but will not survive a reboot until a startup manager is configured."
    ;;
esac

if ! wait_probe gateway http://127.0.0.1:8642 40; then
  service_failure Gateway 8642
fi
echo "Gateway authenticated health OK ($SERVICE_MANAGER)"

if ! wait_probe bridge http://127.0.0.1:9131 40 "$BRIDGE_VERSION"; then
  if [ -f "$BACKUP" ]; then
    mv "$BACKUP" "$TARGET"
    start_named_service bridge >/dev/null 2>&1 || true
  elif [ "$HAD_BRIDGE_TARGET" = 0 ]; then
    rm -f "$TARGET"
  fi
  service_failure Bridge 9131
fi
echo "Mobile Bridge $BRIDGE_VERSION auth + self-update OK ($SERVICE_MANAGER)"

setup_step "Checking Dashboard and credentials"

# Ensure a strong initial Dashboard password through the authenticated Bridge.
# Existing credentials are preserved on repair/update; setup never prints them.
"$HB" dashboard --stop >/dev/null 2>&1 || true
DASH_PASS="$("$VP" -c 'import secrets; print(secrets.token_urlsafe(24))')"
if ! "$VP" - "http://127.0.0.1:9131" "$KEY" "$DASH_PASS" <<'PY'
import json, sys, urllib.request

base, token, password = sys.argv[1:]
headers = {"Authorization": "Bearer " + token, "Accept": "application/json"}
try:
    request = urllib.request.Request(
        base + "/bridge/dashboard/credentials", headers=headers
    )
    with urllib.request.urlopen(request, timeout=65) as response:
        status = response.status
        value = json.loads(response.read(1024 * 1024).decode())
    if status != 200 or value.get("ok") is not True:
        raise RuntimeError("credential endpoint rejected the read")
    if value.get("password_set") is not True:
        body = json.dumps(
            {"username": value.get("username") or "admin", "password": password}
        ).encode()
        request = urllib.request.Request(
            base + "/bridge/dashboard/credentials",
            data=body,
            headers={
                "Authorization": "Bearer " + token,
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=65) as response:
            status = response.status
            value = json.loads(response.read(1024 * 1024).decode())
        if status != 200 or value.get("ok") is not True:
            raise RuntimeError("credential endpoint rejected the change")
except Exception as exc:
    print(
        "Dashboard credential setup failed: " + type(exc).__name__,
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
then
  echo "ERROR: Dashboard authentication could not be configured; no pairing QR will be shown."
  exit 1
fi
start_named_service dashboard >/dev/null 2>&1 || true
if ! wait_probe dashboard http://127.0.0.1:9119 60; then
  service_failure Dashboard 9119
fi
echo "Dashboard health + Gateway state OK ($SERVICE_MANAGER)"

SUDO_READY=0
run_privileged() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    if [ "$SUDO_READY" = 1 ] || sudo -n true >/dev/null 2>&1; then
      SUDO_READY=1
      sudo -n "$@"
      return
    fi
    # `curl ... | sh` occupies stdin with the script itself. Read the sudo
    # password from the controlling terminal so an ordinary interactive user
    # can finish firewall setup in one run. Agents/non-interactive shells still
    # fail closed and receive the exact manual commands below.
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
      echo "Hermes Console needs administrator approval for a private firewall rule." >/dev/tty
      if sudo -v </dev/tty; then
        SUDO_READY=1
        sudo -n "$@"
        return
      fi
    fi
  fi
  return 126
}

ensure_private_firewall() {
  [ "$PAIR_SCHEME" = "http" ] || return 0
  if command -v ufw >/dev/null 2>&1; then
    UFW_ACTIVE=""
    if [ -r /etc/ufw/ufw.conf ] && grep -Eqi '^ENABLED=yes' /etc/ufw/ufw.conf; then
      UFW_ACTIVE=1
    else
      UFW_STATUS="$(run_privileged ufw status 2>/dev/null || true)"
      if printf '%s\n' "$UFW_STATUS" | grep -qi '^Status: active'; then UFW_ACTIVE=1; fi
    fi
    if [ -n "$UFW_ACTIVE" ]; then
      for port in 8642 9119 9131; do
        if ! run_privileged ufw allow from "$FIREWALL_SOURCE" to any port "$port" proto tcp comment 'Hermes Console' >/dev/null; then
          echo "ERROR: UFW is active and a private rule could not be installed."
          echo "Run these commands, then rerun setup:"
          echo "  sudo ufw allow from $FIREWALL_SOURCE to any port 8642 proto tcp"
          echo "  sudo ufw allow from $FIREWALL_SOURCE to any port 9119 proto tcp"
          echo "  sudo ufw allow from $FIREWALL_SOURCE to any port 9131 proto tcp"
          return 1
        fi
      done
      echo "UFW rules installed for private source $FIREWALL_SOURCE"
    fi
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for port in 8642 9119 9131; do
      rule="rule family=ipv4 source address=$FIREWALL_SOURCE port port=$port protocol=tcp accept"
      if ! run_privileged firewall-cmd --permanent --add-rich-rule="$rule" >/dev/null; then
        echo "ERROR: firewalld is active and a private rule could not be installed."
        echo "Add private TCP rules for 8642, 9119 and 9131 from $FIREWALL_SOURCE, then rerun setup."
        return 1
      fi
    done
    run_privileged firewall-cmd --reload >/dev/null
    echo "firewalld rules installed for private source $FIREWALL_SOURCE"
  fi
}

setup_step "Verifying private phone access"

ensure_private_firewall

# Decisive gate: use exactly the URLs encoded in the QR. A loopback-only bind,
# wrong listener, bad token, broken reverse proxy or dead Dashboard stops here.
if ! wait_probe gateway "$GATEWAY_BASE" 12 "" phone; then
  echo "ERROR: Gateway works locally but not through $GATEWAY_BASE."
  echo "Check bind, VPN/LAN routing, reverse proxy and host/cloud firewall."
  exit 1
fi
if ! wait_probe bridge "$BRIDGE_BASE" 12 "$BRIDGE_VERSION" phone; then
  echo "ERROR: Mobile Bridge works locally but not through $BRIDGE_BASE."
  echo "Check routing/proxy rules for /bridge/*."
  exit 1
fi
if ! wait_probe dashboard "$DASHBOARD_BASE" 12 "" phone; then
  echo "ERROR: Dashboard works locally but not through $DASHBOARD_BASE."
  echo "Check routing/proxy rules for /api/status."
  exit 1
fi

setup_step "Generating pairing QR and summary"

printf 'PAIRING_SCHEMA=1\nPAIR_HOST=%s\nPAIR_SCHEME=%s\nPAIR_PORT=%s\nGATEWAY_BASE=%s\nDASHBOARD_BASE=%s\nBRIDGE_BASE=%s\nNETWORK_KIND=%s\nPYTHON_BIN=%s\n' \
  "$HOST" "$PAIR_SCHEME" "$PAIR_PORT" "$GATEWAY_BASE" "$DASHBOARD_BASE" "$BRIDGE_BASE" "$NETWORK_KIND" "$VP" > "$PAIR_ENV"
chmod 600 "$PAIR_ENV"

HTTPS_FLAG=""
[ "$PAIR_SCHEME" != "https" ] || HTTPS_FLAG="1"
LINK="$("$VP" - "$HOST" "$PAIR_PORT" "$KEY" "$HTTPS_FLAG" "$DASHBOARD_BASE" "$BRIDGE_BASE" <<'PY'
import sys, urllib.parse

host, port, token, https, dashboard, bridge = sys.argv[1:]
query = {
    "host": host,
    "port": port,
    "token": token,
    "dashboard": dashboard,
    "bridge": bridge,
    "bridge_token": token,
}
if https:
    query["https"] = "1"
print("hermes://pair?" + urllib.parse.urlencode(query))
PY
)"
echo ""
echo "== SCAN THIS QR WITH HERMES CONSOLE (or copy the link) =="
echo ""
QRPY='import qrcode,sys;q=qrcode.QRCode(border=1);q.add_data(sys.argv[1]);q.make();q.print_ascii(invert=True)'
QR_RENDERED=""
if command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 "$LINK"; then
  QR_RENDERED=1
else
  UV="$HH/bin/uv"
  [ -x "$UV" ] || UV="$(command -v uv 2>/dev/null || true)"
  if [ -n "$UV" ] && "$UV" run --with qrcode python -c "$QRPY" "$LINK" 2>/dev/null; then
    QR_RENDERED=1
  else
    "$VP" -c 'import qrcode' 2>/dev/null || "$VP" -m pip install -q qrcode >/dev/null 2>&1 || true
    if "$VP" -c "$QRPY" "$LINK" 2>/dev/null; then QR_RENDERED=1; fi
  fi
fi
if [ -z "$QR_RENDERED" ]; then
  echo "A QR renderer could not be prepared. Paste the verified link below into Hermes Console."
fi
echo ""
echo "Link: $LINK"
echo ""
echo "All three services passed local and phone-address health/auth checks."
echo "Setup summary:"
echo "  Hermes Agent: ready"
echo "  Gateway: authenticated and reachable"
echo "  Dashboard: ready"
echo "  Mobile Bridge: $BRIDGE_VERSION, authenticated and reachable"
echo "  Service manager: $SERVICE_MANAGER"
echo "  Pairing address: $HOST ($NETWORK_KIND)"
echo "To verify them and show this QR again later:"
echo "  curl -fsSL $REPO_RAW/hermes-pair.sh | sh"
echo "If chat has no model yet, open Dashboard from the app and configure your AI provider/model."
