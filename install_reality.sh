#!/bin/bash

# Reality+VLESS 安装管理脚本 by ChatGPT
# 依赖：xray、curl、jq、iptables、openssl

XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SERVICE="xray.service"
UUID_DIR="/usr/local/etc/xray/clients"

mkdir -p $UUID_DIR

# 获取公网 IP
get_ip() {
    curl -s ipv4.ip.sb || curl -s ifconfig.me || hostname -I | awk '{print $1}'
}

# 生成 Reality 密钥对
generate_reality_keys() {
    $XRAY_BIN x25519
}

# 安装 Xray
install_xray() {
    bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install
}

# 启动 Xray
start_xray() {
    systemctl start $XRAY_SERVICE
    echo "Xray 已启动"
}

# 停止 Xray
stop_xray() {
    systemctl stop $XRAY_SERVICE
    echo "Xray 已停止"
}

# 查看 Xray 状态
status_xray() {
    systemctl status $XRAY_SERVICE
}

# 安装防火墙（iptables-persistent）
install_firewall() {
    apt update && apt install -y iptables-persistent
    echo "防火墙已安装"
}

# 启用防火墙规则
start_firewall() {
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT
    netfilter-persistent save
    echo "防火墙规则已启用"
}

# 停止防火墙规则
stop_firewall() {
    iptables -F
    netfilter-persistent save
    echo "防火墙规则已清空"
}

# 添加自定义防火墙规则
add_firewall_rule() {
    read -p "请输入要开放的端口: " port
    iptables -A INPUT -p tcp --dport $port -j ACCEPT
    netfilter-persistent save
    echo "已添加防火墙规则，端口: $port"
}

# 查看防火墙规则
status_firewall() {
    iptables -L -n
}

# 安装 BBR
install_bbr() {
    modprobe tcp_bbr
    echo "tcp_bbr" | tee -a /etc/modules-load.d/modules.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
    echo "BBR 已启用"
}

# 查看 BBR 状态
status_bbr() {
    sysctl net.ipv4.tcp_congestion_control
    lsmod | grep bbr
}

# 关闭 BBR
disable_bbr() {
    sed -i '/tcp_bbr/d' /etc/modules-load.d/modules.conf
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    sysctl -p
    echo "BBR 配置已移除"
}

# 添加 VLESS+REALITY 节点
add_node() {
    read -p "请输入域名或IP（默认使用本机IP）：" DOMAIN
    DOMAIN=${DOMAIN:-$(get_ip)}

    read -p "请输入端口（默认443）: " PORT
    PORT=${PORT:-443}

    read -p "请输入伪装域名（默认itunes.apple.com）: " SERVER_NAME
    SERVER_NAME=${SERVER_NAME:-itunes.apple.com}

    UUID=$($XRAY_BIN uuid)
    KEYS=$($XRAY_BIN x25519)
    PRIVKEY=$(echo "$KEYS" | grep Private | awk '{print $3}')
    PUBKEY=$(echo "$KEYS" | grep Public | awk '{print $3}')
    SHORT_ID=$(openssl rand -hex 8)

    CLIENT_FILE="$UUID_DIR/${UUID}_${PORT}.json"
    cat > "$CLIENT_FILE" <<EOF
{
  "uuid": "$UUID",
  "port": $PORT,
  "domain": "$DOMAIN",
  "server_name": "$SERVER_NAME",
  "private_key": "$PRIVKEY",
  "public_key": "$PUBKEY",
  "short_id": "$SHORT_ID"
}
EOF

    echo "节点已添加，UUID: $UUID"
    echo "Reality 公钥: $PUBKEY"

    generate_config
    systemctl restart $XRAY_SERVICE

    echo "vless://$UUID@$DOMAIN:$PORT?type=tcp&security=reality&flow=xtls-rprx-vision&encryption=none&fp=chrome&pbk=$PUBKEY&sni=$SERVER_NAME#VLESS-REALITY"
}

# 删除节点（按端口）
remove_node() {
    echo "现有节点："
    ls $UUID_DIR
    read -p "请输入要删除的端口号: " DEL_PORT
    FILE_TO_DELETE=$(find $UUID_DIR -name "*_${DEL_PORT}.json")
    if [[ -f "$FILE_TO_DELETE" ]]; then
        rm -f "$FILE_TO_DELETE"
        echo "已删除: $FILE_TO_DELETE"
        generate_config
        systemctl restart $XRAY_SERVICE
    else
        echo "未找到对应端口的节点"
    fi
}

# 查看所有节点
view_node() {
    echo "当前节点列表："
    for file in $UUID_DIR/*.json; do
        [ -e "$file" ] || continue
        UUID=$(jq -r .uuid "$file")
        DOMAIN=$(jq -r .domain "$file")
        PORT=$(jq -r .port "$file")
        SERVER_NAME=$(jq -r .server_name "$file")
        PUBKEY=$(jq -r .public_key "$file")
        echo "---"
        echo "端口: $PORT"
        echo "UUID: $UUID"
        echo "vless://$UUID@$DOMAIN:$PORT?type=tcp&security=reality&flow=xtls-rprx-vision&encryption=none&fp=chrome&pbk=$PUBKEY&sni=$SERVER_NAME#VLESS-REALITY"
    done
}

# 生成 Xray 配置文件
generate_config() {
    # 默认使用第一个节点的配置作为通用入站设置
    BASE=$(ls $UUID_DIR/*.json | head -n1)
    PORT=$(jq -r .port "$BASE")
    SERVER_NAME=$(jq -r .server_name "$BASE")
    PRIVKEY=$(jq -r .private_key "$BASE")
    SHORT_IDS=$(for f in $UUID_DIR/*.json; do jq -r .short_id "$f"; done | jq -R -s -c 'split("\n") | map(select(. != ""))')

    CLIENTS=$(for f in $UUID_DIR/*.json; do jq -c '{id: .uuid, flow: "xtls-rprx-vision"}' "$f"; done | jq -s '.')

    cat > $XRAY_CONFIG_PATH <<EOF
{
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": $CLIENTS,
        "decryption": "none",
        "fallbacks": []
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SERVER_NAME:443",
          "xver": 0,
          "serverNames": ["$SERVER_NAME"],
          "privateKey": "$PRIVKEY",
          "shortIds": $SHORT_IDS
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF
}

# 主菜单
show_menu() {
    echo "================ Reality 管理菜单 ================"
    echo "1. 添加 VLESS 节点"
    echo "2. 删除 VLESS 节点"
    echo "3. 查看 VLESS 节点"
    echo "4. Xray 管理"
    echo "5. 防火墙 管理"
    echo "6. BBR 管理"
    echo "0. 退出"
    echo "=================================================="
}

# 子菜单：Xray
xray_menu() {
    echo "--- Xray 管理 ---"
    echo "1. 安装"
    echo "2. 启动"
    echo "3. 停止"
    echo "4. 查看状态"
    read -p "请选择: " sub
    case $sub in
        1) install_xray;;
        2) start_xray;;
        3) stop_xray;;
        4) status_xray;;
        *) echo "无效选项";;
    esac
}

# 子菜单：防火墙
firewall_menu() {
    echo "--- 防火墙管理 ---"
    echo "1. 安装"
    echo "2. 启动规则"
    echo "3. 停止规则"
    echo "4. 添加开放端口"
    echo "5. 查看规则"
    read -p "请选择: " sub
    case $sub in
        1) install_firewall;;
        2) start_firewall;;
        3) stop_firewall;;
        4) add_firewall_rule;;
        5) status_firewall;;
        *) echo "无效选项";;
    esac
}

# 子菜单：BBR
bbr_menu() {
    echo "--- BBR 管理 ---"
    echo "1. 安装/启用"
    echo "2. 关闭"
    echo "3. 查看状态"
    read -p "请选择: " sub
    case $sub in
        1) install_bbr;;
        2) disable_bbr;;
        3) status_bbr;;
        *) echo "无效选项";;
    esac
}

# 主循环
while true; do
    show_menu
    read -p "请输入选项: " choice
    case $choice in
        1) add_node;;
        2) remove_node;;
        3) view_node;;
        4) xray_menu;;
        5) firewall_menu;;
        6) bbr_menu;;
        0) exit;;
        *) echo "无效选项，请重新输入";;
    esac
    echo ""
done
