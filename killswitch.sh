#!/usr/bin/env bash
# mac-killswitch — macOS fail-closed 防火墙开关
#
# 核心逻辑：
# 1. 开启时：前提是 Clash 已开 TUN（ks 不碰这个开关，没开就直接拒绝）；
#    自动切换为全局模式（global），从 Clash 提取当前选中节点的 IP 与端口；
#    配置内核 pf 防火墙：仅放行 本机回环、TUN 虚拟网卡、局域网私网、DNS 与该节点连接，其余物理网卡流量全部丢弃。
# 2. 关闭时：只清 ks 自己那份 —— 主规则集还原成系统自带 /etc/pf.conf，
#    并用 -X 释放 ks 自己在 -E 时拿到的那个引用。macOS 自己（pfd/InternetSharing
#    那套虚拟机网络）或别的软件持有的引用一律不动；系统 pf 开不开由它们自己决定。
# 3. 状态判断：ks 自己的状态 = "规则是否在内核 + ks 的 token 是否还在引用表里"；
#    系统 pf 状态与引用持有者分开显示，与 ks 无关。
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
STATE_DIR="$ROOT_DIR/.state"
mkdir -p "$BUILD_DIR" "$STATE_DIR"
TOKEN_FILE="$STATE_DIR/pf.tokens"
# 兼容旧版单值文件
[ -f "$STATE_DIR/pf.token" ] && { cat "$STATE_DIR/pf.token" >> "$TOKEN_FILE"; rm -f "$STATE_DIR/pf.token"; }

AM_ROOT=0
[ "$(id -u)" = "0" ] && AM_ROOT=1
OWNER_UID="${SUDO_UID:-$(id -u)}"
if [ "$AM_ROOT" = "1" ] && [ -n "$OWNER_UID" ]; then
  trap 'chown -R "$OWNER_UID" "$BUILD_DIR" "$STATE_DIR" 2>/dev/null' EXIT
fi

[ -f "$ROOT_DIR/config.env" ] && . "$ROOT_DIR/config.env"

# config.env 里手填的端点（可为空）；do_on 每次都用这个初值，避免菜单里反复按 1 时串到上一次的结果
: "${NODE_ENDPOINTS:=}"
CFG_NODE_ENDPOINTS="$NODE_ENDPOINTS"
: "${DNS_SERVERS:=114.114.114.114 223.5.5.5 223.6.6.6 119.29.29.29}"
: "${DOH_HOSTS:=dns.alidns.com doh.pub}"
: "${LAN_CIDRS:=192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 169.254.0.0/16 224.0.0.0/4}"

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

# 审计日志用：无 tty 时 tty(1) 会打印 "not a tty" 且带换行，会把日志行打断
tty_id() {
  local t
  t="$(tty 2>/dev/null || true)"
  case "$t" in /dev/*) printf '%s' "$t" ;; *) printf 'no-tty' ;; esac
}

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

# ks 自己那份规则是否正压在内核主规则集上（ks 生成的 pf.rules 特征行）
ks_rules_loaded() {
  pfq -s rules | grep -q '^pass quick on lo0 all'
}

# ks 自己在 -E 时拿到的引用 token
# ks 拿过的所有 pf 引用（每行一个，历史遗留的也都在，避免 -E 后漏记）
ks_tokens() {
  [ -f "$TOKEN_FILE" ] || return 0
  tr -s ' \n' '\n' < "$TOKEN_FILE" | grep -E '^[0-9]+$' | sort -u
}

ks_ref_held() {
  local t
  while IFS= read -r t; do
    [ -n "$t" ] && pfq -s References -v | grep -q -- "$t" && return 0
  done < <(ks_tokens)
  return 1
}

# 释放 ks 自己拿过的引用（系统/别家软件的一概不动）；释放不掉的留在文件里下次重试
release_own_tokens() {
  local t out keep=""
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    if pfq -s References -v | grep -q -- "$t"; then
      out="$(sf -X "$t" 2>&1 || true)"
      if pfq -s References -v | grep -q -- "$t"; then
        warn "释放 pf 引用失败：token ${t}（${out##*$'\n'}），已保留记录下次再试"
        keep="${keep}${t}"$'\n'
      else
        ok "已释放 pf 引用 token ${t}"
      fi
    else
      dim "token ${t} 已不在内核引用表里，清掉本地记录"
    fi
  done < <(ks_tokens)
  printf '%s' "$keep" > "$TOKEN_FILE"
}

# pf 引用表：谁把 pf 开着（macOS 自己那套看这里）
pf_holders() {
  pfq -s References -v | awk '/^TOKENS:/{f=1;next} f && $1 ~ /^[0-9]+$/ {printf "%s[%s] token=%s (%s %s %s); ", $2, $1, $3, $4, $5, $6}'
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
  # 本地 unix socket，3 秒还没响应就是 Clash 卡了；避免菜单被拖住
  if [ -n "$d" ]; then
    curl -s --max-time 3 --unix-socket "$SOCK" -X "$m" -H 'Content-Type: application/json' -d "$d" "http://localhost$p"
  else
    curl -s --max-time 3 --unix-socket "$SOCK" -X "$m" "http://localhost$p"
  fi
}

clash_cfg()      { clash_api GET /configs | jq -r "$1 | if . == null then empty else . end" 2>/dev/null; }
clash_mode()     { clash_cfg '.mode'; }
clash_tun()      { clash_cfg '.tun.enable'; }

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

# 当前真正落地的节点名：从 GLOBAL 顺着分组链往下走，直到没有 .now 的那个（只读，不改 Clash）
find_active_node() {
  clash_api GET /proxies | jq -r '
    def walk($n; $d):
      if $d > 8 then empty
      else .proxies[$n] as $p
        | if $p == null then empty
          elif ($p.now // "") == "" then $n
          else walk($p.now; $d + 1)
          end
      end;
    walk("GLOBAL"; 0)
  ' 2>/dev/null
}

VERGE_DIR="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"

# 规则里实际放行的节点端点（从 .build/pf.rules 反读，最可信）
allow_eps() {
  [ -f "$BUILD_DIR/pf.rules" ] || return 0
  sed -n 's/^pass out quick inet proto [a-z]* from any to \([^ ]*\) port = \([0-9]*\).*/\1:\2/p' "$BUILD_DIR/pf.rules" \
    | sort -u | paste -sd, -
}

# 节点的 server:port（只读 profile，不做 DNS，纯本地）
node_addr() {
  local pf
  pf="$(current_profile_file)"
  [ -n "$pf" ] && [ -f "$pf" ] || return 0
  python3 "$ROOT_DIR/lib/node_endpoints.py" "$pf" "$1" 2>/dev/null | paste -sd, -
}

# profile 里所有节点的 server:port（去重；域名走 DoH 解析成 IP:port）
node_all_endpoints() {
  local pf
  pf="$(current_profile_file)"
  [ -n "$pf" ] && [ -f "$pf" ] || return 0
  python3 "$ROOT_DIR/lib/node_endpoints.py" --all "$pf" 2>/dev/null \
    | while IFS= read -r ep; do
        local h="${ep%%:*}" pt="${ep#*:}"
        case "$h" in
          *[!0-9.]*) resolve_a "$h" | sed "s/$/:${pt}/" ;;
          *) printf '%s\n' "$ep" ;;
        esac
      done | sort -u
}

# ---- 节点端点探测 -----------------------------------------------------------
current_profile_file() {
  local cur
  cur="$(grep -E '^current:' "${VERGE_DIR}/profiles.yaml" 2>/dev/null | awk '{print $2}')"
  [ -n "$cur" ] && printf '%s' "${VERGE_DIR}/profiles/${cur}.yaml"
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

  # 锁定节点的端点：物理网卡上放行这一份
  local ep_rules="" ep="" ip port
  IFS=',' read -ra ADDR <<< "$NODE_ENDPOINTS"
  for ep in "${ADDR[@]}"; do
    ep="$(printf '%s' "$ep" | tr -d ' ')"
    [ -z "$ep" ] && continue
    ip="${ep%%:*}"
    port="${ep#*:}"
    if [ -z "$port" ] || [ "$port" = "$ip" ]; then port="443"; fi
    ep_rules="${ep_rules}pass out quick inet proto tcp from any to ${ip} port = ${port} flags S/SA keep state
pass out quick inet proto udp from any to ${ip} port = ${port} keep state
"
  done

  # 其它节点：不跟锁定节点同机的，按 IP 整条封（hy2 会换端口，只封 ip:port 会漏）；
  # 跟锁定节点同 IP 的（同一台机器不同端口，例如 xtls 8881 / hy2 8882），只能按端口封。
  local other_rules="" ep2 ip2 port2 seen_ip=" " seen_ep=" "
  while IFS= read -r ep2; do
    [ -z "$ep2" ] && continue
    ip2="${ep2%%:*}"; port2="${ep2#*:}"
    case ",${NODE_ENDPOINTS}," in *",${ip2}:${port2},"*) continue ;; esac
    if case ",${NODE_ENDPOINTS}," in *",${ip2}:"*) true ;; *) false ;; esac; then
      case "$seen_ep" in *" ${ip2}:${port2} "*) continue ;; esac
      seen_ep="${seen_ep}${ip2}:${port2} "
      other_rules="${other_rules}block drop quick inet proto { tcp, udp } to ${ip2} port = ${port2}
block drop quick inet proto { tcp, udp } from ${ip2} port = ${port2}
"
    else
      case "$seen_ip" in *" ${ip2} "*) continue ;; esac
      seen_ip="${seen_ip}${ip2} "
      other_rules="${other_rules}block drop quick inet proto { tcp, udp } to ${ip2}
block drop quick inet proto { tcp, udp } from ${ip2}
"
    fi
  done <<< "$(node_all_endpoints)"

  # DoH 放行（物理网卡）
  local h ips doh_rules=""
  for h in $DOH_HOSTS; do
    ips="$(resolve_a "$h" | paste -sd, -)"
    [ -n "$ips" ] && doh_rules="${doh_rules}pass out quick proto tcp to { ${ips} } port 443
"
  done

  cat > "$f" <<EOF
set skip on lo0
set block-policy drop

block drop all

# 别的节点：连 TUN 路径也堵（mihomo 出站被 TUN 吞回时源地址是 198.18.0.1）
EOF

  printf '%s' "$other_rules" >> "$f"

  [ -n "$other_rules" ] || warn "profile 里没读到其它节点 IP（或全是锁定节点）：TUN 路径上没额外封堵，换节点只靠物理网卡 block"

  cat >> "$f" <<EOF

# TUN / fake-ip 段全部放行：mihomo 自己的 DNS、DoH、节点连接都从这里走，不能按源地址区分
pass quick on lo0 all
pass quick on ${tun} inet from 198.18.0.0/16
pass quick on ${tun} all
pass quick from any to { ${LAN_CIDRS// /,} }
pass quick proto udp from any port 68 to any port 67
pass out quick proto { tcp, udp } to { ${DNS_SERVERS// /,} } port { 53, 853 }
EOF

  printf '%s' "$doh_rules" >> "$f"
  printf '%s' "$ep_rules" >> "$f"
}

do_on() {
  # ks on 永远不"失败"：每一步只看、只提示，能做多少做多少，退出码 0
  if ! ensure_sudo; then
    warn "没拿到管理员权限：pf 一点没动（这不是 ks 失败）"
    return 0
  fi

  if [ -z "${SOCK:-}" ]; then
    warn "没找到 Clash 控制 socket（Clash 没跑？）：读不到节点，白名单只能用 config.env 的 NODE_ENDPOINTS"
  fi

  # 1. TUN 归你自己管：没开也照装规则，等你打开才通
  if [ "$(clash_tun)" != "true" ]; then
    warn "Clash TUN 没开：规则照样装，TUN 打开前是断网状态（ks 不碰这个开关）"
  fi
  local tun
  tun="$(tun_device)"

  # 2. 模式只提示，不切换
  local current_mode
  current_mode="$(clash_mode)"
  [ "$current_mode" = "global" ] || warn "Clash 现在是 ${current_mode} 模式（不是 global）：分流到 DIRECT 的流量会被一起丢，自己决定"

  # 3. 读当前真正落地的节点（顺分组链走，不改 Clash）；读不到就继续
  local node
  node="$(find_active_node)"
  case "$node" in
    ""|DIRECT|REJECT|REJECT-DROP)
      warn "没读到落地节点（当前出口：${node:-空}）：白名单里不会有任何节点"
      node=""
      ;;
    *) ok "当前出网节点：${node}" ;;
  esac

  # 4. 节点端点 (IP:PORT)：每次重新算（同一个菜单进程里反复按 1 也不会沿用上一次的节点）
  NODE_ENDPOINTS="$CFG_NODE_ENDPOINTS"
  if [ -z "$NODE_ENDPOINTS" ] && [ -n "$node" ]; then
    NODE_ENDPOINTS="$(detect_endpoints "$node")"
  fi
  if [ -n "$NODE_ENDPOINTS" ]; then
    ok "放行节点端点：${NODE_ENDPOINTS}"
  else
    warn "没有节点端点：装上就是全断（要放行就把 IP:PORT 填进 config.env 的 NODE_ENDPOINTS）"
  fi

  # 5. 生成并载入规则（占系统主规则集，ks off 时还原 /etc/pf.conf）
  gen_rules "$tun"
  say "→ 载入内核 pf 规则（TUN: ${tun}，节点端点: ${NODE_ENDPOINTS:-无}）…"
  local loaded=0
  if sf -f "$BUILD_DIR/pf.rules"; then
    loaded=1
    # 规则载入不清已有状态：hysteria2 是长连接 QUIC（UDP keep state），
    # 不刷状态表，ks 生效前建立的节点会话会继续放行 —— "换了节点 hy2 还能出网"。
    sf -F states >/dev/null 2>&1 || warn "清空 pf 状态表失败（ks 生效前的老连接可能还能出去）"

    # 上次没关干净（token 文件被覆盖/丢失）时，先把自己留在引用表里的旧 token 释放掉，
  # 否则 pf 会被一堆 pfctl 引用顶着，off 也关不掉
  release_own_tokens

  # 只拿 ks 自己的引用（-E），token 存下来，off 时 -X 精确释放，不碰别人的引用
    # 注意：pfctl 的 "pf enabled / Token : …" 是打到 stderr 的，别把 stderr 丢掉
    # 记账：-E 前后比对引用表，新增的 token 一律记下来（不依赖 -E 的输出格式）
    local before after tokout tok
    before="$(pfq -s References -v | awk '$1 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {print $3}' | sort -u)"
    tokout="$(sf -E 2>&1 || true)"
    after="$(pfq -s References -v | awk '$1 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {print $3}' | sort -u)"
    tok="$(printf '%s\n' "$tokout" | sed -n 's/^Token[[:space:]]*:[[:space:]]*\([0-9][0-9]*\)$/\1/p' | tail -1)"
    { ks_tokens; printf '%s\n' "$tok"; comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"); } \
      | grep -E '^[0-9]+$' | sort -u > "$TOKEN_FILE"
    tok="$(ks_tokens | tail -1)"
    [ -n "$tok" ] || warn "没拿到 pf 引用 token（-E 输出异常且引用表无变化）"
  else
    warn "pf 规则没装上（规则文件在 ${BUILD_DIR}/pf.rules）：内核一点没改"
  fi

  fw_enabled || warn "pf 当前不是 Enabled（没有持有引用的进程；规则文件已生成）"

  # 6. 不验证联网（自己验）：记节点、写日志、收工
  [ -n "$node" ] && printf '%s' "$node" > "$STATE_DIR/node"
  printf '%s on user=%s tty=%s pid=%s node=%s ref=%s loaded=%s\n' "$(date '+%F %T')" "$(id -un)" "$(tty_id)" "$$" "${node:-?}" "${tok:-none}" "$loaded" >> "$STATE_DIR/ks.log"

  if [ "$loaded" = "1" ] && ks_rules_loaded; then
    ok "ks 已开启：出口锁定 ${node:-未读到}（${NODE_ENDPOINTS:-无端点}）"
    say "      之后在 Clash 里换节点 = 新节点没在白名单里 = 断网；要换出口：ks off → 选好节点 → ks on。"
  else
    warn "ks 没真正生效：规则不在内核（看上一条提示）"
  fi
  dim "      联网自己验：curl -s https://ipinfo.io/json ；要撤：ks off ；彻底放开：ks pfoff"
  dim "      不通时看计数器：sudo pfctl -s rules -v（'block drop quick inet ... to <其它节点IP>' 在涨 = 有别的节点在尝试出网）"
  return 0
}

do_off() {
  # ks off 也永远不"失败"：能清多少清多少，退出码 0
  if ! ensure_sudo; then
    warn "没拿到管理员权限：什么也没改（这不是 ks 失败）"
    return 0
  fi

  # 1. 只清 ks 自己那份规则：主规则集还原成系统自带的 /etc/pf.conf。
  #    若 ks 的规则不在内核（别人/系统自己在用），一律不碰。
  if ks_rules_loaded; then
    say "→ 清除 ks 的规则（主规则集还原成系统自带 /etc/pf.conf）…"
    sf -f /etc/pf.conf >/dev/null 2>&1 || warn "系统规则集还原失败"
  else
    dim "ks 的规则不在内核，无需清除"
  fi

  # 2. 只释放 ks 自己拿过的引用（可能有多个：反复 on 时 -E 每次都拿一个）
  if ks_tokens | grep -q .; then
    release_own_tokens
  else
    dim "ks 没有持有 pf 引用，无需释放"
  fi
  case "$(sf -s info 2>/dev/null)" in *"still enabled"*) dim "pf 仍由其他引用保持开启（那是别人的事）" ;; esac

  # 3. Clash 一律不动（模式/TUN/节点由你自己管）；只如实汇报系统 pf —— 那是 macOS 自己的事
  if fw_enabled; then
    warn "系统 pf 仍为开启（$(pf_holders)由 macOS/其他软件自己管理），ks 只清了自己那份"
  else
    ok "系统 pf 也已关闭（内核里没有其他引用）"
  fi
  printf '%s off user=%s tty=%s pid=%s\n' "$(date '+%F %T')" "$(id -un)" "$(tty_id)" "$$" >> "$STATE_DIR/ks.log"
}

do_status() {
  say "====================  mac-killswitch 状态  ===================="
  # —— ks 自己 ——
  if ks_rules_loaded; then
    ok "ks：已开启（规则压在内核主规则集上，fail-closed 保护中）"
    dim "      规则生成于：$(/usr/bin/stat -f '%Sm' "$BUILD_DIR/pf.rules" 2>/dev/null || echo 未生成过)"
  else
    dim "ks：未开启（ks 的规则不在内核）"
  fi
  if ks_ref_held; then
    dim "      ks 持有 pf 引用：token $(ks_tokens | paste -sd, -)"
  elif ks_tokens | grep -q .; then
    dim "      ks 留有旧 token $(ks_tokens | paste -sd, -)，但内核引用表里已没有它（下次 off 会清掉）"
  fi

  # —— 系统 pf（macOS/其他软件自己那套，与 ks 无关）——
  local h
  h="$(pf_holders)"
  h="${h%; }"
  if fw_enabled; then
    say "系统 pf：已开启（引用持有者：${h:-未列出}）"
  else
    say "系统 pf：未开启"
  fi
  dim "         $(pfq -s info | grep -o 'Status: .*')"

  if [ -n "${SOCK:-}" ]; then
    local cur_node locked_node cur_addr eps
    cur_node="$(find_active_node)"
    cur_addr="$(node_addr "$cur_node")"
    say "Clash 模式：$(clash_mode)   TUN 虚拟网卡：$(clash_tun)"
    say "当前选定节点：${cur_node}${cur_addr:+（${cur_addr}）}"
    # ks 只锁「on 那一刻」的节点端点；之后换节点，新节点的包会被丢（fail-closed），不会跟着切
    if ks_rules_loaded && [ -f "$STATE_DIR/node" ]; then
      locked_node="$(cat "$STATE_DIR/node" 2>/dev/null)"
      eps="$(allow_eps)"
      if [ "$cur_node" != "$locked_node" ]; then
        bad "节点已从 ${locked_node} 切到 ${cur_node}：白名单里只有前者，现在出网应全部被丢（要换出口：ks off → 选节点 → ks on）"
      else
        dim "      白名单锁定：${locked_node}（放行端点 ${eps:-空 = 全断}；换到别的节点会断网）"
      fi
    fi
  else
    dim "Clash：未运行或未找到控制 Socket"
  fi

  say "=============================================================="
}

# 终极恢复：把 pf 整个关掉（系统/别人持有的引用一起压掉），不是 ks off
do_pfoff() {
  if ! ensure_sudo; then
    warn "没拿到管理员权限：pf 没动"
    return 0
  fi
  ks_tokens | grep -q . && release_own_tokens
  say "→ 关闭 pf（pfctl -d：所有引用一起失效，内核不再做过包过滤）…"
  sf -d 2>&1 | sed 's/^/    /'
  if fw_enabled; then
    warn "pf 还是 Enabled（可能被 pfd 立刻拉回来了）"
  else
    ok "pf 已关闭：现在是完全裸奔状态，要恢复过滤用 ks on 或重启 pf"
  fi
  printf '%s pfoff user=%s tty=%s pid=%s\n' "$(date '+%F %T')" "$(id -un)" "$(tty_id)" "$$" >> "$STATE_DIR/ks.log"
  return 0
}

menu() {
  while :; do
    say ""
    do_status
    say "  1) 开启   → 锁当前节点 + 阻断全部旁路（TUN/模式由你在 Verge 里管）"
    say "  2) 关闭   → 只清 ks 自己的规则与 pf 引用（Clash 一律不动）"
    say "  3) 状态   → 重新检查并刷新当前状态"
    say "  4) 关掉所有 pf → 终极恢复（连系统/别人的引用一起压掉，纯裸奔）"
    say "  q) 退出菜单"
    printf "请选择 [1/2/3/4/q]: "
    read -r c
    case "$c" in
      1) do_on;;
      2) do_off;;
      3) do_status;;
      4) do_pfoff;;
      q|Q) break;;
      *) say "无效输入";;
    esac
  done
}

case "${1:-menu}" in
  on)     shift; do_on "$@";;
  off)    shift; do_off "$@";;
  status) shift; do_status "$@";;
  pfoff|pf-off|unpf|alloff) shift; do_pfoff "$@";;
  menu|"") menu;;
  -h|--help|help)
    say "用法: ks [on|off|status|pfoff|menu]    pfoff = 关掉所有 pf（终极恢复）"
    ;;
  *)
    say "未知命令: $1"
    say "用法: ks [on|off|status|pfoff|menu]    pfoff = 关掉所有 pf（终极恢复）"
    exit 1
    ;;
esac
