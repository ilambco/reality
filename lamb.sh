#!/bin/bash

# ==========================================
# Reality & Xray 管理脚本 (Lamb v7 手动替换版)
# 修复：绕过安装脚本，强制手动替换二进制文件
# ==========================================

# --- 核心配置 ---
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_CONF_FILE="${XRAY_CONF_DIR}/config.json"
# 使用官方最新版下载链接
DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"

# --- 颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# --- 基础检查 ---
check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 请以 root 权限运行!${PLAIN}" && exit 1
}

install_dependencies() {
    echo -e "${YELLOW}检查并安装依赖 (jq, unzip, curl)...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y jq curl openssl unzip >/dev/null 2>&1
    else
        yum install -y epel-release >/dev/null 2>&1
        yum install -y jq curl openssl unzip >/dev/null 2>&1
    fi
}

# --- 核心：手动暴力替换内核 ---
manual_install_xray() {
    echo -e "${YELLOW}正在检测内核状态...${PLAIN}"
    
    # 检查当前内核输出是否正常
    if [ -f "$XRAY_BIN" ]; then
        TEST_OUT=$($XRAY_BIN x25519)
        if echo "$TEST_OUT" | grep -q "Password"; then
            echo -e "${RED}检测到魔改版 Xray (含 Password 字段)，必须强制替换！${PLAIN}"
            NEED_INSTALL=1
        elif ! echo "$TEST_OUT" | grep -q "Public"; then
            echo -e "${RED}检测到内核无法输出公钥，必须强制替换！${PLAIN}"
            NEED_INSTALL=1
        else
            echo -e "${GREEN}当前内核正常。${PLAIN}"
            NEED_INSTALL=0
        fi
    else
        NEED_INSTALL=1
    fi

    if [ "$NEED_INSTALL" -eq 1 ]; then
        echo -e "${YELLOW}正在执行手动替换 (Nuclear Option)...${PLAIN}"
        
        # 1. 停止服务
        systemctl stop xray 2>/dev/null
        
        # 2. 删除旧文件
        rm -f "$XRAY_BIN"
        
        # 3. 创建临时目录
        mkdir -p /tmp/xray_install
        
        # 4. 下载官方 ZIP
        echo -e "${YELLOW}正在从 GitHub 下载官方内核...${PLAIN}"
        curl -L -o /tmp/xray.zip "$DOWNLOAD_URL"
        
        if [ ! -f /tmp/xray.zip ]; then
             echo -e "${RED}下载失败，请检查网络连接！${PLAIN}"
             exit 1
        fi
        
        # 5. 解压
        echo -e "${YELLOW}解压并安装...${PLAIN}"
        unzip -o /tmp/xray.zip -d /tmp/xray_install >/dev/null 2>&1
        
        # 6. 移动文件
        mv /tmp/xray_install/xray "$XRAY_BIN"
        chmod +x "$XRAY_BIN"
        
        # 7. 清理
        rm -rf /tmp/xray_install /tmp/xray.zip
        
        echo -e "${GREEN}官方内核替换完成！${PLAIN}"
        
        # 验证
        NEW_VER=$($XRAY_BIN version | head -n 1)
        echo -e "新内核版本: $NEW_VER"
        
        # 重启服务
        systemctl restart xray
    fi

    # 确保配置目录存在
    mkdir -p "$XRAY_CONF_DIR"
    if [ ! -f "$XRAY_CONF_FILE" ] || [ ! -s "$XRAY_CONF_FILE" ]; then
        echo '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"blocked"}]}' > "$XRAY_CONF_FILE"
    fi
}

# --- 节点添加 (标准逻辑) ---
add_reality() {
    echo -e "${YELLOW}正在生成配置...${PLAIN}"
    
    # 再次检查，防止万一
    RAW_OUT=$($XRAY_BIN x25519)
    if echo "$RAW_OUT" | grep -q "Password"; then
        echo -e "${RED}错误：内核仍为魔改版，替换失败。请手动执行 'rm /usr/local/bin/xray' 后重试。${PLAIN}"
        return
    fi
    
    # 标准提取
    PRIVATE_KEY=$(echo "$RAW_OUT" | grep "Private key:" | awk -F': ' '{print $2}' | tr -d '[:space:]')
    PUBLIC_KEY=$(echo "$RAW_OUT" | grep "Public key:" | awk -F': ' '{print $2}' | tr -d '[:space:]')

    if [[ -z "$PRIVATE_KEY" ]] || [[ -z "$PUBLIC_KEY" ]]; then
        echo -e "${RED}错误：获取密钥失败。Debug: $RAW_OUT${PLAIN}"
        return
    fi

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
    if [ -f /usr/local/etc/xray/links.log ]; then
        echo -e "${YELLOW}历史链接记录:${PLAIN}"
        tail -n 5 /usr/local/etc/xray/links.log
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
    VER_INFO=$($XRAY_BIN version 2>/dev/null | head -n 1 | awk '{print $2}')
    [[ -z "$VER_INFO" ]] && VER_INFO="未知"
    
    if systemctl is-active --quiet xray; then X_STATUS="${GREEN}运行中${PLAIN}"; else X_STATUS="${RED}停止${PLAIN}"; fi
    BBR_S=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    [[ "$BBR_S" == "bbr" ]] && B_STATUS="${GREEN}已开启${PLAIN}" || B_STATUS="${RED}未开启${PLAIN}"
    MYIP=$(curl -s4m8 ip.sb)

    echo -e "=================================================="
    echo -e "          Reality & Xray 管理脚本 (Lamb v7)       "
    echo -e "=================================================="
    echo -e " 系统状态:"
    echo -e " - Xray 版本: ${GREEN}${VER_INFO}${PLAIN}" 
    echo -e " - 服务状态 : ${X_STATUS}    - BBR: ${B_STATUS}"
    echo -e " - 本机 IP  : ${MYIP}"
    echo -e "--------------------------------------------------"
    echo -e " [ 节点管理 ]"
    echo -e " 1.  添加 VLESS + Reality 节点"
    echo -e " 2.  添加 Shadowsocks 节点 (开发中)"
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
manual_install_xray  # <--- 执行核弹级替换

while true; do
    show_menu
    case "$CHOICE" in
        1) add_reality ;;
        2) echo "开发中..." ;;
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
