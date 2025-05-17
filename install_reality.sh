#!/bin/bash

# 检查是否以root用户运行
if [ "$EUID" -ne 0 ]; then
  echo "错误：请以root用户运行此脚本。"
  exit 1
fi

# 检查并安装依赖
install_dependencies() {
    echo "检查并安装依赖..."
    if command -v apt > /dev/null; then
        apt update
        apt install -y curl jq uuid-runtime
    elif command -v yum > /dev/null; then
        yum update -y
        yum install -y curl jq uuidgen
    elif command -v dnf > /dev/null; then
        dnf update -y
        dnf install -y curl jq uuidgen
    else
        echo "错误：不支持的操作系统，无法安装依赖。请手动安装 curl, jq, uuidgen。"
        exit 1
    fi

    if ! command -v curl > /dev/null || ! command -v jq > /dev/null || ! command -v uuidgen > /dev/null; then
        echo "错误：依赖安装失败，请手动安装 curl, jq, uuidgen 后重试。"
        exit 1
    fi
    echo "依赖检查完成。"
}

# 安装或更新 Xray
install_xray() {
    echo "安装或更新 Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    if [ $? -ne 0 ]; then
        echo "错误：Xray 安装或更新失败。"
        exit 1
    fi
    echo "Xray 安装或更新完成。"
    systemctl enable xray
}

# 生成 VLESS Reality 配置片段
generate_reality_config() {
    local domain="$1"
    local port="$2"
    local dest="$3"

    echo "正在生成 Reality 密钥对..."
    local key_pair=$(xray x25519)
    local private_key=$(echo "$key_pair" | grep 'Private key:' | awk '{print $3}')
    local public_key=$(echo "$key_pair" | grep 'Public key:' | awk '{print $3}')

    echo "正在生成 Short ID..."
    local short_id=$(xray generate shortid)

    local uuid=$(uuidgen)
    local tag="vless-reality-$port-$uuid" # 为每个节点生成一个唯一的标签

    cat <<EOF
    {
      "listen": "0.0.0.0",
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
            "level": 0
          }
        ],
        "disallowInsecure": true
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$dest",
          "xver": 0,
          "privateKey": "$private_key",
          "minClientVersion": "",
          "maxClientVersion": "",
          "maxTimeDiff": 0,
          "shortIds": [
            "$short_id"
          ],
          "serverNames": [
            "$domain"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      },
      "tag": "$tag"
    }
EOF
    echo "$uuid,$public_key,$short_id,$tag" # 返回 uuid, public_key, short_id, tag 供后续生成链接使用
}

# URL编码函数
urlencode() {
    local string="$1"
    local strlen=${#string}
    local encoded=""
    local char
    for (( i=0; i<strlen; i++ )); do
        char=${string:$i:1}
        case "$char" in
            [a-zA-Z0-9.~_-]) encoded+="$char" ;;
            *) printf '%%%02X' "'$char" ;;
        esac
    done
    echo "$encoded"
}

# 生成 VLESS 链接
generate_vless_link() {
    local uuid="$1"
    local address="$2"
    local port="$3"
    local public_key="$4"
    local short_id="$5"
    local sni="$6"
    local tag="$7" # Use tag for the fragment

    local encoded_public_key=$(urlencode "$public_key")
    local encoded_short_id=$(urlencode "$short_id")
    local encoded_sni=$(urlencode "$sni")
    local encoded_tag=$(urlencode "$tag")

    # 使用 chrome 指纹，这是 Reality 推荐的
    local fingerprint="chrome"

    echo "vless://${uuid}@${address}:${port}?security=reality&type=tcp&pbk=${encoded_public_key}&sid=${encoded_short_id}&sni=${encoded_sni}&fp=${fingerprint}#${encoded_tag}"
}


# 添加节点
add_node() {
    echo "--- 添加 VLESS+TCP+Reality 节点 ---"
    read -p "请输入节点监听端口 (例如: 443): " node_port
    if ! [[ "$node_port" =~ ^[0-9]+$ ]] || [ "$node_port" -le 0 ] || [ "$node_port" -gt 65535 ]; then
        echo "错误：端口号无效。"
        return
    fi

    read -p "请输入 Reality 伪装域名 (例如: example.com): " reality_domain
    if [ -z "$reality_domain" ]; then
        echo "错误：域名不能为空。"
        return
    fi

    read -p "请输入 Reality 伪装目标地址 (例如: www.apple.com:443): " reality_dest
    if [ -z "$reality_dest" ]; then
        echo "错误：伪装目标地址不能为空。"
        return
    fi

    local config_path="/etc/xray/config.json"
    local node_config_info=$(generate_reality_config "$reality_domain" "$node_port" "$reality_dest")
    local uuid=$(echo "$node_config_info" | cut -d',' -f1)
    local public_key=$(echo "$node_config_info" | cut -d',' -f2)
    local short_id=$(echo "$node_config_info" | cut -d',' -f3)
    local tag=$(echo "$node_config_info" | cut -d',' -f4)
    local node_config_json=$(echo "$node_config_info" | sed 's/.*{//' | sed 's/}//') # 提取JSON片段

    if [ ! -f "$config_path" ]; then
        # 创建基础配置
        cat <<EOF > "$config_path"
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    $node_config_json
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF
    else
        # 在现有配置的inbounds数组中添加新的节点配置
        local temp_config=$(jq --argjson new_inbound "$node_config_json" '.inbounds += [$new_inbound]' "$config_path")
        echo "$temp_config" > "$config_path"
    fi

    if [ $? -ne 0 ]; then
        echo "错误：无法更新 Xray 配置文件。"
        return
    fi

    systemctl restart xray
    if [ $? -ne 0 ]; then
        echo "错误：Xray 服务重启失败，请检查配置和日志。"
        return
    fi

    # 打开防火墙端口
    echo "尝试打开防火墙端口 $node_port..."
    if command -v firewall-cmd > /dev/null; then
        firewall-cmd --zone=public --add-port=$node_port/tcp --permanent
        firewall-cmd --reload
        echo "firewalld 规则已更新。"
    elif command -v ufw > /dev/null; then
        ufw allow $node_port/tcp
        ufw reload
        echo "UFW 规则已更新。"
    else
        echo "未检测到 firewalld 或 ufw，请手动配置防火墙规则放行端口 $node_port。"
    fi

    local vless_link=$(generate_vless_link "$uuid" "$reality_domain" "$node_port" "$public_key" "$short_id" "$reality_domain" "$tag")

    echo "--- 节点添加成功 ---"
    echo "UUID: $uuid"
    echo "监听端口: $node_port"
    echo "伪装域名 (SNI): $reality_domain"
    echo "Reality 公钥 (pbk): $public_key"
    echo "Reality 短 ID (sid): $short_id"
    echo "伪装目标地址 (dest): $reality_dest"
    echo "VLESS 链接:"
    echo "$vless_link"
    echo "--------------------"
}

# 查看节点
view_nodes() {
    echo "--- 已配置的 VLESS+TCP+Reality 节点 ---"
    local config_path="/etc/xray/config.json"
    if [ ! -f "$config_path" ]; then
        echo "Xray 配置文件不存在，没有找到节点。"
        return
    fi

    local node_count=0
    jq -c '.inbounds[] | select(.protocol == "vless" and .streamSettings.network == "tcp" and .streamSettings.security == "reality")' "$config_path" | while read -r inbound; do
        local uuid=$(echo "$inbound" | jq -r '.settings.clients[0].id')
        local port=$(echo "$inbound" | jq -r '.port')
        local domain=$(echo "$inbound" | jq -r '.streamSettings.realitySettings.serverNames[0]')
        local public_key=$(echo "$inbound" | jq -r '.streamSettings.realitySettings.publicKey')
        local short_id=$(echo "$inbound" | jq -r '.streamSettings.realitySettings.shortIds[0]')
        local dest=$(echo "$inbound" | jq -r '.streamSettings.realitySettings.dest')
        local tag=$(echo "$inbound" | jq -r '.tag')

        node_count=$((node_count + 1))
        echo "--- 节点 $node_count ---"
        echo "UUID: $uuid"
        echo "监听端口: $port"
        echo "伪装域名 (SNI): $domain"
        echo "Reality 公钥 (pbk): $public_key"
        echo "Reality 短 ID (sid): $short_id"
        echo "伪装目标地址 (dest): $dest"
        local vless_link=$(generate_vless_link "$uuid" "$domain" "$port" "$public_key" "$short_id" "$domain" "$tag")
        echo "VLESS 链接:"
        echo "$vless_link"
        echo "--------------------"
    done

    if [ "$node_count" -eq 0 ]; then
        echo "没有找到 VLESS+TCP+Reality 节点。"
    fi
}

# 删除节点
delete_node() {
    echo "--- 删除 VLESS+TCP+Reality 节点 ---"
    local config_path="/etc/xray/config.json"
    if [ ! -f "$config_path" ]; then
        echo "Xray 配置文件不存在，无法删除节点。"
        return
    fi

    local nodes_info=()
    local node_count=0
     jq -c '.inbounds[] | select(.protocol == "vless" and .streamSettings.network == "tcp" and .streamSettings.security == "reality")' "$config_path" | while read -r inbound; do
        local uuid=$(echo "$inbound" | jq -r '.settings.clients[0].id')
        local port=$(echo "$inbound" | jq -r '.port')
        local domain=$(echo "$inbound" | jq -r '.streamSettings.realitySettings.serverNames[0]')
        local tag=$(echo "$inbound" | jq -r '.tag')
        node_count=$((node_count + 1))
        nodes_info+=("$uuid,$port,$domain,$tag")
        echo "$node_count. UUID: $uuid, 端口: $port, 域名: $domain, Tag: $tag"
    done

    if [ "$node_count" -eq 0 ]; then
        echo "没有找到可删除的 VLESS+TCP+Reality 节点。"
        return
    fi

    read -p "请输入要删除的节点编号: " delete_index
    if ! [[ "$delete_index" =~ ^[0-9]+$ ]] || [ "$delete_index" -le 0 ] || [ "$delete_index" -gt "$node_count" ]; then
        echo "错误：无效的节点编号。"
        return
    fi

    local target_uuid=$(echo "${nodes_info[$delete_index-1]}" | cut -d',' -f1)
    local target_port=$(echo "${nodes_info[$delete_index-1]}" | cut -d',' -f2)

    read -p "确定要删除节点 $delete_index (UUID: $target_uuid) 吗？(y/N): " confirm_delete
    if [[ "$confirm_delete" != "y" && "$confirm_delete" != "Y" ]]; then
        echo "取消删除。"
        return
    fi

    # 使用 jq 删除指定的 inbound
    local temp_config=$(jq --arg uuid "$target_uuid" 'del(.inbounds[] | select(.protocol == "vless" and .settings.clients[0].id == $uuid))' "$config_path")

    if [ -z "$temp_config" ] || [ "$temp_config" == "null" ]; then
         echo "错误：无法从配置中删除节点，或者删除后配置变为空。请手动检查 $config_path"
         return
    fi

    echo "$temp_config" > "$config_path"

    if [ $? -ne 0 ]; then
        echo "错误：无法更新 Xray 配置文件。"
        return
    fi

    systemctl restart xray
    if [ $? -ne 0 ]; then
        echo "错误：Xray 服务重启失败，请检查配置和日志。"
        return
    fi

    echo "节点 (UUID: $target_uuid) 已成功删除。"
    echo "请注意：脚本不会自动关闭防火墙端口 $target_port，如果该端口不再被任何节点使用，请手动关闭。"
}

# 主菜单
show_menu() {
    echo "--- VLESS+TCP+Reality 节点管理脚本 ---"
    echo "1. 安装/更新 Xray"
    echo "2. 添加 VLESS+TCP+Reality 节点"
    echo "3. 查看所有 VLESS+TCP+Reality 节点信息和链接"
    echo "4. 删除 VLESS+TCP+Reality 节点"
    echo "5. 退出"
    echo "----------------------------------------"
}

# 主循环
main() {
    install_dependencies
    install_xray # 确保 Xray 始终是最新或已安装

    while true; do
        show_menu
        read -p "请选择操作 (1-5): " option
        case $option in
            1)
                install_xray
                ;;
            2)
                add_node
                ;;
            3)
                view_nodes
                ;;
            4)
                delete_node
                ;;
            5)
                echo "退出脚本。"
                exit 0
                ;;
            *)
                echo "无效的选项，请重新输入。"
                ;;
        esac
        echo "" # 菜单之间空一行
    done
}

# 启动脚本
main
