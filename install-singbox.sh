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

# 检查是否为 root
if [ "$(id -u)" != "0" ]; then
  echo "请以 root 用户运行此脚本"
  exit 1
fi

# 创建目录
mkdir -p "$CONFIG_DIR" "$CERT_DIR"

# 安装依赖
apk update
apk add -q curl openssl jq

# 生成自签 TLS 证书
echo "生成自签 TLS 证书…"
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" \
  -subj "/CN=$DOMAIN"

# 获取最新 sing-box 版本号
SINGBOX_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
echo "获取 sing-box 最新版本：$SINGBOX_VER"

# 获取该版本的 musl 构建资产名称（自动检测）
ASSET_NAME=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/download/$SINGBOX_VER" \
  | jq -r '.assets[] | select(.name | test("linux.*musl")) | .name' | head -n1)

if [ -z "$ASSET_NAME" ]; then
  echo "错误：未找到 musl 版本的 sing-box 资产。"
  exit 1
fi
echo "找到资产：$ASSET_NAME"

# 下载 musl 二进制
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/$SINGBOX_VER/$ASSET_NAME"
echo "下载：$DOWNLOAD_URL"
wget -q -O "$SINGBOX_BIN" "$DOWNLOAD_URL"
chmod +x "$SINGBOX_BIN"

# 生成 UUID
VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)"

# 生成 sing-box 配置
cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "users": [
        { "id": "$VLESS_UUID" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificates": [
          {
            "certificate": "$CERT_DIR/server.crt",
            "private_key": "$CERT_DIR/server.key"
          }
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

# 重启 / 启动 sing-box
pkill sing-box 2>/dev/null || true
nohup "$SINGBOX_BIN" run -c "$CONFIG_DIR/config.json" >/var/log/sing-box.log 2>&1 &

sleep 2

# 输出节点信息
echo "========================="
echo "VLESS 节点 (自签 TLS)："
echo "vless://$VLESS_UUID@$DOMAIN:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&allowInsecure=1#VLESS-kyn"
echo "配置路径： $CONFIG_DIR/config.json"
echo "日志路径： /var/log/sing-box.log"
echo "========================="
echo "安装并启动完成！"
