#!/bin/sh
# =========================================
# Alpine 256MiB 容器专用
# 一键安装 sing-box (musl)
# 生成 VLESS + 自签 TLS
# 固定端口 34469
# =========================================

CONFIG_DIR="/etc/sing-box"
CERT_DIR="$CONFIG_DIR/cert"
SINGBOX_BIN="/usr/local/bin/sing-box"
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
apk add -q curl openssl jq

# 生成自签 TLS
echo "生成自签 TLS..."
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" \
  -subj "/CN=$DOMAIN"

# 下载 musl 版本 sing-box
echo "下载 sing-box (musl)..."
SINGBOX_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
wget -q -O "$SINGBOX_BIN" "https://github.com/SagerNet/sing-box/releases/download/$SINGBOX_VER/sing-box-${SINGBOX_VER#v}-linux-musl-amd64"
chmod +x "$SINGBOX_BIN"

# 生成 UUID
VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)

# 生成 config.json
cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "users": [ { "id": "$VLESS_UUID" } ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificates": [
          { "certificate": "$CERT_DIR/server.crt", "private_key": "$CERT_DIR/server.key" }
        ]
      }
    }
  ],
  "outbounds": [
    { "type": "direct" },
    { "type": "block" }
  ]
}
EOF

# 停止旧进程并启动 sing-box
pkill sing-box 2>/dev/null
nohup "$SINGBOX_BIN" run -c "$CONFIG_DIR/config.json" >/var/log/sing-box.log 2>&1 &

sleep 2

# 输出节点 URI
echo "========================="
echo "VLESS 节点:"
echo "vless://$VLESS_UUID@$DOMAIN:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&allowInsecure=1#VLESS-kyn"
echo "配置文件: $CONFIG_DIR/config.json"
echo "日志文件: /var/log/sing-box.log"
echo "========================="
echo "安装完成!"
