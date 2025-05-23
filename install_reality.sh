#!/bin/bash
# 自动创建 lamb 快捷方式（首次运行时执行）
if [[ "$(realpath $0)" != "/usr/local/bin/lamb" ]] && [[ ! -f /usr/local/bin/lamb ]]; then
    cp "$(realpath $0)" /usr/local/bin/lamb
    chmod +x /usr/local/bin/lamb
    echo "已创建快捷指令 'lamb'，您可以通过运行 lamb 快速打开脚本"
fi

# 必须以 root 运行
if [[ $EUID -ne 0 ]]; then
   echo "请以 root 用户运行此脚本（使用 sudo 或直接切换为 root）"
   exit 1
fi

# 全局变量
XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SERVICE="xray.service"
UUID_DIR="/usr/local/etc/xray/clients"

# 一次性创建目录 
mkdir -p "$UUID_DIR"

# 获取公网 IP
get_ip() {
    curl -s ipv4.ip.sb || curl -s ifconfig.me || hostname -I | awk '{print $1}'
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

# 卸载 Xray
uninstall_xray() {
    systemctl stop $XRAY_SERVICE
    systemctl disable $XRAY_SERVICE
    rm -rf /usr/local/bin/xray /usr/local/etc/xray /etc/systemd/system/xray.service
    systemctl daemon-reload
    echo "Xray 已卸载"
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
    mkdir -p "$UUID_DIR"
    read -p "请输入域名或IP（默认使用本机IP）:" DOMAIN
    DOMAIN=${DOMAIN:-$(get_ip)}

    read -p "请输入端口（默认443）: " PORT
    PORT=${PORT:-443}

    read -p "请输入伪装域名（默认itunes.apple.com）: " SERVER_NAME
    SERVER_NAME=${SERVER_NAME:-itunes.apple.com}

    UUID=$($XRAY_BIN uuid)
    KEYS=$($XRAY_BIN x25519)
    PRIVKEY=$(echo "$KEYS" | grep Private | awk '{print $3}')
    PUBKEY=$(echo "$KEYS" | grep Public | awk '{print $3}')
    SHORT_ID=$(openssl rand -hex 2)

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

    echo "vless://$UUID@$DOMAIN:$PORT?type=tcp&security=reality&pbk=$PUBKEY&fp=chrome&sni=$SERVER_NAME&sid=$SHORT_ID&spx=%2F&flow=xtls-rprx-vision#Reality-$DOMAIN"
}

remove_node() {
    echo "现有节点："
    ls $UUID_DIR
    read -p "请输入要删除的UUID: " DEL_UUID
    # 查找包含 UUID 的文件
    FILE_TO_DELETE=$(find $UUID_DIR -type f -name "${DEL_UUID}_*.json")
    if [[ -f "$FILE_TO_DELETE" ]]; then
        rm -f "$FILE_TO_DELETE"
        echo "已删除: $FILE_TO_DELETE"
        generate_config
        systemctl restart $XRAY_SERVICE
    else
        echo "未找到对应UUID的节点"
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
        SHORT_ID=$(jq -r .short_id "$file")
        echo "---"
        echo "端口: $PORT"
        echo "UUID: $UUID"
        echo "Reality 公钥: $PUBKEY"
        echo "vless://$UUID@$DOMAIN:$PORT?type=tcp&security=reality&pbk=$PUBKEY&fp=chrome&sni=$SERVER_NAME&sid=$SHORT_ID&spx=%2F&flow=xtls-rprx-vision#Reality-$PORT"
    done
}

# ✅ 支持多个端口节点，生成多个 inbounds 配置项
generate_config() {
    INBOUNDS="[]"
    for file in $UUID_DIR/*.json; do
        [ -f "$file" ] || continue
        UUID=$(jq -r .uuid "$file")
        PORT=$(jq -r .port "$file")
        SERVER_NAME=$(jq -r .server_name "$file")
        PRIVKEY=$(jq -r .private_key "$file")
        SHORT_ID=$(jq -r .short_id "$file")
        PUBKEY=$(jq -r .public_key "$file")
        SHORT_IDS="[\"$SHORT_ID\"]"
        CLIENT="[{\"id\": \"$UUID\", \"flow\": \"xtls-rprx-vision\"}]"

        INBOUND=$(cat <<EOF
{
  "port": $PORT,
  "protocol": "vless",
  "settings": {
    "clients": $CLIENT,
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
EOF
)
        INBOUNDS=$(echo "$INBOUNDS" | jq ". + [$INBOUND]")
    done

    # 写入配置文件
    cat > $XRAY_CONFIG_PATH <<EOF
{
  "inbounds": $INBOUNDS,
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF
}


# 端口转发规则文件
PORT_FORWARD_FILE="/usr/local/etc/xray/port_forward_rules.txt"

# 添加端口转发规则
add_port_forward() {
    read -p "请输入目标 IP 或域名: " TARGET_IP
    [ -z "$TARGET_IP" ] && echo "目标 IP 不能为空" && return

    read -p "请输入目标端口: " TARGET_PORT
    [[ ! "$TARGET_PORT" =~ ^[0-9]+$ ]] && echo "目标端口无效" && return

    read -p "请输入本地转发端口（默认与目标端口相同）: " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-$TARGET_PORT}

    grep -q "^$LOCAL_PORT $TARGET_IP $TARGET_PORT$" "$PORT_FORWARD_FILE" 2>/dev/null
    if [[ $? -eq 0 ]]; then
        echo "该转发规则已存在"
        return
    fi

    iptables -t nat -A PREROUTING -p tcp --dport "$LOCAL_PORT" -j DNAT --to-destination "$TARGET_IP:$TARGET_PORT"
    iptables -t nat -A POSTROUTING -j MASQUERADE
    echo "$LOCAL_PORT $TARGET_IP $TARGET_PORT" >> "$PORT_FORWARD_FILE"
    netfilter-persistent save
    echo "端口转发已添加: 本地 $LOCAL_PORT -> $TARGET_IP:$TARGET_PORT"
}

# 删除端口转发规则
remove_port_forward() {
    read -p "请输入目标 IP 或域名: " TARGET_IP
    [ -z "$TARGET_IP" ] && echo "目标 IP 不能为空" && return

    read -p "请输入目标端口: " TARGET_PORT
    [[ ! "$TARGET_PORT" =~ ^[0-9]+$ ]] && echo "目标端口无效" && return

    MATCH_LINE=$(grep " $TARGET_IP $TARGET_PORT$" "$PORT_FORWARD_FILE" 2>/dev/null)
    if [[ -z "$MATCH_LINE" ]]; then
        echo "未找到该端口转发规则"
        return
    fi

    LOCAL_PORT=$(echo "$MATCH_LINE" | awk '{print $1}')
    iptables -t nat -D PREROUTING -p tcp --dport "$LOCAL_PORT" -j DNAT --to-destination "$TARGET_IP:$TARGET_PORT"
    iptables -t nat -D POSTROUTING -j MASQUERADE
    sed -i "\|^$LOCAL_PORT $TARGET_IP $TARGET_PORT$|d" "$PORT_FORWARD_FILE"
    netfilter-persistent save
    echo "已删除转发: 本地 $LOCAL_PORT -> $TARGET_IP:$TARGET_PORT"
}

# 查看所有端口转发规则
list_port_forward() {
    echo "当前端口转发规则:"
    if [[ ! -s "$PORT_FORWARD_FILE" ]]; then
        echo "暂无端口转发配置"
        return
    fi
    while read -r line; do
        LOCAL_PORT=$(echo "$line" | awk '{print $1}')
        TARGET_IP=$(echo "$line" | awk '{print $2}')
        TARGET_PORT=$(echo "$line" | awk '{print $3}')
        echo "本地端口: $LOCAL_PORT -> $TARGET_IP:$TARGET_PORT"
    done < "$PORT_FORWARD_FILE"
}


# 删除脚本本体和快捷方式
delete_script() {
    echo "即将删除脚本和快捷指令..."
    rm -f /root/install_reality.sh
    rm -f /usr/local/bin/lamb
    echo "脚本和 lamb 快捷方式已删除"
    exit
}

# 主菜单
show_menu() {
    echo "================ Reality 管理菜单 ========"
    echo " 1.   添加VLESS节点"
    echo " 2.   删除VLESS节点"
    echo " 3.   查看VLESS节点"
    echo " --------------- 端口转发 ---------------"
    echo " 4.   添加端口转发"
    echo " 5.   删除端口转发"
    echo " 6.   查看端口转发"
    echo " --------------- Xray 管理 ---------------"
    echo " 7.   安装/启用"
    echo " 8.   停止"
    echo " 9.   查看状态"
    echo " 10.  卸载"
    echo " --------------- UFW 管理 ---------------"
    echo " 11.  安装/启用"
    echo " 12.  关闭"
    echo " 13.  开放端口"
    echo " 14.  查看规则"
    echo " --------------- BBR 管理 ---------------"
    echo " 15.  安装/启用"
    echo " 16.  关闭"
    echo " 17.  查看状态"
    echo " --------------- 脚本管理 ---------------"
    echo " 18.  安装依赖"
    echo " 19.  删除脚本"
    echo " 0.   退出"

    echo " ======================================="
}

# 安装依赖函数
install_deps() {
    DEPS=(curl jq iptables iptables-persistent netfilter-persistent openssl unzip)
    MISSING=()
    for PKG in "${DEPS[@]}"; do
      dpkg -s "$PKG" &>/dev/null || MISSING+=("$PKG")
    done
    if [ ${#MISSING[@]} -gt 0 ]; then
      echo "检测到缺失依赖：${MISSING[*]}，正在安装…"
      apt update
      apt install -y "${MISSING[@]}"
    else
      echo "所有依赖已就绪"
    fi
}

while true; do
    show_menu
    read -p "请输入选项: " choice
    case $choice in

        1) add_node;;
        2) remove_node;;
        3) view_node;;
        
        4) add_port_forward;;
        5) remove_port_forward;;
        6) list_port_forward;;
        
        7)
            if [[ ! -f $XRAY_BIN ]]; then
                install_xray
            fi
            start_xray
            ;;
        8) stop_xray;;
        9) status_xray;;
        10) uninstall_xray;;

        11)
            dpkg -s iptables-persistent &>/dev/null || install_firewall
            start_firewall
            ;;
        12) stop_firewall;;
        13) add_firewall_rule;;
        14) status_firewall;;
        15) install_bbr;;
        16) disable_bbr;;
        17) status_bbr;;
        18)
            apt update
            apt install -y curl jq iptables iptables-persistent netfilter-persistent openssl unzip
            ;;
        19) delete_script;;
        0) exit;;
        *) echo "无效选项，请重新输入";;
    esac
    echo ""
done

# 添加 lamb 快捷方式（仅执行一次即可）
cp "$(realpath "$0")" /usr/local/bin/lamb
chmod +x /usr/local/bin/lamb
echo "你现在可以通过命令 'lamb' 来运行此脚本"
