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
脚本 `on`（不带 `--fw-only`）会自动把 Clash 切到 `global`；若已是 global 则不动 GLOBAL 组的选择。
`ks check` 会核对这两点。

## 安装

```bash
git clone git@github.com:<you>/mac-killswitch.git ~/Documents/dev/mac-killswitch
cd ~/Documents/dev/mac-killswitch
cp config.env.example config.env    # 填自己的节点 IP:端口
chmod +x killswitch.sh
```

alias（写进 `~/.zshrc`）：

```bash
alias ks="$HOME/Documents/dev/mac-killswitch/killswitch.sh"
```

换机器：clone + `cp config.env.example config.env` + 改节点即可，脚本会自动找 Clash Verge 的控制 socket 和 TUN 设备。

## 用法

**只记一个命令：`ks`**（回车即出菜单，带状态、出口 IP、节点）

```bash
ks                # 菜单：1 开启 / 2 关闭 / 3 自检 / 4 详情
ks on             # 直接开启（防火墙 + Clash 切全局，无任何 DIRECT 分流）
ks off            # 直接关闭（pf 停用 + Clash 模式还原）
ks status / check # 状态 / 自检
```

首次（或 sudo 缓存过期后）开启时会问一次你的密码——标准 sudo 行为，密码缓存几分钟，期间再来回切不再问。

开启时自动自检：给 `1.1.1.1` 临时加一条走物理网卡的路由 + 探测几个旁路目标，确认这些包被 `block drop`（读 pf 计数器验证），并打印隧道出口 IP。

## 关掉（没网时的救命命令）

```bash
ks off              # 正常关（还原 Clash 模式 + 停用 pf）
sudo pfctl -d       # 极端情况：直接停用 pf（纯本机操作，不需要网络）
```

`pf` 只是一道本机防火墙规则，关它不需要联网；而且脚本开启时会先自检，如果发现**连隧道都不通**会立刻自动还原，不会把你锁死。

```
App ──► utun（Clash TUN）──► mihomo ──► 节点 IP:PORT ──► 互联网
          ↑ 放行                 ↑ 放行（白名单）
      物理网卡上其它一切 ────────► block drop
```

- `pf` 规则由脚本按 `config.env` 生成到 `.build/pf.rules`，`pfctl -f` 载入、`pfctl -E` 启用。
- 生成的规则保留了 `com.apple` anchor，避免顺手关掉系统自带的应用防火墙。
- 不使用 pf 的话，Clash 那套 TUN 在崩溃/重启的空窗期会让系统路由回落到物理网卡 → 新连接裸奔。这就是 kill switch 存在的意义。

## 注意

- **开启后 Clash 的 DIRECT 分流会被掐死**（国内直连站点连不上）。想要"能上网且不直连"，用默认的全局模式；想保留规则分流用 `ks on --fw-only`，但要接受国内直连规则失败。
- 同时装着 Tailscale / Shadowrocket / V2rayU 等别的 VPN：它们的直连会被一起掐，这是预期行为。
- 换节点：改 `config.env` 的 `NODE_ENDPOINTS` 再 `ks on`（订阅里那些域名解析的动态节点没法预先写白名单）。
- `route-exclude-address` 这类绕过 TUN 的地址也会被掐，需要的话加进 `ALLOW_PORTS_EXTRA`。
- 重启后 pf 恢复系统默认（**默认不开启**）；需要常驻可自己加 LaunchDaemon。
- 脚本执行需要 root（`sudo`），因此 `ks` 会提示输入密码。
