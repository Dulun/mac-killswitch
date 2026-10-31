# mac-killswitch

macOS 上的 **fail-closed 网络开关**：要么全部流量走 Clash(TUN) → 你锁定的那一个节点，要么直接断网。
不存在"代理挂了偷偷直连"，也不存在"随手换个节点就悄悄换了出口"。

内核 `pf` 实现，`ks on` 之后出网只剩这些：

1. 回环 `lo0`
2. 局域网（`LAN_CIDRS`）
3. Clash 的 TUN —— **`198.18.0.0/16`（fake-ip 段）整段放行**：mihomo 自己的 DNS / DoH / 节点连接都从这里走
4. **锁定节点的 `IP:端口`** + bootstrap DNS（53/853）+ DoH（443）

其余全部 `block drop`（含入站与 IPv6）；另外 profile 里**其它所有节点的服务器 IP** 会在任意接口上双向封死。

## 前置要求

- Clash Verge Rev（mihomo 内核）。**TUN 由你自己在 Verge 里打开** —— ks 不碰这个开关，没开只提示、规则照装（= 断网）。
- 选好一个真节点（不能是 `DIRECT` / `REJECT` / 分组节点）。模式建议 `global`；其它模式只提示，不切换。
- `sudo`（改 pf）。可选：跑一次 `./fix-sudo.sh`，把 `pfctl` 加进 sudoers 白名单，之后永久免密。

ks 对 Clash **只读**：`GET /configs` 取 TUN 设备/模式，`GET /proxies` 顺 `GLOBAL → … → .now` 找到真正落地的节点，
再从 profile 里读它的 `server:port`。不切模式、不选节点、不动 TUN。

## 安装

```bash
git clone https://github.com/Dulun/mac-killswitch.git ~/Documents/dev/mac-killswitch
cd ~/Documents/dev/mac-killswitch
cp config.env.example config.env     # 一般不用改
chmod +x killswitch.sh
./fix-sudo.sh                        # 可选：免密（只要一次密码）
```

alias（`~/.zshrc`）：

```bash
alias ks="$HOME/Documents/dev/mac-killswitch/killswitch.sh"
```

## 用法

```bash
ks                # 菜单：1 开启 / 2 关闭 / 3 状态 / 4 关掉所有 pf / q 退出
ks on             # 锁定当前节点（只放行它的 ip:端口）
ks on --same-ip   # 锁定节点所在 IP：该 IP 上任意端口/协议都放行（同机的其它节点也能用）
ks off            # 只清 ks 的东西：规则还原 /etc/pf.conf + 释放自己的 pf 引用；Clash 一律不动
ks status         # 纯读内核 + 只读 Clash，不联网
ks pfoff          # 终极恢复：pfctl -d，整个 pf 关掉（含系统/别人的引用，纯裸奔）
```

`on` / `off` **永远退出 0**，不做联网自检、不回滚、不跑后台进程。通不通自己验：

```bash
curl -s https://ipinfo.io/json     # 出口 IP 应该等于锁定节点
```

### 换节点 = 直接断网，切回 = 自动恢复

规则是静态的，没有守护进程：

- 在 Clash 里切到别的节点 → 那个节点的服务器 IP 已在封堵名单里 → **立刻断网**；
- 切回锁定节点 → 它的 `IP:端口` 一直在放行名单里 → **立刻恢复**；
- 想换成另一个出口：`ks off` → 选节点 → `ks on`，旧节点自动进入封堵名单。

默认按 `ip:端口` 锁；`ks on --same-ip`（或 `config.env` 里 `SAME_IP_ALLOW=1`）改成按 IP 锁：
同一个 IP 上的所有端口/协议都放行 —— 适合同一台机器上挂了 xtls(8881)+hy2(8882) 两个节点、
你想两个都能用的情况。

### 一键关掉（没网时的救命命令）

```bash
ks off                        # 正常关：还原 /etc/pf.conf + 释放 ks 自己的引用
ks pfoff                      # 极端情况：pfctl -d 整个关掉（之后要恢复过滤必须重新 ks on）
sudo pfctl -s References -v   # 看 pf 到底是谁开着的
```

## 它写了什么规则

`gen_rules` 生成到 `.build/pf.rules`，`pfctl -f` 载入主规则集（实际输出）：

```
block drop all

# 其它节点：任意接口、双向全封。不同机器的整条 IP 封（hy2 会换端口，只封 ip:port 会漏）；
# 跟锁定节点同机不同端口的（xtls 8881 / hy2 8882）按端口封
block drop quick inet proto { tcp, udp } to   179.255.127.122 port = 8882
block drop quick inet proto { tcp, udp } from 179.255.127.122 port = 8882
block drop quick inet proto { tcp, udp } to   44.250.23.201
block drop quick inet proto { tcp, udp } from 44.250.23.201
...

pass quick on lo0 all
pass quick on utun1024 inet from 198.18.0.0/16    # fake-ip 段，mihomo 自己也在这条路上
pass quick on utun1024 all
pass quick from any to { 192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,169.254.0.0/16,224.0.0.0/4 }
pass quick proto udp from any port 68 to any port 67
pass out quick proto { tcp, udp } to { <DNS_SERVERS> } port { 53, 853 }
pass out quick proto tcp to { <DoH IPs> } port 443

pass out quick inet proto tcp from any to 44.250.23.201 port = 8881 flags S/SA keep state
pass out quick inet proto udp from any to 44.250.23.201 port = 8881 keep state
```

配套动作：

- **`pfctl -F states`**：清掉 `on` 之前的连接状态。hysteria2 是长连接 QUIC（UDP `keep state`），不清会继续走老节点。
- **`pfctl -E` + token 记账**：每次 `-E` 前后 diff `pfctl -s References`，新增 token 全部写入 `.state/pf.tokens`；
  `on` 开头 / `off` / `pfoff` 都会全量释放。实测 `on → on → off` 之后内核里 0 个 `pfctl` 引用，不需要手动清理。
- **只释放自己的引用**：`pfd` / InternetSharing 等别人的引用一概不动，`ks status` 里分开显示持有者。

## 已知边界

- `ks on` 之后**订阅更新新加**的节点不在封堵名单（物理网卡侧仍被 `block drop all` 挡住，只有"mihomo 把出站塞回 TUN"那条路径可能漏），重跑一次 `ks on` 即可。
- 只扫**当前 profile 文件**里的节点；`proxy-providers` 拉进来的节点读不到（当前用法是内联 profile，不受影响）。
- 规则是 `inet`（IPv4）；IPv6 除隧道内部外全部被 `block drop all` 丢掉。
- 不管 Clash 的模式/TUN/节点，也不管系统 pf 的开关状态；重启后 pf 由系统自己决定。
- 必须让流量真的进隧道：Clash 若在 `rule` 模式或 TUN 关闭，结果就是断网（设计如此）。

## 排查

```bash
ks status                       # ks 是否在内核 / 引用持有者 / 模式 / 当前节点(IP)
sudo pfctl -s rules -v          # 每条规则命中的包数：看是哪条在丢
sudo pfctl -s References -v     # pf 是谁开着的（pid / 名字 / token）
ks pfoff                        # 兜底：全关
tail .state/ks.log              # on / off 审计日志
```

典型"开了 ks 没网"：`ks status` 里 `TUN 虚拟网卡：false` —— 此时只放行 LAN/DNS，其余全断，这是设计行为。

## 文件

```
killswitch.sh          # 全部逻辑
lib/node_endpoints.py  # profile → 节点 server:port（--all 列全部）
config.env             # 本地配置，不进 git
.state/                # node / pf.tokens / ks.log，不进 git
.build/pf.rules        # 生成的规则，不进 git
```

## 许可

MIT
