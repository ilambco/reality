#!/bin/bash

CONFIG_DIR="/usr/local/etc/xray/nodes"
MAIN_CONFIG="/usr/local/etc/xray/config.json"
DB_FILE="/usr/local/etc/xray/nodes.db"
XRAY_BIN="/usr/local/bin/xray"

# 创建必要目录和文件
mkdir -p "$CONFIG_DIR"
touch "$DB_FILE"

function check_dependencies() {
  local missing=()
  if ! command -v jq &> /dev/null; then
    missing+=("jq")
  fi
  if ! command -v qrencode &> /dev/null; then
    missing+=("qrencode")
  fi
  if ! command -v openssl &> /dev/null; then
    missing+=("openssl")
  fi
  
  if [ ${#missing[@]} -gt 0 ]; then
    echo "缺少必要的依赖包: ${missing[*]}"
    read -p "是否自动安装这些依赖？[Y/n] " answer
    if [[ "$answer" =~ ^[Yy]?$ ]]; then
      apt-get update
      apt-get install -y "${missing[@]}"
    else
      echo "请手动安装依赖后再运行脚本。"
      exit 1
    fi
  fi
}

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

function install_xray() {
  if [ -f "$XRAY_BIN" ]; then
    echo "Xray 已经安装。"
    return
  fi
  
  echo "正在安装 Xray..."
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  
  if [ ! -f "$XRAY_BIN" ]; then
    echo "Xray 安装失败！"
    exit 1
  fi
  
  systemctl enable xray
  systemctl start xray
  echo "Xray 安装成功并已启动。"
}

function add_node() {
  if [ ! -f "$XRAY_BIN" ]; then
    echo "Xray 未安装，请先安装 Xray。"
    return
  fi
  
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
  systemctl restart xray

  echo "$PORT $UUID $PUBLIC_KEY $SHORT_ID $FAKE_DOMAIN $FLOW $DOMAIN" >> "$DB_FILE"

  LINK="vless://$UUID@$DOMAIN:$PORT?encryption=none&security=reality&sni=$FAKE_DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp"
  [ "$FLOW" == "true" ] && LINK="$LINK&flow=xtls-rprx-vision"
  LINK="$LINK#Reality-$DOMAIN"

  echo -e "\n>>> 节点导入链接:\n$LINK"
  if command -v qrencode &> /dev/null; then
    qrencode -t ANSIUTF8 "$LINK"
  else
    echo "提示: 安装 qrencode 可以显示二维码 (apt-get install qrencode)"
  fi
}

function delete_node() {
  read -p "请输入要删除的端口号: " PORT
  rm -f "$CONFIG_DIR/$PORT.json"
  sed -i "/^$PORT /d" "$DB_FILE"
  merge_configs
  systemctl restart xray
  echo "节点 $PORT 删除成功并释放端口。"
}

function list_nodes() {
  echo -e "\n已添加的节点信息:\n"
  if [ ! -s "$DB_FILE" ]; then
    echo "没有找到任何节点。"
    return
  fi
  cat "$DB_FILE" | while read line; do
    set -- $line
    echo "端口: $1 | UUID: $2 | PublicKey: $3 | ShortID: $4 | SNI: $5 | Flow: $6 | 域名: $7"
  done
}

function manage_firewall() {
  if ! command -v ufw &> /dev/null; then
    echo "UFW 防火墙未安装。"
    read -p "是否要安装并启用 UFW？[Y/n] " answer
    if [[ "$answer" =~ ^[Yy]?$ ]]; then
      apt-get install -y ufw
      ufw enable
      echo "UFW 已安装并启用。"
    else
      return
    fi
  fi

  while true; do
    echo -e "\n===== 防火墙管理 ====="
    echo "1. 开放端口"
    echo "2. 删除端口"
    echo "3. 查看防火墙状态"
    echo "4. 启用防火墙"
    echo "5. 禁用防火墙"
    echo "0. 返回上级菜单"
    echo "======================"
    read -p "请输入选项: " opt
    case $opt in
      1) 
        read -p "请输入要开放的端口号: " port
        ufw allow "$port"
        echo "端口 $port 已开放。"
        ;;
      2) 
        read -p "请输入要删除的端口规则: " port
        ufw delete allow "$port"
        echo "端口 $port 规则已删除。"
        ;;
      3) ufw status ;;
      4) ufw enable ;;
      5) ufw disable ;;
      0) break ;;
      *) echo "无效选项" ;;
    esac
  done
}

function node_management() {
  while true; do
    echo -e "\n===== 节点管理 ====="
    echo "1. 添加节点"
    echo "2. 删除节点"
    echo "3. 查看节点"
    echo "0. 返回上级菜单"
    echo "===================="
    read -p "请输入选项: " opt
    case $opt in
      1) add_node ;;
      2) delete_node ;;
      3) list_nodes ;;
      0) break ;;
      *) echo "无效选项" ;;
    esac
  done
}

function xray_management() {
  while true; do
    echo -e "\n===== Xray 管理 ====="
    echo "1. 安装 Xray"
    echo "2. 启动 Xray"
    echo "3. 停止 Xray"
    echo "4. 重启 Xray"
    echo "5. 查看 Xray 状态"
    echo "0. 返回上级菜单"
    echo "===================="
    read -p "请输入选项: " opt
    case $opt in
      1) install_xray ;;
      2) systemctl start xray && echo "Xray 启动成功" ;;
      3) systemctl stop xray && echo "Xray 已停止" ;;
      4) systemctl restart xray && echo "Xray 重启成功" ;;
      5) systemctl status xray ;;
      0) break ;;
      *) echo "无效选项" ;;
    esac
  done
}

function main_menu() {
  check_dependencies
  while true; do
    echo -e "\n===== Reality 管理菜单 ====="
    echo "1. 节点管理"
    echo "2. Xray 管理"
    echo "3. 防火墙管理"
    echo "0. 退出"
    echo "=============================="
    read -p "请输入选项: " opt
    case $opt in
      1) node_management ;;
      2) xray_management ;;
      3) manage_firewall ;;
      0) exit 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}

# 检查是否以 root 用户运行
if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 用户运行此脚本。"
  exit 1
fi

# 创建快捷命令
if ! grep -q "alias ilamb='bash $(realpath $0)'" ~/.bashrc; then
  echo "alias ilamb='bash $(realpath $0)'" >> ~/.bashrc
  source ~/.bashrc
  echo "已创建快捷命令 'ilamb'，下次登录后可直接使用。"
fi

main_menu
