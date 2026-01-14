#!/bin/bash

# ===================================================
# Reality & Xray 管理脚本 (Lamb) - 增强版
# ===================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局路径
XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SERVICE="xray.service"
UUID_DIR="/usr/local/etc/xray/clients"
SS_DIR="/usr/local/etc/xray/ss_clients"
TUNNEL_DIR="/usr/local/etc/xray/tunnels"

# --- 1. 自动化环境检测 ---
check_env() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 必须以 root 运行${NC}"; exit 1
    fi

    # 快捷指令
    if [[ ! -f /usr/local/bin/lamb ]]; then
        cp "$(realpath $0)" /usr/local/bin/lamb
        chmod +x /usr/local/bin/lamb
    fi

    # 依赖安装
    DEPS=(curl jq openssl unzip qrencode dnsutils)
    MISSING=()
    for pkg in "${DEPS[@]}"; do
        if ! command -v $pkg &> /dev/null; then MISSING+=("$pkg"); fi
    done
    if [ ${#MISSING[@]} -gt 0 ]; then
        echo -e "${YELLOW}正在安装必要依赖: ${MISSING[*]}${NC}"
        apt update && apt install -y "${MISSING[@]}"
    fi

    mkdir -p "$UUID_DIR" "$SS_DIR" "$TUNNEL_DIR"

    # Xray 安装
    if [[ ! -f $XRAY_BIN ]]; then
        echo -e "${YELLOW}正在安装 Xray 核心...${NC}"
        curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- install
    fi
}

# --- 2. 工具函数 ---
get_ip() { curl -s ipv4.ip.sb || echo "127.0.0.1"; }

validate_sni() {
    local domain=$1
    if dig +short "$domain" | grep -E '^[0-9.]+$' > /dev/null; then return 0; else return 1; fi
}

# 打印节点详细信息函数
print_node_info() {
    local file=$1
    local type=$2
    echo -e "\n${CYAN}========== 节点配置信息 ==========${NC}"
    
    if [[ "$type" == "vless" ]]; then
        REMARK=$(jq -r .remark "$file")
        UUID=$(jq -r .uuid "$file")
        PORT=$(jq -r .port "$file")
        SNI=$(jq -r .server_name "$file")
        PBK=$(jq -r .public_key "$file")
        SID=$(jq -r .short_id "$file")
        IP=$(get_ip)
        URL="vless://$UUID@$IP:$PORT?type=tcp&security=reality&pbk=$PBK&fp=chrome&sni=$SNI&sid=$SID&spx=%2F&flow=xtls-rprx-vision#$REMARK"
        echo -e "${GREEN}协议: VLESS + Reality${NC}"
        echo -e "${YELLOW}公钥 (pbk): $PBK${NC}"
    elif [[ "$type" == "ss" ]]; then
        REMARK=$(jq -r .remark "$file")
        PORT=$(jq -r .port "$file")
        PASS=$(jq -r .password "$file")
        METHOD=$(jq -r .method "$file")
        IP=$(get_ip)
        USERINFO=$(echo -n "${METHOD}:${PASS}" | base64 -w 0)
        URL="ss://${USERINFO}@${IP}:${PORT}#$REMARK"
        echo -e "${GREEN}协议: Shadowsocks (2022-blake3)${NC}"
    fi

    echo -e "${YELLOW}分享链接: ${NC}\n$URL"
    echo -e "${YELLOW}二维码:${NC}"
    qrencode -t ansiutf8 "$URL"
    echo -e "${CYAN}==================================${NC}\n"
}

# --- 3. 核心功能 ---
add_vless() {
    read -p "节点备注: " REMARK
    REMARK=${REMARK:-"Reality_$(date +%s)"}
    read -p "端口 (默认443): " PORT
    PORT=${PORT:-443}
    
    while true; do
        read -p "伪装域名 (SNI, 默认 itunes.apple.com): " SNI
        SNI=${SNI:-itunes.apple.com}
        if validate_sni "$SNI"; then break; else
            read -p "域名解析失败，是否强制使用? (y/n): " force
            [[ "$force" == "y" ]] && break
        fi
    done

    UUID=$($XRAY_BIN uuid)
    # 修复：确保正确捕获公私钥
    KEYS=$($XRAY_BIN x25519)
    PRIV=$(echo "$KEYS" | grep "Private key" | awk '{print $3}')
    PUB=$(echo "$KEYS" | grep "Public key" | awk '{print $3}')
    SID=$(openssl rand -hex 4)

    FILE="$UUID_DIR/${UUID}.json"
    cat > "$FILE" <<EOF
{"remark":"$REMARK","protocol":"vless","uuid":"$UUID","port":$PORT,"server_name":"$SNI","private_key":"$PRIV","public_key":"$PUB","short_id":"$SID"}
EOF
    generate_config && systemctl restart $XRAY_SERVICE
    print_node_info "$FILE" "vless"
}

add_ss() {
    read -p "节点备注: " REMARK
    REMARK=${REMARK:-"SS_$(date +%s)"}
    read -p "端口: " PORT
    METHOD="2022-blake3-aes-256-gcm"
    # 生成 32 位强密码
    PASS=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
    
    FILE="$SS_DIR/ss_${PORT}.json"
    cat > "$FILE" <<EOF
{"remark":"$REMARK","port":$PORT,"password":"$PASS","method":"$METHOD"}
EOF
    generate_config && systemctl restart $XRAY_SERVICE
    print_node_info "$FILE" "ss"
}

add_tunnel() {
    read -p "监听端口: " L_PORT
    read -p "目标 IP: " D_IP
    read -p "目标端口: " D_PORT
    
    FILE="$TUNNEL_DIR/tunnel_${L_PORT}.json"
    cat > "$FILE" <<EOF
{"port":$L_PORT,"address":"$D_IP","dest_port":$D_PORT}
EOF
    generate_config && systemctl restart $XRAY_SERVICE
    echo -e "${GREEN}Tunnel (隧道) 已启用: $L_PORT -> $D_IP:$D_PORT${NC}"
}

generate_config() {
    local INBOUNDS="[]"
    # VLESS 逻辑
    for f in "$UUID_DIR"/*.json; do
        [ -f "$f" ] || continue
        IB=$(cat <<EOF
{
  "port": $(jq .port "$f"), "protocol": "vless",
  "settings": { "clients": [{"id": "$(jq -r .uuid "$f")", "flow": "xtls-rprx-vision"}], "decryption": "none" },
  "streamSettings": { "network": "tcp", "security": "reality",
    "realitySettings": { "show": false, "dest": "$(jq -r .server_name "$f"):443", "xver": 0, "serverNames": ["$(jq -r .server_name "$f")"], "privateKey": "$(jq -r .private_key "$f")", "shortIds": ["$(jq -r .short_id "$f")"] }
  }
}
EOF
)
        INBOUNDS=$(echo "$INBOUNDS" | jq ". + [$IB]")
    done
    # SS 逻辑
    for f in "$SS_DIR"/*.json; do
        [ -f "$f" ] || continue
        IB=$(cat <<EOF
{
  "port": $(jq .port "$f"), "protocol": "shadowsocks",
  "settings": { "method": "$(jq -r .method "$f")", "password": "$(jq -r .password "$f")", "network": "tcp,udp" }
}
EOF
)
        INBOUNDS=$(echo "$INBOUNDS" | jq ". + [$IB]")
    done
    # Tunnel 逻辑
    for f in "$TUNNEL_DIR"/*.json; do
        [ -f "$f" ] || continue
        IB=$(cat <<EOF
{
  "port": $(jq .port "$f"), "protocol": "dokodemo-door",
  "settings": { "address": "$(jq -r .address "$f")", "port": $(jq .dest_port "$f"), "network": "tcp,udp" }
}
EOF
)
        INBOUNDS=$(echo "$INBOUNDS" | jq ". + [$IB]")
    done

    echo "{\"inbounds\": $INBOUNDS, \"outbounds\": [{\"protocol\": \"freedom\"}]}" | jq . > $XRAY_CONFIG_PATH
}

# --- 4. 菜单 ---
show_menu() {
    clear
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${BLUE}          Reality & Xray 管理脚本 (Lamb)          ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo -e "  服务状态: $(systemctl is-active $XRAY_SERVICE) | BBR: $(lsmod | grep -q bbr && echo "开启" || echo "关闭")"
    echo -e "  本机 IP:  $(get_ip)"
    echo -e "${CYAN}--------------------------------------------------${NC}"
    echo -e "  1. 添加 VLESS + Reality 节点"
    echo -e "  2. 添加 Shadowsocks 节点"
    echo -e "  3. 添加 Tunnel (隧道中转)"
    echo -e "  4. 查看 所有节点"
    echo -e "  5. 删除 指定节点/隧道"
    echo -e "  6. 开启/关闭 BBR 加速"
    echo -e "  7. 查看 Xray 日志"
    echo -e "  8. 彻底卸载 Xray"
    echo -e "  0. 退出"
    echo -e "${CYAN}==================================================${NC}"
    echo -n "请选择 [0-8]: "
}

check_env
while true; do
    show_menu
    read choice
    case $choice in
        1) add_vless ;;
        2) add_ss ;;
        3) add_tunnel ;;
        4) 
           for f in "$UUID_DIR"/*.json; do print_node_info "$f" "vless"; done
           for f in "$SS_DIR"/*.json; do print_node_info "$f" "ss"; done
           read -p "按回车返回菜单..." ;;
        5) 
           echo "现有的节点文件:"
           ls "$UUID_DIR" "$SS_DIR" "$TUNNEL_DIR"
           read -p "请输入要删除的文件全名: " d_file
           find /usr/local/etc/xray -name "$d_file" -delete
           generate_config && systemctl restart $XRAY_SERVICE
           ;;
        6) 
           if lsmod | grep -q bbr; then
               sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
               sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
               sysctl -p && echo "BBR 已关闭"
           else
               echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
               echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
               sysctl -p && echo "BBR 已开启"
           fi
           sleep 2 ;;
        7) journalctl -u $XRAY_SERVICE -f -n 50 ;;
        8) 
           systemctl stop $XRAY_SERVICE
           rm -rf /usr/local/bin/xray /usr/local/etc/xray
           echo "已卸载" ; exit ;;
        0) exit ;;
    esac
done
