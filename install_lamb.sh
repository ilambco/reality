#!/bin/bash

# ===================================================
# Reality & Xray 管理脚本 (Lamb) - V1.1.0
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

# 1. 强制环境初始化 (最优先级执行)
pre_flight_check() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 必须以 root 用户运行此脚本${NC}"
        exit 1
    fi

    # 检测并安装最基础的 curl，防止菜单崩溃
    if ! command -v curl &> /dev/null; then
        echo "检测到缺少 curl，正在尝试安装..."
        apt-get update && apt-get install -y curl
    fi

    # 检查其他核心依赖
    DEPS=(jq openssl unzip qrencode dnsutils)
    MISSING=()
    for pkg in "${DEPS[@]}"; do
        if ! command -v $pkg &> /dev/null; then
            MISSING+=("$pkg")
        fi
    done

    if [ ${#MISSING[@]} -gt 0 ]; then
        echo -e "${CYAN}正在安装必要组件: ${MISSING[*]}...${NC}"
        apt-get update && apt-get install -y "${MISSING[@]}"
    fi

    mkdir -p "$UUID_DIR" "$SS_DIR" "$TUNNEL_DIR"

    if [[ ! -f $XRAY_BIN ]]; then
        echo -e "${YELLOW}未检测到 Xray，正在自动安装...${NC}"
        curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- install
    fi

    # 创建快捷指令
    if [[ "$(basename $0)" != "lamb" ]] && [[ ! -f /usr/local/bin/lamb ]]; then
        cp "$(realpath $0)" /usr/local/bin/lamb
        chmod +x /usr/local/bin/lamb
    fi
}

# 2. 辅助工具函数
get_ip() {
    local ip=$(curl -s --max-time 2 ipv4.ip.sb || curl -s --max-time 2 ifconfig.me)
    if [ -z "$ip" ]; then
        ip=$(hostname -I | awk '{print $1}')
    fi
    echo "$ip"
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

# 3. 核心节点功能
print_node_info() {
    local type=$1
    local file=$2
    echo -e "\n${CYAN}================ 节点配置信息 ================${NC}"
    
    if [[ "$type" == "vless" ]]; then
        REMARK=$(jq -r .remark "$file")
        UUID=$(jq -r .uuid "$file")
        IP=$(jq -r .domain "$file")
        PORT=$(jq -r .port "$file")
        SNI=$(jq -r .server_name "$file")
        PBK=$(jq -r .public_key "$file")
        SID=$(jq -r .short_id "$file")
        # 修复 pbk 拼接逻辑
        URL="vless://$UUID@$IP:$PORT?type=tcp&security=reality&pbk=$PBK&fp=chrome&sni=$SNI&sid=$SID&spx=%2F&flow=xtls-rprx-vision#$REMARK"
        
        echo -e "${YELLOW}协议:${NC} VLESS + Reality"
        echo -e "${YELLOW}地址:${NC} $IP"
        echo -e "${YELLOW}端口:${NC} $PORT"
        echo -e "${YELLOW}UUID:${NC} $UUID"
        echo -e "${YELLOW}公钥(pbk):${NC} $PBK"
        echo -e "${YELLOW}SNI:${NC} $SNI"
    
    elif [[ "$type" == "ss" ]]; then
        REMARK=$(jq -r .remark "$file")
        PORT=$(jq -r .port "$file")
        PWD=$(jq -r .password "$file")
        METHOD=$(jq -r .method "$file")
        IP=$(get_ip)
        SAFE_BASE64=$(echo -n "${METHOD}:${PWD}" | base64 | tr -d '\n')
        URL="ss://${SAFE_BASE64}@${IP}:${PORT}#${REMARK}"
        
        echo -e "${YELLOW}协议:${NC} Shadowsocks"
        echo -e "${YELLOW}加密:${NC} $METHOD"
        echo -e "${YELLOW}端口:${NC} $PORT"
    fi

    echo -e "${YELLOW}分享链接:${NC}\n$URL"
    echo -e "${YELLOW}二维码:${NC}"
    qrencode -t ansiutf8 "$URL"
    echo -e "${CYAN}=============================================${NC}"
}

add_node() {
    read -p "请输入节点名称 (备注): " REMARK
    REMARK=${REMARK:-"Reality-Node"}
    IP=$(get_ip)
    read -p "请输入端口 (默认 443): " VLESS_PORT
    VLESS_PORT=${VLESS_PORT:-443}

    read -p "请输入伪装域名 SNI (默认 itunes.apple.com): " SERVER_NAME
    SERVER_NAME=${SERVER_NAME:-itunes.apple.com}

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
    print_node_info "vless" "$CLIENT_FILE"
    read -n 1 -s -r -p "按任意键返回..."
}

add_ss_node() {
    read -p "请输入节点名称 (备注): " REMARK
    REMARK=${REMARK:-"SS-Node"}
    read -p "请输入端口: " SS_PORT
    METHOD="2022-blake3-aes-256-gcm"
    PASSWORD=$(openssl rand -base64 32)

    CLIENT_FILE="$SS_DIR/ss_${SS_PORT}.json"
    cat > "$CLIENT_FILE" <<EOF
{
  "remark": "$REMARK",
  "port": $SS_PORT,
  "password": "$PASSWORD",
  "method": "$METHOD"
}
EOF
    generate_config && systemctl restart $XRAY_SERVICE
    echo -e "${GREEN}SS 节点添加成功！${NC}"
    print_node_info "ss" "$CLIENT_FILE"
    read -n 1 -s -r -p "按任意键返回..."
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
    echo -e "${GREEN}Tunnel (隧道中转) 已添加！${NC}"
    read -n 1 -s -r -p "按任意键返回..."
}

generate_config() {
    INBOUNDS="[]"
    # 组合 VLESS 节点
    for file in "$UUID_DIR"/*.json; do
        [ -f "$file" ] || continue
        PORT=$(jq -r .port "$file"); UUID=$(jq -r .uuid "$file")
        SNI=$(jq -r .server_name "$file"); PRIV=$(jq -r .private_key "$file")
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
    # 组合 SS 节点
    for file in "$SS_DIR"/*.json; do
        [ -f "$file" ] || continue
        PORT=$(jq -r .port "$file"); PWD=$(jq -r .password "$file"); MTD=$(jq -r .method "$file")
        INBOUND=$(cat <<EOF
{
  "port": $PORT, "protocol": "shadowsocks",
  "settings": { "method": "$MTD", "password": "$PWD", "network": "tcp,udp" }
}
EOF
)
        INBOUNDS=$(echo "$INBOUNDS" | jq ". + [$INBOUND]")
    done
    # 组合 Tunnel 节点
    for file in "$TUNNEL_DIR"/*.json; do
        [ -f "$file" ] || continue
        L_PORT=$(jq -r .port "$file"); D_IP=$(jq -r .address "$file"); D_PORT=$(jq -r .dest_port "$file")
        INBOUND=$(cat <<EOF
{
  "port": $L_PORT, "protocol": "dokodemo-door",
  "settings": { "address": "$D_IP", "port": $D_PORT, "network": "tcp,udp" }
}
EOF
)
        INBOUNDS=$(echo "$INBOUNDS" | jq ". + [$INBOUND]")
    done

    cat > $XRAY_CONFIG_PATH <<EOF
{
  "inbounds": $INBOUNDS,
  "outbounds": [{"protocol": "freedom"}]
}
EOF
}

# 4. 菜单与主循环
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
    echo -e "\n  ${PURPLE}[ 隧道管理 (Tunnel) ]${NC}"
    echo -e "  5.  添加 端口转发 (Tunnel)"
    echo -e "  6.  删除 端口转发"
    echo -e "  7.  查看 转发列表"
    echo -e "\n  ${PURPLE}[ 系统工具 ]${NC}"
    echo -e "  8.  开启/关闭 BBR 加速"
    echo -e "  9.  查看 Xray 实时日志"
    echo -e "  10. 彻底卸载 Xray"
    echo -e "  11. 删除本脚本 (自毁)"
    echo -e "  0.  退出脚本"
    echo -e "${CYAN}==================================================${NC}"
    echo -n " 请输入选项 [0-11]: "
}

pre_flight_check
while true; do
    show_menu
    read choice
    case $choice in
        1) add_node ;;
        2) add_ss_node ;;
        3) 
           echo "请输入要删除的节点关键词 (端口/UUID/备注):"
           read key
           find "$UUID_DIR" "$SS_DIR" "$TUNNEL_DIR" -name "*$key*" -delete
           generate_config && systemctl restart $XRAY_SERVICE
           echo "删除完成"
           sleep 1
           ;;
        4) 
           for f in "$UUID_DIR"/*.json; do [ -e "$f" ] && print_node_info "vless" "$f"; done
           for f in "$SS_DIR"/*.json; do [ -e "$f" ] && print_node_info "ss" "$f"; done
           read -n 1 -s -r -p "按任意键返回..."
           ;;
        5) add_tunnel ;;
        6) 
           echo "请输入要删除的 Tunnel 监听端口:"
           read t_port
           rm -f "$TUNNEL_DIR/tunnel_${t_port}.json"
           generate_config && systemctl restart $XRAY_SERVICE
           ;;
        7) ls "$TUNNEL_DIR" && read -n 1 -s -r -p "按任意键返回..." ;;
        8) 
           if get_bbr_status | grep -q "已开启"; then
               sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
               sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
               sysctl -p
           else
               echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
               echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
               sysctl -p
           fi
           ;;
        9) journalctl -u $XRAY_SERVICE -f -n 50 ;;
        10) 
           systemctl stop $XRAY_SERVICE
           rm -rf /usr/local/bin/xray /usr/local/etc/xray
           echo "卸载完成"
           sleep 2
           ;;
        11) rm -f /usr/local/bin/lamb && rm -f "$0" && exit ;;
        0) exit ;;
        *) echo "无效选项" ;;
    esac
done
