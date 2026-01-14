#!/usr/bin/env bash
# =============================================================
# Reality & Xray 管理脚本 (Lamb v10 Final)
# Xray 固定版本: v25.10.15
# Reality pbk = xray x25519 输出中的 Password
# Tunnel = dokodemo-door
# =============================================================

set -e

XRAY_VERSION="25.10.15"
XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/usr/local/etc/xray"
XRAY_CONF="$XRAY_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/xray.service"
SCRIPT_PATH="/usr/local/bin/lamb"

green() { echo -e "\033[32m$1\033[0m"; }
red()   { echo -e "\033[31m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }

require_root() {
  [[ $EUID -ne 0 ]] && red "请使用 root 运行" && exit 1
}

install_deps() {
  apt update
  apt install -y curl jq unzip qrencode lsof iproute2 ca-certificates
}

install_xray() {
  green "安装 Xray v${XRAY_VERSION} ..."
  arch=$(uname -m)
  case "$arch" in
    x86_64) a="64";;
    aarch64) a="arm64-v8a";;
    *) red "不支持的架构: $arch"; exit 1;;
  esac

  tmp=$(mktemp -d)
  curl -L -o "$tmp/xray.zip" \
    "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${a}.zip"
  unzip -o "$tmp/xray.zip" -d "$tmp"
  install -m 755 "$tmp/xray" "$XRAY_BIN"
  mkdir -p "$XRAY_DIR"
  rm -rf "$tmp"

  if [[ ! -f $SERVICE_FILE ]]; then
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=${XRAY_BIN} run -config ${XRAY_CONF}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  fi

  systemctl daemon-reexec
  systemctl daemon-reload
}

ensure_base_config() {
  mkdir -p "$XRAY_DIR"
  [[ -f $XRAY_CONF ]] || cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
}

restart_xray() {
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
}

add_vless_reality() {
  read -rp "端口: " port
  read -rp "SNI (如 itunes.apple.com): " sni

  keys="$(${XRAY_BIN} x25519)"
  private_key="$(echo "$keys" | awk -F': ' '/PrivateKey/{print $2}')"
  pbk="$(echo "$keys" | awk -F': ' '/Password/{print $2}')"

  [[ -z "$private_key" || -z "$pbk" ]] && red "Reality 密钥生成失败" && exit 1

  uuid=$(cat /proc/sys/kernel/random/uuid)
  sid=$(openssl rand -hex 2)

  jq --arg port "$port" \
     --arg uuid "$uuid" \
     --arg sni "$sni" \
     --arg priv "$private_key" \
     --arg sid "$sid" \
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

  green "节点创建成功："
  echo "$link"
  command -v qrencode >/dev/null && qrencode -t ANSIUTF8 "$link"
}

main_menu() {
  clear
  echo "=========== Reality & Xray (Lamb v10 Final) ==========="
  echo "1. 添加 VLESS + Reality 节点"
  echo "0. 退出"
  read -rp "请选择: " c
  case "$c" in
    1) add_vless_reality;;
    0) exit 0;;
  esac
}

require_root
install_deps
install_xray
ensure_base_config

ln -sf "$0" "$SCRIPT_PATH"

while true; do main_menu; done
