#!/bin/bash

# ==========================================
# Reality & Xray 管理脚本 (Lamb 完美修复版)
# ==========================================

# --- 核心配置变量 ---
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_CONF_FILE="${XRAY_CONF_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/xray.service"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# --- 基础检查与安装 ---
check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 请以 root 权限运行此脚本!${PLAIN}" && exit 1
}

install_dependencies() {
    # 这一步至关重要，解决无输出和配置错误的核心
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}正在安装必要组件 (jq, curl)...${PLAIN}"
        if [ -f /etc/debian_version ]; then
            apt-get update -y && apt-get install -y jq curl openssl >/dev/null 2>&1
        else
            yum install -y epel-release && yum install -y jq curl openssl >/dev/null 2>&1
        fi
    fi
}

install_xray_core() {
    if [ ! -f "$XRAY_BIN" ]; then
        echo -e "${YELLOW}正在安装 Xray Core...${PLAIN}"
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi

    # 确保配置文件存在且为合法 JSON
    mkdir -p "$XRAY_CONF_DIR"
    if [ ! -f "$XRAY_CONF_FILE" ] || [ ! -s "$XRAY_CONF_FILE" ]; then
        echo '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"blocked"}]}' > "$XRAY_CONF_FILE"
    fi
}

# --- 核心功能函数 ---

# 1. 添加 Reality 节点 (核心修复)
add_reality() {
    echo -e "${YELLOW}正在生成配置...${PLAIN}"
    
    # 生成 UUID 和 密钥 (使用更严格的提取方式，解决 empty privateKey 问题)
    UUID=$($XRAY_BIN uuid)
    KEYS=$($XRAY_BIN x25519)
    PRIVATE_KEY=$(echo "$KEYS" | grep "Private" | awk -F': ' '{print $2}' | tr -d '[:space:]')
    PUBLIC_KEY=$(echo "$KEYS" | grep "Public" | awk -F': ' '{print $2}' | tr -d '[:space:]')
    SHORT_ID=$(openssl rand -hex 4)
    PORT=$(shuf -i 10000-60000 -n 1)

    # 二次检查，防止空值写入导致 Xray 崩溃
    if [[ -z "$PRIVATE_KEY" ]]; then
        echo -e "${RED}错误：密钥生成失败，请检查 Xray 是否安装正确。${PLAIN}"
        return
    fi

    read -p "请输入回落域名 (默认: www.microsoft.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && DOMAIN="www.microsoft.com"

    # 使用 jq 安全写入配置
    jq --arg uuid "$UUID" \
       --arg port "$PORT" \
       --arg pk "$PRIVATE_KEY" \
       --arg sid "$SHORT_ID" \
       --arg sni "$DOMAIN" \
       '.inbounds += [{
         "port": ($port | tonumber),
         "protocol": "vless",
         "settings": {
           "clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}],
           "decryption": "none"
         },
         "streamSettings": {
           "network": "tcp",
           "security": "reality",
           "realitySettings": {
             "show": false,
             "dest": ($sni + ":443"),
             "xver": 0,
             "serverNames": [$sni],
             "privateKey": $pk,
             "shortIds": [$sid]
           }
         },
         "tag": ("reality_" + $port)
       }]' "$XRAY_CONF_FILE" > "${XRAY_CONF_FILE}.tmp" && mv "${XRAY_CONF_FILE}.tmp" "$XRAY_CONF_FILE"

    # 生成链接
    IP=$(curl -s4m8 ip.sb)
    LINK="vless://${UUID}@${IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DOMAIN}&sid=${SHORT_ID}&spx=%2F#Reality_${PORT}"

    # 重启服务
    systemctl restart xray

    echo -e "--------------------------------------------------"
    echo -e " ${GREEN}节点添加成功！${PLAIN}"
    echo -e " 端口: ${PORT}"
    echo -e " UUID: ${UUID}"
    echo -e " SNI : ${DOMAIN}"
    echo -e " PBK : ${PUBLIC_KEY}"
    echo -e "--------------------------------------------------"
    echo -e " 链接: ${GREEN}${LINK}${PLAIN}"
    echo -e "--------------------------------------------------"
    
    # 可选：将链接保存到文件，方便查看
    echo "${LINK}" >> /usr/local/etc/xray/links.log
}

# 4. 查看节点 (修复无输出)
view_nodes() {
    echo -e "${YELLOW}当前节点列表:${PLAIN}"
    # 从配置文件读取端口和TAG
    jq -r '.inbounds[] | "端口: \(.port) | 类型: \(.protocol) | 备注: \(.tag)"' "$XRAY_CONF_FILE"
    
    echo -e "--------------------------------------------------"
    if [ -f /usr/local/etc/xray/links.log ]; then
        echo -e "${YELLOW}历史添加的链接记录:${PLAIN}"
        cat /usr/local/etc/xray/links.log
    else
        echo -e "${RED}注意：由于 Reality 安全机制，配置文件不保存公钥。${PLAIN}"
        echo -e "${RED}只能查看上方端口信息，完整链接请在添加时保存。${PLAIN}"
    fi
}

# 3. 删除节点
del_node() {
    read -p "请输入要删除的节点端口: " DEL_PORT
    if [[ -z "$DEL_PORT" ]]; then return; fi
    
    jq --argjson p "$DEL_PORT" 'del(.inbounds[] | select(.port == $p))' "$XRAY_CONF_FILE" > "${XRAY_CONF_FILE}.tmp" && mv "${XRAY_CONF_FILE}.tmp" "$XRAY_CONF_FILE"
    echo -e "${GREEN}端口 $DEL_PORT 已删除。${PLAIN}"
    systemctl restart xray
}

# 8. BBR 加速 (修复服务停止问题)
enable_bbr() {
    echo -e "${YELLOW}正在配置 BBR...${PLAIN}"
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
    echo -e "${GREEN}BBR 已开启 (无需重启服务)。${PLAIN}"
}

# 10. 服务控制
srv_control() {
    echo -e " 1. 启动  2. 停止  3. 重启"
    read -p "请选择: " OPT
    case $OPT in
        1) systemctl start xray ;;
        2) systemctl stop xray ;;
        3) systemctl restart xray ;;
    esac
    echo -e "${GREEN}执行完成。${PLAIN}"
}

# 9. 查看日志
view_log() {
    journalctl -u xray -f -n 50
}

# 11. 卸载
uninstall() {
    systemctl stop xray
    systemctl disable xray
    rm -rf "$XRAY_BIN" "$XRAY_CONF_DIR" "/etc/systemd/system/xray.service"
    systemctl daemon-reload
    echo -e "${GREEN}已卸载。${PLAIN}"
}

# --- 菜单显示 (恢复原版样式) ---
show_menu() {
    clear
    # 获取状态
    if systemctl is-active --quiet xray; then X_STATUS="${GREEN}运行中${PLAIN}"; else X_STATUS="${RED}停止${PLAIN}"; fi
    BBR_S=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    if [[ "$BBR_S" == "bbr" ]]; then B_STATUS="${GREEN}已开启${PLAIN}"; else B_STATUS="${RED}未开启${PLAIN}"; fi
    MYIP=$(curl -s4m8 ip.sb)

    echo -e "=================================================="
    echo -e "          Reality & Xray 管理脚本 (Lamb)          "
    echo -e "=================================================="
    echo -e " 系统状态:"
    echo -e " - Xray 服务: ${X_STATUS}    - BBR 加速: ${B_STATUS}"
    echo -e " - 本机 IP  : ${MYIP}"
    echo -e "--------------------------------------------------"
    echo -e " [ 节点管理 ]"
    echo -e " 1.  添加 VLESS + Reality 节点"
    echo -e " 2.  添加 Shadowsocks 节点 (未启用)"
    echo -e " 3.  删除 指定节点"
    echo -e " 4.  查看 所有节点 (链接/二维码)"
    echo -e ""
    echo -e " [ 隧道管理 (Tunnel) ]"
    echo -e " 5.  添加 端口转发 (Tunnel) (未启用)"
    echo -e " 6.  查看/删除 隧道列表 (未启用)"
    echo -e ""
    echo -e " [ 系统工具 ]"
    echo -e " 8.  开启/关闭 BBR 加速"
    echo -e " 9.  查看 Xray 实时日志"
    echo -e " 10. 服务控制: 启动/停止/重启"
    echo -e " 11. 彻底卸载 Xray / 删除脚本"
    echo -e " 0.  退出脚本"
    echo -e "=================================================="
    read -p " 请输入选项 [0-11]: " CHOICE
}

# --- 主循环 ---
check_root
install_dependencies
install_xray_core

while true; do
    show_menu
    case "$CHOICE" in
        1) add_reality ;;
        3) del_node ;;
        4) view_nodes ;;
        8) enable_bbr ;;
        9) view_log ;;
        10) srv_control ;;
        11) uninstall ;;
        0) exit 0 ;;
        *) echo "功能未开发或无效选项" ;;
    esac
    read -p "回车继续..."
done
