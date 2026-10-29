# mac-killswitch

macOS 上的 **fail-closed 网络开关**：要么全部流量走 Clash(TUN)→你的节点，要么直接断网。不存在"代理挂了偷偷直连"这种事。

内核层用 `pf` 防火墙实现，出网只放行四类：

1. 回环 `lo0`
2. 局域网（`LAN_CIDRS`：路由器 / SSH / 打印机）
3. Clash 的 TUN 隧道设备（`utun*`）
4. **你节点的 IP:端口** + bootstrap DNS 服务器

其余全部 `block drop`（含 IPv6 与入站）。Clash 挂掉 / TUN 掉线 / DNS 崩了，结果是——打不开任何网站（断网），而不是露出真实 IP。

## 前置要求

**Clash 必须是 TUN 模式 + 全局模式**：TUN 让所有流量进隧道，全局让隧道里没有任何 DIRECT 分流。
ks 只**读** Clash（控制 socket 取当前落地的节点）：不切模式、不选节点、不动 TUN。模式不是 `global` 时只提示。
`ks check` 会核对这两点。

## 安装

```bash
git clone git@github.com:<you>/mac-killswitch.git ~/Documents/dev/mac-killswitch
cd ~/Documents/dev/mac-killswitch
cp config.env.example config.env    # 什么都不用填：节点 IP:端口 会自动从 Clash 当前选中节点读取
chmod +x killswitch.sh
```

alias（写进 `~/.zshrc`）：

```bash
alias ks="$HOME/Documents/dev/mac-killswitch/killswitch.sh"
```

**前置条件（脚本会自己检查，不满足直接拒绝开启）**：**TUN 由你自己在 Verge 里开、节点由你自己选好**；ks 不碰 Clash 的任何设置。放行名单只有「隧道 + 局域网 + 当前节点 + DNS」，所以 Clash 若在 `rule` 模式，分流到 DIRECT 的流量会被一起丢光（这是你自己选的模式，ks 只提示）。

换机器：clone + `cp config.env.example config.env` 就行——脚本会自动找 Clash Verge 的控制 socket、TUN 设备，并**读取你当前选中的节点 IP:端口**（开启后节点就被锁死，换节点要先 `ks off`）。
想手动指定（比如节点在 TUN 外、或自动读不到）就在 `config.env` 里填 `NODE_ENDPOINTS=1.2.3.4:443,...`，填了就以手填为准。

## 用法

**只记一个命令：`ks`**（回车即出菜单，带状态、节点、节点锁定状态）

ks 不做联网探测（不 curl、不回滚），联网自己验：`curl -s https://ipinfo.io/json`。

```bash
ks                # 菜单：1 开启 / 2 关闭 / 3 状态 / q 退出
ks on             # 直接开启（只装防火墙规则；读 Clash 当前节点当白名单）
ks off            # 直接关闭：只清 ks 自己的规则与 pf 引用（Clash、系统 pf 都不动）
ks status          # 状态（纯读内核，不联网）
ks pfoff           # 终极恢复：pfctl -d，把整个 pf 关掉（含系统/别人的引用，纯裸奔）
```

首次（或 sudo 缓存过期后）开启时会问一次你的密码——标准 sudo 行为，密码缓存几分钟，期间再来回切不再问。

开启时不做联网自检：只校验 Clash 可达 / TUN 已开 / 节点能解析出 `server:port`，然后把规则压进内核并打印锁定的节点。

## 关掉（没网时的救命命令）

```bash
ks off                        # 正常关：清 ks 自己的规则 + 释放 ks 自己的 pf 引用（Clash 不动）
sudo pfctl -s References -v   # 看 pf 到底是谁开着的（pid / 名字 / token / 时间）
sudo pfctl -d                 # 极端情况：把 pf 整个硬关（会连系统/别人持有的引用一起压掉，慎用）
```

`pf` 只是一道本机防火墙规则，关它不需要联网；ks 不会自动回滚（不通就等你手动 `ks off`）。

```
App ──► utun（Clash TUN）──► mihomo ──► 节点 IP:PORT ──► 互联网
          ↑ 放行                 ↑ 放行（白名单）
      物理网卡上其它一切 ────────► block drop
```

- `pf` 规则由脚本按 `config.env` 生成到 `.build/pf.rules`，`pfctl -f` 载入主规则集，`pfctl -E` 启用并把自己的引用 token 存到 `.state/pf.token`。
- TUN 开关全程由你在 Verge 里管：`ks on` 只检查，没开就拒绝；`ks off` 不动 TUN。
- 关闭时：主规则集还原成系统自带 `/etc/pf.conf`，再用 `pfctl -X <token>` 精确释放 ks 自己那一个引用。
- macOS 自己（`pfd` / `InternetSharing` 那套虚拟机网络）或别的软件持有的引用一律不动——它们要开着就让它开着，`ks status` 里分开显示持有人（pid/名字/token/时间）。
- ks 开启期间系统自带的 `com.apple` anchor 暂不参与过滤（主规则集被 ks 的整份规则替换）；关闭即还原。
- 不使用 pf 的话，Clash 那套 TUN 在崩溃/重启的空窗期会让系统路由回落到物理网卡 → 新连接裸奔。这就是 kill switch 存在的意义。

## 注意

- **开启后 Clash 的 DIRECT 分流会被掐死**（国内直连站点连不上）。想要"能上网且不直连"，用默认的全局模式；想保留规则分流用 `ks on --fw-only`，但要接受国内直连规则失败。
- 同时装着 Tailscale / Shadowrocket / V2rayU 等别的 VPN：它们的直连会被一起掐，这是预期行为。
- 换节点：**不能边开边换**。`ks on` 那一刻从 Clash 当前链路取到落地的节点，把它的 `server:port` 写死进白名单；之后你在 Clash 里换节点/换分组，新节点的连接会被 `block drop` 掉 = 直接断网（切回原节点才恢复）。要换出口：`ks off` → 选好节点 → `ks on`（节点 `server` 写域名时会走 DoH 解析成真实 IP）。
- ks 载入规则后会**清空 pf 状态表**（`pfctl -F states`）：hysteria2 这类长连接 QUIC 会话不清会一直沿用 ks 生效前的老节点。
- TUN 路径：`198.18.0.0/16`（fake-ip 段）整段放行 —— mihomo 自己的 DNS/DoH/节点连接都会从这里走，**不能按源地址区分**（按源封会把 DoH 一起封掉，表现就是"有 fake-ip 但没网"）。
- 单节点锁定靠"封其它节点"实现：`ks on` 时从 profile（`--all`）读出所有节点的服务器 IP，扣掉锁定节点，对每个 IP 在 TUN 上双向整条封（不限端口 —— hysteria2 的 QUIC 端口可能被端口跳跃换掉，只封 ip:port 会漏）。物理网卡侧仍是 `block drop all` + 只放行锁定节点 `ip:port`。
- `route-exclude-address` 这类绕过 TUN 的地址也会被掐，需要的话加进 `ALLOW_PORTS_EXTRA`。
- 重启后 pf 由系统自己决定（本机实测会被 `pfd` 为 vmnet 虚拟网络自行打开）；ks 只负责自己那份规则与引用，`ks status` 里分开显示。
- 脚本执行需要 root（`sudo`），因此 `ks` 会提示输入密码。
