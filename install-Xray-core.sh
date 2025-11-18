#!/bin/sh
# =========================================
# Alpine 256MiB 容器专用
# 一键安装 Xray-core (musl)
# 生成 VLESS + 自签 TLS
# 固定端口 34469
# =========================================

CONFIG_DIR="/etc/xray"
CERT_DIR="$CONFIG_DIR/cert"
XRAY_BIN="/usr/local/bin/xray"
VLESS_PORT=34469
DOMAIN="kyn.com"

# 检查 root
if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 执行"
    exit 1
fi

# 创建目录
mkdir -p "$CONFIG_DIR" "$CERT_DIR"

# 安装依赖
apk update
apk add -q curl openssl jq tar

# 生成自签 TLS
echo "生成自签 TLS..."
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" \
  -subj "/CN=$DOMAIN"

# 获取最新 Xray-core 版本
XRAY_VER=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)
echo "最新 Xray-core 版本: $XRAY_VER"

# 下载 musl 版本 Xray-core
ASSET_NAME="Xray-linux-64.zip"  # Alpine 64位 musl版本可用
DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/$XRAY_VER/$ASSET_NAME"
echo "下载 Xray-core: $DOWNLOAD_URL"
curl -L -o /tmp/xray.zip "$DOWNLOAD_URL"
unzip -o /tmp/xray.zip -d /tmp/
mv /tmp/xray /usr/local/bin/xray
chmod +x /usr/local/bin/xray

# 生成 UUID
VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)

# 生成配置文件
cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": { "loglevel": "info" },
  "inbounds": [
    {
      "port": $VLESS_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$VLESS_UUID" }
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

# 停止旧进程并启动 Xray
pkill xray 2>/dev/null || true
nohup /usr/local/bin/xray -config "$CONFIG_DIR/config.json" >/var/log/xray.log 2>&1 &

sleep 2

# 输出 VLESS URI
echo "========================="
echo "VLESS 节点 (自签 TLS)："
echo "vless://$VLESS_UUID@$DOMAIN:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&allowInsecure=1#VLESS-xray"
echo "配置路径： $CONFIG_DIR/config.json"
echo "日志路径： /var/log/xray.log"
echo "========================="
echo "安装完成！"
