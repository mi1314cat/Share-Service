# proxy-share-service

一个**公共的分享链接服务**：只管"怎么存、怎么发 Token、怎么限制时间和次数、怎么访问"。

它**不生成也不解析**任何内核的配置。

```
                 proxy-share-service
                  (Token / TTL / max_uses
                   used_count / 存储 / 访问)
                          │
          ┌───────────────┼───────────────┐
          │               │               │
       mihomo         sing-box          xray
          │               │               │
      自己的面板      自己的面板      自己的面板
      只管理自己      只管理自己      只管理自己
```

本服务**自己**也有一个面板（`panel.sh`），管的是整个服务：
看得到全部 provider、能装/升级/卸载服务本身。两者职责不同，不要混。

## 边界（硬边界，不接受商量）

| 公共服务负责 | 内核自己负责 |
|---|---|
| Token 生成 | 节点怎么生成 |
| TTL / 过期判断 | 完整配置怎么拼 |
| max_uses / used_count | 内容长什么样 |
| content 的存储与读取 | 什么时候创建、什么时候刷新 |
| 创建 / 查询 / 更新 / 删除 | 面板怎么展示 |
| 公开访问与访问控制 | 客户端要什么格式 |

**`content` 对它是不可解析的字节。** `provider` 与 `type` 都只是元数据，
内部**不允许**出现 `if provider == "mihomo"` 这类分支 —— 加第四个内核时，
`src/share_service.py` 一行都不用改。

## 两类资源

```
type=node     单节点 / 节点集合的分享
type=config   整个内核的完整配置分发
```

两者在公共服务眼里**行为完全一致**，只是标签不同。区别只在内核侧怎么生成内容、
面板怎么展示。

## 安装 / 升级 / 卸载

```bash
bash install.sh              # 安装（幂等：已装且健康就什么都不做）
bash install.sh --check      # 只看状态，不做任何改动
bash install.sh upgrade      # 只刷新服务代码并重启（端口/数据/密钥/env 不动）
bash install.sh uninstall              # 没有记录时可直接卸载（数据保留）
bash install.sh uninstall --force      # 有记录时显式确认卸载（数据保留）
bash install.sh uninstall --purge      # 连数据一起删
```

**幂等**：已装过就只做检查，不重装、不改端口、不碰数据。
所以第一个装的内核（比如 M）把它装好之后，后装的 SB/X 会直接复用它。

**升级必须显式**：同一条幂等规则也意味着改了 `share_service.py` 之后再跑
`install.sh` 是**空操作** —— 你会以为升级了其实没有。所以要升级就
`bash install.sh upgrade`。它只换代码：端口、数据、管理密钥、env 一律不动，
替换是原子的（先落 `.new` 再 `mv`，不会让正在运行的进程读到半个文件）。

**`--force` 与 `--purge` 是两件事**：`--force` = "我知道已有链接会失效，仍要卸载
（数据留着）"；`--purge` = "连数据一起删"。有记录却不给任何一个时，卸载会被
拒绝 —— 因为服务一停，M/SB/X 已经发出去的链接会同时失效。

### 内核卸载会不会误删本服务？

**不会。** 这是硬边界：

- M 的 `uninstall_service` / `_uninstall_all` 只认历史遗留的 `mihomo-share`，
  并在 `_uninstall_unit` 里有一道兜底闸门：`proxy-share-service` 直接拒绝删除。
  （曾经这里取的是 `$SHARE_SERVICE`，而它在 `lib/env.sh` 里默认 `mihomo-share`、
  在 `share/share.sh` 里默认 `proxy-share-service` —— 谁生效看 source 顺序。
  一旦取到公共服务而 `SRV_ROOT` 又恰好是 unit 路径的前缀（实测 `SRV_ROOT=/opt`
  或 `/` 就会），卸载 M 会把公共服务一起删掉，SB 和 X 的链接同时断。）
- SB 的 `uninstall.sh` 的 `SERVICES` 里没有它，另有一道同样的兜底闸门，
  并在影响清单里**明说**"公共基础服务不在卸载范围内"。
- 两边的防火墙回收都只按各自的 `.fw-ports` 登记表走，9443 不在任何一张表里，
  所以卸载不会关掉分享端口。

说出来这件事很重要：如果不说，用户会以为面板漏删了，转头自己去
`systemctl disable` —— 那才是真正的事故现场。

## 管理面板

`panel.sh` 是**这个服务自己的**面板，和 M/SB/X 的面板是两回事：

| | 内核面板（M/SB/X 各自的） | 本面板 |
|---|---|---|
| 看得到谁 | 只有自己 provider 的记录 | 全部 provider |
| 能删谁 | 只有自己 provider 的记录 | 任何 provider（需显式指定） |
| 服务本身 | 不碰 | 可装 / 升级 / 重启 / 卸载 |

```bash
bash panel.sh                    # 交互菜单（仅 TTY）
bash panel.sh status [--json]    # 服务状态 + 各内核计数
bash panel.sh list [--provider P] [--json]
bash panel.sh show <token> --provider P
bash panel.sh create --provider P --file F [--tag T] [--ttl H | --expires-at EPOCH] [--max-uses N]
bash panel.sh set <token> --provider P [--file F] [--enable|--disable] [--used-count N]
bash panel.sh del <token> --provider P
bash panel.sh clean [--dry-run]
bash panel.sh url <token>
bash panel.sh check | install | upgrade | start | stop | restart | logs [N]
bash panel.sh uninstall [--force] [--purge]
```

### 给调用方脚本的约定

这是 `panel.sh` 存在的主要理由 —— 它能被别的脚本直接调：

1. **非交互优先**：每个动作都有子命令，不需要喂 stdin。
2. **stdout 只放数据**，提示/告警/进度一律走 stderr。
   所以 `TOK=$(panel.sh create ...)` 拿到的一定是 token 本身。
3. **非 TTY 自动关色**（也认 `NO_COLOR`）。
4. **退出码有语义**：

   | 码 | 含义 |
   |---|---|
   | 0 | 成功 |
   | 1 | 失败 / 服务返回错误 |
   | 2 | 用法错误（参数缺失或非法） |
   | 3 | 服务不可达（没装 / 没跑 / 端口不对） |
   | 4 | 记录不存在（**或 provider 不匹配** —— 跨内核的记录在结构上就看不到） |

5. `--json` 输出机器可读结果，字段与 HTTP API 一致。
6. **端口不写死**：从 env 文件与运行时端口文件读 —— 服务可能因端口回避
   而不是 9443。

注意 `list` 不带 `--provider` 时是**管理视角**（列全部并带 provider 列）。
服务端 `/api/v1/shares` 本身是强制要求 provider 的（不给就 400），
面板是先从 `/api/v1/health` 读出有哪些 provider、再逐个查、在本地合并的。
**不要为了省事去给服务端开这个口子** —— 那个 400 正是内核之间互不可见的保证。

**端口回避**：首选端口（默认 9443）被占就自动往后找一个空闲的，并把实际
端口写进 `/etc/proxy-share-service/env`。已装过的机器**沿用 env 里的端口**，
不会每次升级都换 —— 否则所有已发出去的分享链接全废。

## API

公开（不认证 —— 这就是分享链接本身）：

```
GET  /share/<token>      200 内容 / 404 不存在 / 410 失效 / 503 暂不可用
HEAD /share/<token>      200 预检，不消耗额度
GET  /api/v1/health      健康 + API 版本 + 各 provider 计数
```

管理（`Authorization: Bearer <admin.token>`，且默认只接受回环来源）：

```
POST   /api/v1/shares               创建
GET    /api/v1/shares?provider=…    列表（必须带 provider）
GET    /api/v1/shares/<token>?provider=…   单条元数据
PUT    /api/v1/shares/<token>       更新 content / meta / enabled / ttl
DELETE /api/v1/shares/<token>?provider=…   删除（必须带 provider）
```

创建：

```json
{
  "provider": "mihomo",
  "type": "node",
  "content": "proxies:\n  - name: …",
  "content_type": "text/yaml; charset=utf-8",
  "ttl": 86400,
  "max_uses": 10,
  "meta": { "tag": "all" }
}
```

`meta` 是**不透明元数据**，公共服务只存不读。内核用它记自己的东西
（比如"这条分享对应哪个节点范围"），用于之后的内容刷新。

`token` / `expires_at` 也可以由管理侧指定 —— 前者是给**迁移**用的
（沿用旧 token，已发出去的链接才不会失效），后者是给"已经过期"的记录
用的（`ttl` 表达不了过去的时间点）。

## 关键不变量

都是踩过坑才写下来的，改动时不要动：

1. **先扣次数，再发 body** —— 客户端拿到 200 就一定拿到完整 body；
   任何失败路径（禁用 / 过期 / 用尽 / 无内容）都不消耗额度。
2. **两层互斥**：`threading.Lock`（进程内）+ `flock`（跨进程）。
   只加 flock 时同进程多线程共享 fd，flock 根本不阻塞 ——
   实测 12 个并发请求抢 1 次额度会**全部返回 200**（超发 12 倍）。
3. **HEAD 不消耗额度**（客户端预检用）。
4. **provider 隔离**：列表与删除强制带 provider；删除不匹配返回 **404**
   而不是 403 —— 不泄露"这个 token 存在但不属于你"。

## 数据

```
/var/lib/proxy-share-service/
├── .share.lock
└── shares/
    ├── mihomo/<token>.json
    ├── sing-box/<token>.json
    └── xray/<token>.json
```

一条记录一个 JSON 文件，按 provider 分目录。个人自用规模（几十条）下
比数据库更简单、可人工检查、无依赖、坏一条不影响其它。

## 文件

```
install.sh              安装 / 升级 / 卸载（含端口回避、幂等）
panel.sh                管理面板（可被其它脚本非交互调用）
src/share_service.py    服务本体（纯标准库，零第三方依赖）
client/share_client.py  参考适配器（内核侧接入用，provider 由 env 决定）
docs/INTEGRATION.md     内核侧接入说明
```

## 接入方式（内核侧）

1. 读 `/etc/proxy-share-service/env` 的 `SHARE_PORT`；
   若存在 `/run/proxy-share-service/port` 以它为准（端口回避后的实际值）。
2. 读 `/etc/proxy-share-service/admin.token` 作为 Bearer 密钥。
3. 检测不到服务就调 `install.sh`（幂等，装过就是空操作）。
4. **只写自己的 `provider`**，不要碰别的。
5. 卸载自己时**只删自己的记录**，不要动本服务。
