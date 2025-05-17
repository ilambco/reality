#!/bin/bash

# 检查是否为root用户
if [ "$(id -u)" != "0" ]; then
   echo "此脚本必须以root身份运行" 1>&2
   exit 1
fi

# 定义全局变量
CONFIG_DIR="/usr/local/etc/xray/nodes"
MAIN_CONFIG="/usr/local/etc/xray/config.json"
DB_FILE="/usr/local/etc/xray/nodes.db"
XRAY_BIN="/usr/local/bin/xray"

# 初始化环境
function init_env() {
    mkdir -p "$CONFIG_DIR"
    touch "$DB_FILE"
    
    # 安装必要依赖
    if ! command -v jq &> /dev/null || ! command -v qrencode &> /dev/null; then
        apt update
        apt install -y jq qrencode openssl
    fi
}

# 节点管理函数
function node_management() {
    while true; do
        echo -e "\n===== 节点管理 ====="
        echo "1. 添加节点"
        echo "2. 删除节点"
        echo "3. 查看节点"
        echo "0. 返回主菜单"
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

# Xray管理函数
function xray_management() {
    while true; do
        echo -e "\n===== Xray管理 ====="
        echo "1. 启动Xray"
        echo "2. 停止Xray"
        echo "3. 重启Xray"
        echo "4. 查看状态"
        echo "0. 返回主菜单"
        echo "===================="
        read -p "请输入选项: " opt
        
        case $opt in
            1) systemctl start xray && echo "Xray已启动" ;;
            2) systemctl stop xray && echo "Xray已停止" ;;
            3) systemctl restart xray && echo "Xray已重启" ;;
            4) systemctl status xray ;;
            0) break ;;
            *) echo "无效选项" ;;
        esac
    done
}

# 防火墙管理函数
function firewall_management() {
    while true; do
        echo -e "\n===== 防火墙管理 ====="
        echo "1. 开放端口"
        echo "2. 删除端口"
        echo "3. 查看开放端口"
        echo "4. 安装UFW防火墙"
        echo "5. 启用防火墙"
        echo "6. 禁用防火墙"
        echo "7. 防火墙状态"
        echo "0. 返回主菜单"
        echo "======================="
        read -p "请输入选项: " opt
        
        case $opt in
            1) 
                read -p "请输入要开放的端口(如: 9009): " port
                ufw allow $port/tcp
                echo "端口 $port 已开放"
                ;;
            2) 
                read -p "请输入要删除的端口(如: 9009): " port
                ufw delete allow $port/tcp
                echo "端口 $port 规则已删除"
                ;;
            3) ufw status numbered ;;
            4) 
                apt install -y ufw
                ufw allow ssh
                echo "UFW已安装，SSH端口已放行"
                ;;
            5) 
                ufw enable
                echo "防火墙已启用"
                ;;
            6) 
                ufw disable
                echo "防火墙已禁用"
                ;;
            7) ufw status ;;
            0) break ;;
            *) echo "无效选项" ;;
        esac
    done
}

# 添加节点函数
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
    systemctl restart xray

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

# 其他原有函数保持不变 (delete_node, list_nodes, merge_configs等)
# [...]

# 主菜单
function main_menu() {
    init_env
    
    while true; do
        echo -e "\n===== Reality管理主菜单 ====="
        echo "1. 节点管理"
        echo "2. Xray管理"
        echo "3. 防火墙管理"
        echo "0. 退出"
        echo "============================="
        read -p "请输入选项: " opt
        
        case $opt in
            1) node_management ;;
            2) xray_management ;;
            3) firewall_management ;;
            0) exit 0 ;;
            *) echo "无效选项" ;;
        esac
    done
}

# 创建系统命令
function install_command() {
    if [ ! -f "/usr/local/bin/reality" ]; then
        cp "$0" /usr/local/bin/reality
        chmod +x /usr/local/bin/reality
        echo "命令 'reality' 已安装，现在可以直接在终端输入 reality 来运行本程序"
    fi
}

# 安装命令并启动
install_command
main_menu
