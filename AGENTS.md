# AGENTS.md — mac-killswitch

macOS 上的 fail-closed 网络开关：用 `pf` 只放行「Clash TUN + 一个锁定节点」，其余全断。
`killswitch.sh` 是唯一入口（`ks` 是它的 alias），`lib/node_endpoints.py` 从 Clash profile 里取节点端点。

## 硬约束（改动前先读）

1. **不碰 Clash**：只允许读控制 socket（`GET /configs`、`GET /proxies`）。禁止切模式、选节点、开关 TUN、改 Verge 配置。
2. **不碰系统 pf 的开关**：只 `-f` 自己的主规则集 + `-E`/`-X` 自己那一个引用。`pfd` / InternetSharing 的引用一律不动。
3. **fail-closed**：宁可断网，不可放行。任何解析失败都退化成「不放行」，绝不放宽白名单。
4. **`on` / `off` 永远退出 0**：所有前置条件降级成提示，不 `return 1`、不回滚、不联网自检。
5. **单一出口**：白名单只能有一个节点；换节点必须 `off` → 选 → `on`，看门狗只负责"切走就断网"。

## 规则生成的三条铁律（都是踩过的坑）

- **不要在 TUN 上按源地址过滤**。mihomo 自己的 DNS/DoH/QUIC 出站源地址就是 TUN 地址 `198.18.0.1`，按源封会连 DoH 一起封掉 → 表现为"有 fake-ip 但没网"。
- **`198.18.0.0/16` 整段放行**（`tun` 上），应用流量与 mihomo 内部流量共用这条路径，无法区分。
- **"锁一个节点" = 封其它节点**：从 profile 读出所有节点 IP，扣掉锁定节点，逐个
  `block drop quick inet proto { tcp, udp } to/from <ip>`，**不限接口**（en0 / utun 都要拦；hysteria2 会换端口，只封 `ip:port` 会漏）。

另外两条必须保留：

- 载入规则后 `pfctl -F states`：hysteria2 是长连接 QUIC，不清状态表会继续沿用老会话。
- `-E` 前后 diff `pfctl -s References` 记账 token；`on`/`off`/`pfoff` 全量释放。**不要**只依赖 `-E` 的 stderr 文本。

## 结构

```
killswitch.sh            # 全部逻辑；do_on / do_off / do_status / do_pfoff / do_watch / gen_rules
lib/node_endpoints.py    # <profile> <节点名> → server:port；--all <profile> → 所有节点
config.env               # 本地配置，不进 git（NODE_ENDPOINTS / DNS_SERVERS / DOH_HOSTS / LAN_CIDRS）
.state/                  # node / pf.tokens / watcher.pid / watch / ks.log，不进 git
.build/pf.rules          # 生成的规则，不进 git
```

`.state/node` 记录锁定节点名，`ks status` 用它判断漂移；`.state/watch` 存在时看门狗才轮询。

## 验证（改完必须跑）

```bash
bash -n killswitch.sh                                  # 语法
sudo pfctl -n -f .build/pf.rules                       # 规则能否解析（-n 不载入）
./killswitch.sh status                                 # 只在干净环境里跑，不会改状态
```

需要端到端验证时，**必须**先挂自动关，避免把自己锁死：

```bash
nohup bash -c 'sleep 45; ./killswitch.sh off' &
./killswitch.sh on
curl -s https://ipinfo.io/json | jq -r .ip      # 应等于锁定节点 IP
```

不要为了验证去改用户的节点选择；`GLOBAL` 只在用户要求或明确同意时才动，动完要还原。

## 提交

Conventional Commits，中文正文；`git add` 只加本任务文件（`.state/`、`.build/`、`config.env` 已忽略）。
推送前确认 `git status -sb` 干净；HTTPS push 遇到 HTTP2 framing 错误用
`git -c http.version=HTTP/1.1 push`。
