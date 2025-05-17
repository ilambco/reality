#!/bin/bash

# 检查是否为root用户
if [ "$(id -u)" != "0" ]; then
   echo "此脚本必须以root身份运行" 1>&2
   exit 1
fi

# 定义全局变量
CONFIG_DIR="/usr/local/etc/xray/nodes"
MAIN_CONFIG="/usr/local/etc/xray/config.json"
DB_FILE="/usr/local/etc/xray/nodes.db"
XRAY_BIN="/usr/local/bin/xray"

# 初始化环境
function init_env() {
    mkdir -p "$CONFIG_DIR"
    touch "$DB_FILE"
    
    # 安装必要依赖
    if ! command -v jq &> /dev/null || ! command -v qrencode &> /dev/null; then
        apt update
        apt install -y jq qrencode openssl
    fi
}

# 合并配置文件
function merge_configs() {
  local files=("$CONFIG_DIR"/*.json)
  {
    echo '{ "log": { "loglevel": "warning" }, "inbounds": ['
    for f in "${files[@]}"; do
      cat "$f" | jq '.' 
    done | jq -s 'add | .[]' | jq -s '.'
    echo '], "outbounds": [{ "protocol": "freedom" }] }'
  } > "$MAIN_CONFIG"
}

# 节点管理函数
function node_management() {
    while true; do
        echo -e "\n===== 节点管理 ====="
        echo "1. 添加节点"
        echo "2. 删除节点"
        echo "3. 查看节点"
        echo "0. 返回主菜单"
        echo "===================="
        read -p "请输入选项: " opt
        
        case $opt in
            1) add_node ;;
            2) delete_node ;;
            3) list_nodes ;;
            0) break ;;
            *) echo "无效选项" ;;
        esac
    done
}

# 查看节点函数
function list_nodes() {
    echo -e "\n已添加的节点信息:\n"
    if [ -s "$DB_FILE" ]; then
        cat "$DB_FILE" | while read line; do
            set -- $line
            echo "端口: $1 | UUID: $2 | PublicKey: $3 | ShortID: $4 | SNI: $5 | Flow: $6 | 域名: $7"
        done
    else
        echo "没有找到任何节点记录"
    fi
}

# 删除节点函数
function delete_node() {
    list_nodes
    read -p "请输入要删除的端口号: " PORT
    if grep -q "^$PORT " "$DB_FILE"; then
        rm -f "$CONFIG_DIR/$PORT.json"
        sed -i "/^$PORT /d" "$DB_FILE"
        merge_configs
        systemctl restart xray
        echo "节点 $PORT 删除成功并释放端口。"
    else
        echo "找不到端口 $PORT 对应的节点"
    fi
}

# 其他原有函数保持不变 (add_node, xray_management, firewall_management等)
# [...]

# 主菜单
function main_menu() {
    init_env
    
    while true; do
        echo -e "\n===== Reality管理主菜单 ====="
        echo "1. 节点管理"
        echo "2. Xray管理"
        echo "3. 防火墙管理"
        echo "0. 退出"
        echo "============================="
        read -p "请输入选项: " opt
        
        case $opt in
            1) node_management ;;
            2) xray_management ;;
            3) firewall_management ;;
            0) exit 0 ;;
            *) echo "无效选项" ;;
        esac
    done
}

# 创建系统命令
function install_command() {
    if [ ! -f "/usr/local/bin/reality" ]; then
        cp "$0" /usr/local/bin/reality
        chmod +x /usr/local/bin/reality
        echo "命令 'reality' 已安装，现在可以直接在终端输入 reality 来运行本程序"
    fi
}

# 安装命令并启动
install_command
main_menu
