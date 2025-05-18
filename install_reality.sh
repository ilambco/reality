#!/bin/bash

# ========= 自定义参数 =========
XRAY_CONFIG_PATH="/usr/local/etc/xray"
XRAY_BIN_PATH="/usr/local/bin/xray"
XRAY_SERVICE_PATH="/etc/systemd/system/xray.service"
MANAGER_CMD="/usr/local/bin/reality-manager"

# ========= 安装部分 =========
read -p "请输入用于连接的域名或IP（默认自动获取VPS IP）: " DOMAIN
[ -z "$DOMAIN" ] && DOMAIN=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)

read -p "请输入监听端口（默认 443）: " PORT
[ -z "$PORT" ] && PORT=443

read -p "请输入伪装域名（默认 itunes.apple.com）: " FAKE_DOMAIN
[ -z "$FAKE_DOMAIN" ] && FAKE_DOMAIN="itunes.apple.com"

UUID=$(cat /proc/sys/kernel/random/uuid)

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

cat > $XRAY_CONFIG_PATH/config.json <<EOF
{
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [
        {
          "id": "$UUID",
          "flow": "xtls-rprx-vision"
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

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

VLESS_URI="vless://$UUID@$DOMAIN:$PORT?encryption=none&security=reality&sni=$FAKE_DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp&flow=xtls-rprx-vision#Reality-$DOMAIN"

echo "$PORT|$UUID|$PUBLIC_KEY|$SHORT_ID|$FAKE_DOMAIN" >> /usr/local/etc/xray/clients.txt

cat > $MANAGER_CMD <<'EOF'
#!/bin/bash

CONFIG="/usr/local/etc/xray/config.json"
SERVICE="xray"
CLIENT_DB="/usr/local/etc/xray/clients.txt"

function menu() {
  clear
  echo "=============== Reality 管理脚本 ==============="
  echo "1. 添加新节点"
  echo "2. 删除节点（按端口）"
  echo "3. 查看所有节点链接"
  echo "4. Xray 服务管理"
  echo "5. 切换 Reality flow 设置"
  echo "0. 退出"
  echo "=============================================="
  read -p "请输入选项: " option

  case $option in
    1) add_client;;
    2) delete_client;;
    3) show_links;;
    4) xray_menu;;
    5) toggle_flow;;
    0) exit;;
    *) echo "无效选项"; sleep 1; menu;;
  esac
}

function add_client() {
  read -p "端口: " port
  read -p "伪装域名: " fake
  uuid=$(cat /proc/sys/kernel/random/uuid)
  pub=$(jq -r ".inbounds[0].streamSettings.realitySettings.privateKey" $CONFIG | xray x25519 -i | grep Public | awk '{print $3}')
  sid=$(openssl rand -hex 8)
  jq ".inbounds[0].port = $port | .inbounds[0].settings.clients = [{\"id\": \"$uuid\", \"flow\": \"xtls-rprx-vision\"}] | .inbounds[0].streamSettings.realitySettings.dest=\"$fake:443\" | .inbounds[0].streamSettings.realitySettings.serverNames=[\"$fake\"] | .inbounds[0].streamSettings.realitySettings.shortIds=[\"$sid\"]" $CONFIG > tmp && mv tmp $CONFIG
  echo "$port|$uuid|$pub|$sid|$fake" >> $CLIENT_DB
  systemctl restart $SERVICE
  echo "✅ 节点已添加"
  echo "vless://$uuid@your.domain:$port?encryption=none&security=reality&sni=$fake&fp=chrome&pbk=$pub&sid=$sid&type=tcp&flow=xtls-rprx-vision#Reality-your.domain"
  read -p "按回车返回..." _
  menu
}

function delete_client() {
  read -p "请输入要删除的端口: " port
  sed -i "/^$port|/d" $CLIENT_DB
  echo "❌ 已从记录中移除节点（请手动检查配置文件）"
  read -p "按回车返回..." _
  menu
}

function show_links() {
  echo "========== 所有 Reality 节点链接 =========="
  while IFS='|' read -r port uuid pub sid fake; do
    echo "vless://$uuid@your.domain:$port?encryption=none&security=reality&sni=$fake&fp=chrome&pbk=$pub&sid=$sid&type=tcp&flow=xtls-rprx-vision#Reality-your.domain"
  done < $CLIENT_DB
  read -p "按回车返回..." _
  menu
}

function xray_menu() {
  echo "========== Xray 服务管理 =========="
  echo "1. 启动 Xray"
  echo "2. 停止 Xray"
  echo "3. 重启 Xray"
  echo "4. 查看状态"
  echo "0. 返回上级菜单"
  read -p "请选择: " sub

  case $sub in
    1) systemctl start $SERVICE && echo "✅ 已启动 Xray";;
    2) systemctl stop $SERVICE && echo "🛑 已停止 Xray";;
    3) systemctl restart $SERVICE && echo "🔄 已重启 Xray";;
    4) systemctl status $SERVICE;;
    0) menu;;
    *) echo "无效选项"; sleep 1; xray_menu;;
  esac
  read -p "按回车返回..." _
  xray_menu
}

function toggle_flow() {
  current=$(jq -r ".inbounds[0].settings.clients[0].flow" $CONFIG)
  if [[ "$current" == "xtls-rprx-vision" ]]; then
    new=""
    echo "🧩 当前为：xtls-rprx-vision -> 将切换为：空"
  else
    new="xtls-rprx-vision"
    echo "🧩 当前为空 -> 将切换为：xtls-rprx-vision"
  fi
  jq ".inbounds[0].settings.clients[0].flow = \"$new\"" $CONFIG > tmp.json && mv tmp.json $CONFIG
  systemctl restart $SERVICE
  echo "✅ Flow 已切换为: ${new:-空}"
  read -p "按回车返回..." _
  menu
}

menu
EOF

chmod +x $MANAGER_CMD

# ===== 输出连接信息 =====
echo -e "\n================ Reality 节点部署成功 ================"
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
echo -e "\n>>> 后续可运行 reality-manager 管理节点和服务"
echo -e "======================================================"
