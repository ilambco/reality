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

# ========= 安装 Xray =========
echo -e "\n>>> 安装 Xray-core 最新版本..."
mkdir -p $XRAY_CONFIG_PATH
mkdir -p /usr/local/bin
curl -Lo /tmp/Xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o /tmp/Xray.zip -d /usr/local/bin
chmod +x /usr/local/bin/xray

# ========= 生成 Reality 密钥对 =========
echo -e "\n>>> 生成 Reality 密钥对..."
KEY_OUTPUT=$($XRAY_BIN_PATH x25519)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep 'Private' | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep 'Public' | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)

# ========= 写入配置 =========
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
        "serverNames": ["$FAKE_DOMAIN"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SHORT_ID"]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom","settings": {}}]
}
EOF

# ========= 写入服务 =========
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

# ========= 启动服务 =========
echo -e "\n>>> 启动 Xray 服务..."
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# ========= 输出连接信息 =========
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

# ========= 安装管理脚本 =========
echo -e "\n>>> 安装管理脚本 reality-manager ..."
cat > /usr/local/bin/reality-manager <<'MANAGER'
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
SERVICE="xray"
function menu() {
  clear
  echo "=============== Reality 管理脚本 ==============="
  echo "1. 节点管理"
  echo "2. Xray 服务管理"
  echo "3. 防火墙管理"
  echo "4. 切换 Reality flow 设置"
  echo "0. 退出"
  echo "=============================================="
  read -p "请输入选项: " option
  case $option in
    1) node_menu;;
    2) xray_menu;;
    3) firewall_menu;;
    4) toggle_flow;;
    0) exit;;
    *) echo "无效选项"; sleep 1; menu;;
  esac
}
function node_menu() {
  echo "=========== 节点管理 ==========="
  echo "1. 添加节点 (UUID)"
  echo "2. 删除所有节点"
  echo "3. 查看当前节点"
  echo "0. 返回上级菜单"
  read -p "请选择: " sub
  case $sub in
    1)
      read -p "请输入新的 UUID: " uuid
      jq ".inbounds[0].settings.clients = [{\"id\": \"$uuid\", \"flow\": \"\"}]" $CONFIG > tmp.json && mv tmp.json $CONFIG
      systemctl restart $SERVICE
      echo "✅ 节点已更新并重启 Xray"
      ;;
    2)
      jq ".inbounds[0].settings.clients = []" $CONFIG > tmp.json && mv tmp.json $CONFIG
      systemctl restart $SERVICE
      echo "❌ 所有节点已删除"
      ;;
    3)
      echo "当前 UUID 列表："
      jq -r ".inbounds[0].settings.clients[] | .id" $CONFIG
      ;;
    0) menu;;
    *) echo "无效选项"; sleep 1; node_menu;;
  esac
  read -p "按回车返回..." _
  node_menu
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
function firewall_menu() {
  read -p "请输入要放行的端口号: " port
  firewall-cmd --permanent --add-port=${port}/tcp
  firewall-cmd --permanent --add-port=${port}/udp
  firewall-cmd --reload
  echo "✅ 已放行端口 $port (TCP/UDP)"
  read -p "按回车返回..." _
  menu
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
if ! command -v jq &>/dev/null; then
  echo "❌ 依赖 jq 未安装，正在安装..."
  apt install -y jq || yum install -y jq || { echo "安装 jq 失败"; exit 1; }
fi
menu
MANAGER
chmod +x /usr/local/bin/reality-manager

echo -e "\n✅ 管理脚本已安装，使用方式：reality-manager"
echo -e "你可以随时输入 reality-manager 启动管理菜单"
