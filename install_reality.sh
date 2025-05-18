#!/bin/bash

XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SERVICE="xray.service"
UUID_DIR="/usr/local/etc/xray/clients"

mkdir -p $UUID_DIR

get_ip() {
    curl -s ipv4.ip.sb || curl -s ifconfig.me || hostname -I | awk '{print $1}'
}

install_xray() {
    bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install
}

install_firewall() {
    apt update && apt install -y iptables-persistent
    echo "防火墙已安装"
}

start_firewall() {
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT
    netfilter-persistent save
    echo "防火墙规则已启用"
}

stop_firewall() {
    iptables -F
    netfilter-persistent save
    echo "防火墙规则已清空"
}

status_firewall() {
    iptables -L -n -v
}

install_bbr() {
    modprobe tcp_bbr
    echo "tcp_bbr" | tee -a /etc/modules-load.d/modules.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
    echo "BBR 安装完成"
}

enable_bbr() {
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    sysctl -p
    echo "BBR 已启用"
}

disable_bbr() {
    sed -i '/tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/default_qdisc/d' /etc/sysctl.conf
    sysctl -p
    echo "BBR 已关闭"
}

status_bbr() {
    sysctl net.ipv4.tcp_congestion_control
    lsmod | grep bbr
}

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

remove_node() {
    echo "现有节点列表："
    ls $UUID_DIR
    read -p "请输入要删除的UUID: " DEL_UUID
    rm -f "$UUID_DIR/$DEL_UUID.json"
    generate_config
    systemctl restart $XRAY_SERVICE
    echo "节点 $DEL_UUID 已删除"
}

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

generate_config() {
    PORT=$(jq -r .port $(ls $UUID_DIR/*.json | head -n1))
    SERVER_NAME=$(jq -r .server_name $(ls $UUID_DIR/*.json | head -n1))
    PRIVKEY=$(jq -r .private_key $(ls $UUID_DIR/*.json | head -n1))

    CLIENTS=$(for f in $UUID_DIR/*.json; do jq -c '{id: .uuid, flow: "xtls-rprx-vision"}' "$f"; done | jq -s '.')
    SHORT_IDS=$(for f in $UUID_DIR/*.json; do jq -r .short_id "$f"; done | jq -R -s -c 'split("\n") | map(select(. != ""))')
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

update_script() {
    echo "暂未实现自动更新功能。"
}

uninstall_script() {
    systemctl stop $XRAY_SERVICE
    systemctl disable $XRAY_SERVICE
    rm -rf /usr/local/etc/xray
    rm -f /usr/local/bin/xray
    rm -f /etc/systemd/system/xray.service
    systemctl daemon-reexec
    echo "脚本及 Xray 已卸载"
}

show_menu() {
    echo "========= Reality 管理脚本 ========="
    echo "1. 添加 VLESS 节点"
    echo "2. 删除 VLESS 节点"
    echo "3. 查看 VLESS 节点"
    echo "4. 启动 Xray"
    echo "5. 停止 Xray"
    echo "6. 查看 Xray 状态"
    echo "7. 安装防火墙"
    echo "8. 启动防火墙"
    echo "9. 停止防火墙"
    echo "10. 查看防火墙状态"
    echo "11. 安装 BBR"
    echo "12. 启用 BBR"
    echo "13. 关闭 BBR"
    echo "14. 查看 BBR 状态"
    echo "15. 更新脚本"
    echo "16. 卸载脚本"
    echo "0. 退出"
    echo "===================================="
}

while true; do
    show_menu
    read -p "请输入选项: " choice
    case $choice in
        1) add_node;;
        2) remove_node;;
        3) view_node;;
        4) start_xray;;
        5) stop_xray;;
        6) status_xray;;
        7) install_firewall;;
        8) start_firewall;;
        9) stop_firewall;;
        10) status_firewall;;
        11) install_bbr;;
        12) enable_bbr;;
        13) disable_bbr;;
        14) status_bbr;;
        15) update_script;;
        16) uninstall_script;;
        0) exit;;
        *) echo "无效选项，请重新输入";;
    esac
    echo ""
done
