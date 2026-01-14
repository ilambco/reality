#!/usr/bin/env bash
# =========================================================
# Lamb v10 FULL FINAL
# Reality / Shadowsocks / Tunnel (dokodemo-door)
# Xray 固定版本 v25.10.15
# 兼容 wget | bash
# =========================================================

XRAY_VERSION="25.10.15"
XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/usr/local/etc/xray"
XRAY_CONF="$XRAY_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/xray.service"
SCRIPT_LINK="/usr/local/bin/lamb"

green(){ echo -e "\033[32m$1\033[0m"; }
red(){ echo -e "\033[31m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }

pause(){ read -rp "按回车继续..."; }

require_root(){
  [[ $EUID -ne 0 ]] && red "请使用 root 运行" && exit 1
}

safe_clear(){
  clear >/dev/null 2>&1 || true
}

install_deps(){
  green "安装依赖..."
  apt update -y
  apt install -y curl jq unzip qrencode lsof iproute2 ca-certificates openssl
}

install_xray(){
  if command -v xray >/dev/null && xray version | grep -q "$XRAY_VERSION"; then
    green "Xray v$XRAY_VERSION 已存在"
    return
  fi

  green "安装 Xray v$XRAY_VERSION"
  arch=$(uname -m)
  case "$arch" in
    x86_64) pkg="64" ;;
    aarch64) pkg="arm64-v8a" ;;
    *) red "不支持的架构: $arch"; return ;;
  esac

  tmp=$(mktemp -d)
  curl -L -o "$tmp/xray.zip" \
    "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${pkg}.zip"
  unzip -o "$tmp/xray.zip" -d "$tmp"
  install -m 755 "$tmp/xray" "$XRAY_BIN"
  rm -rf "$tmp"

  mkdir -p "$XRAY_DIR"
}

ensure_config(){
  mkdir -p "$XRAY_DIR"
  [[ -f $XRAY_CONF ]] && return
  cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
}

ensure_service(){
  [[ -f $SERVICE_FILE ]] && return
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=$XRAY_BIN run -config $XRAY_CONF
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable xray >/dev/null 2>&1
}

restart_xray(){
  systemctl restart xray
}

add_vless_reality(){
  read -rp "监听端口: " port
  read -rp "SNI (如 itunes.apple.com): " sni

  keys="$($XRAY_BIN x25519)"
  private_key="$(echo "$keys" | awk -F': ' '/PrivateKey/{print $2}')"
  pbk="$(echo "$keys" | awk -F': ' '/Password/{print $2}')"

  if [[ -z "$private_key" || -z "$pbk" ]]; then
    red "Reality 密钥生成失败"
    echo "$keys"
    pause
    return
  fi

  uuid=$(cat /proc/sys/kernel/random/uuid)
  sid=$(openssl rand -hex 2)

  jq --arg port "$port" --arg uuid "$uuid" --arg sni "$sni" \
     --arg priv "$private_key" --arg sid "$sid" \
  '.inbounds += [{
    "port": ($port|tonumber),
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": $uuid, "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": ($sni + ":443"),
        "serverNames": [$sni],
        "privateKey": $priv,
        "shortIds": [$sid]
      }
    }
  }]' "$XRAY_CONF" > "$XRAY_CONF.tmp" && mv "$XRAY_CONF.tmp" "$XRAY_CONF"

  restart_xray

  ip=$(curl -s https://api.ipify.org)
  link="vless://${uuid}@${ip}:${port}?type=tcp&security=reality&pbk=${pbk}&fp=chrome&sni=${sni}&sid=${sid}&spx=%2F&flow=xtls-rprx-vision"

  green "Reality 节点创建成功："
  echo "$link"
  qrencode -t ANSIUTF8 "$link" 2>/dev/null
  pause
}

add_shadowsocks(){
  read -rp "监听端口: " port
  read -rp "密码: " passwd
  read -rp "加密方式(aes-128-gcm/chacha20-poly1305): " method

  jq --arg port "$port" --arg pass "$passwd" --arg method "$method" \
  '.inbounds += [{
    "port": ($port|tonumber),
    "protocol": "shadowsocks",
    "settings": {
      "method": $method,
      "password": $pass,
      "network": "tcp,udp"
    }
  }]' "$XRAY_CONF" > "$XRAY_CONF.tmp" && mv "$XRAY_CONF.tmp" "$XRAY_CONF"

  restart_xray

  ip=$(curl -s https://api.ipify.org)
  raw="${method}:${passwd}@${ip}:${port}"
  link="ss://$(echo -n "$raw" | base64 -w0)"

  green "Shadowsocks 节点："
  echo "$link"
  qrencode -t ANSIUTF8 "$link" 2>/dev/null
  pause
}

add_tunnel(){
  read -rp "监听端口: " port
  read -rp "目标地址 (IP:PORT): " target

  jq --arg port "$port" --arg target "$target" \
  '.inbounds += [{
    "port": ($port|tonumber),
    "protocol": "dokodemo-door",
    "settings": {
      "address": ($target | split(":")[0]),
      "port": ($target | split(":")[1] | tonumber),
      "network": "tcp,udp"
    }
  }]' "$XRAY_CONF" > "$XRAY_CONF.tmp" && mv "$XRAY_CONF.tmp" "$XRAY_CONF"

  restart_xray
  green "Tunnel 已创建"
  pause
}

main_menu(){
  safe_clear
  echo "========== Lamb v10 FULL FINAL =========="
  echo "1. 添加 VLESS Reality 节点"
  echo "2. 添加 Shadowsocks 节点"
  echo "5. 添加 Tunnel (dokodemo-door)"
  echo "0. 退出"
  echo "========================================"
  read -rp "请选择: " c
  case "$c" in
    1) add_vless_reality ;;
    2) add_shadowsocks ;;
    5) add_tunnel ;;
    0) exit 0 ;;
  esac
}

require_root
install_deps
install_xray
ensure_config
ensure_service
ln -sf "$0" "$SCRIPT_LINK"

while true; do main_menu; done
