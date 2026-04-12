#!/usr/bin/env bash
set -euo pipefail

# Rebuild script for NL gateway stack (no homelab dependency):
# 1) Primary transport (choose one):
#    - Xray VLESS+Reality on TCP 443
#    - NaiveProxy on TCP 8443 (+ ACME HTTP-01 on TCP 80)
# 2) Hysteria2 on UDP 443
# 3) MTProxy (FakeTLS) on TCP 7443
#
# Usage:
#   sudo bash rebuild_nl_gateway.sh
# Optional env overrides:
#   SINGLE_TRANSPORT=vless|naiveproxy
#   VLESS_UUID=... REALITY_SNI=www.cloudflare.com REALITY_DEST=www.cloudflare.com:443
#   REALITY_PRIVATE_KEY=... (optional; keeps old Reality identity)
#   REALITY_SHORT_ID=...
#   NAIVE_DOMAIN=... NAIVE_PORT=8443 NAIVE_USER=... NAIVE_PASS=...
#   NAIVE_EMAIL=... NAIVE_UPSTREAM=https://www.cloudflare.com
#   HY2_SNI=www.microsoft.com HY2_PASSWORD=...
#   MTPROXY_TLS_DOMAIN=www.cloudflare.com MTPROXY_SECRET=...
#
# Optional preflight backup environment:
#   SKIP_PREFLIGHT_BACKUP=1
#   RESTIC_REPOSITORY=... RESTIC_PASSWORD=...
#   BORG_REPO=... BORG_PASSPHRASE=...
#
# Optional Happ-compatible feed layer:
#   HAPP_COMPAT_MODE=1
#   HAPP_SUBSCRIPTION_PORT=18080
#   HAPP_SUBSCRIPTION_PATH=/sub/your-token
#   HAPP_PUBLIC_HOST=vpn.example.com
#   HAPP_PUSH_URL=... HAPP_PUSH_AUTH_HEADER=...

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
is_enabled() {
  case "${1,,}" in
    1 | true | yes | y | on) return 0 ;;
    *) return 1 ;;
  esac
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

VLESS_UUID="${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid)}"
REALITY_SNI="${REALITY_SNI:-www.cloudflare.com}"
REALITY_DEST="${REALITY_DEST:-${REALITY_SNI}:443}"
REALITY_SHORT_ID="${REALITY_SHORT_ID:-$(openssl rand -hex 8)}"
REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-}"

SINGLE_TRANSPORT_RAW="${SINGLE_TRANSPORT:-vless}"
SINGLE_TRANSPORT="$(echo "${SINGLE_TRANSPORT_RAW}" | tr '[:upper:]' '[:lower:]')"
case "${SINGLE_TRANSPORT}" in
  naive) SINGLE_TRANSPORT="naiveproxy" ;;
  vless | naiveproxy) ;;
  *)
    log_err "SINGLE_TRANSPORT must be 'vless' or 'naiveproxy' (got: ${SINGLE_TRANSPORT_RAW})"
    exit 1
    ;;
esac

NAIVE_DOMAIN="${NAIVE_DOMAIN:-}"
NAIVE_PORT="${NAIVE_PORT:-8443}"
NAIVE_USER="${NAIVE_USER:-$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-16)}"
NAIVE_PASS="${NAIVE_PASS:-$(openssl rand -base64 36 | tr -d '=+/' | cut -c1-24)}"
NAIVE_EMAIL="${NAIVE_EMAIL:-}"
NAIVE_UPSTREAM="${NAIVE_UPSTREAM:-https://www.cloudflare.com}"

HY2_SNI="${HY2_SNI:-www.microsoft.com}"
HY2_PASSWORD="${HY2_PASSWORD:-$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-20)}"

MTPROXY_TLS_DOMAIN="${MTPROXY_TLS_DOMAIN:-www.cloudflare.com}"
MTPROXY_SECRET="${MTPROXY_SECRET:-$(openssl rand -hex 16)}"

HAPP_COMPAT_MODE="${HAPP_COMPAT_MODE:-0}"
HAPP_PROFILE_NAME="${HAPP_PROFILE_NAME:-nebula-gateway}"
HAPP_SUBSCRIPTION_TOKEN="${HAPP_SUBSCRIPTION_TOKEN:-$(openssl rand -hex 12)}"
HAPP_SUBSCRIPTION_PORT="${HAPP_SUBSCRIPTION_PORT:-18080}"
HAPP_SUBSCRIPTION_PATH="${HAPP_SUBSCRIPTION_PATH:-/sub/${HAPP_SUBSCRIPTION_TOKEN}}"
HAPP_PUBLIC_HOST="${HAPP_PUBLIC_HOST:-}"
HAPP_PUSH_URL="${HAPP_PUSH_URL:-}"
HAPP_PUSH_AUTH_HEADER="${HAPP_PUSH_AUTH_HEADER:-}"

SKIP_PREFLIGHT_BACKUP="${SKIP_PREFLIGHT_BACKUP:-0}"

HAPP_COMPAT_ENABLED=0
if is_enabled "${HAPP_COMPAT_MODE}"; then
  HAPP_COMPAT_ENABLED=1
  TOTAL_STEPS=$((TOTAL_STEPS + 1))
fi

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
      local apt_packages=(curl wget jq openssl git ca-certificates make gcc g++ zlib1g-dev libssl-dev python3)
      if [[ "${SINGLE_TRANSPORT}" == "naiveproxy" ]]; then
        apt_packages+=(golang-go)
      fi
      apt-get install -y "${apt_packages[@]}"
      ;;
    dnf)
      dnf makecache -y
      local dnf_packages=(curl wget jq openssl git ca-certificates make gcc gcc-c++ zlib-devel openssl-devel python3)
      if [[ "${SINGLE_TRANSPORT}" == "naiveproxy" ]]; then
        dnf_packages+=(golang)
      fi
      dnf install -y "${dnf_packages[@]}"
      ;;
    yum)
      yum makecache -y
      local yum_packages=(curl wget jq openssl git ca-certificates make gcc gcc-c++ zlib-devel openssl-devel python3)
      if [[ "${SINGLE_TRANSPORT}" == "naiveproxy" ]]; then
        yum_packages+=(golang)
      fi
      yum install -y "${yum_packages[@]}"
      ;;
    pacman)
      local pacman_packages=(curl wget jq openssl git ca-certificates base-devel zlib python)
      if [[ "${SINGLE_TRANSPORT}" == "naiveproxy" ]]; then
        pacman_packages+=(go)
      fi
      pacman -Sy --noconfirm --needed "${pacman_packages[@]}"
      ;;
    zypper)
      zypper --non-interactive refresh
      local zypper_packages=(curl wget jq openssl git ca-certificates make gcc gcc-c++ zlib-devel libopenssl-devel python3)
      if [[ "${SINGLE_TRANSPORT}" == "naiveproxy" ]]; then
        zypper_packages+=(go)
      fi
      zypper --non-interactive install "${zypper_packages[@]}"
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

normalize_happ_settings() {
  if [[ "${HAPP_SUBSCRIPTION_PATH}" != /* ]]; then
    HAPP_SUBSCRIPTION_PATH="/${HAPP_SUBSCRIPTION_PATH}"
  fi
  if [[ "${HAPP_SUBSCRIPTION_PATH}" == */ ]]; then
    HAPP_SUBSCRIPTION_PATH="${HAPP_SUBSCRIPTION_PATH%/}"
  fi
  if [[ "${HAPP_SUBSCRIPTION_PATH}" == *".."* ]]; then
    log_err "HAPP_SUBSCRIPTION_PATH cannot contain '..'"
    exit 1
  fi
  if ! [[ "${HAPP_SUBSCRIPTION_PORT}" =~ ^[0-9]+$ ]] || ((HAPP_SUBSCRIPTION_PORT < 1 || HAPP_SUBSCRIPTION_PORT > 65535)); then
    log_err "HAPP_SUBSCRIPTION_PORT must be a valid TCP port (1-65535)"
    exit 1
  fi
}

configure_happ_subscription_feed() {
  local base_dir="/opt/nebula-subscription"
  local raw_rel_path="${HAPP_SUBSCRIPTION_PATH}.txt"
  local json_rel_path="${HAPP_SUBSCRIPTION_PATH}.json"
  local raw_file="${base_dir}${raw_rel_path}"
  local json_file="${base_dir}${json_rel_path}"
  local host_for_url="${HAPP_PUBLIC_HOST:-${SERVER_IP}}"
  local updated_at
  local push_payload
  local rc

  mkdir -p "$(dirname "${raw_file}")" "$(dirname "${json_file}")"

  {
    [[ -n "${PRIMARY_URI}" ]] && echo "${PRIMARY_URI}"
    echo "${HY2_URI}"
    echo "${MT_TLS_URL}"
    echo "${MT_DD_URL}"
  } >"${raw_file}"

  updated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n \
    --arg name "${HAPP_PROFILE_NAME}" \
    --arg updated_at "${updated_at}" \
    --arg txt_path "${raw_rel_path}" \
    --arg json_path "${json_rel_path}" \
    --arg primary_uri "${PRIMARY_URI}" \
    --arg primary_type "${PRIMARY_TYPE}" \
    --arg primary_tag "${PRIMARY_TAG}" \
    --arg hy2_uri "${HY2_URI}" \
    --arg mt_tls_url "${MT_TLS_URL}" \
    --arg mt_dd_url "${MT_DD_URL}" \
    '{
      profile: $name,
      updated_at: $updated_at,
      endpoints: {
        txt: $txt_path,
        json: $json_path
      },
      entries: [
        {tag: $primary_tag, type: $primary_type, uri: $primary_uri},
        {tag: "nl-hysteria2", type: "hysteria2", uri: $hy2_uri},
        {tag: "nl-mtproxy-tls", type: "mtproxy", uri: $mt_tls_url},
        {tag: "nl-mtproxy-dd", type: "mtproxy", uri: $mt_dd_url}
      ]
    } | .entries |= map(select(.uri != ""))' >"${json_file}"

  cat >/etc/systemd/system/nebula-subscription.service <<EOF
[Unit]
Description=Nebula subscription feed
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${base_dir}
ExecStart=/usr/bin/env python3 -m http.server ${HAPP_SUBSCRIPTION_PORT} --bind 0.0.0.0 --directory ${base_dir}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable nebula-subscription
  systemctl restart nebula-subscription
  systemctl is-active --quiet nebula-subscription

  HAPP_SUB_TXT_URL="http://${host_for_url}:${HAPP_SUBSCRIPTION_PORT}${raw_rel_path}"
  HAPP_SUB_JSON_URL="http://${host_for_url}:${HAPP_SUBSCRIPTION_PORT}${json_rel_path}"

  if [[ -n "${HAPP_PUSH_URL}" ]]; then
    push_payload="$(jq -n \
      --arg profile "${HAPP_PROFILE_NAME}" \
      --arg txt_url "${HAPP_SUB_TXT_URL}" \
      --arg json_url "${HAPP_SUB_JSON_URL}" \
      --arg primary_uri "${PRIMARY_URI}" \
      --arg primary_type "${PRIMARY_TYPE}" \
      --arg hy2_uri "${HY2_URI}" \
      --arg mt_tls_url "${MT_TLS_URL}" \
      --arg mt_dd_url "${MT_DD_URL}" \
      '{
        profile: $profile,
        subscription: {txt: $txt_url, json: $json_url},
        links: {
          primary: $primary_uri,
          primary_type: $primary_type,
          vless: (if $primary_type == "vless" then $primary_uri else "" end),
          naiveproxy: (if $primary_type == "naiveproxy" then $primary_uri else "" end),
          hysteria2: $hy2_uri,
          mtproxy_tls: $mt_tls_url,
          mtproxy_dd: $mt_dd_url
        }
      }')"

    set +e
    if [[ -n "${HAPP_PUSH_AUTH_HEADER}" ]]; then
      curl -fsSL -X POST "${HAPP_PUSH_URL}" \
        -H "Content-Type: application/json" \
        -H "${HAPP_PUSH_AUTH_HEADER}" \
        -d "${push_payload}" >/dev/null
    else
      curl -fsSL -X POST "${HAPP_PUSH_URL}" \
        -H "Content-Type: application/json" \
        -d "${push_payload}" >/dev/null
    fi
    rc=$?
    set -e

    if [[ ${rc} -eq 0 ]]; then
      log_ok "Happ push webhook delivered."
    else
      log_warn "Happ push webhook failed (rc=${rc}), continuing."
    fi
  fi
}

detect_server_ip() {
  SERVER_IP="$(curl -4fsSL ifconfig.me || true)"
  if [[ -z "${SERVER_IP}" ]]; then
    SERVER_IP="$(hostname -I | awk '{print $1}')"
  fi
}

build_naive_caddy_if_needed() {
  if command -v /usr/local/bin/caddy-naive >/dev/null 2>&1; then
    if /usr/local/bin/caddy-naive list-modules 2>/dev/null | grep -q '^http.handlers.forward_proxy$'; then
      log_info "caddy-naive with forward_proxy module already exists; reusing"
      return
    fi
  fi

  if ! command -v go >/dev/null 2>&1; then
    log_err "Go toolchain is required for naiveproxy build but 'go' is missing"
    exit 1
  fi

  log_info "Building caddy-naive (this may take a few minutes)"
  GOBIN=/usr/local/bin go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
  local build_dir
  build_dir="$(mktemp -d)"
  (
    cd "${build_dir}"
    /usr/local/bin/xcaddy build \
      --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive \
      --output /usr/local/bin/caddy-naive
  )
  rm -rf "${build_dir}"
  chmod 755 /usr/local/bin/caddy-naive
}

configure_naiveproxy_transport() {
  detect_server_ip
  if [[ -z "${NAIVE_DOMAIN}" ]]; then
    NAIVE_DOMAIN="$(openssl rand -hex 5).${SERVER_IP//./-}.sslip.io"
  fi
  if [[ -z "${NAIVE_EMAIL}" ]]; then
    NAIVE_EMAIL="admin@${NAIVE_DOMAIN}"
  fi
  if ! [[ "${NAIVE_PORT}" =~ ^[0-9]+$ ]] || ((NAIVE_PORT < 1 || NAIVE_PORT > 65535)); then
    log_err "NAIVE_PORT must be a valid TCP port (1-65535)"
    exit 1
  fi

  mkdir -p /etc/caddy /var/www/html
  cat >/etc/caddy/Caddyfile-naive <<EOF
{
  admin off
  email ${NAIVE_EMAIL}
  order forward_proxy before file_server
}

:${NAIVE_PORT}, ${NAIVE_DOMAIN}:${NAIVE_PORT} {
  tls ${NAIVE_EMAIL}

  forward_proxy {
    basic_auth ${NAIVE_USER} ${NAIVE_PASS}
    hide_ip
    hide_via
    probe_resistance
  }

  root * /var/www/html
  file_server
}
EOF

  cat >/etc/systemd/system/naiveproxy-caddy.service <<'EOF'
[Unit]
Description=NaiveProxy via Caddy forwardproxy
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
Environment=HOME=/var/lib/caddy
Environment=XDG_DATA_HOME=/var/lib/caddy
Environment=XDG_CONFIG_HOME=/var/lib/caddy
WorkingDirectory=/var/lib/caddy
ExecStartPre=/usr/bin/install -d -m 700 /var/lib/caddy
ExecStart=/usr/local/bin/caddy-naive run --environ --config /etc/caddy/Caddyfile-naive --adapter caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  echo "<!doctype html><html><head><meta charset=\"utf-8\"><title>Welcome</title></head><body><h1>Welcome</h1></body></html>" >/var/www/html/index.html

  systemctl daemon-reload
  systemctl enable naiveproxy-caddy
  systemctl restart naiveproxy-caddy
  systemctl is-active --quiet naiveproxy-caddy

  NAIVE_PROXY_URL="https://${NAIVE_USER}:${NAIVE_PASS}@${NAIVE_DOMAIN}:${NAIVE_PORT}"
}

log_step "Preflight"
log_info "Detected distro: ${OS_PRETTY} (id=${OS_ID}, version=${OS_VERSION})"
log_info "Package manager: ${PKG_MGR}"
log_info "Script tested on: Ubuntu 24.04 (other distros are best-effort)"
log_info "Primary transport: ${SINGLE_TRANSPORT}"
if [[ "${HAPP_COMPAT_ENABLED}" -eq 1 ]]; then
  normalize_happ_settings
  log_info "Happ-compatible mode: enabled"
  log_info "Happ feed path: ${HAPP_SUBSCRIPTION_PATH} (port ${HAPP_SUBSCRIPTION_PORT})"
else
  log_info "Happ-compatible mode: disabled"
fi
log_ok "Preflight checks passed"

log_step "Preflight backup (best-effort)"
try_preflight_backup

log_step "Installing base packages"
install_base_packages
log_ok "Base packages installed"

if [[ "${SINGLE_TRANSPORT}" == "vless" ]]; then
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
else
  log_step "Installing NaiveProxy toolchain"
  build_naive_caddy_if_needed
  log_ok "NaiveProxy toolchain ready"

  log_step "Configuring NaiveProxy (TCP ${NAIVE_PORT})"
  configure_naiveproxy_transport
  log_ok "NaiveProxy is active"

  if systemctl list-unit-files | grep -q '^xray\.service'; then
    systemctl disable --now xray >/dev/null 2>&1 || true
  fi
fi

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
detect_server_ip

DOMAIN_HEX="$(printf '%s' "${MTPROXY_TLS_DOMAIN}" | od -An -tx1 | tr -d ' \n')"
MT_TLS_SECRET="ee${MTPROXY_SECRET}${DOMAIN_HEX}"

VLESS_URI=""
NAIVE_PROXY_URL="${NAIVE_PROXY_URL:-}"
PRIMARY_URI=""
PRIMARY_TYPE=""
PRIMARY_TAG=""
if [[ "${SINGLE_TRANSPORT}" == "vless" ]]; then
  VLESS_URI="vless://${VLESS_UUID}@${SERVER_IP}:443?encryption=none&security=reality&type=tcp&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SHORT_ID}#nl-reality"
  PRIMARY_URI="${VLESS_URI}"
  PRIMARY_TYPE="vless"
  PRIMARY_TAG="nl-reality"
else
  PRIMARY_URI="${NAIVE_PROXY_URL}"
  PRIMARY_TYPE="naiveproxy"
  PRIMARY_TAG="nl-naiveproxy"
fi
HY2_URI="hysteria2://${HY2_PASSWORD}@${SERVER_IP}:443/?insecure=1&sni=${HY2_SNI}#nl-hysteria2"
MT_TLS_URL="https://t.me/proxy?server=${SERVER_IP}&port=7443&secret=${MT_TLS_SECRET}"
MT_DD_URL="https://t.me/proxy?server=${SERVER_IP}&port=7443&secret=dd${MTPROXY_SECRET}"

HAPP_SUB_TXT_URL=""
HAPP_SUB_JSON_URL=""
if [[ "${HAPP_COMPAT_ENABLED}" -eq 1 ]]; then
  log_step "Configuring Happ-compatible subscription feed"
  configure_happ_subscription_feed
  log_ok "Happ-compatible feed is active"
fi

SUMMARY_FILE="/root/nl-gateway-secrets-$(date +%Y%m%d-%H%M%S).txt"
cat >"${SUMMARY_FILE}" <<EOF
Server IP: ${SERVER_IP}
Detected distro: ${OS_PRETTY}
Tested baseline: Ubuntu 24.04

Primary transport: ${SINGLE_TRANSPORT}
EOF

if [[ "${SINGLE_TRANSPORT}" == "vless" ]]; then
  cat >>"${SUMMARY_FILE}" <<EOF

=== Xray Reality ===
UUID: ${VLESS_UUID}
Reality SNI: ${REALITY_SNI}
Reality DEST: ${REALITY_DEST}
Reality Public Key: ${REALITY_PUB}
Reality Short ID: ${REALITY_SHORT_ID}
VLESS URI:
${VLESS_URI}
EOF
else
  cat >>"${SUMMARY_FILE}" <<EOF

=== NaiveProxy ===
Domain: ${NAIVE_DOMAIN}
Port: ${NAIVE_PORT}
Username: ${NAIVE_USER}
Password: ${NAIVE_PASS}
Upstream camouflage: ${NAIVE_UPSTREAM}
Proxy URL:
${NAIVE_PROXY_URL}
EOF
fi

cat >>"${SUMMARY_FILE}" <<EOF

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

if [[ "${HAPP_COMPAT_ENABLED}" -eq 1 ]]; then
  cat >>"${SUMMARY_FILE}" <<EOF

=== Happ-compatible feed ===
Profile name: ${HAPP_PROFILE_NAME}
TXT subscription URL:
${HAPP_SUB_TXT_URL}
JSON subscription URL:
${HAPP_SUB_JSON_URL}
Note:
Open this URL in Happ/custom client subscription import.
If not reachable from internet, open port ${HAPP_SUBSCRIPTION_PORT}/tcp on firewall/provider side.
EOF
fi

log_step "Final status"
STATUS_FILTER='(:443\b|:7443\b|:8443\b|xray|hysteria|mtproto|naiveproxy-caddy|caddy-naive)'
if [[ "${HAPP_COMPAT_ENABLED}" -eq 1 ]]; then
  STATUS_FILTER="${STATUS_FILTER}|(:${HAPP_SUBSCRIPTION_PORT}\\b|nebula-subscription)"
fi
ss -tulpn | grep -E "${STATUS_FILTER}" || true

echo
log_ok "Done. Summary saved to: ${SUMMARY_FILE}"
echo
if [[ "${SINGLE_TRANSPORT}" == "vless" ]]; then
  echo "VLESS URI:"
  echo "${VLESS_URI}"
else
  echo "NaiveProxy URL:"
  echo "${NAIVE_PROXY_URL}"
fi
echo
echo "Hysteria2 URI:"
echo "${HY2_URI}"
echo
echo "MTProxy (TLS):"
echo "${MT_TLS_URL}"
echo "MTProxy (DD):"
echo "${MT_DD_URL}"

if [[ "${HAPP_COMPAT_ENABLED}" -eq 1 ]]; then
  echo
  echo "Happ-compatible TXT subscription:"
  echo "${HAPP_SUB_TXT_URL}"
  echo "Happ-compatible JSON subscription:"
  echo "${HAPP_SUB_JSON_URL}"
fi
