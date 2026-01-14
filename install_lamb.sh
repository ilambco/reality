#!/bin/bash

# ===================================================
# Reality & Xray 管理脚本 (Lamb) - V1.1.4
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

# 1. 环境初始化
pre_flight_check() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须以 root 运行${NC}" && exit 1

    # 安装依赖
    DEPS=(curl jq openssl unzip qrencode dnsutils)
    if ! command -v curl &> /dev/null; then apt-get update && apt-get install -y curl; fi
    MISSING=()
    for pkg in "${DEPS[@]}"; do
        if ! command -v $pkg &> /dev/null; then MISSING+=("$pkg"); fi
    done
    [[ ${#MISSING[@]} -gt 0 ]] && apt-get update && apt-get install -y "${MISSING[@]}"

    mkdir -p "$UUID_DIR" "$SS_DIR" "$TUNNEL_DIR" "/usr/local/etc/xray"

    # 快捷指令
    cp "$(realpath $0)" /usr/local/bin/lamb 2>/dev/null
    chmod +x /usr/local/bin/lamb 2>/dev/null
}

# 2. 辅助工具
get_ip() {
    local ip=$(curl -s --max-time 3 ipv4.ip.sb || curl -s --max-time 3 ifconfig.me)
    [[ -z "$ip" ]] && ip=$(hostname -I | awk '{print $1}')
    echo "$ip"
}

get_xray_status() {
    systemctl is-active --quiet $XRAY_SERVICE && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}停止${NC}"
}

get_bbr_status() {
    sysctl net.ipv4.tcp_congestion_control | grep -q "bbr" && echo -e "${GREEN}已开启${NC}" || echo -e "${RED}未开启${NC}"
}

# 3. 核心功能
add_node() {
    read -p "请输入节点备注: " REMARK
    REMARK=${REMARK:-"Reality-Node"}
    IP=$(get_ip)
    read -p "请输入端口 (默认 443): " VLESS_PORT
    VLESS_PORT=${VLESS_PORT:-443}
    read -p "请输入伪装域名 (默认 itunes.apple.com): " SERVER_NAME
    SERVER_NAME=${SERVER_NAME:-itunes.apple.com}

    # 核心修复：兼容多种 Xray 输出格式
    echo -e "${CYAN}正在生成密钥对...${NC}"
    KEYS=$($XRAY_BIN x25519 2>/dev/null)
    
    # 尝试匹配 PrivateKey: 或 Private key:
    PRIVKEY=$(echo "$KEYS" | grep -i "Private" | awk -F ': ' '{print $2}' | tr -d '[:space:]')
    # 尝试匹配 Password: 或 Public key:
    PUBKEY=$(echo "$KEYS" | grep -E -i "Public|Password" | awk -F ': ' '{print $2}' | tr -d '[:space:]')
    
    if [[ -z "$PUBKEY" || -z "$PRIVKEY" ]]; then
        echo -e "${RED}错误: 抓取密钥失败！${NC}"
        echo -e "Xray 输出内容为:\n$KEYS"
        read -n 1 -s -r -p "按任意键返回..."
        return 1
    fi

    UUID=$($XRAY_BIN uuid)
    SHORT_ID=$(openssl rand -hex 4)

    CLIENT_FILE="$UUID_DIR/${UUID}.json"
    cat > "$CLIENT_FILE" <<EOF
{
  "remark": "$REMARK", "protocol": "vless", "uuid": "$UUID", "port": $VLESS_PORT,
  "domain": "$IP", "server_name": "$SERVER_NAME", "private_key": "$PRIVKEY",
  "public_key": "$PUBKEY", "short_id": "$SHORT_ID"
}
EOF
    generate_config
    systemctl restart $XRAY_SERVICE
    
    echo -e "${GREEN}节点已成功添加并启动！${NC}"
    URL="vless://$UUID@$IP:$VLESS_PORT?type=tcp&security=reality&pbk=$PUBKEY&fp=chrome&sni=$SERVER_NAME&sid=$SHORT_ID&spx=%2F&flow=xtls-rprx-vision#$REMARK"
    echo -e "\n${YELLOW}您的分享链接:${NC}\n$URL"
    qrencode -t ansiutf8 "$URL"
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

generate_config() {
    local INBOUNDS="[]"
    # VLESS 遍历
    for f in "$UUID_DIR"/*.json; do
        [[ ! -f "$f" ]] && continue
        PT=$(jq -r .port "$f"); UID=$(jq -r .uuid "$f"); SNI=$(jq -r .server_name "$f"); PRV=$(jq -r .private_key "$f"); SID=$(jq -r .short_id "$f")
        IB=$(cat <<EOF
{
  "port": $PT, "protocol": "vless",
  "settings": { "clients": [{"id": "$UID", "flow": "xtls-rprx-vision"}], "decryption": "none" },
  "streamSettings": { "network": "tcp", "security": "reality",
    "realitySettings": { "show": false, "dest": "$SNI:443", "xver": 0, "serverNames": ["$SNI"], "privateKey": "$PRV", "shortIds": ["$SID"] }
  }
}
EOF
)
        INBOUNDS=$(echo "$INBOUNDS" | jq ". + [$IB]")
    done
    # SS 遍历
    for f in "$SS_DIR"/*.json; do
        [[ ! -f "$f" ]] && continue
        PT=$(jq -r .port "$f"); PW=$(jq -r .password "$f"); MT=$(jq -r .method "$f")
        IB=$(cat <<EOF
{ "port": $PT, "protocol": "shadowsocks", "settings": { "method": "$MT", "password": "$PW", "network": "tcp,udp" } }
EOF
)
        INBOUNDS=$(echo "$INBOUNDS" | jq ". + [$IB]")
    done
    
    # 写入配置
    cat > $XRAY_CONFIG_PATH <<EOF
{ "inbounds": $INBOUNDS, "outbounds": [{"protocol": "freedom"}] }
EOF
}

# 4. 主菜单
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
    echo -e "  2.  ${GREEN}添加${NC} Shadowsocks 节点"
    echo -e "  3.  ${RED}删除${NC} 指定节点"
    echo -e "  4.  ${CYAN}查看${NC} 所有节点 (链接/二维码)"
    echo -e "\n  ${PURPLE}[ 隧道管理 ]${NC}"
    echo -e "  5.  添加 端口转发 (Tunnel)"
    echo -e "  6.  查看/删除 隧道列表"
    echo -e "\n  ${PURPLE}[ 系统工具 ]${NC}"
    echo -e "  8.  开启/关闭 BBR 加速"
    echo -e "  9.  查看 Xray 实时日志"
    echo -e "  10. 服务控制: 重启/启动/停止"
    echo -e "  11. 彻底卸载 Xray / 删除脚本"
    echo -e "  0.  退出脚本"
    echo -e "${CYAN}==================================================${NC}"
    echo -n " 请选择 [0-11]: "
}

pre_flight_check
while true; do
    show_menu
    read choice
    case "$choice" in
        1) add_node ;;
        2) 
           read -p "备注: " r; r=${r:-"SS-Node"}; read -p "端口: " p; pw=$(openssl rand -base64 32)
           cf="$SS_DIR/ss_${p}.json"; echo "{ \"remark\": \"$r\", \"port\": $p, \"password\": \"$pw\", \"method\": \"2022-blake3-aes-256-gcm\" }" > "$cf"
           generate_config && systemctl restart $XRAY_SERVICE && echo "SS 节点已添加" ;;
        3) echo -n "输入关键词: "; read k; find "$UUID_DIR" "$SS_DIR" "$TUNNEL_DIR" -name "*$k*" -delete; generate_config; systemctl restart $XRAY_SERVICE; sleep 1 ;;
        4) 
           for f in "$UUID_DIR"/*.json; do [[ -e "$f" ]] && { 
               URL="vless://$(jq -r .uuid "$f")@$(jq -r .domain "$f"):$(jq -r .port "$f")?type=tcp&security=reality&pbk=$(jq -r .public_key "$f")&fp=chrome&sni=$(jq -r .server_name "$f")&sid=$(jq -r .short_id "$f")&spx=%2F&flow=xtls-rprx-vision#$(jq -r .remark "$f")"
               echo -e "\n${YELLOW}备注: $(jq -r .remark "$f")${NC}\n$URL"; qrencode -t ansiutf8 "$URL"
           } done
           read -n 1 -s -r -p "回车继续..." ;;
        8)
           if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
               sed -i '/net.core/d' /etc/sysctl.conf; sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf; sysctl -p
           else
               echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf; echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf; sysctl -p
           fi ;;
        9) journalctl -u $XRAY_SERVICE -f -n 100 ;;
        10) systemctl restart $XRAY_SERVICE ;;
        11) systemctl stop $XRAY_SERVICE; rm -rf /usr/local/bin/xray /usr/local/etc/xray /usr/local/bin/lamb "$0"; exit ;;
        0) exit ;;
        *) echo "无效选项"; sleep 1 ;;
    esac
done
