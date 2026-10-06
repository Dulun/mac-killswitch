#!/usr/bin/env bash
# mac-killswitch — fail-closed 网络开关
#
# 开启后：出网只允许 ① 回环 ② 局域网 ③ Clash TUN 隧道内 ④ 到节点 IP/端口 ⑤ 到 DNS 服务器
# 其余一律丢包。Clash/TUN 挂掉 = 直接断网，绝不裸奔。
#
# 用法：killswitch.sh [on|off|status|check|menu] [--fw-only]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$ROOT/.state"; BUILD_DIR="$ROOT/.build"
mkdir -p "$STATE_DIR" "$BUILD_DIR"

[ -f "$ROOT/config.env" ] && . "$ROOT/config.env"

# ---- 默认配置（可被 config.env 覆盖）----------------------------------------
: "${NODE_ENDPOINTS:=}"                                  # IP:PORT[,IP:PORT ...]
: "${DNS_SERVERS:=114.114.114.114 223.5.5.5 223.6.6.6 119.29.29.29}"
: "${DOH_HOSTS:=dns.alidns.com doh.pub}"                 # 这些域名的 IP 也放行 443
: "${LAN_CIDRS:=192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 169.254.0.0/16 224.0.0.0/4}"
: "${ALLOW_PORTS_EXTRA:=}"                               # 额外放行：IP:PORT

C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✔%s %s\n' "$C_OK" "$C_OFF" "$*"; }
bad()  { printf '%s✘%s %s\n' "$C_BAD" "$C_OFF" "$*"; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

need_root() { [ "$(id -u)" = "0" ] || exec sudo "$0" "$@"; }

# ---- Clash (mihomo) 发现 ----------------------------------------------------
find_sock() {
  local g
  for g in /var/run/clash-verge-service/users/*/verge-mihomo.sock \
           /var/folders/*/*/T/verge-mihomo.sock; do
    [ -S "$g" ] && { printf '%s' "$g"; return 0; }
  done
  return 1
}
SOCK="$(find_sock || true)"
api() { # api <GET|PUT|PATCH|POST|DELETE> <path> [json]
  [ -n "${SOCK:-}" ] || return 1
  local m="$1" p="$2" d="${3:-}"
  if [ -n "$d" ]; then
    curl -s --max-time 8 --unix-socket "$SOCK" -X "$m" -H 'Content-Type: application/json' -d "$d" "http://localhost$p"
  else
    curl -s --max-time 8 --unix-socket "$SOCK" -X "$m" "http://localhost$p"
  fi
}
clash_mode()      { api GET /configs | jq -r '.mode // empty' 2>/dev/null; }
clash_set_mode()  { api PATCH /configs "{\"mode\":\"$1\"}" >/dev/null; }
clash_now()       { api GET /proxies | jq -r --arg n "$1" '.proxies[$n].now // empty' 2>/dev/null; }
clash_select()    { api PUT "/proxies/$1" "{\"name\":\"$2\"}" >/dev/null; }

tun_device() {
  local d
  d="$(api GET /configs | jq -r '.tun.device // empty' 2>/dev/null)"
  if [ -z "$d" ]; then
    for i in $(ifconfig -l | tr ' ' '\n' | grep '^utun'); do
      ifconfig "$i" 2>/dev/null | grep -q '198\.18\.' && { d="$i"; break; }
    done
  fi
  printf '%s' "${d:-utun1024}"
}

# ---- pf 规则 ----------------------------------------------------------------
# 走隧道用 DoH 查真实 IP（本机 dig 会被 Clash 劫持返回 fake-ip 198.18.x）
resolve_a() {
  local h="$1" ips
  ips="$(curl -s --max-time 8 "https://dns.alidns.com/resolve?name=$h&type=A" | jq -r '.Answer[]? | select(.type==1) | .data' 2>/dev/null)"
  [ -z "$ips" ] && ips="$(dig +short A "$h" 2>/dev/null)"
  printf '%s\n' "$ips" | grep -E '^[0-9.]+$' | grep -v '^198\.18\.' | sort -u
}

gen_rules() {
  local tun="$1" f="$BUILD_DIR/pf.rules" ips ports ip port ep dohips
  dohips="$(for h in $DOH_HOSTS; do resolve_a "$h"; done | sort -u | tr '\n' ' ')"
  ips="$(printf '%s' "$NODE_ENDPOINTS $ALLOW_PORTS_EXTRA" | tr ',' ' ' | sed 's/:[0-9-]*$//' | tr ' ' '\n' | grep -E '^[0-9.]+$' | sort -u | tr '\n' ' ')"
  ports="$(printf '%s' "$NODE_ENDPOINTS $ALLOW_PORTS_EXTRA" | tr ',' ' ' | sed -n 's/^[0-9.]*:\([0-9-]*\)$/\1/p' | sort -u | tr '\n' ',' | sed 's/,$//')"

  {
    echo "# mac-killswitch — 生成于 $(date '+%Y-%m-%d %H:%M:%S')"
    echo "scrub-anchor \"com.apple/*\""
    echo "anchor \"com.apple/*\""
    echo "load anchor \"com.apple\" from \"/etc/pf.anchors/com.apple\""
    echo
    echo "set skip on lo0"
    echo "pass quick on lo0 all"
    echo "pass quick on $tun all"
    [ -n "$LAN_CIDRS" ] && echo "pass quick from any to { $(printf '%s' "$LAN_CIDRS" | tr ' ' ',') } all"
    echo "pass quick proto udp from any port 68 to any port 67"
    if [ -n "$ips" ]; then
      printf 'pass out quick proto { tcp, udp } to { %s }' "$ips"
      [ -n "$ports" ] && printf ' port { %s }' "$ports"
      echo " all"
    fi
    for ep in $(printf '%s' "$NODE_ENDPOINTS $ALLOW_PORTS_EXTRA" | tr ',' ' '); do
      ip="${ep%%:*}"; port="${ep#*:}"
      [ "$port" = "$ep" ] && continue
      echo "pass out quick proto { tcp, udp } to $ip port { ${port//-/,} } all"
    done
    echo "pass out quick proto { tcp, udp } to { $DNS_SERVERS } port { 53, 853 } all"
    [ -n "$dohips" ] && echo "pass out quick proto tcp to { $dohips } port 443 all"
    echo
    echo "# 其余全部丢包（v4 + v6 + 入站）"
    echo "block drop quick all"
  } > "$f"
}

# ---- 动作 -------------------------------------------------------------------
do_on() {
  local fw_only=0 tun f
  [ "${1:-}" = "--fw-only" ] && fw_only=1
  [ -n "$NODE_ENDPOINTS" ] || { bad "config.env 里没配 NODE_ENDPOINTS"; exit 1; }

  tun="$(tun_device)"
  f="$(gen_rules "$tun")"
  need_root "$@"
  say "→ 载入 pf 规则（隧道 $tun，节点 $NODE_ENDPOINTS）"
  pfctl -f "$f" || { bad "pf 载入失败"; exit 1; }
  pfctl -E >/dev/null 2>&1 || true
  date '+%Y-%m-%d %H:%M:%S' > "$STATE_DIR/on"
  ok "防火墙已生效：仅放行 隧道/局域网/节点/DNS，其余丢包"

  if [ "$fw_only" = "0" ] && [ -n "${SOCK:-}" ]; then
    local mode node
    mode="$(clash_mode)"; node="$(clash_now '🚀 节点选择')"
    [ -n "$mode" ] && printf '%s' "$mode" > "$STATE_DIR/mode.saved"
    if [ -n "$node" ] && [ "$mode" != "global" ]; then
      clash_set_mode global
      clash_select GLOBAL "$node"
      ok "Clash 已切全局模式（GLOBAL → $node），不再有任何 DIRECT 分流"
    else
      dim "（Clash 已是/保持全局模式：$mode，未改动 GLOBAL 选择）"
    fi
  fi
  print_verify
}

do_off() {
  need_root "$@"
  pfctl -d >/dev/null 2>&1 || true
  rm -f "$STATE_DIR/on"
  ok "防火墙已关闭（pf 停用，恢复系统默认）"
  local saved=""
  [ -f "$STATE_DIR/mode.saved" ] && saved="$(cat "$STATE_DIR/mode.saved")"
  if [ -n "$saved" ] && [ -n "${SOCK:-}" ]; then
    clash_set_mode "$saved"; ok "Clash 模式已还原为 $saved"; rm -f "$STATE_DIR/mode.saved"
  fi
}

print_verify() {
  local iface ip
  iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
  say ""
  say "自检："
  if [ -n "$iface" ]; then
    route -n add -host 1.1.1.1 -interface "$iface" >/dev/null 2>&1
    if curl -s --max-time 4 -o /dev/null http://1.1.1.1/ 2>/dev/null; then
      bad "绕过 TUN 的直连仍能出网 → 规则没生效！"
    else
      ok "绕过 TUN 的直连已被丢包（不可达）"
    fi
    route -n delete -host 1.1.1.1 >/dev/null 2>&1
  fi
  ip="$(curl -s --max-time 8 https://ipinfo.io/json 2>/dev/null | jq -r '(.ip//"")+" "+(.city//"")+" "+(.country//"")' 2>/dev/null)"
  [ -n "$ip" ] && ok "经隧道的出口：$ip" || bad "经隧道的出口不通（节点/隧道有问题？）"
}

do_status() {
  say "SOCK      : ${SOCK:-（未找到 clash 控制 socket）}"
  say "TUN 设备  : $(tun_device)"
  say "节点白名单: ${NODE_ENDPOINTS:-（空）}"
  local mode; mode="$(clash_mode)"; say "Clash 模式: ${mode:-未知}"
  if [ -f "$STATE_DIR/on" ]; then
    ok "kill switch 已开启（$(cat "$STATE_DIR/on")）"
  else
    dim "kill switch 未开启"
  fi
  say "出口 IP   : $(curl -s --max-time 8 https://ipinfo.io/json 2>/dev/null | jq -r '(.ip//"?")+" "+(.city//"")+" "+(.country//"")' 2>/dev/null)"
  say "默认路由  : $(route -n get default 2>/dev/null | awk '/gateway|interface/{printf "%s ", $2}')"
}

do_check() {
  say "1) 直连探测（必须失败）："
  local iface; iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
  if [ -n "$iface" ]; then
    need_root "$@"
    route -n add -host 1.1.1.1 -interface "$iface" >/dev/null 2>&1
    curl -s --max-time 4 -o /dev/null http://1.1.1.1/ && bad "能直连（漏！）" || ok "直连被丢包"
    route -n delete -host 1.1.1.1 >/dev/null 2>&1
  else
    dim "跳过（拿不到默认路由）"
  fi
  say "2) 隧道出口："
  local ip; ip="$(curl -s --max-time 8 https://ipinfo.io/json 2>/dev/null | jq -r '(.ip//"")+" "+(.org//"")+" "+(.city//"")' 2>/dev/null)"
  [ -n "$ip" ] && ok "$ip" || bad "不通"
  say "3) 规则里是否还有 DIRECT 分流："
  if [ -n "${SOCK:-}" ]; then
    clash_mode | grep -q '^global$' && ok "Clash 处于全局模式（无 DIRECT 分流）" \
      || dim "Clash 模式：$(clash_mode)（规则模式，国内直连规则会被防火墙掐掉）"
  fi
}

usage() {
  cat <<EOF
mac-killswitch — fail-closed 网络开关

  killswitch.sh on            开启（防火墙 + Clash 切全局）
  killswitch.sh on --fw-only  只开防火墙（保留 Clash 规则模式）
  killswitch.sh off           关闭并还原
  killswitch.sh status        状态
  killswitch.sh check         自检（直连必须失败 / 隧道必须通）
  killswitch.sh               交互菜单
EOF
}

menu() {
  while :; do
    say ""
    say "mac-killswitch"
    say "  1) 开启（严格：防火墙 + 全局走节点）"
    say "  2) 开启（只开防火墙，保留规则分流）"
    say "  3) 关闭并还原"
    say "  4) 状态"
    say "  5) 自检"
    say "  q) 退出"
    printf '请选择: '; read -r c
    case "$c" in
      1) do_on;; 2) do_on --fw-only;; 3) do_off;; 4) do_status;; 5) do_check;; q|Q|"") return;;
      *) bad "无效选择";;
    esac
  done
}

case "${1:-menu}" in
  on)     shift; do_on "$@";;
  off)    shift; do_off "$@";;
  status) do_status;;
  check)  do_check;;
  rules)  gen_rules "$(tun_device)"; cat "$BUILD_DIR/pf.rules";;
  menu|"") menu;;
  -h|--help|help) usage;;
  *) usage; exit 1;;
esac
