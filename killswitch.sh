#!/usr/bin/env bash
# mac-killswitch — fail-closed 网络开关
#
# 开启后：出网只允许 ① 回环 ② 局域网 ③ Clash TUN 隧道内 ④ 到节点 IP/端口 ⑤ 到 DNS 服务器
# 其余一律丢包（v4 + v6 + 入站）。Clash/TUN 挂掉 = 直接断网，绝不裸奔。
#
# 全程交互：敲 ks 出菜单；需要时输一次密码（sudo 缓存几分钟）
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$ROOT_DIR/.state"; BUILD_DIR="$ROOT_DIR/.build"
mkdir -p "$STATE_DIR" "$BUILD_DIR"

AM_ROOT=0; [ "$(id -u)" = "0" ] && AM_ROOT=1
OWNER_UID="$(ls -nd "$ROOT_DIR" 2>/dev/null | awk '{print $3}')"
# 以 root 运行（sudo ks）时，把生成物的属主还原给仓库主人，避免以后普通用户跑不了
if [ "$AM_ROOT" = "1" ] && [ -n "$OWNER_UID" ]; then
  trap 'chown -R "$OWNER_UID" "$STATE_DIR" "$BUILD_DIR" 2>/dev/null' EXIT
fi

[ -f "$ROOT_DIR/config.env" ] && . "$ROOT_DIR/config.env"

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

# ---- 一次性授权：写 sudoers 白名单，之后永久免密 ------------------------------
PFC=/sbin/pfctl
RTC=/sbin/route
SUDOERS_FILE=/etc/sudoers.d/mac-killswitch

has_sudo() { if [ "$AM_ROOT" = "1" ]; then return 0; fi; sudo -n "$PFC" -s info >/dev/null 2>&1; }
sf() { if [ "$AM_ROOT" = "1" ]; then "$PFC" "$@"; else sudo "$PFC" "$@"; fi; }   # 已授权→无感；sudo ks→直接
sr() { if [ "$AM_ROOT" = "1" ]; then "$RTC" "$@"; else sudo "$RTC" "$@"; fi; }

do_authorize() {
  local u tmp
  u="${SUDO_USER:-}"
  if [ -z "$u" ] || [ "$u" = "root" ]; then
    u="$(ls -ld "$ROOT_DIR" 2>/dev/null | awk '{print $3}')"   # 仓库目录属主
  fi
  if [ -z "$u" ] || [ "$u" = "root" ] || ! id -u "$u" >/dev/null 2>&1; then
    bad "确定不了用户名（请在你的终端里跑：ks）"; return 1
  fi
  tmp="$(mktemp /tmp/mks-sudo.XXXXXX)"
  printf '# mac-killswitch: passwordless pf/route for %s\n%s ALL=(root) NOPASSWD: %s, %s\n' \
         "$u" "$u" "$PFC" "$RTC" > "$tmp"
  say "一次性授权：只在这里输入一次密码，之后 ks 永久免密"
  if ! sudo -v; then rm -f "$tmp"; bad "密码错误，未改动系统"; return 1; fi
  if ! sudo /usr/sbin/visudo -cf "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; bad "规则校验失败，已放弃（系统未改动）"; return 1
  fi
  if sudo /bin/sh -c "mkdir -p /etc/sudoers.d; rm -f '$SUDOERS_FILE'; /usr/bin/install -m 440 -o root -g wheel '$tmp' '$SUDOERS_FILE'"; then
    rm -f "$tmp"
    if sudo -n "$PFC" -s info >/dev/null 2>&1; then
      ok "授权完成：以后 ks 不再问密码"
      return 0
    fi
    bad "文件已写入但未生效，请看 ${SUDOERS_FILE}"; return 1
  fi
  rm -f "$tmp"; bad "安装失败，系统未改动"; return 1
}

ensure_sudo() {
  [ "$AM_ROOT" = "1" ] && return 0
  has_sudo && return 0
  do_authorize && return 0
  say "（退回到普通 sudo，下面还会问一次密码）"
  sudo -v || { bad "无法获得管理员权限"; return 1; }
  return 0
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
clash_cfg()      { api GET /configs | jq -r "$1 // empty" 2>/dev/null; }
clash_mode()     { clash_cfg '.mode'; }
clash_tun()      { clash_cfg '.tun.enable'; }   # true/false
clash_set_mode() { api PATCH /configs "{\"mode\":\"$1\"}" >/dev/null; }
clash_now()      { api GET /proxies | jq -r --arg n "$1" '.proxies[$n].now // empty' 2>/dev/null; }
clash_select()   { api PUT "/proxies/$1" "{\"name\":\"$2\"}" >/dev/null; }

clash_line() {
  if [ -z "${SOCK:-}" ]; then
    bad "Clash: 找不到控制 socket（未运行？）——此时开启＝全断网"
    return
  fi
  local tun mode node dev
  tun="$(clash_tun)"; mode="$(clash_mode)"; dev="$(tun_device)"
  node="$(clash_now GLOBAL)"; [ -z "$node" ] && node="$(clash_now '🚀 节点选择')"
  say " Clash: 模式=${mode:-未知}   TUN=${tun:-未知}（${dev}）   节点=${node:-未知}"
  case "$node" in
    ""|DIRECT|REJECT|REJECT-DROP)
      bad "全局出口指向「${node:-无}」＝直连：国外站点会超时/被墙（pi、Claude 之类的 API 连接被重置就是这个）"
      dim "  → 在 Clash 的 GLOBAL 里选一个真节点，或切回规则模式" ;;
  esac
  [ "$tun" != "true" ] && bad "Clash TUN 没开：开启后流量无处可去＝全断网。先在 Clash 打开 TUN/虚拟网卡。"
  [ "$mode" != "global" ] && dim "（规则模式：开启时脚本会自动切到 global，关闭时还原）"
  return 0
}

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

# ---- 自动探测当前节点 -------------------------------------------------------
VERGE_DIR="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"

current_profile_file() {
  local cur
  cur="$(grep -E '^current:' "${VERGE_DIR}/profiles.yaml" 2>/dev/null | awk '{print $2}')"
  [ -n "$cur" ] && printf '%s' "${VERGE_DIR}/profiles/${cur}.yaml"
}

# 输出 IP:PORT[,IP:PORT ...]；取 GLOBAL（全局模式）或 🚀 节点选择 当前选中的那个节点
detect_endpoints() {
  local pf node eps
  pf="$(current_profile_file)"; [ -f "$pf" ] || return 1
  node="$(clash_now GLOBAL)"; [ -z "$node" ] && node="$(clash_now '🚀 节点选择')"
  case "$node" in ""|DIRECT|REJECT|REJECT-DROP) return 1 ;; esac
  printf '%s' "$node" >&2
  eps="$(python3 "$ROOT_DIR/lib/node_endpoints.py" "$pf" "$node" 2>/dev/null)"
  [ -n "$eps" ] || return 1
  # 域名形式的 server → 解析成真实 IP（走隧道用 DoH，避免 fake-ip）
  printf '%s' "$eps" | while IFS= read -r ep; do
    host="${ep%%:*}"; port="${ep#*:}"
    case "$host" in
      *[!0-9.]*) for ip in $(resolve_a "$host"); do printf '%s:%s\n' "$ip" "$port"; done ;;
      *) printf '%s:%s\n' "$host" "$port" ;;
    esac
  done | paste -sd, -
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
    p0="$(block_packets)"
    # 制造"绕过 TUN 的直连"尝试：先强制路由到物理网卡（不改全局路由，用完即删）
    for t in $PROBE_IPS; do
      sr -n add -host "$t" -interface "$iface" >/dev/null 2>&1
      nc -G 2 -w 2 -z "$t" 443 >/dev/null 2>&1
      nc -G 2 -w 2 -z "$t" 80  >/dev/null 2>&1
      sr -n delete -host "$t" >/dev/null 2>&1
    done
    curl -s --noproxy '*' --connect-timeout 2 --max-time 3 -o /dev/null http://1.1.1.1/ 2>/dev/null
    sleep 1
    p1="$(block_packets)"
    case "${p0}${p1}" in
      *[!0-9]*|"") dim "（读不到 block 计数器，跳过该项自检）" ;;
      *)
        if [ "$p1" -gt "$p0" ]; then
          ok "旁路尝试被防火墙丢弃（block 计数 ${p0} → ${p1}）"
        else
          bad "旁路尝试没有被丢弃（block 计数没变：${p0}）→ 规则可能没生效"
        fi ;;
    esac
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
  if [ -z "$NODE_ENDPOINTS" ]; then
    NODE_ENDPOINTS="$(detect_endpoints)"
    if [ -z "$NODE_ENDPOINTS" ]; then
      bad "自动获取节点失败，请在 config.env 里手动填 NODE_ENDPOINTS"; return 1
    fi
    ok "已从 Clash 自动获取当前节点：${NODE_ENDPOINTS}"
  fi
  if ! ensure_sudo; then return 1; fi

  if [ -n "${SOCK:-}" ] && [ "$(clash_tun)" != "true" ]; then
    bad "Clash 的 TUN 没开：现在开 kill switch 会变成全断网（连节点都到不了）"
    say "  先在 Clash Verge 里打开 TUN（设置 → 虚拟网卡/TUN 模式），再重按 1"
    return 1
  fi
  tun="$(tun_device)"
  f="$BUILD_DIR/pf.rules"
  gen_rules "$tun"
  say "→ 载入 pf 规则（隧道 ${tun}，节点 ${NODE_ENDPOINTS}）"
  sf -f "$f" || { bad "pf 载入失败"; return 1; }
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
    return 1
  fi
  say ""
  dim "关掉：ks off   （或 sudo /sbin/pfctl -d；本机操作，不需要网络）"
}

do_off() {
  ensure_sudo || return 1
  sf -d >/dev/null 2>&1
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
  if [ -n "$NODE_ENDPOINTS" ]; then say "节点白名单: ${NODE_ENDPOINTS}（config.env 手动指定）"
  else say "节点白名单: $(detect_endpoints)（自动：Clash 当前选中节点）"; fi
  say "Clash 模式: $(clash_mode)"
  say "Clash TUN : $(clash_tun)（$(tun_device)）"
  has_sudo && dim "sudo      : 已授权（缓存中）" || dim "sudo      : 下次开启时会要一次密码"
  if [ -f "$STATE_DIR/on" ]; then ok "kill switch 已开启（$(cat "$STATE_DIR/on")）"; else dim "kill switch 未开启"; fi
  say "出口 IP   : $(tunnel_egress)"
  say "默认路由  : $(route -n get default 2>/dev/null | awk '/gateway|interface/{printf "%s ", $2}')"
}

do_check() { print_verify; }

usage() {
  cat <<EOF
mac-killswitch — fail-closed 网络开关

  ks                    ← 直接敲这个，出菜单（推荐，不用记参数）
  sudo ks               ← 也行：按管理员跑，不用任何授权配置
  ks on                 开启（防火墙 + Clash 全局）
  ks off                关闭并还原
  ks status / check     状态 / 自检
EOF
}

menu() {
  while :; do
    local state egress
    if [ -f "$STATE_DIR/on" ]; then state="${C_OK}已开启${C_OFF}（只走节点，旁路断网）"; else state="${C_DIM}未开启${C_OFF}（正常上网）"; fi
    egress="$(tunnel_egress)"
    say ""
    say "====================  mac-killswitch  ===================="
    say " 状态: ${state}"
    say " 出口: ${egress:-（测不到，检查 Clash/节点）}"
    clash_line
    if [ -n "$NODE_ENDPOINTS" ]; then say " 节点: ${NODE_ENDPOINTS}   节点来源: config.env"; else say " 节点: $(detect_endpoints)   节点来源: 自动（Clash）"; fi
    say "========================================================="
    say "  1) 开启   → 防火墙 + 全局走节点（国内直连也会断，这就是目的）"
    say "  2) 关闭   → 一切恢复原样（没网时用这个）"
    say "  3) 自检   → 看旁路是否真被丢包、隧道是否通"
    say "  4) 详情   → 状态原始信息"
    if has_sudo; then say "  5) 授权   → 已生效（ks 免密）"; else say "  5) 授权   → 输一次密码，之后 ks 永久免密"; fi
    say "  q) 退出"
    printf ' 选择: '; read -r c
    case "$c" in
      1) do_on;;
      2) do_off;;
      3) do_check;;
      4) do_status;;
      5) ensure_sudo;;
      q|Q|"") return;;
      *) bad "请输入 1-5 或 q";;
    esac
  done
}

case "${1:-menu}" in
  on)     shift; do_on "$@";;
  off)    shift; do_off "$@";;
  status) do_status;;
  check)  do_check;;
  rules)  if [ -z "$NODE_ENDPOINTS" ]; then NODE_ENDPOINTS="$(detect_endpoints)"; fi
          gen_rules "$(tun_device)"; cat "$BUILD_DIR/pf.rules";;
  node)   say "Clash 当前选中: $(clash_now GLOBAL)"; say "自动探测端点: $(detect_endpoints)";;
  menu|"") menu;;
  -h|--help|help) usage;;
  *) usage; exit 1;;
esac
