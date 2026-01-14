#!/usr/bin/env bash
# ============================================================
# Reality & Xray 管理脚本 (Lamb v9 - FINAL)
# Xray 固定版本: 25.10.15
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
  "inbounds": [],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
}

restart_xray(){ systemctl restart xray; }
server_ip(){ curl -s https://api.ipify.org; }

# ---------------- 节点 ----------------
add_vless_reality(){
  read -rp "端口: " port
  read -rp "SNI (必填，如 itunes.apple.com): " sni
  [[ -z "$sni" ]] && err "SNI 不能为空" && pause && return

  keys="$($XRAY_BIN x25519)"
  priv="$(echo "$keys" | awk -F': ' '/PrivateKey/{print $2}')"
  pbk="$(echo "$keys" | awk -F': ' '/Password/{print $2}')"
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
  ip=$(server_ip)
  link="vless://${uuid}@${ip}:${port}?type=tcp&security=reality&pbk=${pbk}&fp=chrome&sni=${sni}&sid=${sid}&spx=%2F&flow=xtls-rprx-vision"
  log "节点创建成功："
  echo "$link"
  qrencode -t ANSIUTF8 "$link" 2>/dev/null
  pause
}

add_shadowsocks(){
  read -rp "端口: " port
  read -rp "密码: " pass
  read -rp "加密(aes-128-gcm/chacha20-poly1305): " method
  jq --arg p "$port" --arg pw "$pass" --arg m "$method" \
  '.inbounds += [{
    "port": ($p|tonumber),
    "protocol": "shadowsocks",
    "settings": { "method": $m, "password": $pw, "network": "tcp,udp" }
  }]' "$XRAY_CONF" > "$XRAY_CONF.tmp" && mv "$XRAY_CONF.tmp" "$XRAY_CONF"
  restart_xray
  ip=$(server_ip)
  ss=$(echo -n "${method}:${pass}@${ip}:${port}" | base64 -w0)
  echo "ss://${ss}"
  qrencode -t ANSIUTF8 "ss://${ss}" 2>/dev/null
  pause
}

list_nodes(){
  jq -r '.inbounds | to_entries[] |
  "\(.key)) \(.value.protocol) 端口:\(.value.port)"' "$XRAY_CONF"
  pause
}

delete_node(){
  list_nodes
  read -rp "输入序号删除: " idx
  jq "del(.inbounds[$idx])" "$XRAY_CONF" > "$XRAY_CONF.tmp" && mv "$XRAY_CONF.tmp" "$XRAY_CONF"
  restart_xray
  log "已删除"
  pause
}

# ---------------- Tunnel ----------------
add_tunnel(){
  read -rp "监听端口: " lp
  read -rp "目标 IP/域名: " dip
  read -rp "目标端口: " dp
  jq --arg lp "$lp" --arg dip "$dip" --arg dp "$dp" \
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
  log "Tunnel 创建成功"
  pause
}

# ---------------- 系统 ----------------
toggle_bbr(){
  sysctl net.ipv4.tcp_congestion_control | grep -q bbr && {
    sysctl -w net.ipv4.tcp_congestion_control=cubic
    warn "BBR 已关闭"
  } || {
    modprobe tcp_bbr
    sysctl -w net.ipv4.tcp_congestion_control=bbr
    log "BBR 已开启"
  }
  pause
}

service_ctl(){
  echo "1. 启动  2. 停止  3. 重启"
  read -rp "选择: " c
  case $c in
    1) systemctl start xray;;
    2) systemctl stop xray;;
    3) systemctl restart xray;;
  esac
  pause
}

show_status(){
  clear_safe
  echo "================================================"
  echo "Reality & Xray 管理脚本 (Lamb v9)"
  echo "================================================"
  echo "Xray 版本: $XRAY_VERSION"
  systemctl is-active xray >/dev/null && echo "服务状态: 运行中" || echo "服务状态: 已停止"
  sysctl net.ipv4.tcp_congestion_control | grep -q bbr && echo "BBR: 已开启" || echo "BBR: 未开启"
  echo "本机 IP: $(server_ip)"
  echo "================================================"
}

# ---------------- 菜单 ----------------
menu(){
  show_status
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
    3) delete_node;;
    4) list_nodes;;
    5) add_tunnel;;
    6) list_nodes;;
    8) toggle_bbr;;
    9) journalctl -u xray -f;;
    10) service_ctl;;
    11) rm -f "$SELF_LINK" && log "已删除脚本"; exit 0;;
    0) exit 0;;
  esac
}

# ---------------- 入口 ----------------
install_deps
install_xray
ensure_config
ln -sf "$0" "$SELF_LINK"

while true; do menu; done
