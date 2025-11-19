#!/bin/sh
# =========================================
# Alpine 256MiB 容器专用
# 一键安装 Xray-core (musl)
# 支持：
#   1. 有域名：自动申请 Let's Encrypt 证书 + 自动写入 acme.sh 续期 crontab
#   2. 无域名：使用自签证书
#   3. 安装后输入 xray → 自动查询节点信息（新增）
# =========================================

CONFIG_DIR="/etc/xray"
CERT_DIR="$CONFIG_DIR/cert"
XRAY_BIN="/usr/local/bin/xray"
INFO_SH="/usr/local/bin/xray-info"

DEFAULT_PORT=443
DEFAULT_FAKE_DOMAIN="kyn.com"

CONNECT_ADDR=$(curl -s ipv4.ip.sb || curl -s ifconfig.me || curl -s ipinfo.io/ip)

# Root check
if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 执行"
    exit 1
fi

echo "当前公网 IP：$CONNECT_ADDR"

# 选择模式
echo "证书模式："
echo "  1) 有域名（自动申请 Let's Encrypt）"
echo "  2) 无域名（自签证书）"
read -p "请选择 [1/2，默认 2]： " MODE
[ -z "$MODE" ] && MODE=2

USE_DOMAIN=0
DOMAIN=""

if [ "$MODE" = "1" ]; then
    USE_DOMAIN=1
    read -p "请输入已解析到本机 IP 的域名： " DOMAIN
    [ -z "$DOMAIN" ] && { echo "域名不能为空"; exit 1; }
    echo "将使用域名：$DOMAIN"
else
    DOMAIN="$DEFAULT_FAKE_DOMAIN"
    echo "无域名模式 → 自签证书"
fi

# 端口输入
read -p "请输入 VLESS 端口 [默认 $DEFAULT_PORT]： " VLESS_PORT
[ -z "$VLESS_PORT" ] && VLESS_PORT=$DEFAULT_PORT

if ! echo "$VLESS_PORT" | grep -Eq '^[0-9]+$'; then
    echo "端口必须是数字"
    exit 1
fi

mkdir -p "$CONFIG_DIR" "$CERT_DIR"

apk update
apk add -q curl openssl jq tar unzip

# 证书逻辑
if [ "$USE_DOMAIN" -eq 1 ]; then
    echo "安装 acme.sh..."
    if [ ! -d "$HOME/.acme.sh" ]; then
        curl https://get.acme.sh | sh
    fi
    export PATH="$HOME/.acme.sh:$PATH"

    echo "申请 Let's Encrypt 证书..."
    $HOME/.acme.sh/acme.sh --issue --standalone -d "$DOMAIN" --force
    $HOME/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
        --key-file "$CERT_DIR/server.key" \
        --fullchain-file "$CERT_DIR/server.crt" \
        --force

    echo "写入 acme.sh 续期计划到 crontab..."
    crontab -l 2>/dev/null | grep -v "acme.sh --cron" >/tmp/cron_tmp || true
    echo "15 3 * * * $HOME/.acme.sh/acme.sh --cron --home $HOME/.acme.sh > /dev/null 2>&1" >>/tmp/cron_tmp
    crontab /tmp/cron_tmp
    rm -f /tmp/cron_tmp

else
    echo "生成自签证书..."
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$CERT_DIR/server.key" \
        -out "$CERT_DIR/server.crt" \
        -subj "/CN=$DOMAIN"
fi

# 下载 Xray
XRAY_VER=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)
ASSET="Xray-linux-64.zip"
curl -L -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/$XRAY_VER/$ASSET"
unzip -o /tmp/xray.zip -d /tmp/
mv /tmp/xray "$XRAY_BIN"
chmod +x "$XRAY_BIN"

# UUID
UUID=$(cat /proc/sys/kernel/random/uuid)

# 写配置
cat >"$CONFIG_DIR/config.json"<<EOF
{
  "log": { "loglevel": "info" },
  "inbounds": [
    {
      "port": $VLESS_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$UUID" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "$DOMAIN",
          "certificates": [
            {
              "certificateFile": "$CERT_DIR/server.crt",
              "keyFile": "$CERT_DIR/server.key"
            }
          ]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF

pkill xray 2>/dev/null || true
nohup "$XRAY_BIN" -config "$CONFIG_DIR/config.json" >/var/log/xray.log 2>&1 &

# =========================================
# 生成 xray-info（新增功能）
# =========================================

cat >"$INFO_SH"<<'EOF'
#!/bin/sh
CONFIG="/etc/xray/config.json"

if ! command -v jq >/dev/null; then
  echo "缺少 jq，请执行：apk add jq"
  exit 1
fi

if [ ! -f "$CONFIG" ]; then
    echo "找不到配置 $CONFIG"
    exit 1
fi

UUID=$(jq -r '.inbounds[0].settings.clients[0].id' $CONFIG)
PORT=$(jq -r '.inbounds[0].port' $CONFIG)
SNI=$(jq -r '.inbounds[0].streamSettings.tlsSettings.serverName' $CONFIG)
CERT=$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile' $CONFIG)

IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me || curl -s ipinfo.io/ip)

if openssl x509 -in "$CERT" -noout -issuer 2>/dev/null | grep -qi "Let's Encrypt"; then
  MODE="有域名 + Let's Encrypt"
  ALLOW=0
  HOST="$SNI"
else
  MODE="无域名 + 自签证书"
  ALLOW=1
  HOST="$IP"
fi

echo "================ Xray 节点信息 ================"
echo "模式：$MODE"
echo "UUID：$UUID"
echo "端口：$PORT"
echo "SNI：$SNI"
echo "IP：$IP"
echo
echo "VLESS 链接："
echo "vless://$UUID@$HOST:$PORT?encryption=none&security=tls&sni=$SNI&allowInsecure=$ALLOW#Xray"
echo
echo "配置：$CONFIG"
echo "日志：/var/log/xray.log"
echo "==============================================="
EOF

chmod +x "$INFO_SH"

# 写入 alias（新增功能）
echo "alias xray='/usr/local/bin/xray-info'" >> /etc/profile

# 输出结果
echo "========================="
if [ "$USE_DOMAIN" -eq 1 ]; then
    echo "当前模式：有域名 + Let's Encrypt"
    echo "VLESS：vless://$UUID@$DOMAIN:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&allowInsecure=0#Xray"
else
    echo "当前模式：无域名 + 自签证书"
    echo "VLESS：vless://$UUID@$CONNECT_ADDR:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&allowInsecure=1#Xray"
fi

echo ""
echo "✔ 二次查询节点：直接输入  →  xray"
echo "✔ Xray 本体路径不变：    →  /usr/local/bin/xray"
echo "========================="
echo "安装完成！"
