#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# Reality 小机脚本（Lite） - Fixed
# - nodes/:     一用户一端口节点 (vless/ss inbound)
# - tunnels/:   tunnel(dokodemo-door) 转发 inbound
# - outbounds/: 分流出口(通常SS) outbound
# - routes/:    分流规则(域名列表 -> outboundTag)
#
# Fixes:
# 1) Robust xray x25519 parsing (avoid empty pub/priv key)
# 2) Use official config test: xray run -test -c <config>
# 3) Add cleanup for broken vless node files (empty keys)
# ==========================================================

# --------- 基本检查 ----------
if [[ $EUID -ne 0 ]]; then
  echo "请以 root 运行（sudo 或 root）"
  exit 1
fi

# 自动创建 lamb 快捷方式（可选）
if [[ "$(basename "$0")" != "lamb" ]] && [[ ! -f /usr/local/bin/lamb ]]; then
  cp "$(realpath "$0")" /usr/local/bin/lamb || true
  chmod +x /usr/local/bin/lamb || true
fi

# --------- 全局变量 ----------
XRAY_BIN="/usr/local/bin/xray"
XRAY_SERVICE="xray.service"

BASE_DIR="/usr/local/etc/xray"
NODES_DIR="$BASE_DIR/nodes"
TUNNELS_DIR="$BASE_DIR/tunnels"
OUTBOUNDS_DIR="$BASE_DIR/outbounds"
ROUTES_DIR="$BASE_DIR/routes"
XRAY_CONFIG_PATH="$BASE_DIR/config.json"
XRAY_CONFIG_BAK_DIR="$BASE_DIR/backup"

# --------- 工具函数 ----------
now_ts() { date "+%Y-%m-%d %H:%M:%S"; }

die() { echo "错误: $*" >&2; exit 1; }

valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && ((p>=1 && p<=65535))
}

get_ip() {
  curl -s ipv4.ip.sb 2>/dev/null || curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'
}

ensure_dirs() {
  mkdir -p "$BASE_DIR" "$NODES_DIR" "$TUNNELS_DIR" "$OUTBOUNDS_DIR" "$ROUTES_DIR" "$XRAY_CONFIG_BAK_DIR"
}

install_deps() {
  local deps=(curl jq openssl unzip iptables iptables-persistent netfilter-persistent python3)
  local missing=()
  for p in "${deps[@]}"; do
    dpkg -s "$p" &>/dev/null || missing+=("$p")
  done
  if ((${#missing[@]} > 0)); then
    echo "检测到缺失依赖：${missing[*]}，正在安装…"
    apt update
    apt install -y "${missing[@]}"
  fi
}

install_xray_if_missing() {
  if [[ ! -x "$XRAY_BIN" ]]; then
    echo "未检测到 Xray，开始安装…"
    curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o /tmp/install-xray.sh \
      || die "下载 Xray 安装脚本失败"
    bash /tmp/install-xray.sh install || die "Xray 安装失败"
  fi
}

bootstrap() {
  ensure_dirs
  install_deps
  install_xray_if_missing

  systemctl enable "$XRAY_SERVICE" >/dev/null 2>&1 || true

  # 如果没有配置先生成一个空配置（避免服务无配置启动失败）
  if [[ ! -f "$XRAY_CONFIG_PATH" ]]; then
    cat > "$XRAY_CONFIG_PATH" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [{ "tag":"direct","protocol":"freedom" }],
  "routing": { "domainStrategy":"AsIs", "rules":[] }
}
EOF
  fi

  systemctl restart "$XRAY_SERVICE" >/dev/null 2>&1 || true
}

status_xray() {
  systemctl status "$XRAY_SERVICE" --no-pager || true
}

# --------- 配置安全写入 + 校验 + 回滚 ----------
apply_config_safely() {
  local tmp="$XRAY_CONFIG_PATH.tmp"
  local bak="$XRAY_CONFIG_BAK_DIR/config_$(date +%Y%m%d_%H%M%S).json"

  # jq 校验
  jq . "$tmp" >/dev/null 2>&1 || die "生成的 JSON 配置无效（jq 校验未通过）"

  # 官方推荐测试：xray run -test -c <config>
  if [[ -x "$XRAY_BIN" ]]; then
    if "$XRAY_BIN" run -test -c "$tmp" >/dev/null 2>&1; then
      :
    else
      echo "警告: Xray 配置测试未通过（xray run -test -c ...），将不应用该配置"
      exit 1
    fi
  fi

  # 备份旧配置
  if [[ -f "$XRAY_CONFIG_PATH" ]]; then
    cp "$XRAY_CONFIG_PATH" "$bak" || true
  fi

  # 替换并重启
  mv "$tmp" "$XRAY_CONFIG_PATH"
  if systemctl restart "$XRAY_SERVICE"; then
    echo "配置已应用并重启 Xray 成功"
  else
    echo "重启失败，尝试回滚…"
    if [[ -f "$bak" ]]; then
      cp "$bak" "$XRAY_CONFIG_PATH"
      systemctl restart "$XRAY_SERVICE" || true
      die "已回滚到上一版配置：$bak"
    fi
    die "无可用备份，无法回滚"
  fi
}

# --------- 核心：从实体文件生成 config ----------
generate_config() {
  ensure_dirs

  local inbounds_json="[]"
  local outbounds_json="[]"
  local rules_json="[]"

  shopt -s nullglob

  # ---- inbounds: nodes ----
  for f in "$NODES_DIR"/*.json; do
    local enabled type
    enabled="$(jq -r '.enabled // true' "$f")"
    [[ "$enabled" == "true" ]] || continue
    type="$(jq -r '.type' "$f")"

    if [[ "$type" == "vless" ]]; then
      local uuid port server_name privkey short_id
      uuid="$(jq -r '.uuid' "$f")"
      port="$(jq -r '.port' "$f")"
      server_name="$(jq -r '.server_name' "$f")"
      privkey="$(jq -r '.private_key' "$f")"
      short_id="$(jq -r '.short_id' "$f")"

      # 防止坏文件导致整体无法应用：跳过空 key 的 vless
      if [[ -z "$privkey" || "$privkey" == "null" ]]; then
        echo "警告: 跳过坏的 VLESS 文件（private_key 为空）: $(basename "$f")"
        continue
      fi

      local inbound
      inbound="$(cat <<EOF
{
  "listen": "0.0.0.0",
  "port": $port,
  "protocol": "vless",
  "settings": {
    "clients": [
      { "id": "$uuid", "flow": "xtls-rprx-vision" }
    ],
    "decryption": "none"
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
      inbounds_json="$(echo "$inbounds_json" | jq --argjson x "$inbound" '. + [$x]')"

    elif [[ "$type" == "ss" ]]; then
      local port method password
      port="$(jq -r '.port' "$f")"
      method="$(jq -r '.method' "$f")"
      password="$(jq -r '.password' "$f")"

      if [[ -z "$password" || "$password" == "null" || -z "$method" || "$method" == "null" ]]; then
        echo "警告: 跳过坏的 SS 文件: $(basename "$f")"
        continue
      fi

      local inbound
      inbound="$(cat <<EOF
{
  "listen": "0.0.0.0",
  "port": $port,
  "protocol": "shadowsocks",
  "settings": {
    "method": "$method",
    "password": "$password",
    "network": "tcp,udp",
    "ivCheck": false
  }
}
EOF
)"
      inbounds_json="$(echo "$inbounds_json" | jq --argjson x "$inbound" '. + [$x]')"
    fi
  done

  # ---- inbounds: tunnels ----
  for f in "$TUNNELS_DIR"/*.json; do
    local enabled
    enabled="$(jq -r '.enabled // true' "$f")"
    [[ "$enabled" == "true" ]] || continue

    local listen_port dest_addr dest_port network
    listen_port="$(jq -r '.listen_port' "$f")"
    dest_addr="$(jq -r '.dest_addr' "$f")"
    dest_port="$(jq -r '.dest_port' "$f")"
    network="$(jq -r '.network // "tcp"' "$f")"

    local inbound
    inbound="$(cat <<EOF
{
  "listen": "0.0.0.0",
  "port": $listen_port,
  "protocol": "dokodemo-door",
  "settings": {
    "address": "$dest_addr",
    "port": $dest_port,
    "network": "$network"
  }
}
EOF
)"
    inbounds_json="$(echo "$inbounds_json" | jq --argjson x "$inbound" '. + [$x]')"
  done

  # ---- outbounds: built-in ----
  outbounds_json="$(echo "$outbounds_json" | jq '. + [{"tag":"direct","protocol":"freedom"}]')"
  outbounds_json="$(echo "$outbounds_json" | jq '. + [{"tag":"block","protocol":"blackhole"}]')"

  # ---- outbounds: custom (only shadowsocks for now) ----
  for f in "$OUTBOUNDS_DIR"/*.json; do
    local enabled
    enabled="$(jq -r '.enabled // true' "$f")"
    [[ "$enabled" == "true" ]] || continue

    local tag protocol
    tag="$(jq -r '.tag' "$f")"
    protocol="$(jq -r '.protocol' "$f")"

    if [[ "$protocol" == "shadowsocks" ]]; then
      local server port method password
      server="$(jq -r '.server' "$f")"
      port="$(jq -r '.port' "$f")"
      method="$(jq -r '.method' "$f")"
      password="$(jq -r '.password' "$f")"

      if [[ -z "$server" || "$server" == "null" || -z "$password" || "$password" == "null" ]]; then
        echo "警告: 跳过坏的 outbound 文件: $(basename "$f")"
        continue
      fi

      local ob
      ob="$(cat <<EOF
{
  "tag": "$tag",
  "protocol": "shadowsocks",
  "settings": {
    "servers": [
      {
        "address": "$server",
        "port": $port,
        "method": "$method",
        "password": "$password"
      }
    ]
  }
}
EOF
)"
      outbounds_json="$(echo "$outbounds_json" | jq --argjson x "$ob" '. + [$x]')"
    fi
  done

  # ---- routing rules: user-defined only ----
  for f in "$ROUTES_DIR"/*.json; do
    local enabled
    enabled="$(jq -r '.enabled // true' "$f")"
    [[ "$enabled" == "true" ]] || continue

    local rtype outbound_tag
    rtype="$(jq -r '.type' "$f")"
    outbound_tag="$(jq -r '.outbound' "$f")"

    if [[ "$rtype" == "domain" ]]; then
      local domains
      domains="$(jq -c '.domains' "$f")"
      local rule
      rule="$(cat <<EOF
{
  "type": "field",
  "domain": $domains,
  "outboundTag": "$outbound_tag"
}
EOF
)"
      rules_json="$(echo "$rules_json" | jq --argjson x "$rule" '. + [$x]')"
    fi
  done

  # ---- write tmp config ----
  cat > "$XRAY_CONFIG_PATH.tmp" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": $inbounds_json,
  "outbounds": $outbounds_json,
  "routing": {
    "domainStrategy": "AsIs",
    "rules": $rules_json
  }
}
EOF

  apply_config_safely
}

# --------- robust x25519 parsing ----------
get_x25519_keys() {
  local keys priv pub
  keys="$("$XRAY_BIN" x25519 2>/dev/null || true)"

  # 优先解析 "xxx: yyy"
  priv="$(echo "$keys" | awk -F': *' 'tolower($0) ~ /private/ {print $2; exit}' | tr -d '\r' | xargs)"
  pub="$(echo "$keys"  | awk -F': *' 'tolower($0) ~ /public/  {print $2; exit}' | tr -d '\r' | xargs)"

  # 兜底：没有冒号就取最后一列
  if [[ -z "$priv" || -z "$pub" ]]; then
    priv="$(echo "$keys" | awk 'tolower($0) ~ /private/ {print $NF; exit}' | tr -d '\r' | xargs)"
    pub="$(echo "$keys"  | awk 'tolower($0) ~ /public/  {print $NF; exit}' | tr -d '\r' | xargs)"
  fi

  if [[ -z "$priv" || -z "$pub" ]]; then
    echo "xray x25519 输出如下（用于排查）："
    echo "$keys"
    return 1
  fi

  echo "$priv|$pub"
  return 0
}

# --------- 实体创建 ----------
add_vless_node() {
  ensure_dirs
  install_xray_if_missing

  local domain port server_name remark
  read -rp "请输入域名或IP（默认本机公网IP）: " domain
  domain="${domain:-$(get_ip)}"

  read -rp "请输入端口（默认443）: " port
  port="${port:-443}"
  valid_port "$port" || die "端口无效"

  read -rp "请输入伪装域名 SNI（默认 itunes.apple.com）: " server_name
  server_name="${server_name:-itunes.apple.com}"

  read -rp "备注（可空）: " remark

  local uuid short_id created
  uuid="$("$XRAY_BIN" uuid)"
  short_id="$(openssl rand -hex 2)"
  created="$(now_ts)"

  local kp priv pub
  if ! kp="$(get_x25519_keys)"; then
    die "无法解析 x25519 的私钥/公钥，请检查 Xray 版本输出格式"
  fi
  priv="${kp%%|*}"
  pub="${kp##*|}"

  local file="$NODES_DIR/vless_${port}_${uuid}.json"
  cat > "$file" <<EOF
{
  "type": "vless",
  "enabled": true,
  "remark": $(jq -Rn --arg v "$remark" '$v'),
  "created_at": "$created",
  "uuid": "$uuid",
  "port": $port,
  "domain": $(jq -Rn --arg v "$domain" '$v'),
  "server_name": $(jq -Rn --arg v "$server_name" '$v'),
  "private_key": "$priv",
  "public_key": "$pub",
  "short_id": "$short_id"
}
EOF

  echo "已添加 VLESS+Reality 节点：$file"
  echo "Reality 公钥: $pub"

  generate_config

  echo "节点链接："
  echo "vless://${uuid}@${domain}:${port}?type=tcp&security=reality&pbk=${pub}&fp=chrome&sni=${server_name}&sid=${short_id}&spx=%2F&flow=xtls-rprx-vision#Reality-${port}"
}

add_ss_node() {
  ensure_dirs

  local port method password remark created id
  read -rp "请输入端口（默认10000）: " port
  port="${port:-10000}"
  valid_port "$port" || die "端口无效"

  read -rp "备注（可空）: " remark
  method="2022-blake3-aes-256-gcm"
  password="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
  created="$(now_ts)"
  id="$(openssl rand -hex 6)"

  local file="$NODES_DIR/ss_${port}_${id}.json"
  cat > "$file" <<EOF
{
  "type": "ss",
  "enabled": true,
  "remark": $(jq -Rn --arg v "$remark" '$v'),
  "created_at": "$created",
  "port": $port,
  "method": "$method",
  "password": "$password"
}
EOF

  echo "已添加 Shadowsocks 节点：$file"
  generate_config

  local ip userinfo
  ip="$(get_ip)"
  userinfo="$(printf "%s:%s" "$method" "$password" | base64 -w 0)"
  echo "节点链接："
  echo "ss://${userinfo}@${ip}:${port}#SS-${port}"
}

add_tunnel() {
  ensure_dirs

  local listen_port dest_addr dest_port network remark created
  read -rp "请输入 tunnel 监听端口（例如 12345）: " listen_port
  valid_port "$listen_port" || die "监听端口无效"

  read -rp "请输入目标地址（IP或域名）: " dest_addr
  [[ -n "$dest_addr" ]] || die "目标地址不能为空"

  read -rp "请输入目标端口（例如 443）: " dest_port
  valid_port "$dest_port" || die "目标端口无效"

  read -rp "网络类型 tcp/udp/tcp,udp（默认 tcp）: " network
  network="${network:-tcp}"

  read -rp "备注（可空）: " remark
  created="$(now_ts)"

  local file="$TUNNELS_DIR/tunnel_${listen_port}.json"
  cat > "$file" <<EOF
{
  "type": "tunnel",
  "enabled": true,
  "remark": $(jq -Rn --arg v "$remark" '$v'),
  "created_at": "$created",
  "listen_port": $listen_port,
  "dest_addr": $(jq -Rn --arg v "$dest_addr" '$v'),
  "dest_port": $dest_port,
  "network": $(jq -Rn --arg v "$network" '$v')
}
EOF

  echo "已添加 tunnel：$file"
  generate_config
}

# --------- 查看/导出 ----------
view_export_all() {
  ensure_dirs
  local export_file="/root/xray_export_$(date +%Y%m%d_%H%M%S).txt"
  : > "$export_file"

  echo "================ 节点列表（nodes） ================"
  echo "================ 节点列表（nodes） ================" >>"$export_file"

  # VLESS
  echo -e "\n[VLESS+Reality]"
  echo -e "\n[VLESS+Reality]" >>"$export_file"

  local has=false
  shopt -s nullglob
  for f in "$NODES_DIR"/vless_*.json; do
    has=true
    local uuid port domain server_name pub short_id remark enabled
    enabled="$(jq -r '.enabled // true' "$f")"
    uuid="$(jq -r '.uuid' "$f")"
    port="$(jq -r '.port' "$f")"
    domain="$(jq -r '.domain' "$f")"
    server_name="$(jq -r '.server_name' "$f")"
    pub="$(jq -r '.public_key' "$f")"
    short_id="$(jq -r '.short_id' "$f")"
    remark="$(jq -r '.remark // ""' "$f")"

    local link="vless://${uuid}@${domain}:${port}?type=tcp&security=reality&pbk=${pub}&fp=chrome&sni=${server_name}&sid=${short_id}&spx=%2F&flow=xtls-rprx-vision#Reality-${port}"
    echo "[$(basename "$f")] enabled=$enabled remark=${remark}"
    echo "$link"
    echo "[$(basename "$f")] enabled=$enabled remark=${remark}" >>"$export_file"
    echo "$link" >>"$export_file"
    echo "---" | tee -a "$export_file"
  done
  [[ "$has" == "true" ]] || { echo "(无)"; echo "(无)" >>"$export_file"; }

  # SS
  echo -e "\n[Shadowsocks]"
  echo -e "\n[Shadowsocks]" >>"$export_file"

  local ip userinfo
  ip="$(get_ip)"
  has=false
  for f in "$NODES_DIR"/ss_*.json; do
    has=true
    local port method password remark enabled
    enabled="$(jq -r '.enabled // true' "$f")"
    port="$(jq -r '.port' "$f")"
    method="$(jq -r '.method' "$f")"
    password="$(jq -r '.password' "$f")"
    remark="$(jq -r '.remark // ""' "$f")"
    userinfo="$(printf "%s:%s" "$method" "$password" | base64 -w 0)"
    local link="ss://${userinfo}@${ip}:${port}#SS-${port}"

    echo "[$(basename "$f")] enabled=$enabled remark=${remark}"
    echo "$link"
    echo "[$(basename "$f")] enabled=$enabled remark=${remark}" >>"$export_file"
    echo "$link" >>"$export_file"
    echo "---" | tee -a "$export_file"
  done
  [[ "$has" == "true" ]] || { echo "(无)"; echo "(无)" >>"$export_file"; }

  # Tunnels
  echo -e "\n================ tunnel 列表（tunnels） ================"
  echo -e "\n================ tunnel 列表（tunnels） ================" >>"$export_file"

  has=false
  for f in "$TUNNELS_DIR"/*.json; do
    has=true
    local lp da dp nw remark enabled
    enabled="$(jq -r '.enabled // true' "$f")"
    lp="$(jq -r '.listen_port' "$f")"
    da="$(jq -r '.dest_addr' "$f")"
    dp="$(jq -r '.dest_port' "$f")"
    nw="$(jq -r '.network' "$f")"
    remark="$(jq -r '.remark // ""' "$f")"

    echo "[$(basename "$f")] enabled=$enabled remark=${remark}  ${lp} -> ${da}:${dp}  (${nw})"
    echo "[$(basename "$f")] enabled=$enabled remark=${remark}  ${lp} -> ${da}:${dp}  (${nw})" >>"$export_file"
  done
  [[ "$has" == "true" ]] || { echo "(无)"; echo "(无)" >>"$export_file"; }

  echo -e "\n导出文件：$export_file"
}

# --------- 删除（统一入口） ----------
pick_and_delete() {
  ensure_dirs
  echo "请选择要删除的类型："
  echo "1) 节点（VLESS/SS）"
  echo "2) tunnel"
  echo "3) 分流出口（outbound）"
  echo "4) 分流规则（route）"
  read -rp "输入 (1-4): " t

  local files=()
  case "$t" in
    1) mapfile -t files < <(ls -1 "$NODES_DIR"/*.json 2>/dev/null || true) ;;
    2) mapfile -t files < <(ls -1 "$TUNNELS_DIR"/*.json 2>/dev/null || true) ;;
    3) mapfile -t files < <(ls -1 "$OUTBOUNDS_DIR"/*.json 2>/dev/null || true) ;;
    4) mapfile -t files < <(ls -1 "$ROUTES_DIR"/*.json 2>/dev/null || true) ;;
    *) die "无效选择" ;;
  esac

  if ((${#files[@]} == 0)); then
    echo "没有可删除的条目"
    return
  fi

  echo "可删除列表："
  local i=1
  for f in "${files[@]}"; do
    local remark enabled
    remark="$(jq -r '.remark // .name // ""' "$f" 2>/dev/null || echo "")"
    enabled="$(jq -r '.enabled // true' "$f" 2>/dev/null || echo "true")"
    echo "$i) $(basename "$f") enabled=$enabled remark=$remark"
    ((i++))
  done

  read -rp "输入序号删除: " idx
  [[ "$idx" =~ ^[0-9]+$ ]] || die "序号无效"
  ((idx>=1 && idx<=${#files[@]})) || die "序号越界"

  local target="${files[$((idx-1))]}"
  rm -f "$target"
  echo "已删除：$target"

  generate_config
}

# --------- 分流出口（outbound） ----------
set_split_outbound() {
  ensure_dirs
  echo "添加/更新 分流出口（建议填 TW 的 SS 节点）"
  local tag server port method password remark created
  read -rp "出口 tag（例如 tw）: " tag
  [[ -n "$tag" ]] || die "tag 不能为空"

  read -rp "服务器地址（IP/域名）: " server
  [[ -n "$server" ]] || die "server 不能为空"

  read -rp "端口: " port
  valid_port "$port" || die "端口无效"

  read -rp "加密方式（默认 2022-blake3-aes-256-gcm）: " method
  method="${method:-2022-blake3-aes-256-gcm}"

  read -rp "密码: " password
  [[ -n "$password" ]] || die "password 不能为空"

  read -rp "备注（可空）: " remark
  created="$(now_ts)"

  local file="$OUTBOUNDS_DIR/outbound_${tag}.json"
  cat > "$file" <<EOF
{
  "protocol": "shadowsocks",
  "enabled": true,
  "tag": $(jq -Rn --arg v "$tag" '$v'),
  "remark": $(jq -Rn --arg v "$remark" '$v'),
  "created_at": "$created",
  "server": $(jq -Rn --arg v "$server" '$v'),
  "port": $port,
  "method": $(jq -Rn --arg v "$method" '$v'),
  "password": $(jq -Rn --arg v "$password" '$v')
}
EOF

  echo "已写入分流出口：$file"
  generate_config
}

# --------- 分流规则（route） ----------
set_split_rule() {
  ensure_dirs
  echo "创建/更新 分流规则（不内置规则，你输入域名列表即可）"
  local name outbound domains_csv remark created
  read -rp "规则名（例如 ai_rule）: " name
  [[ -n "$name" ]] || die "规则名不能为空"

  read -rp "命中的出口 tag（例如 tw，或 direct/block）: " outbound
  [[ -n "$outbound" ]] || die "outbound 不能为空"

  echo "请输入域名列表（逗号分隔），例如："
  echo "openai.com,chatgpt.com,*.tiktok.com,tiktokcdn.com"
  read -rp "domains: " domains_csv
  [[ -n "$domains_csv" ]] || die "domains 不能为空"

  read -rp "备注（可空）: " remark
  created="$(now_ts)"

  local domains_json
  domains_json="$(python3 - <<PY
import json
s = """$domains_csv"""
arr = [x.strip() for x in s.split(",") if x.strip()]
print(json.dumps(arr, ensure_ascii=False))
PY
)"

  local file="$ROUTES_DIR/route_${name}.json"
  cat > "$file" <<EOF
{
  "type": "domain",
  "enabled": true,
  "name": $(jq -Rn --arg v "$name" '$v'),
  "remark": $(jq -Rn --arg v "$remark" '$v'),
  "created_at": "$created",
  "outbound": $(jq -Rn --arg v "$outbound" '$v'),
  "domains": $domains_json
}
EOF

  echo "已写入分流规则：$file"
  generate_config
}

# --------- 清理坏节点（空 key） ----------
cleanup_broken_nodes() {
  ensure_dirs
  local count=0
  shopt -s nullglob
  for f in "$NODES_DIR"/vless_*.json; do
    local priv pub
    priv="$(jq -r '.private_key // ""' "$f")"
    pub="$(jq -r '.public_key // ""' "$f")"
    if [[ -z "$priv" || "$priv" == "null" || -z "$pub" || "$pub" == "null" ]]; then
      echo "删除坏的 VLESS 节点文件（空 key）: $(basename "$f")"
      rm -f "$f"
      ((count++))
    fi
  done
  echo "清理完成，删除 $count 个坏节点文件"
  generate_config
}

# --------- 菜单 ----------
show_menu() {
  echo "======== Reality 小机脚本（Lite）========"
  echo "1) 添加 VLESS+Reality 节点"
  echo "2) 添加 Shadowsocks 节点"
  echo "3) 查看/导出 所有节点链接"
  echo "4) 添加 tunnel 转发"
  echo "5) 删除（节点 / tunnel / 出口 / 规则）"
  echo "6) 设置分流出口"
  echo "7) 设置分流规则"
  echo "8) 查看 Xray 状态"
  echo "9) 清理坏节点（空 key）"
  echo "0) 退出"
  echo "======================================="
}

main() {
  bootstrap

  while true; do
    show_menu
    read -rp "请输入选项: " c
    echo ""
    case "$c" in
      1) add_vless_node ;;
      2) add_ss_node ;;
      3) view_export_all ;;
      4) add_tunnel ;;
      5) pick_and_delete ;;
      6) set_split_outbound ;;
      7) set_split_rule ;;
      8) status_xray ;;
      9) cleanup_broken_nodes ;;
      0) exit 0 ;;
      *) echo "无效选项" ;;
    esac
    echo ""
  done
}

main
