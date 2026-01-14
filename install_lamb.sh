#!/bin/bash

# ==========================================
# Reality & Xray 管理脚本 (Lamb 修复版)
# 修复：节点无输出、服务自启、BBR 冲突问题
# 依赖：curl, jq, openssl, systemd
# ==========================================

# --- 全局变量 ---
XRAY_BIN_PATH="/usr/local/bin/xray"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
SYSTEMD_FILE="/etc/systemd/system/xray.service"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# --- 基础函数 ---

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 请使用 sudo 或 root 权限运行此脚本！${PLAIN}"
        exit 1
    fi
}

install_dependencies() {
    echo -e "${YELLOW}正在检查并安装必要依赖 (jq, curl, openssl)...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y jq curl openssl wget >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        yum install -y epel-release >/dev/null 2>&1
        yum install -y jq curl openssl wget >/dev/null 2>&1
    fi
    
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}错误: jq 安装失败，脚本无法处理 JSON。请手动安装 jq。${PLAIN}"
        exit 1
    fi
}

# --- Xray 核心安装与配置 ---

install_xray() {
    if [ -f "${XRAY_BIN_PATH}" ]; then
        echo -e "${GREEN}Xray 已安装。${PLAIN}"
        return
    fi
    
    echo -e "${YELLOW}开始安装 Xray 最新版本...${PLAIN}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    # 确保配置目录存在
    mkdir -p ${XRAY_CONFIG_DIR}
    
    # 初始化空配置 (如果不存在)
    if [ ! -f "${XRAY_CONFIG_FILE}" ] || [ ! -s "${XRAY_CONFIG_FILE}" ]; then
        cat > ${XRAY_CONFIG_FILE} <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ]
}
EOF
    fi
    
    # 修复 Systemd 文件以确保自启
    cat > ${SYSTEMD_FILE} <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BIN_PATH} run -c ${XRAY_CONFIG_FILE}
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable xray
    echo -e "${GREEN}Xray 安装完成并已设置开机自启。${PLAIN}"
}

# --- 功能逻辑 ---

enable_bbr() {
    echo -e "${YELLOW}正在配置 BBR...${PLAIN}"
    # 简单的 BBR 开启逻辑，不应干扰 Xray
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    sysctl -p >/dev/null 2>&1
    echo -e "${GREEN}BBR 已开启 (无需重启 Xray)。${PLAIN}"
}

check_status() {
    if systemctl is-active --quiet xray; then
        XRAY_STATUS="${GREEN}运行中${PLAIN}"
    else
        XRAY_STATUS="${RED}已停止${PLAIN}"
    fi
    
    BBR_STATUS=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    if [[ "$BBR_STATUS" == "bbr" ]]; then
        BBR_COLOR="${GREEN}已开启${PLAIN}"
    else
        BBR_COLOR="${RED}未开启${PLAIN}"
    fi
    
    IP=$(curl -s4m8 ip.sb)
}

# --- 节点管理 (重点修复部分) ---

add_reality_node() {
    echo -e "${YELLOW}正在生成 Reality 节点配置...${PLAIN}"
    
    # 生成必要参数
    UUID=$(${XRAY_BIN_PATH} uuid)
    KEYS=$(${XRAY_BIN_PATH} x25519)
    PRIVATE_KEY=$(echo "$KEYS" | awk '/Private/{print $3}')
    PUBLIC_KEY=$(echo "$KEYS" | awk '/Public/{print $3}')
    SHORT_ID=$(openssl rand -hex 4)
    PORT=$(shuf -i 10000-65000 -n 1) # 随机端口避免冲突
    
    read -p "请输入目标网站 (默认: www.microsoft.com): " DEST_URL
    [ -z "$DEST_URL" ] && DEST_URL="www.microsoft.com"

    # 使用 jq 构造 JSON 对象并插入 (解决 sed 写入失败的问题)
    # 这是一个标准的 VLESS-Reality 入站配置
    jq --arg uuid "$UUID" \
       --arg port "$PORT" \
       --arg pk "$PRIVATE_KEY" \
       --arg sid "$SHORT_ID" \
       --arg dest "$DEST_URL:443" \
       --arg server "$DEST_URL" \
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
             "dest": $dest,
             "xver": 0,
             "serverNames": [$server],
             "privateKey": $pk,
             "shortIds": [$sid]
           }
         },
         "tag": ("reality_" + $port)
       }]' ${XRAY_CONFIG_FILE} > ${XRAY_CONFIG_FILE}.tmp && mv ${XRAY_CONFIG_FILE}.tmp ${XRAY_CONFIG_FILE}

    echo -e "${GREEN}节点添加成功！正在重启 Xray...${PLAIN}"
    systemctl restart xray
    sleep 1
    
    # 立即输出链接
    IP=$(curl -s4m8 ip.sb)
    SHARE_LINK="vless://${UUID}@${IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_URL}&sid=${SHORT_ID}&spx=%2F#Reality_${PORT}"
    
    echo -e "--------------------------------------------------"
    echo -e " VLESS + Reality 节点详情:"
    echo -e " IP: ${IP}"
    echo -e " Port: ${PORT}"
    echo -e " UUID: ${UUID}"
    echo -e " SNI: ${DEST_URL}"
    echo -e " Public Key: ${PUBLIC_KEY}"
    echo -e " Short ID: ${SHORT_ID}"
    echo -e "--------------------------------------------------"
    echo -e " 复制链接: ${GREEN}${SHARE_LINK}${PLAIN}"
    echo -e "--------------------------------------------------"
}

view_nodes() {
    echo -e "${YELLOW}正在读取节点列表...${PLAIN}"
    # 使用 jq 解析并构建链接
    # 注意：这里需要重新生成分享链接，为了简化，我们尽量从配置文件反推
    # 但由于 JSON 不存 Public Key (只有 Private Key)，无法反推完整的 Reality 链接供客户端使用
    # 所以我们这里只列出端口和基本信息，Reality 的 PrivateKey 无法算出 PublicKey
    
    echo -e "目前 Xray 配置文件中的入站列表："
    echo -e "--------------------------------------------------"
    jq -r '.inbounds[] | "端口: \(.port), 协议: \(.protocol), Tag: \(.tag)"' ${XRAY_CONFIG_FILE}
    echo -e "--------------------------------------------------"
    echo -e "${RED}注意：由于 Reality 机制限制，配置文件中只保存私钥。${PLAIN}"
    echo -e "${RED}查看完整分享链接建议在添加节点时立即保存，或手动记录公钥。${PLAIN}"
}

delete_node() {
    read -p "请输入要删除的节点端口: " DEL_PORT
    if [ -z "$DEL_PORT" ]; then echo "取消操作"; return; fi
    
    # 使用 jq 删除特定端口的 inbound
    jq --argjson port "$DEL_PORT" 'del(.inbounds[] | select(.port == $port))' ${XRAY_CONFIG_FILE} > ${XRAY_CONFIG_FILE}.tmp && mv ${XRAY_CONFIG_FILE}.tmp ${XRAY_CONFIG_FILE}
    
    echo -e "${GREEN}端口 $DEL_PORT 的节点已删除。重启服务中...${PLAIN}"
    systemctl restart xray
}

service_control() {
    echo -e "1. 启动 Xray"
    echo -e "2. 停止 Xray"
    echo -e "3. 重启 Xray"
    read -p "选择: " ACT
    case $ACT in
        1) systemctl start xray; echo "已启动" ;;
        2) systemctl stop xray; echo "已停止" ;;
        3) systemctl restart xray; echo "已重启" ;;
        *) echo "无效选项" ;;
    esac
}

check_logs() {
    journalctl -u xray -f -n 50
}

uninstall_xray() {
    echo -e "${RED}确定要卸载 Xray 吗? [y/N]${PLAIN}"
    read -r CONFIRM
    if [[ "$CONFIRM" != "y" ]]; then return; fi
    
    systemctl stop xray
    systemctl disable xray
    rm -f ${SYSTEMD_FILE}
    rm -rf ${XRAY_BIN_PATH}
    rm -rf ${XRAY_CONFIG_DIR}
    systemctl daemon-reload
    echo -e "${GREEN}Xray 已彻底卸载。${PLAIN}"
}

# --- 菜单循环 ---

main_menu() {
    clear
    check_status
    echo -e "=================================================="
    echo -e "          Reality & Xray 管理脚本 (Lamb 修复版)    "
    echo -e "=================================================="
    echo -e " 系统状态:"
    echo -e " - Xray 服务: ${XRAY_STATUS}    - BBR 加速: ${BBR_COLOR}"
    echo -e " - 本机 IP  : ${IP}"
    echo -e "--------------------------------------------------"
    echo -e " [ 节点管理 ]"
    echo -e " 1.  添加 VLESS + Reality 节点 (修复版)"
    echo -e " 2.  删除 指定节点"
    echo -e " 3.  查看 所有节点列表"
    echo -e ""
    echo -e " [ 系统工具 ]"
    echo -e " 4.  开启 BBR 加速 (安全模式)"
    echo -e " 5.  查看 Xray 实时日志"
    echo -e " 6.  服务控制: 启动/停止/重启"
    echo -e " 7.  彻底卸载 Xray"
    echo -e " 0.  退出脚本"
    echo -e "=================================================="
    read -p " 请输入选项 [0-7]: " num
    
    case "$num" in
        1) add_reality_node ;;
        2) delete_node ;;
        3) view_nodes ;;
        4) enable_bbr ;;
        5) check_logs ;;
        6) service_control ;;
        7) uninstall_xray ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项，请重试${PLAIN}" ;;
    esac
}

# --- 主程序入口 ---
check_root
install_dependencies
install_xray

while true; do
    main_menu
    read -p "回车继续..."
done
