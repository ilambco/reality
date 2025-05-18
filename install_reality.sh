#!/bin/bash

XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SERVICE="xray.service"
UUID_DIR="/usr/local/etc/xray/clients"

mkdir -p $UUID_DIR

# 获取公网 IP
get_ip() {
    curl -s ipv4.ip.sb || curl -s ifconfig.me || hostname -I | awk '{print $1}'
}

# 安装 Xray
install_xray() {
    bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install
}

# 安装防火墙
install_firewall() {
    apt update && apt install -y iptables-persistent
    echo "防火墙已安装"
}

# 启动防火墙
start_firewall() {
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT
    netfilter-persistent save
    echo "防火墙规则已启用"
}

# 停止防火墙
stop_firewall() {
    iptables -F
    netfilter-persistent save
    echo "防火墙规则已清空"
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

# 添加 VLESS+REALITY 节点
add_node() {
    read -p "请输入域名或IP（默认使用本机IP）：" DOMAIN
    DOMAIN=${DOMAIN:-$(get_ip)}

    read -p "请输入端口（默认443）: " PORT
    PORT=${PORT:-443}

    read -p "请输入伪装域名（默认itunes.apple.com）: " SERVER_NAME
    SERVER_NAME=${SERVER_NAME:-itunes.apple.com}

    UUID=$(xray uuid)
    PRIVKEY=$(xray x25519 | grep Private | awk '{print $3}')
    PUBKEY=$(xray x25519 | grep Public | awk '{print $3}')
    SHORT_ID=$(openssl rand -hex 8)

    CLIENT_FILE="$UUID_DIR/$UUID.json"
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

# 删除节点
remove_node() {
    echo "现有节点列表："
    ls $UUID_DIR
    read -p "请输入要删除的UUID: " DEL_UUID
    rm -f "$UUID_DIR/$DEL_UUID.json"
    generate_config
    systemctl restart $XRAY_SERVICE
    echo "节点 $DEL_UUID 已删除"
}

# 查看节点
view_node() {
    for file in $UUID_DIR/*.json; do
        [ -e "$file" ] || continue
        UUID=$(jq -r .uuid "$file")
        DOMAIN=$(jq -r .domain "$file")
        PORT=$(jq -r .port "$file")
        SERVER_NAME=$(jq -r .server_name "$file")
        PUBKEY=$(jq -r .public_key "$file")
        echo "vless://$UUID@$DOMAIN:$PORT?type=tcp&security=reality&flow=xtls-rprx-vision&encryption=none&fp=chrome&pbk=$PUBKEY&sni=$SERVER_NAME#VLESS-REALITY"
    done
}

# 生成 config.json
generate_config() {
    PORT=$(jq -r .port $(ls $UUID_DIR/*.json | head -n1))
    SERVER_NAME=$(jq -r .server_name $(ls $UUID_DIR/*.json | head -n1))
    PRIVKEY=$(jq -r .private_key $(ls $UUID_DIR/*.json | head -n1))
    SHORT_ID=$(jq -r .short_id $(ls $UUID_DIR/*.json | head -n1))

    CLIENTS="$(for f in $UUID_DIR/*.json; do jq -c '{id: .uuid, flow: "xtls-rprx-vision"}' "$f"; done | jq -s '.')"
    SERVER_NAMES="[\"$SERVER_NAME\"]"

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
          "serverNames": $SERVER_NAMES,
          "privateKey": "$PRIVKEY",
          "shortIds": ["$SHORT_ID"]
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

# 管理 Xray 服务
start_xray() {
    systemctl start $XRAY_SERVICE
    echo "Xray 已启动"
}

stop_xray() {
    systemctl stop $XRAY_SERVICE
    echo "Xray 已停止"
}

status_xray() {
    systemctl status $XRAY_SERVICE
}

# 主菜单
show_menu() {
    echo "========= Reality 管理脚本 ========="
    echo "1. 安装 Xray"
    echo "2. 添加 VLESS+REALITY 节点"
    echo "3. 删除节点"
    echo "4. 查看节点"
    echo "5. 启动 Xray"
    echo "6. 停止 Xray"
    echo "7. 查看 Xray 状态"
    echo "8. 安装防火墙"
    echo "9. 启动防火墙"
    echo "10. 停止防火墙"
    echo "11. 安装/启用 BBR"
    echo "0. 退出"
    echo "===================================="
}

while true; do
    show_menu
    read -p "请输入选项: " choice
    case $choice in
        1) install_xray;;
        2) add_node;;
        3) remove_node;;
        4) view_node;;
        5) start_xray;;
        6) stop_xray;;
        7) status_xray;;
        8) install_firewall;;
        9) start_firewall;;
        10) stop_firewall;;
        11) install_bbr;;
        0) exit;;
        *) echo "无效选项，请重新输入";;
    esac
    echo ""
done
