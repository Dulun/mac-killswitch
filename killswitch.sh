#!/usr/bin/env bash
# mac-killswitch — macOS fail-closed 防火墙开关
#
# 核心逻辑：
# 1. 开启时：自动将 Clash 切换为全局模式（global）并确保开启 TUN 虚拟网卡；
#    从 Clash 提取当前选中节点的 IP 与端口；
#    配置内核 pf 防火墙：仅放行 本机回环、TUN 虚拟网卡、局域网私网、DNS 与该节点连接，其余物理网卡流量全部丢弃。
# 2. 关闭时：彻底停用 pf 防火墙，将 Clash 恢复为规则分流模式（rule）。
# 3. 状态判断：永远直接查询内核 pf 状态，不依赖任何本地标记文件，杜绝虚假状态。
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
STATE_DIR="$ROOT_DIR/.state"
mkdir -p "$BUILD_DIR" "$STATE_DIR"

AM_ROOT=0
[ "$(id -u)" = "0" ] && AM_ROOT=1
OWNER_UID="${SUDO_UID:-$(id -u)}"
if [ "$AM_ROOT" = "1" ] && [ -n "$OWNER_UID" ]; then
  trap 'chown -R "$OWNER_UID" "$BUILD_DIR" "$STATE_DIR" 2>/dev/null' EXIT
fi

[ -f "$ROOT_DIR/config.env" ] && . "$ROOT_DIR/config.env"

: "${NODE_ENDPOINTS:=}"
: "${DNS_SERVERS:=114.114.114.114 223.5.5.5 223.6.6.6 119.29.29.29}"
: "${DOH_HOSTS:=dns.alidns.com doh.pub}"
: "${LAN_CIDRS:=192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 169.254.0.0/16 224.0.0.0/4}"
: "${PROBE_IPS:=1.1.1.1 8.8.8.8}"

C_OK=$'\033[32m'
C_BAD=$'\033[31m'
C_WARN=$'\033[33m'
C_DIM=$'\033[2m'
C_OFF=$'\033[0m'

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✔%s %s\n' "$C_OK" "$C_OFF" "$*"; }
bad()  { printf '%s✘%s %s\n' "$C_BAD" "$C_OFF" "$*"; }
warn() { printf '%s⚠%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

# ---- 权限与 pf 命令封装 ----------------------------------------------------
PFC=/sbin/pfctl

has_sudo() {
  [ "$AM_ROOT" = "1" ] && return 0
  sudo -n "$PFC" -s info >/dev/null 2>&1
}

sf() {
  if [ "$AM_ROOT" = "1" ]; then
    "$PFC" "$@"
  else
    sudo "$PFC" "$@"
  fi
}

pfq() {
  if [ "$AM_ROOT" = "1" ]; then
    "$PFC" "$@" 2>/dev/null
  else
    sudo -n "$PFC" "$@" 2>/dev/null
  fi
}

ensure_sudo() {
  [ "$AM_ROOT" = "1" ] && return 0
  has_sudo && return 0
  say "需要管理员权限管理防火墙，请输入一次密码："
  sudo -v || { bad "无法获得管理员权限"; return 1; }
  return 0
}

fw_enabled() {
  pfq -s info | grep -q 'Status: Enabled'
}

fw_is_ours() {
  pfq -s rules | grep -q '^pass quick on lo0 all$'
}

# ---- Clash 控制 API --------------------------------------------------------
find_sock() {
  local g
  for g in /var/run/clash-verge-service/users/*/verge-mihomo.sock \
           /var/folders/*/*/T/verge-mihomo.sock; do
    [ -S "$g" ] && { printf '%s' "$g"; return 0; }
  done
  return 1
}

SOCK="$(find_sock || true)"

clash_api() {
  [ -n "${SOCK:-}" ] || return 1
  local m="$1" p="$2" d="${3:-}"
  if [ -n "$d" ]; then
    curl -s --max-time 6 --unix-socket "$SOCK" -X "$m" -H 'Content-Type: application/json' -d "$d" "http://localhost$p"
  else
    curl -s --max-time 6 --unix-socket "$SOCK" -X "$m" "http://localhost$p"
  fi
}

clash_cfg()      { clash_api GET /configs | jq -r "$1 // empty" 2>/dev/null; }
clash_mode()     { clash_cfg '.mode'; }
clash_tun()      { clash_cfg '.tun.enable'; }
clash_now()      { clash_api GET /proxies | jq -r --arg n "$1" '.proxies[$n].now // empty' 2>/dev/null; }
clash_set_mode() { clash_api PATCH /configs "{\"mode\":\"$1\"}" >/dev/null; }
clash_select()   { clash_api PUT "/proxies/$1" "{\"name\":\"$2\"}" >/dev/null; }

clash_ensure_tun() {
  if [ "$(clash_tun)" != "true" ]; then
    say "→ 自动开启 Clash TUN 虚拟网卡…"
    clash_api PATCH /configs '{"tun":{"enable":true}}' >/dev/null
    sleep 0.5
  fi
}

tun_device() {
  local d
  d="$(clash_cfg '.tun.device')"
  if [ -z "$d" ]; then
    for i in $(ifconfig -l | tr ' ' '\n' | grep '^utun'); do
      ifconfig "$i" 2>/dev/null | grep -q '198\.18\.' && { d="$i"; break; }
    done
  fi
  printf '%s' "${d:-utun1024}"
}

# 寻找当前生效的代理节点名称
find_active_node() {
  local n
  n="$(clash_now GLOBAL)"
  case "$n" in
    ""|DIRECT|REJECT|REJECT-DROP)
      # 如果 GLOBAL 未设置或指向直连，尝试从常见分组寻找
      local grp
      for grp in "🚀 节点选择" "良心云" "节点选择" "PROXY"; do
        n="$(clash_now "$grp")"
        case "$n" in ""|DIRECT|REJECT|REJECT-DROP) ;; *) break ;; esac
      done
      ;;
  esac
  case "$n" in
    ""|DIRECT|REJECT|REJECT-DROP)
      # 如果还是找不到，从所有代理中挑选第一个非直连节点
      n="$(clash_api GET /proxies | jq -r '[.proxies[] | select(.type=="Vless" or .type=="Hysteria2" or .type=="Shadowsocks" or .type=="Trojan") | .name][0] // empty' 2>/dev/null)"
      ;;
  esac
  printf '%s' "$n"
}

# ---- 节点端点探测 -----------------------------------------------------------
current_profile_file() {
  local v_dir="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
  local cur
  cur="$(grep -E '^current:' "${v_dir}/profiles.yaml" 2>/dev/null | awk '{print $2}')"
  [ -n "$cur" ] && printf '%s' "${v_dir}/profiles/${cur}.yaml"
}

resolve_a() {
  local h="$1" ips
  ips="$(curl -s --max-time 5 "https://dns.alidns.com/resolve?name=$h&type=A" 2>/dev/null | jq -r '.Answer[]? | select(.type==1) | .data' 2>/dev/null)"
  [ -z "$ips" ] && ips="$(dig +short A "$h" 2>/dev/null)"
  printf '%s\n' "$ips" | grep -E '^[0-9.]+$' | grep -v '^198\.18\.' | sort -u
}

detect_endpoints() {
  local target_node="$1"
  local pf eps
  pf="$(current_profile_file)"
  [ -f "$pf" ] || return 1

  eps="$(python3 "$ROOT_DIR/lib/node_endpoints.py" "$pf" "$target_node" 2>/dev/null)"
  [ -n "$eps" ] || return 1

  printf '%s\n' "$eps" | while IFS= read -r ep; do
    [ -z "$ep" ] && continue
    local host="${ep%%:*}" port="${ep#*:}"
    [ -z "$port" ] && continue
    case "$host" in
      *[!0-9.]*)
        for ip in $(resolve_a "$host"); do
          [ -n "$ip" ] && printf '%s:%s\n' "$ip" "$port"
        done
        ;;
      *)
        printf '%s:%s\n' "$host" "$port"
        ;;
    esac
  done | sort -u | paste -sd, -
}

# ---- pf 规则生成 ------------------------------------------------------------
gen_rules() {
  local tun="$1"
  local f="$BUILD_DIR/pf.rules"

  local doh_ips=""
  for h in $DOH_HOSTS; do
    doh_ips="$doh_ips $(resolve_a "$h" | tr '\n' ' ')"
  done

  cat > "$f" <<EOF
set skip on lo0
set block-policy drop

block drop all

pass quick on lo0 all
pass quick on ${tun} all
pass quick from any to { ${LAN_CIDRS// /,} }
pass quick proto udp from any port 68 to any port 67
pass out quick proto { tcp, udp } to { ${DNS_SERVERS// /,} } port { 53, 853 }
EOF

  if [ -n "$doh_ips" ]; then
    local doh_clean
    doh_clean="$(echo "$doh_ips" | tr -s ' ' ',')"
    cat >> "$f" <<EOF
pass out quick proto tcp to { ${doh_clean#,} } port 443
EOF
  fi

  # 放行唯一的当前节点端点 (IP:PORT)
  IFS=',' read -ra ADDR <<< "$NODE_ENDPOINTS"
  for ep in "${ADDR[@]}"; do
    ep="$(echo "$ep" | tr -d ' ')"
    [ -z "$ep" ] && continue
    local ip="${ep%%:*}"
    local port="${ep#*:}"
    [ -z "$port" ] || [ "$port" = "$ip" ] && port="443"
    cat >> "$f" <<EOF
pass out quick inet proto tcp from any to $ip port = $port flags S/SA keep state
pass out quick inet proto udp from any to $ip port = $port keep state
EOF
  done
}

tunnel_egress() {
  curl -s --max-time 6 https://ipinfo.io/json 2>/dev/null | jq -r '.ip + " " + .city + " " + .country' 2>/dev/null || true
}

block_packets() {
  pfq -s rules -v 2>/dev/null | awk '/block drop quick all/ {getline; print $2}' | tr -d ' '
}

# ---- 核心动作 ---------------------------------------------------------------
do_on() {
  ensure_sudo || return 1

  if [ -z "${SOCK:-}" ]; then
    bad "未找到 Clash 控制 Socket（请先启动 Clash Verge）"
    return 1
  fi

  # 1. 自动启用 TUN 虚拟网卡
  clash_ensure_tun
  local tun
  tun="$(tun_device)"

  # 2. 自动切换 Clash 为全局模式 (global)
  local current_mode
  current_mode="$(clash_mode)"
  if [ "$current_mode" != "global" ]; then
    printf '%s' "$current_mode" > "$STATE_DIR/mode.saved"
    clash_set_mode "global"
    ok "已自动将 Clash 切换为全局模式（原模式: ${current_mode}）"
  fi

  # 3. 确定当前选中的节点并确保 GLOBAL 指向它
  local node
  node="$(find_active_node)"
  if [ -z "$node" ]; then
    bad "无法在 Clash 中找到有效可用节点，请在 Clash 中选择一个节点后再开"
    return 1
  fi
  clash_select GLOBAL "$node"
  ok "当前出网节点：${node}"

  # 4. 获取节点白名单端点 (IP:PORT)
  if [ -z "$NODE_ENDPOINTS" ]; then
    NODE_ENDPOINTS="$(detect_endpoints "$node")"
    if [ -z "$NODE_ENDPOINTS" ]; then
      bad "自动探测节点 ${node} 的服务器 IP 失败，请在 config.env 手动填写 NODE_ENDPOINTS"
      return 1
    fi
  fi
  ok "放行节点端点：${NODE_ENDPOINTS}"

  # 5. 生成并载入防火墙规则
  gen_rules "$tun"
  say "→ 载入内核 pf 规则（放行 TUN 虚拟网卡: ${tun} 与节点: ${NODE_ENDPOINTS}）…"
  sf -f "$BUILD_DIR/pf.rules" || { bad "pf 规则载入失败"; return 1; }
  sf -E >/dev/null 2>&1 || true

  if ! fw_enabled; then
    bad "防火墙未能成功启用"
    return 1
  fi
  ok "防火墙已在内核生效：物理网卡旁路直连全部掐断，仅允许经由 Clash TUN"

  # 6. 安全回滚机制：实测隧道是否连通互联网
  say "→ 正在验证隧道连通性…"
  local egress
  egress="$(tunnel_egress)"
  if [ -z "$egress" ]; then
    bad "开启后隧道无法连接互联网！"
    warn "触发安全回滚：正在还原系统并关闭防火墙，避免断网…"
    do_off
    return 1
  fi

  ok "全链路通畅！出口 IP：${egress}"
  say "提示：当前为极致收紧模式，仅放行此单个节点；Clash 内测速其他节点报 Timeout 属正常现象。"
}

do_off() {
  ensure_sudo || return 1
  say "→ 正在停用内核 pf 防火墙…"
  sf -d >/dev/null 2>&1 || true

  # 恢复 Clash 为规则模式
  if [ -n "${SOCK:-}" ]; then
    local saved="rule"
    if [ -f "$STATE_DIR/mode.saved" ]; then
      saved="$(cat "$STATE_DIR/mode.saved" 2>/dev/null || echo "rule")"
      rm -f "$STATE_DIR/mode.saved"
    fi
    clash_set_mode "$saved"
    ok "Clash 模式已恢复为：${saved}"
  fi

  if fw_enabled; then
    warn "防火墙状态仍为开启，请检查是否有外部进程控制 pf"
  else
    ok "防火墙已关闭，系统网络完全恢复原样（正常直连与分流）"
  fi
}

do_status() {
  say "====================  mac-killswitch 状态  ===================="
  if fw_enabled; then
    if fw_is_ours; then
      ok "防火墙状态：已开启（fail-closed 保护中，旁路完全拦截）"
    else
      warn "防火墙状态：已开启（非 mac-killswitch 规则，由其他软件接管）"
    fi
  else
    dim "防火墙状态：未开启（系统默认网络，无任何阻断）"
  fi

  if [ -n "${SOCK:-}" ]; then
    say "Clash 模式：$(clash_mode)   TUN 虚拟网卡：$(clash_tun) ($(tun_device))"
    say "当前选定节点：$(find_active_node)"
  else
    dim "Clash：未运行或未找到控制 Socket"
  fi

  local egress
  egress="$(tunnel_egress)"
  say "出口 IP：${egress:-（无法获取）}"
  say "=============================================================="
}

menu() {
  while :; do
    say ""
    do_status
    say "  1) 开启   → 自动开 TUN + 设全局 + 放行该节点 + 阻断全部旁路"
    say "  2) 关闭   → 关闭防火墙 + 恢复 Clash 规则模式"
    say "  3) 状态   → 重新检查并刷新当前状态"
    say "  q) 退出菜单"
    printf "请选择 [1/2/3/q]: "
    read -r c
    case "$c" in
      1) do_on;;
      2) do_off;;
      3) do_status;;
      q|Q) break;;
      *) say "无效输入";;
    esac
  done
}

case "${1:-menu}" in
  on)     shift; do_on "$@";;
  off)    shift; do_off "$@";;
  status) do_status;;
  menu|"") menu;;
  -h|--help|help)
    say "用法: ks [on|off|status|menu]"
    ;;
  *)
    say "未知命令: $1"
    say "用法: ks [on|off|status|menu]"
    exit 1
    ;;
esac
