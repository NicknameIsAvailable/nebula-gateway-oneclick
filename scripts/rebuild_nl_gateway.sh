#!/usr/bin/env bash
set -euo pipefail

# Rebuild script for NL gateway stack (no homelab dependency):
# 1) Xray VLESS+Reality on TCP 443
# 2) Hysteria2 on UDP 443
# 3) MTProxy (FakeTLS) on TCP 7443
#
# Usage:
#   sudo bash rebuild_nl_gateway.sh
# Optional env overrides:
#   VLESS_UUID=... REALITY_SNI=www.cloudflare.com REALITY_DEST=www.cloudflare.com:443
#   REALITY_PRIVATE_KEY=... (optional; keeps old Reality identity)
#   REALITY_SHORT_ID=...
#   HY2_SNI=www.microsoft.com HY2_PASSWORD=...
#   MTPROXY_TLS_DOMAIN=www.cloudflare.com MTPROXY_SECRET=...
#
# Optional preflight backup environment:
#   SKIP_PREFLIGHT_BACKUP=1
#   RESTIC_REPOSITORY=... RESTIC_PASSWORD=...
#   BORG_REPO=... BORG_PASSPHRASE=...

TOTAL_STEPS=11
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

trap 'log_err "Failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

if [[ "${EUID}" -ne 0 ]]; then
  log_err "Run as root: sudo bash $0"
  exit 1
fi

if [[ ! -d /run/systemd/system ]]; then
  log_err "systemd is required for this script."
  exit 1
fi

VLESS_UUID="${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid)}"
REALITY_SNI="${REALITY_SNI:-www.cloudflare.com}"
REALITY_DEST="${REALITY_DEST:-${REALITY_SNI}:443}"
REALITY_SHORT_ID="${REALITY_SHORT_ID:-$(openssl rand -hex 8)}"
REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-}"

HY2_SNI="${HY2_SNI:-www.microsoft.com}"
HY2_PASSWORD="${HY2_PASSWORD:-$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-20)}"

MTPROXY_TLS_DOMAIN="${MTPROXY_TLS_DOMAIN:-www.cloudflare.com}"
MTPROXY_SECRET="${MTPROXY_SECRET:-$(openssl rand -hex 16)}"

SKIP_PREFLIGHT_BACKUP="${SKIP_PREFLIGHT_BACKUP:-0}"

OS_PRETTY="unknown"
OS_ID="unknown"
OS_VERSION="unknown"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_PRETTY="${PRETTY_NAME:-unknown}"
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-unknown}"
fi

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
    return
  fi
  if command -v dnf >/dev/null 2>&1; then
    echo "dnf"
    return
  fi
  if command -v yum >/dev/null 2>&1; then
    echo "yum"
    return
  fi
  if command -v pacman >/dev/null 2>&1; then
    echo "pacman"
    return
  fi
  if command -v zypper >/dev/null 2>&1; then
    echo "zypper"
    return
  fi
  echo ""
}

PKG_MGR="$(detect_pkg_manager)"
if [[ -z "${PKG_MGR}" ]]; then
  log_err "Unsupported distro: cannot detect package manager."
  exit 1
fi

install_base_packages() {
  case "${PKG_MGR}" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y curl wget jq openssl git ca-certificates make gcc g++ zlib1g-dev libssl-dev
      ;;
    dnf)
      dnf makecache -y
      dnf install -y curl wget jq openssl git ca-certificates make gcc gcc-c++ zlib-devel openssl-devel
      ;;
    yum)
      yum makecache -y
      yum install -y curl wget jq openssl git ca-certificates make gcc gcc-c++ zlib-devel openssl-devel
      ;;
    pacman)
      pacman -Sy --noconfirm --needed curl wget jq openssl git ca-certificates base-devel zlib
      ;;
    zypper)
      zypper --non-interactive refresh
      zypper --non-interactive install curl wget jq openssl git ca-certificates make gcc gcc-c++ zlib-devel libopenssl-devel
      ;;
    *)
      log_err "Unsupported package manager: ${PKG_MGR}"
      exit 1
      ;;
  esac
}

try_preflight_backup() {
  if [[ "${SKIP_PREFLIGHT_BACKUP}" == "1" ]]; then
    log_warn "Preflight backup explicitly skipped (SKIP_PREFLIGHT_BACKUP=1)."
    return
  fi

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"

  if command -v restic >/dev/null 2>&1; then
    if [[ -n "${RESTIC_REPOSITORY:-}" && -n "${RESTIC_PASSWORD:-}" ]]; then
      log_info "Found restic with repository config. Running best-effort backup..."
      set +e
      restic snapshots >/dev/null 2>&1 || restic init >/dev/null 2>&1
      restic backup /etc /usr/local /opt /root --one-file-system --tag "nebula-preflight" --tag "${ts}"
      local rc=$?
      set -e
      if [[ ${rc} -eq 0 ]]; then
        log_ok "Preflight backup completed via restic."
        return
      fi
      log_warn "restic backup failed (rc=${rc}), continuing deployment."
    else
      log_warn "restic installed but RESTIC_REPOSITORY / RESTIC_PASSWORD not set."
    fi
  fi

  if command -v borg >/dev/null 2>&1; then
    if [[ -n "${BORG_REPO:-}" && -n "${BORG_PASSPHRASE:-}" ]]; then
      log_info "Found borg with repository config. Running best-effort backup..."
      set +e
      borg create --stats --compression lz4 "${BORG_REPO}::nebula-preflight-${ts}" /etc /usr/local /opt /root
      local rc=$?
      set -e
      if [[ ${rc} -eq 0 ]]; then
        log_ok "Preflight backup completed via borg."
        return
      fi
      log_warn "borg backup failed (rc=${rc}), continuing deployment."
    else
      log_warn "borg installed but BORG_REPO / BORG_PASSPHRASE not set."
    fi
  fi

  if command -v timeshift >/dev/null 2>&1; then
    log_info "Found timeshift. Running best-effort snapshot..."
    set +e
    timeshift --create --comments "nebula-preflight-${ts}" --tags O
    local rc=$?
    set -e
    if [[ ${rc} -eq 0 ]]; then
      log_ok "Preflight snapshot completed via timeshift."
      return
    fi
    log_warn "timeshift snapshot failed (rc=${rc}), continuing deployment."
  fi

  log_warn "No configured backup tool detected. Skipping preflight backup."
}

extract_reality_private_key() {
  echo "$1" | awk -F': ' '/Private key|PrivateKey/ {print $2; exit}'
}

extract_reality_public_key() {
  echo "$1" | awk -F': ' '/Public key|PublicKey|Password \(PublicKey\)/ {print $2; exit}'
}

log_step "Preflight"
log_info "Detected distro: ${OS_PRETTY} (id=${OS_ID}, version=${OS_VERSION})"
log_info "Package manager: ${PKG_MGR}"
log_info "Script tested on: Ubuntu 24.04 (other distros are best-effort)"
log_ok "Preflight checks passed"

log_step "Preflight backup (best-effort)"
try_preflight_backup

log_step "Installing base packages"
install_base_packages
log_ok "Base packages installed"

log_step "Installing Xray"
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root
XRAY_BIN="$(command -v xray || true)"
if [[ -z "${XRAY_BIN}" ]]; then
  XRAY_BIN="/usr/local/bin/xray"
fi
log_ok "Xray installed (${XRAY_BIN})"

log_step "Generating Reality keys"
if [[ -n "${REALITY_PRIVATE_KEY}" ]]; then
  XRAY_KEYS="$("${XRAY_BIN}" x25519 -i "${REALITY_PRIVATE_KEY}")"
  REALITY_PRIV="${REALITY_PRIVATE_KEY}"
  REALITY_PUB="$(extract_reality_public_key "${XRAY_KEYS}")"
else
  XRAY_KEYS="$("${XRAY_BIN}" x25519)"
  REALITY_PRIV="$(extract_reality_private_key "${XRAY_KEYS}")"
  REALITY_PUB="$(extract_reality_public_key "${XRAY_KEYS}")"
fi

if [[ -z "${REALITY_PRIV}" || -z "${REALITY_PUB}" ]]; then
  log_err "Failed to parse Reality keys from xray output"
  exit 1
fi
log_ok "Reality keys ready"

log_step "Configuring Xray (VLESS+Reality on TCP 443)"
mkdir -p /usr/local/etc/xray
cat >/usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "inbound-443",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${VLESS_UUID}", "email": "vpn@server", "flow": "" }
        ],
        "decryption": "none",
        "fallbacks": []
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": [ "${REALITY_SNI}" ],
          "privateKey": "${REALITY_PRIV}",
          "shortIds": [ "${REALITY_SHORT_ID}" ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ]
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "blocked", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "outboundTag": "blocked", "protocol": [ "bittorrent" ] }
    ]
  }
}
EOF
chmod 644 /usr/local/etc/xray/config.json
systemctl enable xray
systemctl restart xray
systemctl is-active --quiet xray
log_ok "Xray is active"

log_step "Installing Hysteria2"
bash -c "$(curl -fsSL https://get.hy2.sh/)"
log_ok "Hysteria2 installed"

log_step "Configuring Hysteria2 (UDP 443)"
mkdir -p /etc/hysteria
openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
  -keyout /etc/hysteria/server.key \
  -out /etc/hysteria/server.crt \
  -subj "/CN=${HY2_SNI}" >/dev/null 2>&1

cat >/etc/hysteria/config.yaml <<EOF
listen: :443

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: ${HY2_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://${HY2_SNI}
    rewriteHost: true

bandwidth:
  up: 200 mbps
  down: 200 mbps

ignoreClientBandwidth: false
EOF

if id hysteria >/dev/null 2>&1; then
  chown hysteria:hysteria /etc/hysteria/server.key /etc/hysteria/server.crt
fi
chmod 640 /etc/hysteria/server.key /etc/hysteria/server.crt
systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server
systemctl is-active --quiet hysteria-server
log_ok "Hysteria2 is active"

log_step "Installing MTProxy"
if [[ ! -d /opt/MTProxy/.git ]]; then
  rm -rf /opt/MTProxy
  git clone https://github.com/TelegramMessenger/MTProxy /opt/MTProxy
else
  git -C /opt/MTProxy pull --ff-only
fi
make -C /opt/MTProxy
curl -fsSL https://core.telegram.org/getProxySecret -o /opt/MTProxy/proxy-secret
curl -fsSL https://core.telegram.org/getProxyConfig -o /opt/MTProxy/proxy-multi.conf
log_ok "MTProxy binaries/config downloaded"

log_step "Configuring MTProxy (FakeTLS on TCP 7443)"
cat >/etc/systemd/system/mtproxy.service <<EOF
[Unit]
Description=MTProto Proxy
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/MTProxy/objs/bin
ExecStart=/opt/MTProxy/objs/bin/mtproto-proxy -u nobody -p 8888 -H 7443 -D ${MTPROXY_TLS_DOMAIN} -S ${MTPROXY_SECRET} --aes-pwd /opt/MTProxy/proxy-secret /opt/MTProxy/proxy-multi.conf -M 1
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable mtproxy
systemctl restart mtproxy
systemctl is-active --quiet mtproxy
log_ok "MTProxy is active"

log_step "Generating client links and summary"
SERVER_IP="$(curl -4fsSL ifconfig.me || true)"
if [[ -z "${SERVER_IP}" ]]; then
  SERVER_IP="$(hostname -I | awk '{print $1}')"
fi

DOMAIN_HEX="$(printf '%s' "${MTPROXY_TLS_DOMAIN}" | od -An -tx1 | tr -d ' \n')"
MT_TLS_SECRET="ee${MTPROXY_SECRET}${DOMAIN_HEX}"

VLESS_URI="vless://${VLESS_UUID}@${SERVER_IP}:443?encryption=none&security=reality&type=tcp&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SHORT_ID}#nl-reality"
HY2_URI="hysteria2://${HY2_PASSWORD}@${SERVER_IP}:443/?insecure=1&sni=${HY2_SNI}#nl-hysteria2"
MT_TLS_URL="https://t.me/proxy?server=${SERVER_IP}&port=7443&secret=${MT_TLS_SECRET}"
MT_DD_URL="https://t.me/proxy?server=${SERVER_IP}&port=7443&secret=dd${MTPROXY_SECRET}"

SUMMARY_FILE="/root/nl-gateway-secrets-$(date +%Y%m%d-%H%M%S).txt"
cat >"${SUMMARY_FILE}" <<EOF
Server IP: ${SERVER_IP}
Detected distro: ${OS_PRETTY}
Tested baseline: Ubuntu 24.04

=== Xray Reality ===
UUID: ${VLESS_UUID}
Reality SNI: ${REALITY_SNI}
Reality DEST: ${REALITY_DEST}
Reality Public Key: ${REALITY_PUB}
Reality Short ID: ${REALITY_SHORT_ID}
VLESS URI:
${VLESS_URI}

=== Hysteria2 ===
Password: ${HY2_PASSWORD}
SNI: ${HY2_SNI}
URI:
${HY2_URI}

=== MTProxy ===
Domain: ${MTPROXY_TLS_DOMAIN}
Secret: ${MTPROXY_SECRET}
TLS Secret:
${MT_TLS_SECRET}
Telegram TLS URL:
${MT_TLS_URL}
Telegram DD URL:
${MT_DD_URL}
EOF

log_step "Final status"
ss -tulpn | grep -E '(:443\b|:7443\b|xray|hysteria|mtproto)' || true

echo
log_ok "Done. Summary saved to: ${SUMMARY_FILE}"
echo
echo "VLESS URI:"
echo "${VLESS_URI}"
echo
echo "Hysteria2 URI:"
echo "${HY2_URI}"
echo
echo "MTProxy (TLS):"
echo "${MT_TLS_URL}"
echo "MTProxy (DD):"
echo "${MT_DD_URL}"
