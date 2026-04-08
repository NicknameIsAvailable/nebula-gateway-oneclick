#!/usr/bin/env bash
set -euo pipefail

TOTAL_STEPS=7
CURRENT_STEP=0

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_BLUE=$'\033[34m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
else
  C_RESET=""
  C_BOLD=""
  C_BLUE=""
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
fi

log_step() { CURRENT_STEP=$((CURRENT_STEP + 1)); echo; echo "${C_BOLD}${C_BLUE}[${CURRENT_STEP}/${TOTAL_STEPS}] $*${C_RESET}"; }
log_info() { echo "${C_BLUE}[info]${C_RESET} $*"; }
log_ok() { echo "${C_GREEN}[ok]${C_RESET} $*"; }
log_warn() { echo "${C_YELLOW}[warn]${C_RESET} $*"; }
log_err() { echo "${C_RED}[error]${C_RESET} $*"; }

is_enabled() {
  case "${1,,}" in
    1 | true | yes | y | on) return 0 ;;
    *) return 1 ;;
  esac
}

require_env() {
  local key="$1"
  if [[ -z "${!key:-}" ]]; then
    log_err "Required env var is missing: ${key}"
    exit 1
  fi
}

trap 'log_err "Failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

if [[ "${EUID}" -ne 0 ]]; then
  log_err "Run as root: sudo bash $0"
  exit 1
fi

if [[ ! -d /run/systemd/system ]]; then
  log_err "systemd is required for this script."
  exit 1
fi

require_env "CHAIN_EXIT_HOST"
require_env "CHAIN_EXIT_PORT"
require_env "CHAIN_EXIT_UUID"
require_env "CHAIN_REALITY_SERVER_NAME"
require_env "CHAIN_REALITY_PUBLIC_KEY"
require_env "CHAIN_REALITY_SHORT_ID"

CHAIN_EXIT_FLOW="${CHAIN_EXIT_FLOW:-}"
CHAIN_XHTTP_MODE="${CHAIN_XHTTP_MODE:-packet-up}"
CHAIN_XHTTP_PATH="${CHAIN_XHTTP_PATH:-/}"
CHAIN_FULL_TUNNEL="${CHAIN_FULL_TUNNEL:-1}"
CHAIN_KEEP_HOME_CLIENT_UUID="${CHAIN_KEEP_HOME_CLIENT_UUID:-1}"
CHAIN_EXIT_REMARK="${CHAIN_EXIT_REMARK:-}"
CHAIN_EXIT_CLIENT_EMAIL="${CHAIN_EXIT_CLIENT_EMAIL:-}"
CHAIN_EXIT_REALITY_DEST="${CHAIN_EXIT_REALITY_DEST:-}"

if [[ "${CHAIN_XHTTP_PATH}" != /* ]]; then
  CHAIN_XHTTP_PATH="/${CHAIN_XHTTP_PATH}"
fi
if [[ -z "${CHAIN_XHTTP_PATH}" ]]; then
  CHAIN_XHTTP_PATH="/"
fi

if ! [[ "${CHAIN_EXIT_PORT}" =~ ^[0-9]+$ ]] || ((CHAIN_EXIT_PORT < 1 || CHAIN_EXIT_PORT > 65535)); then
  log_err "CHAIN_EXIT_PORT must be a valid TCP port (1-65535)"
  exit 1
fi

if [[ "${CHAIN_XHTTP_MODE}" != "packet-up" ]]; then
  log_warn "Expected CHAIN_XHTTP_MODE=packet-up per design, got '${CHAIN_XHTTP_MODE}'"
fi

CONFIG_PATH="/usr/local/etc/xray/config.json"
if [[ -f /usr/local/etc/xray/config.json ]]; then
  CONFIG_PATH="/usr/local/etc/xray/config.json"
elif [[ -f /etc/xray/config.json ]]; then
  CONFIG_PATH="/etc/xray/config.json"
fi

CONFIG_DIR="$(dirname "${CONFIG_PATH}")"
BACKUP_DIR="${CONFIG_DIR}/backups"
mkdir -p "${CONFIG_DIR}" "${BACKUP_DIR}"

log_step "Preflight"
log_info "Config path: ${CONFIG_PATH}"
log_info "EXIT endpoint: ${CHAIN_EXIT_HOST}:${CHAIN_EXIT_PORT}"
log_info "XHTTP path/mode: ${CHAIN_XHTTP_PATH} / ${CHAIN_XHTTP_MODE}"
if is_enabled "${CHAIN_FULL_TUNNEL}"; then
  log_info "Routing mode: full tunnel"
else
  log_info "Routing mode: split (phone direct, local-socks via chain)"
fi
log_ok "Preflight checks passed"

log_step "Backup existing Xray config"
if [[ -f "${CONFIG_PATH}" ]]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  cp -f "${CONFIG_PATH}" "${BACKUP_DIR}/config-${ts}.json"
  log_ok "Backup saved to ${BACKUP_DIR}/config-${ts}.json"
else
  log_warn "No existing config found, creating a fresh one"
fi

log_step "Building HOME bridge Xray config"
PYTHON_OUTPUT="$(
CONFIG_PATH="${CONFIG_PATH}" \
CHAIN_EXIT_HOST="${CHAIN_EXIT_HOST}" \
CHAIN_EXIT_PORT="${CHAIN_EXIT_PORT}" \
CHAIN_EXIT_UUID="${CHAIN_EXIT_UUID}" \
CHAIN_EXIT_FLOW="${CHAIN_EXIT_FLOW}" \
CHAIN_REALITY_SERVER_NAME="${CHAIN_REALITY_SERVER_NAME}" \
CHAIN_REALITY_PUBLIC_KEY="${CHAIN_REALITY_PUBLIC_KEY}" \
CHAIN_REALITY_SHORT_ID="${CHAIN_REALITY_SHORT_ID}" \
CHAIN_XHTTP_MODE="${CHAIN_XHTTP_MODE}" \
CHAIN_XHTTP_PATH="${CHAIN_XHTTP_PATH}" \
CHAIN_FULL_TUNNEL="${CHAIN_FULL_TUNNEL}" \
CHAIN_KEEP_HOME_CLIENT_UUID="${CHAIN_KEEP_HOME_CLIENT_UUID}" \
python3 - <<'PY'
import json
import os
import secrets
import subprocess
import sys
import uuid

CONFIG_PATH = os.environ["CONFIG_PATH"]

CHAIN_EXIT_HOST = os.environ["CHAIN_EXIT_HOST"]
CHAIN_EXIT_PORT = int(os.environ["CHAIN_EXIT_PORT"])
CHAIN_EXIT_UUID = os.environ["CHAIN_EXIT_UUID"]
CHAIN_EXIT_FLOW = os.environ.get("CHAIN_EXIT_FLOW", "")
CHAIN_REALITY_SERVER_NAME = os.environ["CHAIN_REALITY_SERVER_NAME"]
CHAIN_REALITY_PUBLIC_KEY = os.environ["CHAIN_REALITY_PUBLIC_KEY"]
CHAIN_REALITY_SHORT_ID = os.environ["CHAIN_REALITY_SHORT_ID"]
CHAIN_XHTTP_MODE = os.environ.get("CHAIN_XHTTP_MODE", "packet-up")
CHAIN_XHTTP_PATH = os.environ.get("CHAIN_XHTTP_PATH", "/") or "/"
CHAIN_FULL_TUNNEL = os.environ.get("CHAIN_FULL_TUNNEL", "1").strip().lower() in {"1", "true", "yes", "on", "y"}
CHAIN_KEEP_HOME_CLIENT_UUID = os.environ.get("CHAIN_KEEP_HOME_CLIENT_UUID", "1").strip().lower() in {"1", "true", "yes", "on", "y"}


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except Exception:
        return {}


def find_xray_bin():
    candidates = [
        "/usr/local/bin/xray",
        "/usr/bin/xray",
        "xray",
    ]
    for cand in candidates:
        try:
            proc = subprocess.run([cand, "version"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
        except FileNotFoundError:
            continue
        if proc.returncode == 0:
            return cand
    raise RuntimeError("xray binary not found (required for x25519 key operations)")


def parse_key_output(output):
    private_key = ""
    public_key = ""
    for line in output.splitlines():
        if "Private key:" in line or "PrivateKey:" in line:
            private_key = line.split(":", 1)[1].strip()
        if "Public key:" in line or "PublicKey:" in line or "Password (PublicKey):" in line:
            public_key = line.split(":", 1)[1].strip()
    return private_key, public_key


def derive_public_key(xray_bin, private_key):
    proc = subprocess.run([xray_bin, "x25519", "-i", private_key], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"failed to derive public key: {proc.stdout.strip()}")
    _priv, pub = parse_key_output(proc.stdout)
    if not pub:
        raise RuntimeError("failed to parse public key from xray output")
    return pub


def generate_key_pair(xray_bin):
    proc = subprocess.run([xray_bin, "x25519"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"failed to generate x25519 key pair: {proc.stdout.strip()}")
    priv, pub = parse_key_output(proc.stdout)
    if not priv or not pub:
        raise RuntimeError("failed to parse x25519 key pair from xray output")
    return priv, pub


existing = load_json(CONFIG_PATH)
existing_inbounds = existing.get("inbounds") if isinstance(existing, dict) else []
if not isinstance(existing_inbounds, list):
    existing_inbounds = []

phone_inbound = None
local_socks = None
for inbound in existing_inbounds:
    if not isinstance(inbound, dict):
        continue
    tag = inbound.get("tag")
    if tag == "phone-in":
        phone_inbound = inbound
    elif tag == "local-socks":
        local_socks = inbound

if phone_inbound is None:
    for inbound in existing_inbounds:
        if isinstance(inbound, dict) and inbound.get("protocol") == "vless":
            phone_inbound = inbound
            break

xray_bin = find_xray_bin()

# Keep old phone identity whenever possible.
existing_uuid = ""
existing_priv = ""
existing_short = ""
existing_server_names = []
existing_dest = ""
existing_phone_port = 443

if isinstance(phone_inbound, dict):
    existing_phone_port = int(phone_inbound.get("port") or 443)
    settings = phone_inbound.get("settings") if isinstance(phone_inbound.get("settings"), dict) else {}
    clients = settings.get("clients") if isinstance(settings, dict) else []
    if isinstance(clients, list) and clients and isinstance(clients[0], dict):
        existing_uuid = clients[0].get("id") or ""

    stream = phone_inbound.get("streamSettings") if isinstance(phone_inbound.get("streamSettings"), dict) else {}
    reality = stream.get("realitySettings") if isinstance(stream.get("realitySettings"), dict) else {}

    priv = reality.get("privateKey")
    if isinstance(priv, str):
        existing_priv = priv

    short_ids = reality.get("shortIds") if isinstance(reality.get("shortIds"), list) else []
    for short in short_ids:
        if isinstance(short, str) and short.strip():
            existing_short = short
            break

    server_names = reality.get("serverNames") if isinstance(reality.get("serverNames"), list) else []
    existing_server_names = [s for s in server_names if isinstance(s, str) and s.strip()]

    dest = reality.get("dest")
    if isinstance(dest, str) and dest.strip():
        existing_dest = dest

if CHAIN_KEEP_HOME_CLIENT_UUID and existing_uuid:
    phone_uuid = existing_uuid
else:
    phone_uuid = str(uuid.uuid4())

if existing_priv:
    phone_priv = existing_priv
    phone_pub = derive_public_key(xray_bin, phone_priv)
else:
    phone_priv, phone_pub = generate_key_pair(xray_bin)

phone_short = existing_short or secrets.token_hex(8)
phone_server_names = existing_server_names or [CHAIN_REALITY_SERVER_NAME, "www.cloudflare.com", "www.microsoft.com"]
# Keep stable ordering while removing duplicates.
phone_server_names = list(dict.fromkeys(phone_server_names))
phone_dest = existing_dest or f"{phone_server_names[0]}:443"

socks_port = 1080
if isinstance(local_socks, dict):
    try:
        socks_port = int(local_socks.get("port") or 1080)
    except Exception:
        socks_port = 1080

inbound_tags = ["phone-in", "local-socks"]
routing_rules = [
    {
        "type": "field",
        "outboundTag": "block",
        "protocol": ["bittorrent"],
    },
    {
        "type": "field",
        "inboundTag": inbound_tags,
        "ip": [
            "geoip:private",
            "100.64.0.0/10",
        ],
        "outboundTag": "direct",
    },
    {
        "type": "field",
        "inboundTag": inbound_tags,
        "domain": [
            "domain:localhost",
            "full:localhost",
        ],
        "outboundTag": "direct",
    },
]

if CHAIN_FULL_TUNNEL:
    routing_rules.append(
        {
            "type": "field",
            "inboundTag": inbound_tags,
            "outboundTag": "to-nl",
        }
    )
else:
    routing_rules.extend(
        [
            {
                "type": "field",
                "inboundTag": ["local-socks"],
                "outboundTag": "to-nl",
            },
            {
                "type": "field",
                "inboundTag": ["phone-in"],
                "outboundTag": "direct",
            },
        ]
    )

outbound_user = {
    "id": CHAIN_EXIT_UUID,
    "encryption": "none",
    "flow": CHAIN_EXIT_FLOW,
}

new_config = {
    "log": {"loglevel": "warning"},
    "inbounds": [
        {
            "tag": "phone-in",
            "listen": "0.0.0.0",
            "port": existing_phone_port,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": phone_uuid,
                        "email": "phone@homelab",
                        "flow": "",
                    }
                ],
                "decryption": "none",
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": False,
                    "dest": phone_dest,
                    "xver": 0,
                    "serverNames": phone_server_names,
                    "privateKey": phone_priv,
                    "shortIds": [phone_short],
                },
            },
            "sniffing": {
                "enabled": True,
                "destOverride": ["http", "tls", "quic"],
            },
        },
        {
            "tag": "local-socks",
            "listen": "127.0.0.1",
            "port": socks_port,
            "protocol": "socks",
            "settings": {
                "auth": "noauth",
                "udp": True,
            },
            "sniffing": {
                "enabled": True,
                "destOverride": ["http", "tls", "quic"],
            },
        },
    ],
    "outbounds": [
        {
            "tag": "to-nl",
            "protocol": "vless",
            "settings": {
                "vnext": [
                    {
                        "address": CHAIN_EXIT_HOST,
                        "port": CHAIN_EXIT_PORT,
                        "users": [outbound_user],
                    }
                ]
            },
            "streamSettings": {
                "network": "xhttp",
                "security": "reality",
                "realitySettings": {
                    "serverName": CHAIN_REALITY_SERVER_NAME,
                    "fingerprint": "chrome",
                    "show": False,
                    "publicKey": CHAIN_REALITY_PUBLIC_KEY,
                    "shortId": CHAIN_REALITY_SHORT_ID,
                    "spiderX": "/",
                },
                "xhttpSettings": {
                    "mode": CHAIN_XHTTP_MODE,
                    "path": CHAIN_XHTTP_PATH,
                },
            },
        },
        {
            "tag": "direct",
            "protocol": "freedom",
        },
        {
            "tag": "block",
            "protocol": "blackhole",
        },
    ],
    "routing": {
        "domainStrategy": "AsIs",
        "rules": routing_rules,
    },
}

with open(CONFIG_PATH, "w", encoding="utf-8") as f:
    json.dump(new_config, f, ensure_ascii=False, indent=2)
    f.write("\n")

print(
    json.dumps(
        {
            "config_path": CONFIG_PATH,
            "socks_port": socks_port,
            "phone_uuid": phone_uuid,
            "phone_public_key": phone_pub,
            "phone_short_id": phone_short,
            "phone_server_name": phone_server_names[0],
            "phone_dest": phone_dest,
            "xray_bin": xray_bin,
        },
        ensure_ascii=False,
    )
)
PY
)"

if [[ -z "${PYTHON_OUTPUT}" ]]; then
  log_err "Python config builder returned empty output"
  exit 1
fi

get_json_field() {
  local field="$1"
  FIELD_NAME="${field}" JSON_INPUT="${PYTHON_OUTPUT}" python3 - <<'PY'
import json
import os

field = os.environ["FIELD_NAME"]
obj = json.loads(os.environ["JSON_INPUT"])
print(obj.get(field, ""))
PY
}

SOCKS_PORT="$(get_json_field socks_port)"
PHONE_UUID="$(get_json_field phone_uuid)"
PHONE_PUB="$(get_json_field phone_public_key)"
PHONE_SHORT_ID="$(get_json_field phone_short_id)"
PHONE_SNI="$(get_json_field phone_server_name)"
PHONE_DEST="$(get_json_field phone_dest)"

chmod 644 "${CONFIG_PATH}"
log_ok "Xray config updated at ${CONFIG_PATH}"

log_step "Restarting Xray"
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
systemctl is-active --quiet xray
log_ok "Xray service is active"

log_step "Chain smoke test"
if [[ -z "${SOCKS_PORT}" ]]; then
  SOCKS_PORT="1080"
fi

SOCKS_READY=0
for _ in $(seq 1 20); do
  if ss -ltn | awk '{print $4}' | grep -Eq "(127\\.0\\.0\\.1|\\*|::|\\[::1\\]):${SOCKS_PORT}$"; then
    SOCKS_READY=1
    break
  fi
  sleep 0.5
done

if [[ "${SOCKS_READY}" -ne 1 ]]; then
  log_err "local socks listener did not appear on 127.0.0.1:${SOCKS_PORT} after restart"
  ss -ltnp | grep -E ":${SOCKS_PORT}\\b|xray" || true
  exit 1
fi

PROXY_IFCONFIG="$(curl -4fsS --max-time 15 --proxy "socks5h://127.0.0.1:${SOCKS_PORT}" https://ifconfig.me || true)"
if [[ -z "${PROXY_IFCONFIG}" ]]; then
  log_err "Proxy smoke failed: cannot reach ifconfig.me via local socks on ${SOCKS_PORT}"
  exit 1
fi

DIRECT_IFCONFIG="$(curl -4fsS --max-time 8 https://ifconfig.me || true)"
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 --proxy "socks5h://127.0.0.1:${SOCKS_PORT}" https://www.google.com || true)"
if [[ -z "${HTTP_CODE}" ]]; then
  log_err "Proxy smoke failed: no HTTP response from google.com"
  exit 1
fi

case "${HTTP_CODE}" in
  2*|3*)
    log_ok "Proxy HTTP test succeeded (code ${HTTP_CODE})"
    ;;
  *)
    log_err "Proxy HTTP test failed (code ${HTTP_CODE})"
    exit 1
    ;;
esac

if [[ -n "${DIRECT_IFCONFIG}" && "${DIRECT_IFCONFIG}" == "${PROXY_IFCONFIG}" ]]; then
  log_warn "Direct and proxy egress IP are equal (${PROXY_IFCONFIG}); verify chain routing manually"
else
  log_ok "Proxy egress differs from direct egress (chain likely active)"
fi

log_step "Writing summary"
SUMMARY_FILE="/tmp/home-chain-summary-$(date +%Y%m%d-%H%M%S).txt"
cat >"${SUMMARY_FILE}" <<EOF
HOME chain bridge applied

Config path: ${CONFIG_PATH}
EXIT host: ${CHAIN_EXIT_HOST}
EXIT port: ${CHAIN_EXIT_PORT}
EXIT remark: ${CHAIN_EXIT_REMARK}
EXIT client email: ${CHAIN_EXIT_CLIENT_EMAIL}
EXIT reality dest: ${CHAIN_EXIT_REALITY_DEST}
XHTTP mode/path: ${CHAIN_XHTTP_MODE} ${CHAIN_XHTTP_PATH}
Full tunnel: ${CHAIN_FULL_TUNNEL}
Keep home UUID: ${CHAIN_KEEP_HOME_CLIENT_UUID}

HOME inbound profile
UUID: ${PHONE_UUID}
Reality SNI: ${PHONE_SNI}
Reality DEST: ${PHONE_DEST}
Reality Public Key: ${PHONE_PUB}
Reality Short ID: ${PHONE_SHORT_ID}

Smoke checks
Local socks port: ${SOCKS_PORT}
Proxy ifconfig.me: ${PROXY_IFCONFIG}
Direct ifconfig.me: ${DIRECT_IFCONFIG}
Proxy google.com HTTP code: ${HTTP_CODE}
EOF
chmod 644 "${SUMMARY_FILE}" || true

log_step "Final status"
ss -tulpn | grep -E ':443\b|:1080\b|xray' || true

echo
log_ok "Done. Summary saved to: ${SUMMARY_FILE}"
echo "Proxy ifconfig.me via home local-socks: ${PROXY_IFCONFIG}"
echo "Direct ifconfig.me on home: ${DIRECT_IFCONFIG}"
