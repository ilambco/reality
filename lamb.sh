#!/bin/bash

# ==========================================
# Reality & Xray 管理脚本 (Lamb 最终修复版)
# 修复：兼容非常规 Xray 版本密钥生成
# ==========================================

# --- 核心配置变量 ---
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_CONF_FILE="${XRAY_CONF_DIR}/config.json"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# --- 基础检查 ---
check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 请以 root 权限运行!${PLAIN}" && exit 1
}

install_dependencies() {
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}安装 jq...${PLAIN}"
        if [ -f /etc/debian_version ]; then
            apt-get update -y && apt-get install -y jq curl openssl >/dev/null 2>&1
        else
            yum install -y epel-release && yum install -y jq curl openssl >/dev/null 2>&1
        fi
    fi
}

install_xray_core() {
    if [ ! -f "$XRAY_BIN" ]; then
        echo -e "${YELLOW}安装 Xray...${PLAIN}"
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi
    mkdir -p "$XRAY_CONF_DIR"
    if [ ! -f "$XRAY_CONF_FILE" ] || [ ! -s "$XRAY_CONF_FILE" ]; then
        echo '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"blocked"}]}' > "$XRAY_CONF_FILE"
    fi
}

# --- 核心修复：密钥生成函数 ---
generate_keys() {
    # 1. 尝试直接生成
    RAW_OUT=$($XRAY_BIN x25519)
    
    # 2. 暴力提取 Private Key (兼容 "Private key:" 和 "PrivateKey:")
    # grep -i 忽略大小写，cut -d: -f2 取冒号后面部分，tr -d 删除所有空格换行
    PRIVATE_KEY=$(echo "$RAW_OUT" | grep -i "Private" | head -n 1 | cut -d: -f2 | tr -d '[:space:]')
    
    # 3. 提取 Public Key
    PUBLIC_KEY=$(echo "$RAW_OUT" | grep -i "Public" | head -n 1 | cut -d: -f2 | tr -d '[:space:]')

    # 4. 【关键修复】如果 Public Key 是空的 (你的情况)，用 Private Key 反推
    if [[ -n "$PRIVATE_KEY" ]] && [[ -z "$PUBLIC_KEY" ]]; then
        # echo "尝试反推公钥..." 
        # 将私钥喂回 xray 计算公钥
        CALC_OUT=$(echo "$PRIVATE_KEY" | $XRAY_BIN x25519 -i)
        PUBLIC_KEY=$(echo "$CALC_OUT" | grep -i "Public" | head -n 1 | cut -d: -f2 | tr -d '[:space:]')
    fi

    # 5. 最终检查
    if [[ -z "$PRIVATE_KEY" ]] || [[ -z "$PUBLIC_KEY" ]]; then
        echo -e "${RED}严重错误：无法生成有效的 Xray 密钥对。${PLAIN}"
        echo -e "Debug Raw: $RAW_OUT"
        return 1
    fi
    return 0
}

# --- 功能函数 ---

add_reality() {
    echo -e "${YELLOW}正在生成配置...${PLAIN}"
    
    # 调用上面的修复版密钥生成
    if ! generate_keys; then return; fi
    
    UUID=$($XRAY_BIN uuid)
    SHORT_ID=$(openssl rand -hex 4)
    PORT=$(shuf -i 10000-60000 -n 1)

    read -p "请输入回落域名 (默认: www.microsoft.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && DOMAIN="www.microsoft.com"

    # 写入配置
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

    # 保存链接
    echo "$LINK" >> /usr/local/etc/xray/links.log

    systemctl restart xray
    sleep 1

    echo -e "--------------------------------------------------"
    echo -e " ${GREEN}节点添加成功！${PLAIN}"
    echo -e " 端口: ${PORT}"
    echo -e " UUID: ${UUID}"
    echo -e " SNI : ${DOMAIN}"
    echo -e " PBK : ${PUBLIC_KEY}"
    echo -e "--------------------------------------------------"
    echo -e " 链接: ${GREEN}${LINK}${PLAIN}"
    echo -e "--------------------------------------------------"
}

view_nodes() {
    echo -e "${YELLOW}当前节点列表:${PLAIN}"
    jq -r '.inbounds[] | "端口: \(.port) | 协议: \(.protocol) | Tag: \(.tag)"' "$XRAY_CONF_FILE"
    echo -e "--------------------------------------------------"
    echo -e "${YELLOW}最近生成的链接记录 (存于本地):${PLAIN}"
    if [ -f /usr/local/etc/xray/links.log ]; then
        tail -n 5 /usr/local/etc/xray/links.log
    else
        echo "无记录"
    fi
}

del_node() {
    read -p "请输入要删除的节点端口: " DEL_PORT
    [[ -z "$DEL_PORT" ]] && return
    jq --argjson p "$DEL_PORT" 'del(.inbounds[] | select(.port == $p))' "$XRAY_CONF_FILE" > "${XRAY_CONF_FILE}.tmp" && mv "${XRAY_CONF_FILE}.tmp" "$XRAY_CONF_FILE"
    echo -e "${GREEN}端口 $DEL_PORT 已删除。${PLAIN}"
    systemctl restart xray
}

enable_bbr() {
    echo -e "${YELLOW}配置 BBR...${PLAIN}"
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
    echo -e "${GREEN}BBR 已开启。${PLAIN}"
}

srv_control() {
    echo -e " 1. 启动  2. 停止  3. 重启"
    read -p "选择: " OPT
    case $OPT in
        1) systemctl start xray ;;
        2) systemctl stop xray ;;
        3) systemctl restart xray ;;
    esac
}

view_log() { journalctl -u xray -f -n 50; }

uninstall() {
    systemctl stop xray
    systemctl disable xray
    rm -rf "$XRAY_BIN" "$XRAY_CONF_DIR" "/etc/systemd/system/xray.service"
    rm -f /usr/local/etc/xray/links.log
    systemctl daemon-reload
    echo -e "${GREEN}已卸载。${PLAIN}"
}

# --- 菜单 ---
show_menu() {
    clear
    if systemctl is-active --quiet xray; then X_STATUS="${GREEN}运行中${PLAIN}"; else X_STATUS="${RED}停止${PLAIN}"; fi
    BBR_S=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    [[ "$BBR_S" == "bbr" ]] && B_STATUS="${GREEN}已开启${PLAIN}" || B_STATUS="${RED}未开启${PLAIN}"
    MYIP=$(curl -s4m8 ip.sb)

    echo -e "=================================================="
    echo -e "          Reality & Xray 管理脚本 (Lamb v3)       "
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
    echo -e " [ 隧道管理 ]"
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
        *) echo "无效选项" ;;
    esac
    read -p "回车继续..."
done
