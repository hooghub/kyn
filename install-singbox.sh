#!/bin/sh
#
# Sing-Box Installer for Alpine Linux
# - VLESS + TLS (Self-Signed Cert)
# - Hysteria2
# - Fixed TLS Domain: kyn.com (NOT required to resolve)
#
# GitHub-friendly version (no color codes, no interactive input)

set -e

WORK_DIR="/etc/sing-box"
BIN_DIR="/usr/local/bin"
CONFIG="${WORK_DIR}/config.json"
DOMAIN="kyn.com"
VLESS_PORT=443
H2_PORT=8443

echo "[INFO] Updating apk packages..."
apk update
apk add --no-cache curl tar ca-certificates jq openssl bash

# Detect architecture
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *) ARCH="amd64" ;;
esac

# Install sing-box
SINGBOX_BIN="${BIN_DIR}/sing-box"
if [ ! -f "$SINGBOX_BIN" ]; then
  echo "[INFO] Downloading sing-box from GitHub..."
  LATEST_URL="$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/SagerNet/sing-box/releases/latest)"
  TAG="$(basename "$LATEST_URL" | sed 's/^v//')"

  TMP=$(mktemp -d)
  cd "$TMP"

  FILE="sing-box-${TAG}-linux-${ARCH}.tar.gz"
  curl -fLO "https://github.com/SagerNet/sing-box/releases/download/v${TAG}/${FILE}"
  tar -xzf "$FILE"

  install -m 755 $(find . -name sing-box -type f) "$SINGBOX_BIN"
  cd /
  rm -rf "$TMP"
fi

# Detect public IP
PUB_IP="$(curl -s ifconfig.me || curl -s ipinfo.io/ip)"
[ -z "$PUB_IP" ] && PUB_IP="0.0.0.0"

# Credentials
UUID=$(cat /proc/sys/kernel/random/uuid)
H2_PASS=$(head -c 16 /dev/urandom | base64 | tr -d '=')

# Certificate
CERT_DIR="${WORK_DIR}/cert"
mkdir -p "$CERT_DIR"

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -subj "/CN=${DOMAIN}" \
  -keyout "${CERT_DIR}/server.key" \
  -out "${CERT_DIR}/server.crt" >/dev/null 2>&1

# Config directory
mkdir -p "$WORK_DIR"

# Write config
cat > "$CONFIG" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": ${VLESS_PORT},
      "users": [ { "id": "${UUID}" } ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "certificates": [
          { "certificate": "${CERT_DIR}/server.crt", "private_key": "${CERT_DIR}/server.key" }
        ]
      }
    },
    {
      "type": "hysteria2",
      "listen": "0.0.0.0",
      "listen_port": ${H2_PORT},
      "users": [ { "password": "${H2_PASS}" } ],
      "masquerade": "https://bing.com",
      "udp": true
    }
  ],
  "outbounds": [
    { "type": "direct" },
    { "type": "block" }
  ]
}
EOF

# Run sing-box
nohup "$SINGBOX_BIN" run -c "$CONFIG" >/var/log/sing-box.log 2>&1 &

# Output URIs
echo ""
echo "===== Generated Nodes ====="
echo ""
echo "VLESS Node:"
echo "vless://${UUID}@${DOMAIN}:${VLESS_PORT}?encryption=none&security=tls&sni=${DOMAIN}&allowInsecure=1#VLESS-kyn"
echo ""
echo "Hysteria2 Node:"
echo "hysteria2://${H2_PASS}@${PUB_IP}:${H2_PORT}?insecure=1&obfs=bing#HY2-kyn"
echo ""
echo "Config: $CONFIG"
echo ""
