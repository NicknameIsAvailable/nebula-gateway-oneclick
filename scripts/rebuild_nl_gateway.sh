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
#   REALITY_PRIVATE_KEY=... (optional; if set, keeps old Reality identity)
#   REALITY_SHORT_ID=... HY2_SNI=www.microsoft.com HY2_PASSWORD=...
#   MTPROXY_TLS_DOMAIN=www.cloudflare.com MTPROXY_SECRET=...

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

VLESS_UUID="${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid)}"
REALITY_SNI="${REALITY_SNI:-www.cloudflare.com}"
REALITY_DEST="${REALITY_DEST:-${REALITY_SNI}:443}"
REALITY_SHORT_ID="${REALITY_SHORT_ID:-$(openssl rand -hex 8)}"
REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-}"

HY2_SNI="${HY2_SNI:-www.microsoft.com}"
HY2_PASSWORD="${HY2_PASSWORD:-$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-20)}"

MTPROXY_TLS_DOMAIN="${MTPROXY_TLS_DOMAIN:-www.cloudflare.com}"
MTPROXY_SECRET="${MTPROXY_SECRET:-$(openssl rand -hex 16)}"

echo "[1/8] Installing base packages..."
apt-get update -y
apt-get install -y curl wget jq openssl git build-essential libssl-dev zlib1g-dev ca-certificates xxd

echo "[2/8] Installing Xray..."
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root

echo "[3/8] Generating Reality keys..."
if [[ -n "${REALITY_PRIVATE_KEY}" ]]; then
  XRAY_KEYS="$(/usr/local/bin/xray x25519 -i "${REALITY_PRIVATE_KEY}")"
  REALITY_PRIV="${REALITY_PRIVATE_KEY}"
  REALITY_PUB="$(echo "${XRAY_KEYS}" | awk '/Public key:/ {print $3}')"
else
  XRAY_KEYS="$(/usr/local/bin/xray x25519)"
  REALITY_PRIV="$(echo "${XRAY_KEYS}" | awk '/Private key:/ {print $3}')"
  REALITY_PUB="$(echo "${XRAY_KEYS}" | awk '/Public key:/ {print $3}')"
fi

if [[ -z "${REALITY_PRIV}" || -z "${REALITY_PUB}" ]]; then
  echo "Failed to parse Reality keys from xray output"
  exit 1
fi

echo "[4/8] Writing Xray config..."
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

echo "[5/8] Installing & configuring Hysteria2..."
bash -c "$(curl -fsSL https://get.hy2.sh/)"

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

echo "[6/8] Installing & configuring MTProxy..."
if [[ ! -d /opt/MTProxy/.git ]]; then
  rm -rf /opt/MTProxy
  git clone https://github.com/TelegramMessenger/MTProxy /opt/MTProxy
else
  git -C /opt/MTProxy pull --ff-only
fi

make -C /opt/MTProxy
curl -fsSL https://core.telegram.org/getProxySecret -o /opt/MTProxy/proxy-secret
curl -fsSL https://core.telegram.org/getProxyConfig -o /opt/MTProxy/proxy-multi.conf

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

echo "[7/8] Detecting public IPv4..."
SERVER_IP="$(curl -4fsSL ifconfig.me || true)"
if [[ -z "${SERVER_IP}" ]]; then
  SERVER_IP="$(hostname -I | awk '{print $1}')"
fi

DOMAIN_HEX="$(printf '%s' "${MTPROXY_TLS_DOMAIN}" | xxd -p -c 256)"
MT_TLS_SECRET="ee${MTPROXY_SECRET}${DOMAIN_HEX}"

VLESS_URI="vless://${VLESS_UUID}@${SERVER_IP}:443?encryption=none&security=reality&type=tcp&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SHORT_ID}#nl-reality"
HY2_URI="hysteria2://${HY2_PASSWORD}@${SERVER_IP}:443/?insecure=1&sni=${HY2_SNI}#nl-hysteria2"
MT_TLS_URL="https://t.me/proxy?server=${SERVER_IP}&port=7443&secret=${MT_TLS_SECRET}"
MT_DD_URL="https://t.me/proxy?server=${SERVER_IP}&port=7443&secret=dd${MTPROXY_SECRET}"

echo "[8/8] Writing summary..."
SUMMARY_FILE="/root/nl-gateway-secrets-$(date +%Y%m%d-%H%M%S).txt"
cat >"${SUMMARY_FILE}" <<EOF
Server IP: ${SERVER_IP}

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

echo
echo "Done. Summary saved to: ${SUMMARY_FILE}"
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
