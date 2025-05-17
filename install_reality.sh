#!/bin/bash

# Reality VLESS + TCP 一键部署脚本，支持二维码生成
# 默认不加 flow，支持用户选择启用 flow=xtls-rprx-vision

echo -e "\n========== Reality 节点部署开始 ==========\n"

# 安装依赖
apt update -y
apt install curl unzip qrencode -y

# 用户交互设置
read -p "请输入用于连接的域名或IP（默认自动获取VPS IP）: " DOMAIN
read -p "请输入监听端口（默认 443）: " PORT
read -p "请输入伪装域名（Reality伪装目标，默认 itunes.apple.com）: " FAKE_DOMAIN
read -p "是否启用 flow=xtls-rprx-vision? [y/N]: " USE_FLOW

DOMAIN=${DOMAIN:-$(curl -s ipv4.ip.sb)}
PORT=${PORT:-443}
FAKE_DOMAIN=${FAKE_DOMAIN:-itunes.apple.com}
ENABLE_FLOW=false
[[ "$USE_FLOW" =~ ^[Yy]$ ]] && ENABLE_FLOW=true

# 安装 Xray
echo -e "\n>>> 安装 Xray-core 最新版本..."
XRAY_ZIP="/tmp/Xray.zip"
curl -L -o $XRAY_ZIP https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o $XRAY_ZIP -d /usr/local/bin/
chmod +x /usr/local/bin/xray

# 生成密钥对
echo -e "\n>>> 生成 Reality 密钥对..."
KEYS=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | awk '/Private/{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | awk '/Public/{print $3}')
SHORT_ID=$(openssl rand -hex 8)
UUID=$(cat /proc/sys/kernel/random/uuid)

# 写入配置文件
echo -e "\n>>> 写入 Xray 配置文件..."
mkdir -p /usr/local/etc/xray
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{
        "id": "$UUID",
        "flow": "xtls-rprx-vision"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$FAKE_DOMAIN:443",
        "xver": 0,
        "serverNames": ["$FAKE_DOMAIN"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SHORT_ID"]
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# flow 不启用则删除配置中 flow 项
if ! $ENABLE_FLOW; then
  sed -i '/"flow"/d' /usr/local/etc/xray/config.json
fi

# systemd 启动服务
echo -e "\n>>> 写入 systemd 服务..."
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=always
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# 构造导入链接
LINK="vless://$UUID@$DOMAIN:$PORT?encryption=none&security=reality&sni=$FAKE_DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp"
[[ "$ENABLE_FLOW" == "true" ]] && LINK="$LINK&flow=xtls-rprx-vision"
LINK="$LINK#Reality-$DOMAIN"

# 输出信息
echo -e "\n================ Reality 节点部署成功 ================\n"
echo -e "协议: VLESS + TCP + Reality"
echo -e "地址: $DOMAIN"
echo -e "端口: $PORT"
echo -e "UUID: $UUID"
echo -e "PublicKey: $PUBLIC_KEY"
echo -e "ShortID: $SHORT_ID"
echo -e "伪装域名: $FAKE_DOMAIN"
echo -e "Reality 指纹: chrome"
$ENABLE_FLOW && echo -e "Flow: xtls-rprx-vision" || echo -e "Flow: 未启用"

echo -e "\n>>> 节点导入链接如下（v2rayN/v2rayNG 直接导入）:\n$LINK"

# 生成二维码
echo -e "\n>>> 节点二维码（扫码导入）:\n"
qrencode -t ANSIUTF8 "$LINK"

echo -e "\n======================================================\n"
