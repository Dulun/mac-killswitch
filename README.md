# mac-killswitch

macOS 上的 **fail-closed 网络开关**：要么全部流量走 Clash(TUN) → 你锁定的那一个节点，要么直接断网。
不存在"代理挂了偷偷直连"，也不存在"随手换个节点就悄悄换了出口"。

用内核 `pf` 实现，`ks on` 之后出网只剩四类：

1. 回环 `lo0`
2. 局域网（`LAN_CIDRS`）
3. Clash 的 TUN —— 但 **`198.18.0.0/16`（fake-ip 段）整段放行**：mihomo 自己的 DNS/DoH/节点连接都从这里走
4. **锁定节点的 `IP:端口`** + bootstrap DNS / DoH

其余全部 `block drop`（含入站与 IPv6）。此外，profile 里**其它所有节点的服务器 IP** 会在任意接口上双向封死 ——
所以 Clash 里换节点的那一刻，出口就没了。

## 前置要求

- Clash Verge Rev（mihomo 内核），**TUN 模式由你自己在 Verge 里打开** —— ks 不碰这个开关；没开会提示，规则照样装（= 断网）。
- 选好一个真节点（不可是 `DIRECT` / `REJECT` / 分组）。建议 `global` 模式；其它模式只提示，不切换。
- 只有 `sudo`（改 pf），不需要联网。

ks 对 Clash **只读**：`GET /configs` 拿 TUN 设备/模式，`GET /proxies` 顺 `GLOBAL → … → .now` 链找到真正落地的节点。
不切模式、不选节点、不动 TUN。

## 安装

```bash
git clone https://github.com/Dulun/mac-killswitch.git ~/Documents/dev/mac-killswitch
cd ~/Documents/dev/mac-killswitch
cp config.env.example config.env     # 一般什么都不用改
chmod +x killswitch.sh
```

alias（`~/.zshrc`）：

```bash
alias ks="$HOME/Documents/dev/mac-killswitch/killswitch.sh"
```

## 用法

```bash
ks                # 菜单：1 开启 / 2 关闭 / 3 状态 / 4 关掉所有 pf / q 退出
ks on             # 锁定当前节点 + 装规则
ks off            # 只清 ks 的东西（规则还原 /etc/pf.conf + 释放自己的 pf 引用），Clash 一律不动
ks status         # 纯读内核 + 只读 Clash，不联网
ks pfoff          # 终极恢复：pfctl -d，整个 pf 关掉（含系统/别人的引用，纯裸奔）
```

`on` / `off` **永远退出 0**，也不做联网自检、不回滚 —— 通不通自己验：
`curl -s https://ipinfo.io/json`。

### 换节点

规则是**静态**的，没有任何后台进程：

- 在 Clash 里换到别的节点 → 那个节点的服务器 IP 已在封堵名单里 → **立刻断网**；
- 切回锁定节点 → 它的 `IP:端口` 本来就在放行名单里 → **立刻恢复**；
- 想换成另一个出口：`ks off` → 选节点 → `ks on`。新一轮里旧节点自动进入封堵名单，不会继续放行。

### 关掉（没网时的救命命令）

```bash
ks off                        # 正常关：还原 /etc/pf.conf + 释放 ks 自己的引用（Clash/系统 pf 不动）
ks pfoff                      # 极端情况：pfctl -d 整个关掉（之后要恢复过滤必须重新 ks on）
sudo pfctl -s References -v   # 看 pf 到底是谁开着的
```

## 它到底写了什么规则

`gen_rules` 生成到 `.build/pf.rules`，`pfctl -f` 载入主规则集：

```
block drop all

# 其它节点的服务器 IP：任意接口、双向、任意端口全封（hy2 会换端口，只封 ip:port 会漏）
block drop quick inet proto { tcp, udp } to   <其它节点IP>
block drop quick inet proto { tcp, udp } from <其它节点IP>

pass quick on lo0 all
pass quick on <tun> inet from 198.18.0.0/16
pass quick on <tun> all
pass quick from any to { <LAN_CIDRS> }
pass quick proto udp from any port 68 to any port 67
pass out quick proto { tcp, udp } to { <DNS_SERVERS> } port { 53, 853 }
pass out quick proto tcp to { <DoH IPs> } port 443

pass out quick inet proto tcp from any to <锁定节点IP> port = <端口> flags S/SA keep state
pass out quick inet proto udp from any to <锁定节点IP> port = <端口> keep state
```

配套动作：

- **`pfctl -F states`**：清掉 `on` 之前就存在的连接状态。hysteria2 是长连接 QUIC（UDP `keep state`），不清会继续沿用老节点。
- **`pfctl -E` + token 记账**：每次 `-E` 前后比对 `pfctl -s References`，新增 token 全部写入 `.state/pf.tokens`；`on` 开头 / `off` / `pfoff` 都会全量释放。实测 `on → on → off` 之后内核引用表里 0 个 `pfctl` token。
- **只释放自己的引用**：`pfd`、InternetSharing 等别人的引用一概不动，`ks status` 里分开显示。

## 无后台进程

`ks` 是一次性脚本：装完规则就退出，不跑 daemon、不轮询 Clash。所有保证都由内核里的静态规则提供。

## 已知边界

- `ks on` 之后**订阅更新新加**的节点不在封堵名单里（物理网卡侧仍被 `block drop all` 挡住，只有"mihomo 把出站塞回 TUN"那条路径可能漏），重跑一次 `ks on` 即可。
- 只扫**当前 profile 文件**里的节点；`proxy-providers` 拉进来的节点读不到（当前用法是内联 profile，不受影响）。
- 规则是 `inet`（IPv4）；IPv6 除了隧道内部，物理网卡上全部被 `block drop all` 丢掉。
- ks 不管 Clash 的模式/TUN/节点，也不管系统 pf 的开关状态。
- 重启后 pf 由系统自己决定（本机实测会被 `pfd` 为 vmnet 自行打开），ks 只负责自己那份。

## 排查

```bash
ks status                            # ks 是否在内核 / 引用持有者 / 模式 / 当前节点(IP)
sudo pfctl -s rules -v               # 每条规则命中的包数：看是哪条在丢
sudo pfctl -s References -v          # pf 是谁开着的（pid / 名字 / token）
ks pfoff                             # 兜底：全关
tail .state/ks.log                   # on / off / switch / lockdown 审计日志
```

典型的"开了 ks 没网"：Clash 的 TUN 没开（`ks status` 里 `TUN 虚拟网卡：false`），此时规则只有 LAN/DNS 放行，其余全断 —— 这是设计行为。

## 许可

MIT
