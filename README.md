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

## 安装

```bash
bash install.sh              # 安装或升级（幂等）
bash install.sh --check      # 只看状态
bash install.sh uninstall    # 卸载（数据默认保留）
bash install.sh uninstall --purge   # 连数据一起删
```

**幂等**：已装过就只做检查，不重装、不改端口、不碰数据。
所以第一个装的内核（比如 M）把它装好之后，后装的 SB/X 会直接复用它。

**内核不拥有它**：卸载内核**不会**删除本服务 —— 内核卸载时无法知道
SB/X 还在不在用，任何"猜"都会删掉别人的东西。只有 `install.sh uninstall`
能卸载它。

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
src/share_service.py    服务本体（纯标准库，零第三方依赖）
```

## 接入方式（内核侧）

1. 读 `/etc/proxy-share-service/env` 的 `SHARE_PORT`；
   若存在 `/run/proxy-share-service/port` 以它为准（端口回避后的实际值）。
2. 读 `/etc/proxy-share-service/admin.token` 作为 Bearer 密钥。
3. 检测不到服务就调 `install.sh`（幂等，装过就是空操作）。
4. **只写自己的 `provider`**，不要碰别的。
5. 卸载自己时**只删自己的记录**，不要动本服务。
