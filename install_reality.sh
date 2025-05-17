#!/bin/bash

# ========= 自定义参数（可交互或默认） =========

read -p "请输入用于连接的域名或IP（默认自动获取VPS IP）: " DOMAIN
[ -z "$DOMAIN" ] && DOMAIN=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)

read -p "请输入监听端口（默认 443）: " PORT
[ -z "$PORT" ] && PORT=443

read -p "请输入伪装域名（Reality伪装目标，默认 itunes.apple.com）: " FAKE_DOMAIN
[ -z "$FAKE_DOMAIN" ] && FAKE_DOMAIN="itunes.apple.com"

UUID=$(cat /proc/sys/kernel/random/uuid)
XRAY_CONFIG_PATH="/usr/local/etc/xray"
XRAY_BIN_PATH="/usr/local/bin/xray"
XRAY_SERVICE_PATH="/etc/systemd/system/xray.service"

echo -e "\n>>> 安装 Xray-core 最新版本..."
mkdir -p $XRAY_CONFIG_PATH
mkdir -p /usr/local/bin
curl -Lo /tmp/Xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o /tmp/Xray.zip -d /usr/local/bin
chmod +x /usr/local/bin/xray

echo -e "\n>>> 生成 Reality 密钥对..."
KEY_OUTPUT=$($XRAY_BIN_PATH x25519)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep 'Private' | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep 'Public' | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)

echo -e "\n>>> 写入 Xray 配置文件..."
cat > $XRAY_CONFIG_PATH/config.json <<EOF
{
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [
        {
          "id": "$UUID",
          "flow": ""
        }
      ],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$FAKE_DOMAIN:443",
        "xver": 0,
        "serverNames": [
          "$FAKE_DOMAIN"
        ],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": [
          "$SHORT_ID"
        ]
      }
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "settings": {}
  }]
}
EOF

echo -e "\n>>> 写入 systemd 服务..."
cat > $XRAY_SERVICE_PATH <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=$XRAY_BIN_PATH run -config $XRAY_CONFIG_PATH/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

echo -e "\n>>> 启动 Xray 服务..."
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# ===== 输出连接信息 =====
echo -e "\n================ Reality 节点部署成功 ================"

VLESS_URI="vless://$UUID@$DOMAIN:$PORT?encryption=none&security=reality&sni=$FAKE_DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp&flow=xtls-rprx-vision#Reality-$DOMAIN"

echo -e "协议: VLESS + TCP + Reality"
echo -e "地址: $DOMAIN"
echo -e "端口: $PORT"
echo -e "UUID: $UUID"
echo -e "PublicKey: $PUBLIC_KEY"
echo -e "ShortID: $SHORT_ID"
echo -e "伪装域名: $FAKE_DOMAIN"
echo -e "Reality 指纹: chrome"
echo -e "\n>>> 节点导入链接如下（v2rayN/v2rayNG 直接导入）:"
echo -e "$VLESS_URI"
echo -e "\n======================================================"
