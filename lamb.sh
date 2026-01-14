#!/bin/bash
# Reality & Xray 管理脚本 (Lamb v9)
# 说明：
# - 强制安装/更新到 Xray v25.10.15（避免与新版不兼容）
# - 菜单与功能按截图对齐：节点管理 / 隧道管理(占位) / 系统工具
# - VLESS+Reality 节点可用；Shadowsocks / Tunnel 功能暂未启用（保留菜单入口）

set -euo pipefail

# 自动创建 lamb 快捷方式（首次运行时执行）
if [[ "$(basename "$0")" != "lamb" ]] && [[ ! -f /usr/local/bin/lamb ]]; then
  cp "$(realpath "$0")" /usr/local/bin/lamb || { echo "无法创建快捷方式"; exit 1; }
  chmod +x /usr/local/bin/lamb || { echo "无法设置执行权限"; exit 1; }
  echo "已创建快捷指令 'lamb'，您可以通过运行 lamb 快速打开脚本"
fi

# 必须以 root 运行
if [[ ${EUID:-999} -ne 0 ]]; then
  echo "请以 root 用户运行此脚本（使用 sudo 或直接切换为 root）"
  exit 1
fi

# ========= 全局变量 =========
SCRIPT_VER="v9"
XRAY_VERSION_PIN="25.10.15"

XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SERVICE_FILE="/etc/systemd/system/xray.service"
XRAY_SERVICE_NAME="xray.service"

UUID_DIR="/usr/local/etc/xray/clients"
SS_DIR="/usr/local/etc/xray/ss_clients"

mkdir -p "$UUID_DIR" "$SS_DIR" /usr/local/etc/xray

# ========= 工具函数 =========
log() { echo -e "$*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ensure_deps() {
  local deps=(curl jq openssl unzip)
  local missing=()
  for p in "${deps[@]}"; do
    need_cmd "$p" || missing+=("$p")
  done

  # qrencode 仅用于输出二维码（可选）
  if ! need_cmd qrencode; then
    : # optional
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    log "检测到缺失依赖：${missing[*]}，正在安装…"
    export DEBIAN_FRONTEND=noninteractive
    apt update -y
    apt install -y "${missing[@]}"
  fi
}

get_ip() {
  curl -s ipv4.ip.sb || curl -s ifconfig.me || hostname -I | awk '{print $1}'
}

bbr_enabled() {
  sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -qi bbr
}

service_state() {
  if systemctl list-unit-files | grep -q '^xray\.service'; then
    systemctl is-active --quiet "$XRAY_SERVICE_NAME" && echo "运行中" || echo "未运行"
  else
    echo "未安装"
  fi
}

xray_version() {
  if [[ -x "$XRAY_BIN" ]]; then
    "$XRAY_BIN" version 2>/dev/null | head -n 1 | awk '{print $2}' || true
  fi
}

# ========= Xray 安装/更新（强制版本） =========
create_systemd_service_if_missing() {
  if [[ -f "$XRAY_SERVICE_FILE" ]]; then
    return 0
  fi

  cat > "$XRAY_SERVICE_FILE" <<'EOF'
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$XRAY_SERVICE_NAME" >/dev/null 2>&1 || true
}

download_and_install_xray_pinned() {
  local arch
  arch="$(uname -m)"
  local asset=""
  case "$arch" in
    x86_64|amd64) asset="Xray-linux-64.zip" ;;
    aarch64|arm64) asset="Xray-linux-arm64-v8a.zip" ;;
    armv7l|armv7) asset="Xray-linux-arm32-v7a.zip" ;;
    *) echo "不支持的架构：$arch"; exit 1 ;;
  esac

  local url="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION_PIN}/${asset}"
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  log "开始下载 Xray v${XRAY_VERSION_PIN}（${asset}）…"
  curl -fL "$url" -o "$tmpdir/xray.zip"

  unzip -o "$tmpdir/xray.zip" -d "$tmpdir/out" >/dev/null
  if [[ ! -f "$tmpdir/out/xray" ]]; then
    echo "安装包中未找到 xray 可执行文件，下载可能失败或版本资源变更。"
    exit 1
  fi

  install -m 0755 "$tmpdir/out/xray" "$XRAY_BIN"
  create_systemd_service_if_missing

  # 初始化配置（如不存在）
  if [[ ! -f "$XRAY_CONFIG_PATH" ]]; then
    cat > "$XRAY_CONFIG_PATH" <<'EOF'
{
  "inbounds": [],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF
  fi

  log "Xray 已安装/更新到 v${XRAY_VERSION_PIN}"
}

install_or_update_xray() {
  download_and_install_xray_pinned
  systemctl restart "$XRAY_SERVICE_NAME" >/dev/null 2>&1 || systemctl start "$XRAY_SERVICE_NAME" >/dev/null 2>&1 || true
}

uninstall_xray() {
  systemctl stop "$XRAY_SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl disable "$XRAY_SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$XRAY_BIN"
  rm -rf /usr/local/etc/xray
  rm -f "$XRAY_SERVICE_FILE"
  systemctl daemon-reload
  log "Xray 已彻底卸载"
}

# ========= 服务控制 =========
start_xray() { systemctl start "$XRAY_SERVICE_NAME"; log "Xray 已启动"; }
stop_xray()  { systemctl stop  "$XRAY_SERVICE_NAME"; log "Xray 已停止"; }
restart_xray(){ systemctl restart "$XRAY_SERVICE_NAME"; log "Xray 已重启"; }

# ========= 日志 =========
tail_xray_log() {
  log "按 Ctrl+C 退出实时日志…"
  journalctl -u "$XRAY_SERVICE_NAME" -f --no-pager
}

# ========= BBR =========
enable_bbr() {
  modprobe tcp_bbr || { echo "加载 BBR 模块失败"; exit 1; }
  grep -q '^tcp_bbr$' /etc/modules-load.d/modules.conf 2>/dev/null || echo "tcp_bbr" >> /etc/modules-load.d/modules.conf

  # 防止重复写入
  grep -q '^net.core.default_qdisc=fq$' /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  grep -q '^net.ipv4.tcp_congestion_control=bbr$' /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

  sysctl -p >/dev/null
  log "BBR：已开启"
}

disable_bbr() {
  sed -i '/^tcp_bbr$/d' /etc/modules-load.d/modules.conf 2>/dev/null || true
  sed -i '/^net.core.default_qdisc=fq$/d' /etc/sysctl.conf 2>/dev/null || true
  sed -i '/^net.ipv4.tcp_congestion_control=bbr$/d' /etc/sysctl.conf 2>/dev/null || true
  sysctl -p >/dev/null || true
  log "BBR：已关闭（已移除配置）"
}

toggle_bbr() {
  if bbr_enabled; then
    disable_bbr
  else
    enable_bbr
  fi
}

# ========= 节点管理（VLESS + Reality） =========
ensure_xray_ready() {
  if [[ ! -x "$XRAY_BIN" ]]; then
    echo "未检测到 Xray，先执行 11 -> 安装/更新 Xray（固定 v${XRAY_VERSION_PIN}）"
    return 1
  fi
  return 0
}

generate_config() {
  local inbounds="[]"

  # VLESS 节点
  for file in "$UUID_DIR"/*.json; do
    [[ -f "$file" ]] || continue
    local proto
    proto="$(jq -r .protocol "$file" 2>/dev/null || echo "")"
    [[ "$proto" == "vless" ]] || continue

    local uuid port server_name privkey short_id
    uuid="$(jq -r .uuid "$file")"
    port="$(jq -r .port "$file")"
    server_name="$(jq -r .server_name "$file")"
    privkey="$(jq -r .private_key "$file")"
    short_id="$(jq -r .short_id "$file")"

    local inbound
    inbound="$(cat <<EOF
{
  "port": $port,
  "protocol": "vless",
  "settings": {
    "clients": [
      { "id": "$uuid", "flow": "xtls-rprx-vision" }
    ],
    "decryption": "none",
    "fallbacks": []
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "dest": "$server_name:443",
      "xver": 0,
      "serverNames": ["$server_name"],
      "privateKey": "$privkey",
      "shortIds": ["$short_id"]
    }
  }
}
EOF
)"
    inbounds="$(echo "$inbounds" | jq ". + [$inbound]")"
  done

  # 写入配置文件
  echo "$inbounds" | jq . >/dev/null 2>&1 || { echo "生成的 JSON 配置无效"; exit 1; }
  cat > "$XRAY_CONFIG_PATH" <<EOF
{
  "inbounds": $inbounds,
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF
}

add_vless_reality_node() {
  ensure_xray_ready || return 0

  read -p "请输入域名或IP（默认使用本机IP）: " DOMAIN
  DOMAIN="${DOMAIN:-$(get_ip)}"

  read -p "请输入端口（默认443）: " VLESS_PORT
  VLESS_PORT="${VLESS_PORT:-443}"

  read -p "请输入伪装域名（默认itunes.apple.com）: " SERVER_NAME
  SERVER_NAME="${SERVER_NAME:-itunes.apple.com}"

  local uuid keys priv pub short_id
  uuid="$("$XRAY_BIN" uuid)"
  keys="$("$XRAY_BIN" x25519)"
  priv="$(echo "$keys" | awk '/Private/{print $3}')"
  pub="$(echo "$keys"  | awk '/Public/{print $3}')"
  short_id="$(openssl rand -hex 2)"

  local client_file="$UUID_DIR/${uuid}_${VLESS_PORT}.json"
  cat > "$client_file" <<EOF
{
  "protocol": "vless",
  "uuid": "$uuid",
  "port": $VLESS_PORT,
  "domain": "$DOMAIN",
  "server_name": "$SERVER_NAME",
  "private_key": "$priv",
  "public_key": "$pub",
  "short_id": "$short_id"
}
EOF

  generate_config
  systemctl restart "$XRAY_SERVICE_NAME" >/dev/null 2>&1 || true

  local link="vless://${uuid}@${DOMAIN}:${VLESS_PORT}?type=tcp&security=reality&pbk=${pub}&fp=chrome&sni=${SERVER_NAME}&sid=${short_id}&spx=%2F&flow=xtls-rprx-vision#Reality-${DOMAIN}"
  log "\n节点已添加："
  log "- 端口：$VLESS_PORT"
  log "- UUID：$uuid"
  log "- Reality 公钥：$pub"
  log "- 链接：$link"

  if need_cmd qrencode; then
    log "\n二维码（终端显示）："
    qrencode -t ansiutf8 "$link" || true
  else
    log "\n提示：安装 qrencode 后可在终端直接输出二维码：apt install -y qrencode"
  fi
}

remove_node() {
  echo "现有 VLESS 节点："
  ls -1 "$UUID_DIR" 2>/dev/null | grep -E '\.json$' || { echo "暂无节点"; return 0; }

  read -p "请输入要删除的 UUID（或直接粘贴文件名前缀 UUID）： " DEL_UUID
  local f
  f="$(find "$UUID_DIR" -maxdepth 1 -type f -name "${DEL_UUID}_*.json" -print -quit || true)"
  if [[ -n "${f:-}" && -f "$f" ]]; then
    rm -f "$f"
    generate_config
    systemctl restart "$XRAY_SERVICE_NAME" >/dev/null 2>&1 || true
    echo "已删除：$f"
  else
    echo "未找到对应 UUID 的节点"
  fi
}

view_nodes() {
  echo "【VLESS 节点列表】"
  local found=0
  for file in "$UUID_DIR"/*.json; do
    [[ -e "$file" ]] || continue
    local proto
    proto="$(jq -r .protocol "$file" 2>/dev/null || echo "")"
    [[ "$proto" == "vless" ]] || continue
    found=1

    local uuid domain port server_name pub short_id
    uuid="$(jq -r .uuid "$file")"
    domain="$(jq -r .domain "$file")"
    port="$(jq -r .port "$file")"
    server_name="$(jq -r .server_name "$file")"
    pub="$(jq -r .public_key "$file")"
    short_id="$(jq -r .short_id "$file")"

    local link="vless://${uuid}@${domain}:${port}?type=tcp&security=reality&pbk=${pub}&fp=chrome&sni=${server_name}&sid=${short_id}&spx=%2F&flow=xtls-rprx-vision#Reality-${port}"

    echo "----------------------------------------"
    echo "端口: $port"
    echo "UUID: $uuid"
    echo "Reality 公钥: $pub"
    echo "链接: $link"
    if need_cmd qrencode; then
      qrencode -t ansiutf8 "$link" || true
    fi
  done

  if [[ $found -eq 0 ]]; then
    echo "暂无 VLESS 节点"
  fi
}

# ========= 隧道管理（占位） =========
tunnel_add_placeholder() {
  echo "该功能（端口转发 Tunnel）当前未启用：菜单占位。"
  echo "如需实现：请说明希望的模式（例如 dokodemo-door/iptables/socat），我可以按你的目标补全。"
}
tunnel_list_placeholder() {
  echo "该功能（查看/删除 隧道列表）当前未启用：菜单占位。"
}

# ========= 脚本管理 =========
delete_script() {
  echo "即将删除脚本和快捷指令..."
  rm -f "$(realpath "$0")" || true
  rm -f /usr/local/bin/lamb || true
  echo "脚本和 lamb 快捷方式已删除"
  exit 0
}

# ========= UI =========
show_header() {
  clear || true
  echo "============================================================"
  echo "        Reality & Xray 管理脚本 (Lamb ${SCRIPT_VER})"
  echo "============================================================"
  echo
  echo "系统状态："
  echo "- Xray 版本：${XRAY_VERSION_PIN}（强制固定）"
  local installed_ver
  installed_ver="$(xray_version || true)"
  if [[ -n "${installed_ver:-}" ]]; then
    echo "  - 已安装版本：${installed_ver}"
  else
    echo "  - 已安装版本：未安装"
  fi
  echo "- 服务状态：$(service_state)"
  echo "- 本机 IP  ：$(get_ip)"
  if bbr_enabled; then
    echo "- BBR：已开启"
  else
    echo "- BBR：未开启"
  fi
  echo
}

show_menu() {
  echo "[ 节点管理 ]"
  echo "1.  添加 VLESS + Reality 节点"
  echo "2.  添加 Shadowsocks 节点（未启用）"
  echo "3.  删除 指定节点"
  echo "4.  查看 所有节点（链接/二维码）"
  echo
  echo "[ 隧道管理 (Tunnel) ]"
  echo "5.  添加 端口转发 (Tunnel)（未启用）"
  echo "6.  查看/删除 隧道列表（未启用）"
  echo
  echo "[ 系统工具 ]"
  echo "8.  开启/关闭 BBR 加速"
  echo "9.  查看 Xray 实时日志"
  echo "10. 服务控制：启动/停止/重启"
  echo "11. 安装/更新 Xray（固定 v${XRAY_VERSION_PIN}） / 彻底卸载 Xray / 删除脚本"
  echo
  echo "0.  退出脚本"
  echo "------------------------------------------------------------"
}

service_control_menu() {
  echo
  echo "服务控制："
  echo "1) 启动"
  echo "2) 停止"
  echo "3) 重启"
  echo "0) 返回"
  read -p "请选择 (0-3): " c
  case "$c" in
    1) start_xray;;
    2) stop_xray;;
    3) restart_xray;;
    0) ;;
    *) echo "无效选择";;
  esac
}

xray_manage_menu() {
  echo
  echo "Xray / 脚本管理："
  echo "1) 安装/更新 Xray（强制 v${XRAY_VERSION_PIN}）"
  echo "2) 彻底卸载 Xray"
  echo "3) 删除脚本（含 lamb 快捷方式）"
  echo "0) 返回"
  read -p "请选择 (0-3): " c
  case "$c" in
    1) install_or_update_xray;;
    2) uninstall_xray;;
    3) delete_script;;
    0) ;;
    *) echo "无效选择";;
  esac
}

# ========= 主循环 =========
main() {
  ensure_deps

  while true; do
    show_header
    show_menu
    read -p "请输入选项 [0-11]: " choice
    case "$choice" in
      1) add_vless_reality_node;;
      2) echo "Shadowsocks 节点功能未启用（菜单占位）。";;
      3) remove_node;;
      4) view_nodes;;
      5) tunnel_add_placeholder;;
      6) tunnel_list_placeholder;;
      8) toggle_bbr;;
      9) tail_xray_log;;
      10) service_control_menu;;
      11) xray_manage_menu;;
      0) exit 0;;
      *) echo "无效选项，请重新输入";;
    esac
    echo
    read -p "按回车继续..." _ || true
  done
}

main "$@"
