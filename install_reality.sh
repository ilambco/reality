#!/bin/bash

# 检查是否为root用户
if [ "$(id -u)" != "0" ]; then
   echo "此脚本必须以root身份运行" 1>&2
   exit 1
fi

# 安装必要的依赖
apt update
apt install -y curl wget jq qrencode openssl

# 安装Xray
echo "正在安装Xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 创建必要的目录和文件
CONFIG_DIR="/usr/local/etc/xray/nodes"
MAIN_CONFIG="/usr/local/etc/xray/config.json"
DB_FILE="/usr/local/etc/xray/nodes.db"
XRAY_BIN="/usr/local/bin/xray"

mkdir -p "$CONFIG_DIR"
touch "$DB_FILE"

# 设置默认配置文件
cat > "$MAIN_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

# 创建systemd服务文件（如果不存在）
if [ ! -f "/etc/systemd/system/xray.service" ]; then
    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$XRAY_BIN run -config $MAIN_CONFIG
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xray
fi

# 启动Xray服务
systemctl start xray

# 定义功能函数
function merge_configs() {
  local files=("$CONFIG_DIR"/*.json)
  {
    echo '{ "log": { "loglevel": "warning" }, "inbounds": ['
    for f in "${files[@]}"; do
      cat "$f" | jq '.' 
    done | jq -s 'add | .[]' | jq -s '.'
    echo '], "outbounds": [{ "protocol": "freedom" }] }'
  } > "$MAIN_CONFIG"
}

function restart_xray() {
  systemctl restart xray
}

function add_node() {
  read -p "请输入域名或IP（默认自动获取VPS IP）: " DOMAIN
  DOMAIN=${DOMAIN:-$(curl -s ipv4.ip.sb)}
  read -p "请输入监听端口（例如 10001）: " PORT
  read -p "请输入伪装域名（默认 itunes.apple.com）: " FAKE_DOMAIN
  read -p "是否启用 flow=xtls-rprx-vision? [y/N]: " USE_FLOW

  FAKE_DOMAIN=${FAKE_DOMAIN:-itunes.apple.com}
  [[ "$USE_FLOW" =~ ^[Yy]$ ]] && FLOW=true || FLOW=false

  KEYS=$($XRAY_BIN x25519)
  PRIVATE_KEY=$(echo "$KEYS" | awk '/Private/{print $3}')
  PUBLIC_KEY=$(echo "$KEYS" | awk '/Public/{print $3}')
  SHORT_ID=$(openssl rand -hex 8)
  UUID=$(cat /proc/sys/kernel/random/uuid)

  NODE_CONFIG="$CONFIG_DIR/$PORT.json"
  cat > "$NODE_CONFIG" <<EOF
{
  "port": $PORT,
  "protocol": "vless",
  "settings": {
    "clients": [{
      "id": "$UUID"$( [ "$FLOW" == "true" ] && echo ', "flow": "xtls-rprx-vision"' )
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
}
EOF

  merge_configs
  restart_xray

  echo "$PORT $UUID $PUBLIC_KEY $SHORT_ID $FAKE_DOMAIN $FLOW $DOMAIN" >> "$DB_FILE"

  LINK="vless://$UUID@$DOMAIN:$PORT?encryption=none&security=reality&sni=$FAKE_DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp"
  [ "$FLOW" == "true" ] && LINK="$LINK&flow=xtls-rprx-vision"
  LINK="$LINK#Reality-$DOMAIN"

  echo -e "\n>>> 节点导入链接:\n$LINK"
  if command -v qrencode &> /dev/null; then
    qrencode -t ANSIUTF8 "$LINK"
  else
    echo "注意: qrencode未安装，无法生成二维码"
  fi
}

function delete_node() {
  read -p "请输入要删除的端口号: " PORT
  rm -f "$CONFIG_DIR/$PORT.json"
  sed -i "/^$PORT /d" "$DB_FILE"
  merge_configs
  restart_xray
  echo "节点 $PORT 删除成功并释放端口。"
}

function list_nodes() {
  echo -e "\n已添加的节点信息:\n"
  cat "$DB_FILE" | while read line; do
    set -- $line
    echo "端口: $1 | UUID: $2 | PublicKey: $3 | ShortID: $4 | SNI: $5 | Flow: $6 | 域名: $7"
  done
}

function start_xray() {
  systemctl start xray && echo "Xray 启动成功"
}

function stop_xray() {
  systemctl stop xray && echo "Xray 已停止"
}

function status_xray() {
  systemctl status xray
}

function menu() {
  while true; do
    echo -e "\n===== Reality 管理菜单 ====="
    echo "1. 添加新节点"
    echo "2. 删除节点"
    echo "3. 查看所有节点"
    echo "4. 启动 Xray"
    echo "5. 停止 Xray"
    echo "6. 重启 Xray"
    echo "7. 查看 Xray 状态"
    echo "0. 退出"
    echo "=============================="
    read -p "请输入选项: " opt
    case $opt in
      1) add_node ;;
      2) delete_node ;;
      3) list_nodes ;;
      4) start_xray ;;
      5) stop_xray ;;
      6) restart_xray ;;
      7) status_xray ;;
      0) exit 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}

# 显示欢迎信息
echo "===================================="
echo " Xray Reality 一键安装管理脚本"
echo " 版本: 1.1"
echo " 作者: 根据用户需求定制"
echo "===================================="

# 检查防火墙
if ! command -v ufw &> /dev/null; then
  echo "检测到未安装UFW防火墙，建议安装以增强安全性"
  read -p "是否要安装UFW防火墙? [y/N]: " install_ufw
  if [[ "$install_ufw" =~ ^[Yy]$ ]]; then
    apt install -y ufw
    ufw allow ssh
    ufw enable
    echo "UFW防火墙已安装并启用，SSH端口已放行"
  fi
fi

# 进入主菜单
menu
