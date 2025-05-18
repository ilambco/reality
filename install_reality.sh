#!/bin/bash

# Xray 和节点相关路径
XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SERVICE="xray.service"
UUID_DIR="/usr/local/etc/xray/clients"
mkdir -p $UUID_DIR

# 获取公网 IP
get_ip() {
    curl -s ipv4.ip.sb || curl -s ifconfig.me || hostname -I | awk '{print $1}'
}

# 安装 Xray 核心
install_xray() {
    bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install
    echo "Xray 安装完成"
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

    CLIENT_FILE="$UUID_DIR/$PORT.json"
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

# 删除节点（通过端口）
remove_node() {
    echo "当前所有节点："
    ls $UUID_DIR
    read -p "请输入要删除的端口: " PORT
    rm -f "$UUID_DIR/$PORT.json"
    generate_config
    systemctl restart $XRAY_SERVICE
    echo "端口 $PORT 的节点已删除"
}

# 查看节点列表
view_node() {
    echo "======= 节点信息列表 ======="
    for file in $UUID_DIR/*.json; do
        [ -e "$file" ] || continue
        UUID=$(jq -r .uuid "$file")
        DOMAIN=$(jq -r .domain "$file")
        PORT=$(jq -r .port "$file")
        SERVER_NAME=$(jq -r .server_name "$file")
        PUBKEY=$(jq -r .public_key "$file")
        echo "[端口:$PORT] UUID: $UUID"
        echo "vless://$UUID@$DOMAIN:$PORT?type=tcp&security=reality&flow=xtls-rprx-vision&encryption=none&fp=chrome&pbk=$PUBKEY&sni=$SERVER_NAME#VLESS-REALITY"
        echo "------------------------------"
    done
}

# 生成 config.json 配置文件
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

# Xray 管理函数
xray_menu() {
    echo "--- Xray 管理 ---"
    echo "1. 安装 Xray"
    echo "2. 启动 Xray"
    echo "3. 停止 Xray"
    echo "4. 查看 Xray 状态"
    read -p "请选择: " opt
    case $opt in
        1) install_xray;;
        2) systemctl start $XRAY_SERVICE; echo "Xray 已启动";;
        3) systemctl stop $XRAY_SERVICE; echo "Xray 已停止";;
        4) systemctl status $XRAY_SERVICE;;
        *) echo "无效选项";;
    esac
}

# 防火墙相关
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

firewall_menu() {
    echo "--- 防火墙管理 ---"
    echo "1. 安装防火墙"
    echo "2. 启动防火墙"
    echo "3. 停止防火墙"
    echo "4. 查看当前规则"
    read -p "请选择: " opt
    case $opt in
        1) install_firewall;;
        2) start_firewall;;
        3) stop_firewall;;
        4) iptables -L -n -v;;
        *) echo "无效选项";;
    esac
}

# BBR 相关
install_bbr() {
    modprobe tcp_bbr
    echo "tcp_bbr" | tee -a /etc/modules-load.d/modules.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
    echo "BBR 已启用"
}

disable_bbr() {
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    sysctl -p
    echo "BBR 已关闭（请重启生效）"
}

bbr_menu() {
    echo "--- BBR 管理 ---"
    echo "1. 安装/启用 BBR"
    echo "2. 关闭 BBR"
    echo "3. 查看 BBR 状态"
    read -p "请选择: " opt
    case $opt in
        1) install_bbr;;
        2) disable_bbr;;
        3) sysctl net.ipv4.tcp_congestion_control;;
        *) echo "无效选项";;
    esac
}

# 主菜单
show_menu() {
    echo "========= Reality 管理脚本 ========="
    echo "1. 添加 VLESS 节点"
    echo "2. 删除 VLESS 节点"
    echo "3. 查看 VLESS 节点"
    echo "4. Xray 管理"
    echo "5. 防火墙管理"
    echo "6. BBR 管理"
    echo "0. 退出"
    echo "===================================="
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
