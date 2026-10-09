# 接入指南 — 别的脚本怎么调用这个服务


> 运维侧说明：本服务自带管理面板 `panel.sh`（仓库根目录），可被其它脚本
> 非交互调用（stdout 只放数据、退出码有语义、`--json` 可选）。
> 内核面板只该管自己 provider 的记录；跨 provider 的运维操作走 `panel.sh`。
> 详见 README 的「管理面板」一节。


给**内核项目**（mihomo / sing-box / xray / 以后的第四个）的开发者看。
所有调用都从 GitHub 走，不需要本地有本仓库的副本。

---

## 一、30 秒版

```bash
# 1) 确保服务在位（幂等；已装就是空操作，不会重复安装/占端口/覆盖数据）
curl -fsSL https://raw.githubusercontent.com/mi1314cat/Share-Service/main/install.sh | bash

# 2) 读接入参数
PORT=$(sed -n 's/^SHARE_PORT=//p' /etc/proxy-share-service/env)
TOKEN=$(cat /etc/proxy-share-service/admin.token)

# 3) 创建一条分享
curl -fsS -X POST "http://127.0.0.1:$PORT/api/v1/shares" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"provider":"sing-box","type":"config","content":"...","ttl":86400,"max_uses":5}'
```

返回：

```json
{"token":"…32hex…","url":"http://host:9443/share/…","provider":"sing-box",
 "created_at":…,"expires_at":…,"max_uses":5,"used_count":0,"state":"active"}
```

客户端以后访问 `GET /share/<token>` 就能拿到你放进去的 `content`。

---

## 二、五条接入规则

**1. 只写自己的 `provider`。**
列表与删除接口**强制**要求带 `provider`，所以你在结构上不可能看到或误删
别人的分享。`provider` 只是一个标签，服务内部没有任何按它分支的逻辑。

**2. `content` 必须是**你自己**生成好的。**
服务不生成、不解析、不理解它的内容 —— 它只是一个字节容器。
放在 `content` 里的是 YAML 还是 JSON、有没有 `proxies:`，服务完全不管。

**3. 卸载自己时只删自己的记录。**

```bash
curl -fsS -X DELETE -H "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:$PORT/api/v1/shares/$tok?provider=sing-box"
```

**绝不**去 `systemctl disable` / 删 `/etc/systemd/system/proxy-share-service.service`
—— 别的内核可能还在用。彻底卸载只有 `install.sh uninstall` 能做。

**4. 不要写死端口。**
它可能因为**端口回避**而不是 9443。按这个顺序读：

```bash
PORT=$(cat /run/proxy-share-service/port 2>/dev/null)      # 实际绑定值，优先
[ -n "$PORT" ] || PORT=$(sed -n 's/^SHARE_PORT=//p' /etc/proxy-share-service/env)
[ -n "$PORT" ] || PORT=9443                                 # 兜底
```

**5. 装不上不要让你的安装失败。**
分享不是内核的核心功能。检查/安装失败只提示，用户之后还能重试。

---

## 三、检查 → 不存在才装 → 启动

内核安装器里照抄这一段（等价于 `install.sh` 的幂等逻辑，但**不下载整个安装器**
就能先探测）：

```bash
PSS_ENV=/etc/proxy-share-service/env
PORT=$(sed -n 's/^SHARE_PORT=//p' "$PSS_ENV" 2>/dev/null)
[ -n "$PORT" ] || PORT=9443

if curl -fsS --max-time 4 "http://127.0.0.1:$PORT/api/v1/health" >/dev/null 2>&1; then
    echo "公共分享服务已在位，直接复用（端口 $PORT）"
else
    echo "公共分享服务不在，正在安装..."
    curl -fsSL https://raw.githubusercontent.com/mi1314cat/Share-Service/main/install.sh | bash \
      || echo "安装失败（不影响内核使用，之后可在面板重试）"
fi
```

`install.sh` 的行为：

| 情况 | 动作 |
|---|---|
| 已装且健康 | **什么都不做**（不重装、不改端口、不碰数据） |
| 已装但不健康 | 修复（端口与数据保持不变） |
| 没装 | 端口回避后安装 → 生成管理密钥 → 写 systemd unit → 启动 → 健康检查 |

---

## 四、参考适配层

`client/share_client.py` 是现成的接入层，**纯标准库、零依赖**。
直接抄进你的项目，改一个环境变量就能用：

```bash
export SHARE_PROVIDER=sing-box
python3 share_client.py ensure                          # 打印端口
python3 share_client.py create --type config --content-file /tmp/sb.json \
        --ttl 86400 --max-uses 5 --meta '{"tag":"full"}'
python3 share_client.py list      --type config          # JSON 数组
python3 share_client.py get       --token <t>
python3 share_client.py update    --token <t> --content-file /tmp/sb-new.json
python3 share_client.py update    --token <t> --enabled false
python3 share_client.py delete    --token <t>
python3 share_client.py health
```

同样的能力也可以直接用 curl，接口就是下面那张表。

---

## 五、API 全表

### 公开（不认证 —— 这就是分享链接本身）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/share/<token>` | 200 内容 / 404 不存在 / 410 失效（禁用·过期·用尽）/ 503 暂不可用 |
| HEAD | `/share/<token>` | 200 预检，**不消耗额度** |
| GET | `/api/v1/health` | 健康 + `api_version` + 各 provider 计数 |

### 管理（`Authorization: Bearer <admin.token>`，默认只接受回环来源）

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/v1/shares` | 创建 |
| GET | `/api/v1/shares?provider=…[&type=…]` | 列表（**必须带 provider**）|
| GET | `/api/v1/shares/<token>?provider=…` | 单条元数据（不含 content，带 `content_sha256`）|
| PUT | `/api/v1/shares/<token>` | 更新 `content` / `meta` / `enabled` / `ttl` |
| DELETE | `/api/v1/shares/<token>?provider=…` | 删除 |

创建请求体：

```json
{
  "provider": "sing-box",
  "type": "config",
  "content": "{\"outbounds\":[…]}\n",
  "content_type": "application/json; charset=utf-8",
  "ttl": 86400,
  "max_uses": 5,
  "meta": { "tag": "full" }
}
```

字段：

| 字段 | 必填 | 说明 |
|---|---|---|
| `provider` | ✅ | 你的标识（字母数字 `._-`，≤32 字符）。进**文件路径**，所以有形状校验 |
| `type` | | `node` \| `config`，默认 `node`。纯标签，服务侧行为一致 |
| `content` | ✅ | 你自己生成的内容，≤4 MiB。服务不解析 |
| `content_type` | | 返回时的 Content-Type，默认 `text/yaml; charset=utf-8` |
| `ttl` | | 秒；`0` = 永久 |
| `max_uses` | | `0` = 不限 |
| `meta` | | **不透明**元数据，只存不读。内核用它记自己的东西（比如"这条对应哪些节点"）|
| `token` | | 一般不用。**迁移**时用来沿用旧 token |
| `expires_at` | | 绝对到期时间，优先于 `ttl`。用来表达"已经过期"（`ttl` 表达不了过去）|

---

## 六、内容保鲜（"活链接"）

服务的 `content` 是**创建时写入的快照**。想让已发出去的链接跟着你的节点变化走，
自己刷新 —— token / URL / TTL / 使用次数**都不会变**：

```bash
# 只有内容真的变了才写：先比 content_sha256
NEW=$(sha256sum /tmp/new-content | awk '{print $1}')
CUR=$(curl -fsS -H "Authorization: Bearer $TOKEN" \
      "http://127.0.0.1:$PORT/api/v1/shares/$tok?provider=sing-box" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["content_sha256"])')
[ "$NEW" = "$CUR" ] || curl -fsS -X PUT "http://127.0.0.1:$PORT/api/v1/shares/$tok" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "{\"provider\":\"sing-box\",\"content\":$(python3 -c 'import json,sys;print(json.dumps(open(sys.argv[1]).read()))' /tmp/new-content)}"
```

**什么时候刷**：节点变了之后。建议挂在"生成节点完成"和"打开分享面板"两个点上 ——
两处都是幂等的，内容没变就是一次 GET，不写盘。

---

## 七、自动清理

**用完的（`used_count >= max_uses`）和过期的记录会被自动删除**，默认开启：

| 变量 | 默认 | 说明 |
|---|---|---|
| `SHARE_AUTO_CLEAN` | `1` | 关掉设 `0` |
| `SHARE_CLEAN_INTERVAL` | `300` | 秒，后台清理周期 |
| `SHARE_CLEAN_GRACE` | `0` | 失效后保留多久再删 |

所以在服务启动时与每 5 分钟各清一次。**已被你主动禁用的记录不会被删**
（那是你的记录，不是垃圾）。手动清一次：`share_service.py --cleanup`。

> 副作用要知道：一条分享被用尽后，客户端**下一次**访问会拿到 404 而不是 410
> （记录已经不存在了）。两者都是"拉不到"，功能上等价。

---

## 八、安全边界（你不需要额外做什么，但要知道）

| 项 | 做法 |
|---|---|
| 管理 API | Bearer 密钥 + **默认只接受回环来源**。密钥文件 0600 |
| 公开访问 | `/share/` 不认证，但 token 是 128 位随机（`secrets.token_hex(16)`）|
| 枚举 | 失败一律 404，不区分"不存在"与"不属于你" |
| 并发超发 | 先扣次数再发 body；`threading.Lock` + `flock` 双层互斥 |
| 路径穿越 | token 形状校验（`^[0-9a-f]{32}$`）后才拼路径 |
| provider 隔离 | 列表/删除强制带 provider，存储按 provider 分目录 |

管理 API 绑回环意味着**内核与服务必须在同一台机器上**。跨机部署需要
把 `SHARE_ADMIN_LOOPBACK_ONLY` 设为 `0`，并自己保证那个端口不对外 ——
默认值是有意选的：个人自用场景下"同机"是最简单也最安全的假设。

---

## 九、故障排查

```bash
bash install.sh --check                     # 状态 / 端口 / 健康 / 各内核计数
journalctl -u proxy-share-service -n 50     # 日志（清理动作也会记在这里）
```

| 症状 | 原因 |
|---|---|
| `curl /share/<token>` 返回 404 | token 写错、已被自动清理、或记录不存在 |
| 返回 410 | 禁用 / 过期 / 用尽（清理周期还没轮到它）|
| 管理 API 返回 401 | 密钥不对，或**请求不是从回环发来的** |
| 管理 API 返回 400 `provider is required` | 忘了带 `provider` —— 这是有意的，不给"默认全部"的余地 |
| 端口不是 9443 | 端口回避了。读 `/run/proxy-share-service/port` |
| 内核面板看不到分享 | `provider` 传错了（每个内核只能看到自己的）|
