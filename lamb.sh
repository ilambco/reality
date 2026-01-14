#!/usr/bin/env bash
# =========================================================
# Lamb v10 FULL FINAL
# Xray v25.10.15 固定
# Reality pbk = Password
# Tunnel = dokodemo-door
# =========================================================

XRAY_VERSION="25.10.15"
XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/usr/local/etc/xray"
XRAY_CONF="$XRAY_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/xray.service"
SCRIPT_LINK="/usr/local/bin/lamb"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

log() { echo -e "${GREEN}$1${RESET}"; }
warn(){ echo -e "${YELLOW}$1${RESET}"; }
err() { echo -e "${RED}$1${RESET}"; }

require_root() {
  [[ $EUID -ne 0 ]] && err "请使用 root 运行" && exit 1
}

safe_clear() {
  clear >/dev/null 2>&1 || true
}

pause() {
  read -rp "按回车继续..."
}

install_deps() {
  log "安装依赖..."
  apt update -y
  apt install -y curl jq unzip qrencode lsof iproute2 ca-certificates openssl
}

install_xray() {
  if [[ -x "$XRAY_BIN" ]]; then
    cur=$("$XRAY_BIN" version 2>/dev/null | head -n1)
    [[ "$cur" == *"$XRAY_VERSION"* ]] && return
  fi

  log "安装 Xray v$XRAY_VERSION ..."
  arch=$(uname -m)
  case "$arch" in
    x86_64) a="64";;
    aarch64) a="arm64-v8a";;
    *) err "不支持的架构 $arch"; exit 1;;
  esac

  tmp=$(mktemp -d)
  curl -L -o "$tmp/xray.zip" \
    "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${a}.zip"
  unzip -o "$tmp/xray.zip" -d "$tmp"
  install -m 755 "$tmp/xray" "$XRAY_BIN"
  mkdir -p "$XRAY_DIR"
  rm -rf "$tmp"

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

  systemctl daemon-reexec
  systemctl daemon-reload
  systemctl enable xray
}

ensure_config() {
  mkdir -p "$XRAY_DIR"
  [[ -f "$XRAY_CONF" ]] || cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
}

restart_xray() {
  systemctl restart xray
}

get_ip() {
  curl -s https://api.ipify.org
}

# ---------------- VLESS Reality ----------------
add_vless_reality() {
  read -rp "端口: " port
  read -rp "SNI (如 itunes.apple.com): " sni

  keys="$($XRAY_BIN x25519)"
  private_key="$(echo "$keys" | awk -F': ' '/PrivateKey/{print $2}')"
  pbk="$(echo "$keys" | awk -F': ' '/Password/{print $2}')"

  [[ -z "$private_key" || -z "$pbk" ]] && err "Reality 密钥生成失败" && pause && return

  uuid=$(cat /proc/sys/kernel/random/uuid)
  sid=$(openssl rand -hex 2)

  jq --arg port "$port" --arg uuid "$uuid" --arg sni "$sni" \
     --arg pk "$private_key" --arg sid "$sid" \
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
        "privateKey": $pk,
        "shortIds": [$sid]
      }
    }
  }]' "$XRAY_CONF" > "$XRAY_CONF.tmp" && mv "$XRAY_CONF.tmp" "$XRAY_CONF"

  restart_xray
  ip=$(get_ip)

  link="vless://${uuid}@${ip}:${port}?type=tcp&security=reality&pbk=${pbk}&fp=chrome&sni=${sni}&sid=${sid}&spx=%2F&flow=xtls-rprx-vision"
  log "VLESS Reality 创建成功："
  echo "$link"
  qrencode -t ANSIUTF8 "$link" 2>/dev/null
  pause
}

# ---------------- Shadowsocks ----------------
add_shadowsocks() {
  read -rp "端口: " port
  read -rp "密码: " pass
  read -rp "加密(aes-128-gcm/chacha20-poly1305): " method

  jq --arg port "$port" --arg pass "$pass" --arg method "$method" \
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
  ip=$(get_ip)
  base=$(echo -n "${method}:${pass}@${ip}:${port}" | base64 -w0)
  link="ss://${base}"
  log "Shadowsocks 创建成功："
  echo "$link"
  qrencode -t ANSIUTF8 "$link" 2>/dev/null
  pause
}

# ---------------- Tunnel (dokodemo-door) ----------------
add_tunnel() {
  read -rp "本地监听端口: " lport
  read -rp "目标地址: " dip
  read -rp "目标端口: " dport

  jq --arg lp "$lport" --arg dip "$dip" --arg dp "$dport" \
  '.inbounds += [{
    "port": ($lp|tonumber),
    "protocol": "dokodemo-door",
    "settings": {
      "address": $dip,
      "port": ($dp|tonumber),
      "network": "tcp,udp"
    }
  }]' "$XRAY_CONF" > "$XRAY_CONF.tmp" && mv "$XRAY_CONF.tmp" "$XRAY_CONF"

  restart_xray
  log "Tunnel 创建成功: ${lport} -> ${dip}:${dport}"
  pause
}

# ---------------- List / Delete ----------------
list_inbounds() {
  jq -r '.inbounds[] | "\(.protocol) 端口:\(.port)"' "$XRAY_CONF"
  pause
}

delete_inbound() {
  jq -r '.inbounds | to_entries[] | "\(.key): \(.value.protocol) 端口 \(.value.port)"' "$XRAY_CONF"
  read -rp "输入序号删除: " idx
  jq "del(.inbounds[$idx])" "$XRAY_CONF" > "$XRAY_CONF.tmp" && mv "$XRAY_CONF.tmp" "$XRAY_CONF"
  restart_xray
  log "已删除"
  pause
}

# ---------------- Menu ----------------
menu() {
  safe_clear
  echo "=========== Lamb v10 FULL ==========="
  echo "1. 添加 VLESS Reality"
  echo "2. 添加 Shadowsocks"
  echo "3. 添加 Tunnel (dokodemo-door)"
  echo "4. 查看所有 Inbound"
  echo "5. 删除 Inbound"
  echo "6. 查看 Xray 日志"
  echo "7. 重启 Xray"
  echo "0. 退出"
  read -rp "选择: " c
  case "$c" in
    1) add_vless_reality;;
    2) add_shadowsocks;;
    3) add_tunnel;;
    4) list_inbounds;;
    5) delete_inbound;;
    6) journalctl -u xray -f;;
    7) restart_xray;;
    0) exit 0;;
  esac
}

# ---------------- Entry ----------------
require_root
install_deps
install_xray
ensure_config
ln -sf "$0" "$SCRIPT_LINK"

while true; do menu; done
