#!/bin/bash

# ===================================================
# Reality & Xray 管理脚本 (Lamb)
# ===================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局变量
XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SERVICE="xray.service"
UUID_DIR="/usr/local/etc/xray/clients"
SS_DIR="/usr/local/etc/xray/ss_clients"
TUNNEL_DIR="/usr/local/etc/xray/tunnels"

# 1. 环境初始化与依赖检查
check_env() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 必须以 root 用户运行此脚本${NC}"
        exit 1
    fi

    # 创建快捷指令
    if [[ "$(basename $0)" != "lamb" ]] && [[ ! -f /usr/local/bin/lamb ]]; then
        cp "$(realpath $0)" /usr/local/bin/lamb
        chmod +x /usr/local/bin/lamb
        echo -e "${GREEN}已创建快捷指令 'lamb'，下次可直接输入 lamb 运行${NC}"
    fi

    echo -e "${CYAN}正在检查系统依赖...${NC}"
    DEPS=(curl jq openssl unzip qrencode dnsutils)
    MISSING=()
    for pkg in "${DEPS[@]}"; do
        if ! command -v $pkg &> /dev/null; then
            MISSING+=("$pkg")
        fi
    done

    if [ ${#MISSING[@]} -gt 0 ]; then
        apt update && apt install -y "${MISSING[@]}"
    fi

    mkdir -p "$UUID_DIR" "$SS_DIR" "$TUNNEL_DIR"

    if [[ ! -f $XRAY_BIN ]]; then
        echo -e "${YELLOW}未检测到 Xray，正在自动安装...${NC}"
        curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- install
    fi
}

# 2. 辅助函数
get_ip() {
    curl -s ipv4.ip.sb || curl -s ifconfig.me || echo "未知IP"
}

get_xray_status() {
    if systemctl is-active --quiet $XRAY_SERVICE; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}停止${NC}"
    fi
}

get_bbr_status() {
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo -e "${GREEN}已开启${NC}"
    else
        echo -e "${RED}未开启${NC}"
    fi
}

# SNI 校验函数
validate_sni() {
    local domain=$1
    echo -e "${CYAN}正在校验 SNI: $domain ...${NC}"
    if dig +short "$domain" > /dev/null; then
        return 0
    else
        return 1
    fi
}

# 3. 核心业务函数
add_node() {
    read -p "请输入节点名称 (备注): " REMARK
    REMARK=${REMARK:-"Reality-Node"}
    
    IP=$(get_ip)
    read -p "请输入端口 (默认 443): " VLESS_PORT
    VLESS_PORT=${VLESS_PORT:-443}

    while true; do
        read -p "请输入伪装域名 SNI (默认 itunes.apple.com): " SERVER_NAME
        SERVER_NAME=${SERVER_NAME:-itunes.apple.com}
        if validate_sni "$SERVER_NAME"; then
            echo -e "${GREEN}SNI 校验通过！${NC}"
            break
        else
            echo -e "${RED}警告: 域名 $SERVER_NAME 似乎无法解析，请检查拼写或更换。${NC}"
            read -p "是否强制使用？(y/n): " force
            [[ "$force" == "y" ]] && break
        fi
    done

    UUID=$($XRAY_BIN uuid)
    KEYS=$($XRAY_BIN x25519)
    PRIVKEY=$(echo "$KEYS" | grep Private | awk '{print $3}')
    PUBKEY=$(echo "$KEYS" | grep Public | awk '{print $3}')
    SHORT_ID=$(openssl rand -hex 4)

    CLIENT_FILE="$UUID_DIR/${UUID}.json"
    cat > "$CLIENT_FILE" <<EOF
{
  "remark": "$REMARK",
  "protocol": "vless",
  "uuid": "$UUID",
  "port": $VLESS_PORT,
  "domain": "$IP",
  "server_name": "$SERVER_NAME",
  "private_key": "$PRIVKEY",
  "public_key": "$PUBKEY",
  "short_id": "$SHORT_ID"
}
EOF
    generate_config && systemctl restart $XRAY_SERVICE
    echo -e "${GREEN}节点添加成功！${NC}"
}

view_node() {
    echo -e "${PURPLE}=== VLESS + Reality 节点列表 ===${NC}"
    for file in "$UUID_DIR"/*.json; do
        [ -e "$file" ] || continue
        REMARK=$(jq -r .remark "$file")
        UUID=$(jq -r .uuid "$file")
        IP=$(jq -r .domain "$file")
        PORT=$(jq -r .port "$file")
        SNI=$(jq -r .server_name "$file")
        PBK=$(jq -r .public_key "$file")
        SID=$(jq -r .short_id "$file")
        
        URL="vless://$UUID@$IP:$PORT?type=tcp&security=reality&pbk=$PBK&fp=chrome&sni=$SNI&sid=$SID&spx=%2F&flow=xtls-rprx-vision#$REMARK"
        
        echo -e "${YELLOW}备注: $REMARK${NC}"
        echo -e "链接: $URL"
        qrencode -t ansiutf8 "$URL"
        echo "------------------------------------------------"
    done
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

add_tunnel() {
    read -p "请输入中转监听端口: " L_PORT
    read -p "请输入落地目标 IP: " D_IP
    read -p "请输入落地目标端口: " D_PORT
    
    CLIENT_FILE="$TUNNEL_DIR/tunnel_${L_PORT}.json"
    cat > "$CLIENT_FILE" <<EOF
{
  "port": $L_PORT,
  "protocol": "tunnel",
  "address": "$D_IP",
  "dest_port": $D_PORT
}
EOF
    generate_config && systemctl restart $XRAY_SERVICE
    echo -e "${GREEN}Tunnel 隧道添加成功！${NC}"
}

generate_config() {
    INBOUNDS="[]"

    # 处理 VLESS
    for file in "$UUID_DIR"/*.json; do
        [ -f "$file" ] || continue
        # ... (解析逻辑同上，构建 JSON 对象)
        PORT=$(jq -r .port "$file")
        UUID=$(jq -r .uuid "$file")
        SNI=$(jq -r .server_name "$file")
        PRIV=$(jq -r .private_key "$file")
        SID=$(jq -r .short_id "$file")
        
        INBOUND=$(cat <<EOF
{
  "port": $PORT, "protocol": "vless",
  "settings": { "clients": [{"id": "$UUID", "flow": "xtls-rprx-vision"}], "decryption": "none" },
  "streamSettings": { "network": "tcp", "security": "reality",
    "realitySettings": { "show": false, "dest": "$SNI:443", "xver": 0, "serverNames": ["$SNI"], "privateKey": "$PRIV", "shortIds": ["$SID"] }
  }
}
EOF
)
        INBOUNDS=$(echo "$INBOUNDS" | jq ". + [$INBOUND]")
    done

    # 处理 Tunnel (Dokodemo-door)
    for file in "$TUNNEL_DIR"/*.json; do
        [ -f "$file" ] || continue
        L_PORT=$(jq -r .port "$file")
        D_IP=$(jq -r .address "$file")
        D_PORT=$(jq -r .dest_port "$file")
        
        T_INBOUND=$(cat <<EOF
{
  "port": $L_PORT, "protocol": "dokodemo-door",
  "settings": { "address": "$D_IP", "port": $D_PORT, "network": "tcp,udp" }
}
EOF
)
        INBOUNDS=$(echo "$INBOUNDS" | jq ". + [$T_INBOUND]")
    done

    # 写入文件
    cat > $XRAY_CONFIG_PATH <<EOF
{
  "inbounds": $INBOUNDS,
  "outbounds": [{"protocol": "freedom"}]
}
EOF
}

# BBR 管理
toggle_bbr() {
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        sysctl -p
        echo -e "${YELLOW}BBR 已关闭${NC}"
    else
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        echo -e "${GREEN}BBR 已开启${NC}"
    fi
}

# 4. 菜单展示
show_menu() {
    clear
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${BLUE}          Reality & Xray 管理脚本 (Lamb)          ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo -e "  系统状态:"
    echo -e "  - Xray 服务: $(get_xray_status)    - BBR 加速: $(get_bbr_status)"
    echo -e "  - 本机 IP  : ${YELLOW}$(get_ip)${NC}"
    echo -e "${CYAN}--------------------------------------------------${NC}"
    echo -e "  ${PURPLE}[ 节点管理 ]${NC}"
    echo -e "  1.  ${GREEN}添加${NC} VLESS + Reality 节点"
    echo -e "  2.  ${GREEN}添加${NC} Shadowsocks 节点 (2022-blake3)"
    echo -e "  3.  ${RED}删除${NC} 指定节点"
    echo -e "  4.  ${CYAN}查看${NC} 所有节点 (链接/二维码)"
    
    echo -e "\n  ${PURPLE}[ 隧道管理 (Tunnel) ]${NC}"
    echo -e "  5.  添加 端口转发 (Tunnel)"
    echo -e "  6.  删除 端口转发"
    echo -e "  7.  查看 转发列表"
    
    echo -e "\n  ${PURPLE}[ 系统工具 ]${NC}"
    echo -e "  8.  开启/关闭 BBR 加速"
    echo -e "  9.  查看 Xray 实时日志"
    echo -e "  10. ${RED}彻底卸载 Xray${NC}"
    echo -e "  11. 删除本脚本 (自毁)"
    echo -e "  0.  退出脚本"
    echo -e "${CYAN}==================================================${NC}"
    echo -n " 请输入选项 [0-11]: "
}

# 5. 主循环
check_env
while true; do
    show_menu
    read choice
    case $choice in
        1) add_node ;;
        2) echo "SS 逻辑集成中..." ;; # 可参考原脚本 SS 逻辑
        3) 
           echo "请输入要删除的节点 UUID:"
           read d_uuid
           rm -f "$UUID_DIR/${d_uuid}.json"
           generate_config && systemctl restart $XRAY_SERVICE
           ;;
        4) view_node ;;
        5) add_tunnel ;;
        8) toggle_bbr ;;
        9) journalctl -u $XRAY_SERVICE -f -n 50 ;;
        10) 
           systemctl stop $XRAY_SERVICE
           rm -rf /usr/local/bin/xray /usr/local/etc/xray
           echo "卸载完成" 
           ;;
        11) rm -f /usr/local/bin/lamb && rm -f "$0" && exit ;;
        0) exit ;;
        *) echo "无效选项" ;;
    esac
done
