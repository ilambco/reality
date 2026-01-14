#!/usr/bin/env bash
# ============================================================
# Reality & Xray 管理脚本 (Lamb v9 FINAL)
# Xray v25.10.15 固定
# Reality pbk = Password
# Tunnel = dokodemo-door
# ============================================================

XRAY_VERSION="25.10.15"
XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/usr/local/etc/xray"
XRAY_CONF="$XRAY_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/xray.service"
SELF_LINK="/usr/local/bin/lamb"

GREEN="\033[32m"; RED="\033[31m"; YELLOW="\033[33m"; NC="\033[0m"
log(){ echo -e "${GREEN}$1${NC}"; }
warn(){ echo -e "${YELLOW}$1${NC}"; }
err(){ echo -e "${RED}$1${NC}"; }
pause(){ read -rp "按回车继续..."; }
clear_safe(){ clear 2>/dev/null || true; }

[[ $EUID -ne 0 ]] && err "请使用 root 运行" && exit 1

# ---------------- 基础 ----------------
install_deps(){
  apt update -y
  apt install -y curl jq unzip qrencode lsof iproute2 ca-certificates openssl
}

install_xray(){
  if [[ -x $XRAY_BIN ]] && "$XRAY_BIN" version | grep -q "$XRAY_VERSION"; then return; fi
  arch=$(uname -m)
  case "$arch" in
    x86_64) a=64;;
    aarch64) a=arm64-v8a;;
    *) err "不支持架构 $arch"; exit 1;;
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
  systemctl daemon-reload
  systemctl enable xray
}

ensure_config(){
  mkdir -p "$XRAY_DIR"
  [[ -f "$XRAY_CONF" ]] || cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": []
}
EOF
}

restart_xray(){ systemctl restart xray; }
server_ip(){ curl -s https://api.ipify.org; }

# ---------------- 节点数据工具 ----------------
save_node_meta(){
  jq --arg n "$1" --arg l "$2" '. + [{"name":$n,"link":$l}]' \
    "$XRAY_DIR/nodes.json" 2>/dev/null > "$XRAY_DIR/nodes.tmp" \
    || echo "[{\"name\":\"$1\",\"link\":\"$2\"}]" > "$XRAY_DIR/nodes.tmp"
  mv "$XRAY_DIR/nodes.tmp" "$XRAY_DIR/nodes.json"
}

# ---------------- VLESS Reality ----------------
add_vless_reality(){
  read -rp "请输入域名或IP（默认使用本机IP）: " host
  host=${host:-$(server_ip)}

  read -rp "请输入端口（默认10000）: " port
  port=${port:-10000}

  read -rp "请输入伪装域名（默认itunes.apple.com）: " sni
  sni=${sni:-itunes.apple.com}

  read -rp "名称 (默认 Reality-${port}): " name
  name=${name:-Reality-${port}}

  keys="$($XRAY_BIN x25519)"
  priv="$(awk -F': ' '/PrivateKey/{print $2}' <<< "$keys")"
  pbk="$(awk -F': ' '/Password/{print $2}' <<< "$keys")"
  [[ -z "$priv" || -z "$pbk" ]] && err "Reality 密钥生成失败" && pause && return

  uuid=$(cat /proc/sys/kernel/random/uuid)
  sid=$(openssl rand -hex 2)

  jq --arg p "$port" --arg u "$uuid" --arg s "$sni" \
     --arg pk "$priv" --arg sid "$sid" \
  '.inbounds += [{
    "port": ($p|tonumber),
    "protocol": "vless",
    "settings": {
      "clients": [{"id": $u, "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": ($s + ":443"),
        "serverNames": [$s],
        "privateKey": $pk,
        "shortIds": [$sid]
      }
    }
  }]' "$XRAY_CONF" > "$XRAY_CONF.tmp" && mv "$XRAY_CONF.tmp" "$XRAY_CONF"

  restart_xray

  link="vless://${uuid}@${host}:${port}?type=tcp&security=reality&pbk=${pbk}&fp=chrome&sni=${sni}&sid=${sid}&spx=%2F&flow=xtls-rprx-vision"
  save_node_meta "$name" "$link"

  log "VLESS Reality 节点已添加"
  echo "名称: $name"
  echo "端口: $port"
  echo "链接:"
  echo "$link"
  qrencode -t ANSIUTF8 "$link" 2>/dev/null
  pause
}

# ---------------- Shadowsocks ----------------
add_shadowsocks(){
  read -rp "请输入域名或IP（默认使用本机IP）: " host
  host=${host:-$(server_ip)}

  read -rp "请输入端口（默认20000）: " port
  port=${port:-20000}

  read -rp "名称 (默认 SS-${port}): " name
  name=${name:-SS-${port}}

  pass=$(openssl rand -base64 32)
  method="2022-blake3-aes-256-gcm"

  jq --arg p "$port" --arg pw "$pass" --arg m "$method" \
  '.inbounds += [{
    "port": ($p|tonumber),
    "protocol": "shadowsocks",
    "settings": { "method": $m, "password": $pw, "network": "tcp,udp" }
  }]' "$XRAY_CONF" > "$XRAY_CONF.tmp" && mv "$XRAY_CONF.tmp" "$XRAY_CONF"

  restart_xray

  raw="${method}:${pass}@${host}:${port}"
  link="ss://$(echo -n "$raw" | base64 -w0)"
  save_node_meta "$name" "$link"

  log "Shadowsocks 节点已添加"
  echo "端口: $port"
  echo "名称: $name"
  echo
  echo "密码: $pass"
  echo "加密方式: $method"
  echo "节点链接: $link"
  qrencode -t ANSIUTF8 "$link" 2>/dev/null
  pause
}

# ---------------- 查看节点 ----------------
list_nodes(){
  [[ ! -f "$XRAY_DIR/nodes.json" ]] && warn "暂无节点" && pause && return
  jq -r '.[] | "名称: \(.name)\n端口: (见链接)\n链接:\n\(.link)\n"' "$XRAY_DIR/nodes.json"
  pause
}

# ---------------- 菜单 ----------------
menu(){
  clear_safe
  echo "================================================"
  echo "Reality & Xray 管理脚本 (Lamb v9)"
  echo "================================================"
  echo "[ 节点管理 ]"
  echo "1. 添加 VLESS + Reality 节点"
  echo "2. 添加 Shadowsocks 节点"
  echo "3. 删除 指定节点"
  echo "4. 查看 所有节点 (链接/二维码)"
  echo
  echo "[ 隧道管理 (Tunnel) ]"
  echo "5. 添加 端口转发 (Tunnel)"
  echo "6. 查看/删除 隧道列表"
  echo
  echo "[ 系统工具 ]"
  echo "8. 开启/关闭 BBR 加速"
  echo "9. 查看 Xray 实时日志"
  echo "10. 服务控制：启动/停止/重启"
  echo "11. 重新安装 Xray / 删除脚本"
  echo "0. 退出脚本"
  echo
  read -rp "请输入选项 [0-11]: " c
  case $c in
    1) add_vless_reality;;
    2) add_shadowsocks;;
    4) list_nodes;;
    0) exit 0;;
  esac
}

# ---------------- 入口 ----------------
install_deps
install_xray
ensure_config
ln -sf "$0" "$SELF_LINK"

while true; do menu; done
