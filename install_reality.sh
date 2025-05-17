#!/bin/bash

# Check root permission
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本"
  exit 1
fi

CONFIG_FILE="/etc/xray/config.json"
NODE_LOG="/var/log/xray_nodes.log"

# 安装 Xray
install_xray() {
    if ! command -v xray &> /dev/null; then
        echo "正在安装 Xray..."
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
        systemctl enable xray
    fi
}

# 生成新配置
generate_config() {
    local uuid=$(xray uuid)
    local key_pair=$(xray x25519)
    local private_key=$(echo "$key_pair" | awk '/Private key:/ {print $3}')
    local public_key=$(echo "$key_pair" | awk '/Public key:/ {print $3}')
    local short_id=$(openssl rand -hex 8)
    
    read -p "请输入监听端口（默认443）: " port
    port=${port:-443}

    cat > $CONFIG_FILE << EOF
{
    "inbounds": [{
        "port": $port,
        "protocol": "vless",
        "settings": {
            "clients": [{
                "id": "$uuid"
            }],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": false,
                "dest": "www.lovelive-anime.jp:443",
                "xver": 0,
                "serverNames": ["www.lovelive-anime.jp"],
                "privateKey": "$private_key",
                "shortIds": ["$short_id"]
            }
        }
    }],
    "outbounds": [{
        "protocol": "freedom"
    }]
}
EOF

    # 保存节点信息
    local node_info="$(date +'%F %T')|$uuid|$port|$public_key|$short_id"
    echo "$node_info" >> $NODE_LOG
    
    systemctl restart xray
    echo -e "\n新节点创建成功！"
    show_node_info "$node_info"
}

# 显示节点信息
show_node_info() {
    local info=(${1//|/ })
    echo -e "\n================================"
    echo "创建时间：${info[0]}"
    echo "UUID：${info[1]}"
    echo "端口：${info[2]}"
    echo "公钥：${info[3]}"
    echo "Short ID：${info[4]}"
    echo -e "================================\n"
    
    # 生成 VLESS 链接
    local vless_link="vless://${info[1]}@$(curl -4s ip.sb):${info[2]}?security=reality&encryption=none&pbk=${info[3]}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=www.lovelive-anime.jp&sid=${info[4]}#Reality_TCP_Node"
    echo -e "VLESS 链接：\n$vless_link\n"
}

# 节点管理菜单
manage_nodes() {
    echo -e "\n已创建节点："
    local nodes=()
    local index=1
    
    while IFS= read -r line; do
        echo "[$index] 创建时间：${line%%|*}"
        nodes+=("$line")
        ((index++))
    done < "$NODE_LOG"
    
    read -p "请输入要操作的节点编号 (0返回主菜单): " choice
    if [[ $choice -ge 1 && $choice -lt $index ]]; then
        selected_node=${nodes[$((choice-1))]}
        node_action_menu "$selected_node"
    fi
}

# 节点操作菜单
node_action_menu() {
    local node_info=(${1//|/ })
    echo -e "\n选择操作："
    echo "1. 查看节点信息"
    echo "2. 删除节点"
    read -p "请选择操作: " action

    case $action in
        1)
            show_node_info "$1"
            ;;
        2)
            sed -i "/${node_info[1]}/d" "$NODE_LOG"
            echo "节点已删除！"
            ;;
        *)
            echo "无效选择"
            ;;
    esac
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n======== Xray 管理菜单 ========"
        echo "1. 创建新节点"
        echo "2. 管理现有节点"
        echo "3. 退出"
        read -p "请选择操作: " choice

        case $choice in
            1)
                install_xray
                generate_config
                ;;
            2)
                manage_nodes
                ;;
            3)
                exit 0
                ;;
            *)
                echo "无效选择，请重新输入"
                ;;
        esac
    done
}

# 初始化日志文件
[ ! -f "$NODE_LOG" ] && touch "$NODE_LOG"

main_menu
