#!/bin/sh
# =========================================
# Alpine 256MiB 容器专用
# 一键安装 Xray-core (musl)
# 支持：
#   1. 有域名：自动申请 Let's Encrypt 证书
#   2. 无域名：使用自签 TLS（沿用原来的逻辑）
# =========================================

CONFIG_DIR="/etc/xray"
CERT_DIR="$CONFIG_DIR/cert"
XRAY_BIN="/usr/local/bin/xray"

# 默认端口
DEFAULT_PORT=443

# 无域名模式下使用的伪域名（只用来自签和 SNI，可以按需修改）
DEFAULT_FAKE_DOMAIN="kyn.com"

# 客户端实际连接用的公网 IP（请改成你的真实 IP，如有需要）
CONNECT_ADDR=$(curl -s ipv4.ip.sb || curl -s ifconfig.me || curl -s ipinfo.io/ip)

# 检查 root
if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 执行"
    exit 1
fi

echo "===================================="
echo "当前检测到的公网 IP：$CONNECT_ADDR"
echo "如与真实 IP 不符，请自行修改脚本中的 CONNECT_ADDR 变量。"
echo "===================================="

# 选择是否使用域名
echo "证书/域名模式选择："
echo "  1) 使用已经解析到本机的域名（自动申请 Let's Encrypt 证书）"
echo "  2) 无域名（使用自签证书，沿用原来的逻辑）"
read -p "请选择 [1/2，默认 2]: " MODE

if [ -z "$MODE" ]; then
    MODE=2
fi

USE_DOMAIN=0
DOMAIN=""

case "$MODE" in
    1)
        USE_DOMAIN=1
        echo "选择：有域名模式（Let's Encrypt）"
        read -p "请输入已经解析到本机的域名（如：example.com）： " DOMAIN
        if [ -z "$DOMAIN" ]; then
            echo "域名不能为空"
            exit 1
        fi
        echo "使用域名：$DOMAIN"
        echo "请确保该域名已解析到本机 IP：$CONNECT_ADDR"
        ;;
    2)
        USE_DOMAIN=0
        DOMAIN="$DEFAULT_FAKE_DOMAIN"
        echo "选择：无域名模式（自签证书）"
        echo "将使用伪域名：$DOMAIN 生成自签证书和 SNI"
        ;;
    *)
        echo "无效选项：$MODE"
        exit 1
        ;;
esac

echo "===================================="
echo "VLESS 端口设置"
read -p "请输入 VLESS 端口 [默认 ${DEFAULT_PORT}]： " VLESS_PORT

# 如果直接回车，使用默认端口
if [ -z "$VLESS_PORT" ]; then
    VLESS_PORT=$DEFAULT_PORT
fi

# 简单端口校验：必须是 1-65535 的数字
if ! echo "$VLESS_PORT" | grep -Eq '^[0-9]+$'; then
    echo "端口必须是数字，当前输入：$VLESS_PORT"
    exit 1
fi

if [ "$VLESS_PORT" -lt 1 ] || [ "$VLESS_PORT" -gt 65535 ]; then
    echo "端口必须在 1-65535 之间，当前输入：$VLESS_PORT"
    exit 1
fi

echo "使用端口：$VLESS_PORT"
echo "===================================="

# 创建目录
mkdir -p "$CONFIG_DIR" "$CERT_DIR"

# 安装依赖（增加 unzip）
apk update
apk add -q curl openssl jq tar unzip

# 如果是有域名模式，安装 acme.sh 并申请证书
if [ "$USE_DOMAIN" -eq 1 ]; then
    echo "===================================="
    echo "安装 / 更新 acme.sh，用于申请 Let's Encrypt 证书..."
    if [ ! -d "$HOME/.acme.sh" ]; then
        curl https://get.acme.sh | sh
    else
        $HOME/.acme.sh/acme.sh --upgrade
    fi

    # 确保 acme.sh 在 PATH 中
    export PATH="$HOME/.acme.sh:$PATH"

    echo "使用 standalone 模式在 80 端口签发证书，请确保 80 端口未被占用。"
    echo "开始为域名 $DOMAIN 申请证书..."
    $HOME/.acme.sh/acme.sh --issue --standalone -d "$DOMAIN" --force

    if [ "$?" -ne 0 ]; then
        echo "证书申请失败，请检查域名解析和防火墙。"
        exit 1
    fi

    echo "安装证书到 $CERT_DIR ..."
    $HOME/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
        --key-file       "$CERT_DIR/server.key" \
        --fullchain-file "$CERT_DIR/server.crt" \
        --force

    if [ "$?" -ne 0 ]; then
        echo "证书安装失败。"
        exit 1
    fi

    echo "Let's Encrypt 证书申请并安装成功。"

else
    # 无域名模式：生成自签 TLS
    echo "===================================="
    echo "无域名模式，生成自签 TLS 证书（CN=$DOMAIN）..."
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" \
      -subj "/CN=$DOMAIN"
fi

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

echo "========================="
if [ "$USE_DOMAIN" -eq 1 ]; then
    echo "当前为【有域名 + Let's Encrypt】模式"
    echo "建议客户端直接使用域名连接（host = 域名）："
    echo "vless://$VLESS_UUID@$DOMAIN:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&allowInsecure=0#VLESS-xray-$DOMAIN"
else
    echo "当前为【无域名 + 自签证书】模式"
    echo "VLESS 节点 (公网 IP + 伪域名 SNI)："
    echo "vless://$VLESS_UUID@$CONNECT_ADDR:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&allowInsecure=1#VLESS-xray-selfsigned"
fi
echo "配置路径： $CONFIG_DIR/config.json"
echo "日志路径： /var/log/xray.log"
echo "========================="
echo "安装完成！"
