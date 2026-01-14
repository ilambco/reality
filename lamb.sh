#!/bin/bash

# ==========================================
# Reality & Xray 管理脚本 (Lamb v9 降级版)
# 核心功能：强制锁定安装 Xray v25.10.15
# 修复：解决 v26+ 版本输出格式变更导致无 PBK 的问题
# ==========================================

# --- 核心配置 ---
# 用户指定的稳定版本
TARGET_VERSION="v25.10.15"
# 官方下载地址构造
DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${TARGET_VERSION}/Xray-linux-64.zip"

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_CONF_FILE="${XRAY_CONF_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/xray.service"

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
    # 这一步不能省，降级需要 unzip
    if ! command -v unzip &> /dev/null || ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}安装必要工具 (unzip, jq, curl)...${PLAIN}"
        if [ -f /etc/debian_version ]; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y jq curl openssl unzip >/dev/null 2>&1
        else
            yum install -y epel-release >/dev/null 2>&1
            yum install -y jq curl openssl unzip >/dev/null 2>&1
        fi
    fi
}

# --- 核心：强制降级/安装指定版本 ---
force_install_specific_version() {
    # 获取当前版本
    CURRENT_VER=""
    if [ -f "$XRAY_BIN" ]; then
        CURRENT_VER=$($XRAY_BIN version | head -n 1 | awk '{print $2}')
    fi

    # 如果当前版本不是 v25.10.15，则执行强制替换
    if [[ "$CURRENT_VER" != "$TARGET_VERSION" ]]; then
        echo -e "${YELLOW}检测到当前版本 ($CURRENT_VER) 与目标不一致。${PLAIN}"
        echo -e "${YELLOW}正在强制降级到官方稳定版 ${TARGET_VERSION} ...${PLAIN}"
        
        # 1. 停止服务并杀掉进程 (防止文件占用)
        systemctl stop xray 2>/dev/null
        killall -9 xray 2>/dev/null
        
        # 2. 删除旧二进制文件
        rm -f "$XRAY_BIN"
        
        # 3. 创建临时目录
        mkdir -p /tmp/xray_install
        
        # 4. 下载指定版本
        echo -e "${YELLOW}正在下载: ${DOWNLOAD_URL}${PLAIN}"
        curl -L -o /tmp/xray.zip "$DOWNLOAD_URL"
        
        if [ ! -s /tmp/xray.zip ]; then
            echo -e "${RED}下载失败！请检查网络或 GitHub 连接。${PLAIN}"
            rm -rf /tmp/xray_install
            exit 1
        fi
        
        # 5. 解压
        unzip -o /tmp/xray.zip -d /tmp/xray_install >/dev/null 2>&1
        
        # 6. 归位
        mv /tmp/xray_install/xray "$XRAY_BIN"
        chmod +x "$XRAY_BIN"
        
        # 7. 清理
        rm -rf /tmp/xray_install /tmp/xray.zip
        
        echo -e "${GREEN}成功安装 Xray ${TARGET_VERSION}！${PLAIN}"
    else
        echo -e "${GREEN}当前已是目标版本 ${TARGET_VERSION}，无需重复安装。${PLAIN}"
    fi

    # 8. 确保 Systemd 服务文件存在 (修复 Unit not found)
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BIN} run -c ${XRAY_CONF_FILE}
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1
    
    # 9. 初始化配置目录
    mkdir -p "$XRAY_CONF_DIR"
    if [ ! -f "$XRAY_CONF_FILE" ] || [ ! -s "$XRAY_CONF_FILE" ]; then
        echo '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"blocked"}]}' > "$XRAY_CONF_FILE"
    fi
    
    # 10. 启动服务
    systemctl restart xray
}

# --- 功能函数 ---

add_reality() {
    echo -e "${YELLOW}正在生成 Reality 节点...${PLAIN}"
    
    # 此时已经是 v25.10.15，输出格式是标准的，可以放心使用标准提取
    # 标准格式: "Private key: xxxx" (冒号后有空格)
    RAW_OUT=$($XRAY_BIN x25519)
    
    PRIVATE_KEY=$(echo "$RAW_OUT" | grep "Private key:" | awk -F': ' '{print $2}' | tr -d '[:space:]')
    PUBLIC_KEY=$(echo "$RAW_OUT" | grep "Public key:" | awk -F': ' '{print $2}' | tr -d '[:space:]')

    # 预防性检查
    if [[ -z "$PUBLIC_KEY" ]]; then
        echo -e "${RED}错误：密钥提取失败。当前内核输出如下：${PLAIN}"
        echo "$RAW_OUT"
        return
    fi

    UUID=$($XRAY_BIN uuid)
    SHORT_ID=$(openssl rand -hex 4)
    PORT=$(shuf -i 10000-60000 -n 1) # 随机端口
    
    read -p "请输入回落域名 (默认: www.microsoft.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && DOMAIN="www.microsoft.com"

    # 使用 jq 写入 (最稳妥)
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
    
    # 记录
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
    echo -e "${YELLOW}当前配置节点:${PLAIN}"
    jq -r '.inbounds[] | "端口: \(.port) | 协议: \(.protocol) | Tag: \(.tag)"' "$XRAY_CONF_FILE"
    echo -e "--------------------------------------------------"
    if [ -f /usr/local/etc/xray/links.log ]; then
        echo -e "${YELLOW}本地历史链接记录:${PLAIN}"
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

# --- 菜单 (恢复完整布局) ---
show_menu() {
    clear
    # 显示当前版本
    VER_INFO=$($XRAY_BIN version 2>/dev/null | head -n 1 | awk '{print $2}')
    [[ -z "$VER_INFO" ]] && VER_INFO="未知"
    
    if systemctl is-active --quiet xray; then X_STATUS="${GREEN}运行中${PLAIN}"; else X_STATUS="${RED}停止${PLAIN}"; fi
    BBR_S=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    [[ "$BBR_S" == "bbr" ]] && B_STATUS="${GREEN}已开启${PLAIN}" || B_STATUS="${RED}未开启${PLAIN}"
    MYIP=$(curl -s4m8 ip.sb)

    echo -e "=================================================="
    echo -e "          Reality & Xray 管理脚本 (Lamb v9)       "
    echo -e "=================================================="
    echo -e " 系统状态:"
    echo -e " - Xray 版本: ${GREEN}${VER_INFO}${PLAIN}" 
    echo -e " - 服务状态 : ${X_STATUS}    - BBR: ${B_STATUS}"
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

# --- 主程序入口 ---
check_root
install_dependencies
# 启动时立即执行强制版本检查/降级
force_install_specific_version

while true; do
    show_menu
    case "$CHOICE" in
        1) add_reality ;;
        2) echo "暂未启用" ;;
        3) del_node ;;
        4) view_nodes ;;
        5) echo "暂未启用" ;;
        6) echo "暂未启用" ;;
        8) enable_bbr ;;
        9) view_log ;;
        10) srv_control ;;
        11) uninstall ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
    read -p "回车继续..."
done
