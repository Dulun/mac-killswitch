#!/usr/bin/env bash
# mac-killswitch — fail-closed 网络开关
#
# 开启后：出网只允许 ① 回环 ② 局域网 ③ Clash TUN 隧道内 ④ 到节点 IP/端口 ⑤ 到 DNS 服务器
# 其余一律丢包（v4 + v6 + 入站）。Clash/TUN 挂掉 = 直接断网，绝不裸奔。
#
# 首次使用：ks setup-sudo（只弹一次密码，之后全程免密）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$ROOT/.state"; BUILD_DIR="$ROOT/.build"
mkdir -p "$STATE_DIR" "$BUILD_DIR"

[ -f "$ROOT/config.env" ] && . "$ROOT/config.env"

# ---- 默认配置（可被 config.env 覆盖）----------------------------------------
: "${NODE_ENDPOINTS:=}"                                  # IP[:PORT][, ...]
: "${DNS_SERVERS:=114.114.114.114 223.5.5.5 223.6.6.6 119.29.29.29}"
: "${DOH_HOSTS:=dns.alidns.com doh.pub}"                 # 这些域名解析出的 IP 也放行 443
: "${LAN_CIDRS:=192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 169.254.0.0/16 224.0.0.0/4}"
: "${ALLOW_PORTS_EXTRA:=}"                               # 额外放行：IP:PORT
: "${PROBE_IPS:=1.1.1.1 8.8.8.8 39.156.66.10}"           # 自检用的"旁路"目标

C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
say() { printf '%s\n' "$*"; }
ok()  { printf '%s✔%s %s\n' "$C_OK" "$C_OFF" "$*"; }
bad() { printf '%s✘%s %s\n' "$C_BAD" "$C_OFF" "$*"; }
dim() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

# ---- 免密 sudo（白名单只有 pfctl / route）-----------------------------------
PFC=/sbin/pfctl
RTC=/sbin/route
SUDOERS_FILE=/etc/sudoers.d/mac-killswitch

has_sudo() { sudo -n "$PFC" -s info >/dev/null 2>&1; }
sf() { sudo -n "$PFC" "$@"; }
sr() { sudo -n "$RTC" "$@"; }
sudo_hint() { bad "还没授权：先跑一次  ks setup-sudo  （只弹这一次密码）"; }

do_setup_sudo() {
  local u tmp
  u="${SUDO_USER:-}"
  [ -z "$u" ] || [ "$u" = "root" ] && u="$(ls -ld "$ROOT" 2>/dev/null | awk '{print $3}')"
  if [ -z "$u" ] || [ "$u" = "root" ] || ! id -u "$u" >/dev/null 2>&1; then
    bad "无法确定目标用户（请用你自己的账号在终端里跑 setup-sudo）"; return 1
  fi
  tmp="$(mktemp /tmp/mac-killswitch-sudo.XXXXXX)"
  {
    echo "# mac-killswitch: allow ${u} to manage pf/routes without password"
    echo "${u} ALL=(root) NOPASSWD: ${PFC}, ${RTC}"
  } > "$tmp"
  say "→ 校验并写入 ${SUDOERS_FILE}（目标用户：${u}；需要输入一次密码）"
  if sudo /bin/sh -c "/usr/sbin/visudo -cf '$tmp' >/dev/null 2>&1 && cp '$tmp' '$SUDOERS_FILE' && chmod 440 '$SUDOERS_FILE' && chown root:wheel '$SUDOERS_FILE'"; then
    rm -f "$tmp"
    has_sudo && ok "完成：以后 ks 不再需要密码" || bad "写入后仍未生效，请手动检查 ${SUDOERS_FILE}"
  else
    rm -f "$tmp"
    sudo /bin/sh -c "rm -f '$SUDOERS_FILE'"
    bad "写入失败（已清理残留文件）"
  fi
}

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

api() {
  [ -n "${SOCK:-}" ] || return 1
  local m="$1" p="$2" d="${3:-}"
  if [ -n "$d" ]; then
    curl -s --max-time 8 --unix-socket "$SOCK" -X "$m" -H 'Content-Type: application/json' -d "$d" "http://localhost$p"
  else
    curl -s --max-time 8 --unix-socket "$SOCK" -X "$m" "http://localhost$p"
  fi
}
clash_mode()     { api GET /configs | jq -r '.mode // empty' 2>/dev/null; }
clash_set_mode() { api PATCH /configs "{\"mode\":\"$1\"}" >/dev/null; }
clash_now()      { api GET /proxies | jq -r --arg n "$1" '.proxies[$n].now // empty' 2>/dev/null; }
clash_select()   { api PUT "/proxies/$1" "{\"name\":\"$2\"}" >/dev/null; }

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
    echo "pass quick on ${tun} all"
    [ -n "$LAN_CIDRS" ] && echo "pass quick from any to { $(printf '%s' "$LAN_CIDRS" | tr ' ' ',') }"
    echo "pass quick proto udp from any port 68 to any port 67"
    if [ -n "$ips" ]; then
      printf 'pass out quick proto { tcp, udp } to { %s }' "$ips"
      [ -n "$ports" ] && printf ' port { %s }' "$ports"
      echo
    fi
    for ep in $(printf '%s' "$NODE_ENDPOINTS $ALLOW_PORTS_EXTRA" | tr ',' ' '); do
      ip="${ep%%:*}"; port="${ep#*:}"
      [ "$port" = "$ep" ] && continue
      echo "pass out quick proto { tcp, udp } to ${ip} port { ${port//-/,} }"
    done
    echo "pass out quick proto { tcp, udp } to { ${DNS_SERVERS} } port { 53, 853 }"
    [ -n "$dohips" ] && echo "pass out quick proto tcp to { ${dohips} } port 443"
    echo
    echo "# 其余全部丢包（v4 + v6 + 入站）"
    echo "block drop quick all"
  } > "$f"
}

# ---- 自检 -------------------------------------------------------------------
block_packets() { # 读 block 规则的丢包计数
  sf -s rules -v 2>/dev/null | awk '
    /block drop quick all/ { getline; if (match($0, /Packets: [0-9]+/)) print substr($0, RSTART+9, RLENGTH-9); exit }'
}

tunnel_egress() {
  curl -s --max-time 8 https://ipinfo.io/json 2>/dev/null | jq -r '(.ip//"")+" "+(.city//"")+" "+(.country//"")' 2>/dev/null
}

print_verify() {
  local iface p0 p1 ip
  iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
  say ""
  say "自检："
  if has_sudo && [ -n "$iface" ]; then
    p0="$(block_packets)"; p0="${p0:-0}"
    # 制造"绕过 TUN 的直连"尝试：先强制路由到物理网卡（不改全局路由，用完即删）
    for t in $PROBE_IPS; do
      sr -n add -host "$t" -interface "$iface" >/dev/null 2>&1
      nc -G 2 -w 2 -z "$t" 443 >/dev/null 2>&1
      nc -G 2 -w 2 -z "$t" 80  >/dev/null 2>&1
      sr -n delete -host "$t" >/dev/null 2>&1
    done
    curl -s --noproxy '*' --connect-timeout 2 --max-time 3 -o /dev/null http://1.1.1.1/ 2>/dev/null
    sleep 1
    p1="$(block_packets)"; p1="${p1:-0}"
    if [ "$p1" -gt "$p0" ]; then
      ok "旁路尝试被防火墙丢弃（block 计数 ${p0} → ${p1}）"
    else
      bad "旁路尝试没有被丢弃（block 计数没变：${p0}）→ 规则可能没生效"
    fi
  else
    dim "（未授权 sudo，跳过防火墙自检）"
  fi
  ip="$(tunnel_egress)"
  [ -n "$ip" ] && ok "经隧道的出口：${ip}" || bad "经隧道的出口不通（节点/隧道有问题？）"
}

# ---- 动作 -------------------------------------------------------------------
do_on() {
  local fw_only=0 tun f mode node
  [ "${1:-}" = "--fw-only" ] && fw_only=1
  [ -n "$NODE_ENDPOINTS" ] || { bad "config.env 里没配 NODE_ENDPOINTS"; exit 1; }
  has_sudo || { sudo_hint; exit 1; }

  tun="$(tun_device)"
  f="$BUILD_DIR/pf.rules"
  gen_rules "$tun"
  say "→ 载入 pf 规则（隧道 ${tun}，节点 ${NODE_ENDPOINTS}）"
  sf -f "$f" || { bad "pf 载入失败"; exit 1; }
  sf -E >/dev/null 2>&1
  date '+%Y-%m-%d %H:%M:%S' > "$STATE_DIR/on"
  ok "防火墙已生效：仅放行 隧道/局域网/节点/DNS，其余丢包"

  if [ "$fw_only" = "0" ] && [ -n "${SOCK:-}" ]; then
    mode="$(clash_mode)"; node="$(clash_now '🚀 节点选择')"
    [ -n "$mode" ] && printf '%s' "$mode" > "$STATE_DIR/mode.saved"
    if [ -n "$node" ] && [ "$mode" != "global" ]; then
      clash_set_mode global
      clash_select GLOBAL "$node"
      ok "Clash 已切全局模式（GLOBAL → ${node}），没有任何 DIRECT 分流"
    else
      dim "（Clash 已是/保持全局模式：${mode}）"
    fi
  fi

  print_verify

  # 安全网：连隧道出口都不通 → 自动还原，避免把你锁死
  if [ -z "$(tunnel_egress)" ]; then
    bad "开启后隧道出口不通 → 自动还原（宁可没开，也不让你没网）"
    do_off
    exit 1
  fi
  say ""
  dim "关掉：ks off   （或 sudo /sbin/pfctl -d；本机操作，不需要网络）"
}

do_off() {
  if has_sudo; then sf -d >/dev/null 2>&1; else sudo "$PFC" -d >/dev/null 2>&1; fi
  rm -f "$STATE_DIR/on"
  ok "防火墙已关闭（pf 停用，恢复系统默认）"
  local saved=""
  [ -f "$STATE_DIR/mode.saved" ] && saved="$(cat "$STATE_DIR/mode.saved")"
  if [ -n "$saved" ] && [ -n "${SOCK:-}" ]; then
    clash_set_mode "$saved"; ok "Clash 模式已还原为 ${saved}"; rm -f "$STATE_DIR/mode.saved"
  fi
}

do_status() {
  say "SOCK      : ${SOCK:-（未找到 clash 控制 socket）}"
  say "TUN 设备  : $(tun_device)"
  say "节点白名单: ${NODE_ENDPOINTS:-（空）}"
  say "Clash 模式: $(clash_mode)"
  has_sudo && dim "sudo      : 已免密授权" || dim "sudo      : 未授权（跑 ks setup-sudo）"
  if [ -f "$STATE_DIR/on" ]; then ok "kill switch 已开启（$(cat "$STATE_DIR/on")）"; else dim "kill switch 未开启"; fi
  say "出口 IP   : $(tunnel_egress)"
  say "默认路由  : $(route -n get default 2>/dev/null | awk '/gateway|interface/{printf "%s ", $2}')"
}

do_check() { print_verify; }

usage() {
  cat <<EOF
mac-killswitch — fail-closed 网络开关

  killswitch.sh setup-sudo    一次性授权（只弹一次密码，写 /etc/sudoers.d）
  killswitch.sh on            开启（防火墙 + Clash 全局）
  killswitch.sh on --fw-only  只开防火墙，保留 Clash 规则模式
  killswitch.sh off           关闭并还原
  killswitch.sh status        状态
  killswitch.sh check         自检（旁路必须被丢包 / 隧道必须通）
  killswitch.sh rules         只打印将要载入的 pf 规则
  killswitch.sh               交互菜单
EOF
}

menu() {
  while :; do
    say ""
    say "mac-killswitch$([ -f "$STATE_DIR/on" ] && echo "  [已开启]")"
    say "  1) 开启（严格：防火墙 + 全局走节点）"
    say "  2) 开启（只开防火墙，保留规则分流）"
    say "  3) 关闭并还原"
    say "  4) 状态"
    say "  5) 自检"
    say "  6) 一次性授权（免密）"
    say "  q) 退出"
    printf '请选择: '; read -r c
    case "$c" in
      1) do_on;; 2) do_on --fw-only;; 3) do_off;; 4) do_status;; 5) do_check;;
      6) do_setup_sudo;; q|Q|"") return;;
      *) bad "无效选择";;
    esac
  done
}

case "${1:-menu}" in
  setup-sudo) do_setup_sudo;;
  on)     shift; do_on "$@";;
  off)    shift; do_off "$@";;
  status) do_status;;
  check)  do_check;;
  rules)  gen_rules "$(tun_device)"; cat "$BUILD_DIR/pf.rules";;
  menu|"") menu;;
  -h|--help|help) usage;;
  *) usage; exit 1;;
esac
