#!/bin/bash

# ===================================================
# Reality & Xray 管理脚本 (Lamb) - V1.1.2
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

# 1. 环境初始化与服务自愈
pre_flight_check() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须以 root 运行${NC}" && exit 1

    # 基础依赖强制安装
    DEPS=(curl jq openssl unzip qrencode dnsutils)
    if ! command -v curl &> /dev/null; then apt-get update && apt-get install -y curl; fi
    
    MISSING=()
    for pkg in "${DEPS[@]}"; do
        if ! command -v $pkg &> /dev/null; then MISSING+=("$pkg"); fi
    done
    [[ ${#MISSING[@]} -gt 0 ]] && apt-get update && apt-get install -y "${MISSING[@]}"

    mkdir -p "$UUID_DIR" "$SS_DIR" "$TUNNEL_DIR"

    # 安装 Xray
    if [[ ! -f $XRAY_BIN ]]; then
        echo -e "${YELLOW}正在安装 Xray...${NC}"
        curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- install
    fi

    # 启动服务
    systemctl enable $XRAY_SERVICE >/dev/null 2>&1
    systemctl start $XRAY_SERVICE >/dev/null 2>&1

    # 快捷指令
    if [[ ! -f /usr/local/bin/lamb ]]; then
        cp "$(realpath $0)" /usr/local/bin/lamb
        chmod +x /usr/local/bin/lamb
    fi
}

# 2. 辅助工具
get_ip() {
    local ip=$(curl -s --max-time 2 ipv4.ip.sb || curl -s --max-time 2 ifconfig.me)
    [[ -z "$ip" ]] && ip=$(hostname -I | awk '{print $1}')
    echo "$ip"
}

get_xray_status() {
    systemctl is-active --quiet $XRAY_SERVICE && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}停止${NC}"
}

get_bbr_status() {
    sysctl net.ipv4.tcp_congestion_control | grep -q "bbr" && echo -e "${GREEN}已开启${NC}" || echo -e "${RED}未开启${NC}"
}

# 3. 核心节点功能
print_node_info() {
    local type=$1
    local file=$2
    [[ ! -f "$file" ]] && return
    
    echo -e "\n${CYAN}================ 节点配置信息 ================${NC}"
    if [[ "$type" == "vless" ]]; then
        REMARK=$(jq -r .remark "$file"); UUID=$(jq -r .uuid "$file"); IP=$(jq -r .domain "$file")
        PORT=$(jq -r .port "$file"); SNI=$(jq -r .server_name "$file"); PBK=$(jq -r .public_key "$file"); SID=$(jq -r .short_id "$file")
        
        URL="vless://$UUID@$IP:$PORT?type=tcp&security=reality&pbk=$PBK&fp=chrome&sni=$SNI&sid=$SID&spx=%2F&flow=xtls-rprx-vision#$REMARK"
        
        echo -e "${YELLOW}协议:${NC} VLESS+Reality  ${YELLOW}备注:${NC} $REMARK"
        echo -e "${YELLOW}地址:${NC} $IP  ${YELLOW}端口:${NC} $PORT"
        echo -e "${YELLOW}UUID:${NC} $UUID"
        echo -e "${YELLOW}公钥:${NC} $PBK"
    elif [[ "$type" == "ss" ]]; then
        REMARK=$(jq -r .remark "$file"); PORT=$(jq -r .port "$file"); PWD=$(jq -r .password "$file"); MTD=$(jq -r .method "$file"); IP=$(get_ip)
        URL="ss://$(echo -n "${MTD}:${PWD}" | base64 | tr -d '\n')@${IP}:${PORT}#${REMARK}"
        echo -e "${YELLOW}协议:${NC} Shadowsocks  ${YELLOW}备注:${NC} $REMARK"
        echo -e "${YELLOW}端口:${NC} $PORT  ${YELLOW}加密:${NC} $MTD"
    fi
    echo -e "${YELLOW}分享链接:${NC}\n$URL"
    echo -e "${YELLOW}二维码:${NC}"
    qrencode -t ansiutf8 "$URL"
    echo -e "${CYAN}=============================================${NC}"
}

add_node() {
    read -p "请输入节点备注: " REMARK
    REMARK=${REMARK:-"Reality-Node"}
    IP=$(get_ip)
    read -p "请输入端口 (默认 443): " VLESS_PORT
    VLESS_PORT=${VLESS_PORT:-443}
    read -p "请输入伪装域名 (默认 itunes.apple.com): " SERVER_NAME
    SERVER_NAME=${SERVER_NAME:-itunes.apple.com}

    # 生成密钥对并增强解析逻辑
    UUID=$($XRAY_BIN uuid)
    KEYS=$($XRAY_BIN x25519)
    # 使用 awk 分隔符提取，更兼容
    PRIVKEY=$(echo "$KEYS" | grep "Private" | awk -F ': ' '{print $2}' | xargs)
    PUBKEY=$(echo "$KEYS" | grep "Public" | awk -F ': ' '{print $2}' | xargs)
    SHORT_ID=$(openssl rand -hex 4)

    # 校验公钥是否成功生成
    if [[ -z "$PUBKEY" ]]; then
        echo -e "${RED}错误: 无法生成 Reality 密钥对，请检查 Xray 是否正常工作${NC}"
        return 1
    fi

    CLIENT_FILE="$UUID_DIR/${UUID}.json"
    cat > "$CLIENT_FILE" <<EOF
{
  "remark": "$REMARK", "protocol": "vless", "uuid": "$UUID", "port": $VLESS_PORT,
  "domain": "$IP", "server_name": "$SERVER_NAME", "private_key": "$PRIVKEY",
  "public_key": "$PUBKEY", "short_id": "$SHORT_ID"
}
EOF
    generate_config && systemctl restart $XRAY_SERVICE
    echo -e "${GREEN}节点添加成功！${NC}"
    print_node_info "vless" "$CLIENT_FILE"
    read -n 1 -s -r -p "按任意键返回..."
}

generate_config() {
    INBOUNDS="[]"
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
    # 写入文件
    cat > $XRAY_CONFIG_PATH <<EOF
{ "inbounds": $INBOUNDS, "outbounds": [{"protocol": "freedom"}] }
EOF
}

# 4. 菜单与控制
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
    echo -e "  6.  查看/删除 隧道列表"
    echo -e "\n  ${PURPLE}[ 系统工具 ]${NC}"
    echo -e "  8.  ${YELLOW}开启/关闭 BBR 加速${NC}"
    echo -e "  9.  查看 Xray 实时日志"
    echo -e "  10. 服务控制: 启动/停止/重启"
    echo -e "  11. 彻底卸载 Xray / 删除脚本"
    echo -e "  0.  退出脚本"
    echo -e "${CYAN}==================================================${NC}"
    echo -n " 请输入选项 [0-11]: "
}

pre_flight_check
while true; do
    show_menu
    read choice
    case "$choice" in
        1) add_node ;;
        2) 
           read -p "备注: " r; r=${r:-"SS-Node"}; read -p "端口: " p; m="2022-blake3-aes-256-gcm"; pw=$(openssl rand -base64 32)
           cf="$SS_DIR/ss_${p}.json"; echo "{ \"remark\": \"$r\", \"port\": $p, \"password\": \"$pw\", \"method\": \"$m\" }" > "$cf"
           generate_config && systemctl restart $XRAY_SERVICE && print_node_info "ss" "$cf" ;;
        3) 
           echo -n "输入删除关键词: "; read k; find "$UUID_DIR" "$SS_DIR" "$TUNNEL_DIR" -name "*$k*" -delete
           generate_config && systemctl restart $XRAY_SERVICE && echo "已处理"; sleep 1 ;;
        4) 
           for f in "$UUID_DIR"/*.json; do [[ -e "$f" ]] && print_node_info "vless" "$f"; done
           for f in "$SS_DIR"/*.json; do [[ -e "$f" ]] && print_node_info "ss" "$f"; done
           read -n 1 -s -r -p "回车继续..." ;;
        5)
           read -p "本地监听端口: " lp; read -p "目标IP: " tip; read -p "目标端口: " tp
           echo "{ \"port\": $lp, \"address\": \"$tip\", \"dest_port\": $tp }" > "$TUNNEL_DIR/tunnel_${lp}.json"
           generate_config && systemctl restart $XRAY_SERVICE && echo "转发已添加" ;;
        8)
           if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
               sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
               sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
               sysctl -p && echo "BBR 已关闭"
           else
               echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
               echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
               sysctl -p && echo "BBR 已开启"
           fi
           sleep 2 ;;
        9) journalctl -u $XRAY_SERVICE -f -n 50 ;;
        10)
           echo -e "1. 启动 2. 停止 3. 重启"; read -p "选择: " sc
           [[ "$sc" == "1" ]] && systemctl start $XRAY_SERVICE
           [[ "$sc" == "2" ]] && systemctl stop $XRAY_SERVICE
           [[ "$sc" == "3" ]] && systemctl restart $XRAY_SERVICE ;;
        11)
           read -p "彻底卸载? (y/n): " confirm
           [[ "$confirm" == "y" ]] && { systemctl stop $XRAY_SERVICE; rm -rf /usr/local/bin/xray /usr/local/etc/xray /usr/local/bin/lamb "$0"; exit; } ;;
        0) exit ;;
        *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
    esac
done
