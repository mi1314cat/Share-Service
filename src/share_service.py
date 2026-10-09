#!/usr/bin/env python3
"""
share_service.py — 公共分享服务 (proxy-share-service)

职责边界 (硬边界, 不要越界):
    只做   : Token / TTL / max_uses / used_count / expires_at
             content 存储与读取 / 创建 / 查询 / 更新 / 删除 / 过期判断
    绝不做 : 解析 content / 认识 mihomo·sing-box·xray 的任何字段

    content 对本服务是**不可解析的字节**。provider 与 type 都只是元数据,
    只用于存储与过滤, 服务内部**不允许出现**任何按 provider 分支的逻辑。
    加第四个内核时, 本文件一行都不用改。

    "谁生成内容" 永远是内核自己的事:
        M  生成 mihomo 的节点/完整配置  → 交给本服务保存
        SB 生成 sing-box 的             → 同上
        X  生成 xray 的                 → 同上

两类资源 (行为完全一致, 只是标签不同):
    type=node    单节点 / 节点集合的分享
    type=config  整个内核的完整配置分发

路由:
    公开 (不认证, 这就是分享链接本身):
        GET  /share/<token>        200 内容 / 404 不存在 / 410 失效 / 503 暂不可用
        HEAD /share/<token>        200 预检, **不消耗额度**
        GET  /api/v1/health        健康 + 版本 + 各 provider 计数

    管理 (需 Bearer 认证, 且默认只接受回环来源):
        POST   /api/v1/shares              创建
        GET    /api/v1/shares              列表 (必须带 provider)
        GET    /api/v1/shares/<token>      单条元数据 (必须带 provider)
        PUT    /api/v1/shares/<token>      更新 content / meta
        DELETE /api/v1/shares/<token>      删除 (必须带 provider)

关键不变量 (照搬自 M 项目已验证的实现, 都是踩过坑的):
    * **先扣次数, 再发 body** —— 客户端拿到 200 就一定拿到完整 body;
      任何失败路径 (禁用/过期/用尽/无内容) 都不消耗额度。
    * 校验→扣减→保存在**双层锁**内完成:
        threading.Lock (进程内) + flock (跨进程)。
      只加 flock 时同进程多线程共享 fd, flock 根本不阻塞 —— 实测 12 个并发
      请求抢 1 次额度会全部返回 200 (超发 12 倍)。

端口回避:
    启动时若 SHARE_PORT 被占, 自动向后找一个空闲端口, 并把**实际端口**写进
    PORT_FILE, 供内核侧发现。首选端口在正常重启时不会变 (只有一个候选)。
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import hmac
import json
import os
import re
import secrets
import socket
import socketserver
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler

VERSION = "1.0.0"
API_VERSION = 1

# ---- 配置 (全部来自环境变量; 安装器写 /etc/proxy-share-service/env) ----
DATA_DIR = os.environ.get("SHARE_DATA_DIR", "/var/lib/proxy-share-service")
PORT = int(os.environ.get("SHARE_PORT", "9443"))
# 对外可达地址, 只用于拼分享 URL 给调用方看。留空则健康检查里返回相对路径。
PUBLIC_BASE = os.environ.get("SHARE_PUBLIC_BASE", "").rstrip("/")
BIND_ADDR = os.environ.get("SHARE_BIND", "::")     # 默认双栈
ADMIN_TOKEN_FILE = os.environ.get("SHARE_ADMIN_TOKEN_FILE",
                                  "/etc/proxy-share-service/admin.token")
PORT_FILE = os.environ.get("SHARE_PORT_FILE", "/run/proxy-share-service/port")
# 管理 API 是否只接受回环来源。默认开 —— 管理 API 与公开访问必须分离。
ADMIN_LOOPBACK_ONLY = os.environ.get("SHARE_ADMIN_LOOPBACK_ONLY", "1") == "1"
# 端口被占时向后找多少个
PORT_SCAN_RANGE = int(os.environ.get("SHARE_PORT_SCAN", "200"))

# ---- 自动清理 (用完 / 过期 的记录默认删除) ----
#
# 内核的分享链接大多是**一次性**的 (默认 max_uses=1)。如果不清理, 用过的、
# 过期的记录会一直躺在数据目录和内核面板的列表里 —— 实测见过 4 条全是
# "已过期/已用尽"的历史记录, 没有任何用处却占着视线。
#
# 清理判据 (与"失效"判据完全一致, 不引入第二套语义):
#   expires_at > 0 且 now > expires_at       -> 过期
#   max_uses  > 0 且 used_count >= max_uses  -> 用尽
#   enabled == false 的**不删** —— 那是用户主动禁用的, 是记录不是垃圾
#
# SHARE_CLEAN_GRACE: 失效后保留多久再删 (默认 0 = 立即)。
#   留个可调的口子是为了"想回看这条被谁用过"的场景, 默认按需求走立即删除。
AUTO_CLEAN = os.environ.get("SHARE_AUTO_CLEAN", "1") == "1"
CLEAN_INTERVAL = int(os.environ.get("SHARE_CLEAN_INTERVAL", "300"))
CLEAN_GRACE = int(os.environ.get("SHARE_CLEAN_GRACE", "0"))

TOKEN_RE = re.compile(r"^[0-9a-f]{32}$")
# provider / type 都只是标签, 但必须限制形状 —— 它们会进**文件路径**
LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$")
MAX_CONTENT = 4 * 1024 * 1024          # 4 MiB: 一份完整配置远远够用
VALID_TYPES = ("node", "config")


def log(msg: str) -> None:
    sys.stderr.write("[share-service] %s\n" % msg)
    sys.stderr.flush()


def load_admin_token() -> str:
    try:
        with open(ADMIN_TOKEN_FILE, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


# =============================================================
# 存储 —— 一条记录一个 JSON 文件, 按 provider 分目录
#
# 为什么不用 SQLite: 个人自用规模 (几十条), 文件更简单、可人工检查、
# 无依赖、坏一条不影响其它。分目录则天然完成 provider 隔离。
# =============================================================
SHARES = os.path.join(DATA_DIR, "shares")
LOCK = os.path.join(DATA_DIR, ".share.lock")
_THREAD_LOCK = threading.Lock()


@contextlib.contextmanager
def share_lock():
    os.makedirs(DATA_DIR, exist_ok=True)
    with _THREAD_LOCK:
        fd = os.open(LOCK, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)


def provider_dir(provider: str) -> str:
    return os.path.join(SHARES, provider)


def record_path(provider: str, token: str) -> str:
    return os.path.join(provider_dir(provider), token + ".json")


def load_record(provider: str, token: str):
    try:
        with open(record_path(provider, token), encoding="utf-8") as fh:
            return json.load(fh)
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def save_record(rec: dict) -> None:
    d = provider_dir(rec["provider"])
    os.makedirs(d, exist_ok=True)
    path = record_path(rec["provider"], rec["token"])
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(rec, fh, indent=1, ensure_ascii=False)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def delete_record(provider: str, token: str) -> bool:
    try:
        os.unlink(record_path(provider, token))
        return True
    except FileNotFoundError:
        return False


def iter_providers():
    try:
        for name in sorted(os.listdir(SHARES)):
            if LABEL_RE.match(name) and os.path.isdir(provider_dir(name)):
                yield name
    except FileNotFoundError:
        return


def list_records(provider: str, rtype: str = "") -> list:
    out = []
    d = provider_dir(provider)
    try:
        names = sorted(os.listdir(d))
    except FileNotFoundError:
        return out
    for n in names:
        if not n.endswith(".json"):
            continue
        try:
            with open(os.path.join(d, n), encoding="utf-8") as fh:
                rec = json.load(fh)
        except (OSError, json.JSONDecodeError):
            continue
        if rtype and rec.get("type") != rtype:
            continue
        out.append(rec)
    return out


def effective_state(rec: dict, now: int) -> str:
    """有效 / 已禁用 / 已过期 / 已用尽。只读判断, 不改记录。"""
    if not rec.get("enabled", True):
        return "disabled"
    exp = int(rec.get("expires_at", 0))
    if exp and now > exp:
        return "expired"
    mu = int(rec.get("max_uses", 0))
    if mu and int(rec.get("used_count", 0)) >= mu:
        return "used_up"
    return "active"


def public_view(rec: dict, now: int) -> dict:
    """给调用方的元数据视图 —— 不含 content (列表接口不该拖几 MB 内容)。"""
    exp = int(rec.get("expires_at", 0))
    return {
        "token": rec.get("token"),
        "provider": rec.get("provider"),
        "type": rec.get("type"),
        "meta": rec.get("meta", {}),
        "created_at": rec.get("created_at", 0),
        "expires_at": exp,
        "max_uses": int(rec.get("max_uses", 0)),
        "used_count": int(rec.get("used_count", 0)),
        "last_used_at": rec.get("last_used_at", 0),
        "enabled": rec.get("enabled", True),
        "state": effective_state(rec, now),
        "content_type": rec.get("content_type", "text/plain; charset=utf-8"),
        "content_bytes": len(rec.get("content", "").encode("utf-8")),
        # 内容哈希: 调用方用它判断"要不要 PUT", 避免无谓写盘。
        # 只暴露哈希, 不暴露内容 —— 列表接口不该拖几 MB。
        "content_sha256": hashlib.sha256(
            rec.get("content", "").encode("utf-8")).hexdigest(),
        "url_path": "/share/" + str(rec.get("token", "")),
        "url": (PUBLIC_BASE + "/share/" + str(rec.get("token", ""))) if PUBLIC_BASE else "",
    }


def cleanup_once(now: int | None = None) -> int:
    """删除**已过期 / 已用尽**的记录, 返回删除条数。

    ★ 判据与 effective_state() 完全一致 —— 不另立一套, 否则会出现
      "面板显示已过期、但清理器认为还没到"这种两处漂移。

    进程内/跨进程都走 share_lock: 清理与"扣次数"必须互斥, 否则可能把一条
    正在被消费的记录删掉 (客户端拿到 200 之后记录没了, 用户看不到使用痕迹)。
    """
    now = now or int(time.time())
    dead = []
    for provider in iter_providers():
        for rec in list_records(provider):
            # 主动禁用的不删 —— 那是用户的记录, 不是垃圾
            if not rec.get("enabled", True):
                continue
            exp = int(rec.get("expires_at", 0))
            mu = int(rec.get("max_uses", 0))
            used = int(rec.get("used_count", 0))
            # 用 >= 而不是 >: 宽限期为 0 时, "刚刚用尽"必须当场可删。
            # 用 > 的话同一秒内判定不成立, 一条用完的记录要等到下一个清理周期
            # 才消失 —— 实测就是这样漏掉了一条 (4 条里只删了 1 条)。
            if exp and now >= exp + CLEAN_GRACE:
                dead.append((provider, rec["token"], "expired"))
            elif mu and used >= mu:
                # 用尽的以**最后一次使用时间**为基准算宽限期, 不是创建时间 ——
                # 一条 30 天前创建、刚刚才被拉走的分享不该立刻消失。
                base = int(rec.get("last_used_at", 0)) or int(rec.get("created_at", 0))
                if now >= base + CLEAN_GRACE:
                    dead.append((provider, rec["token"], "used_up"))
    if not dead:
        return 0
    with share_lock():
        n = 0
        for provider, token, why in dead:
            if delete_record(provider, token):
                n += 1
                log("cleanup: 删除 %s 记录 provider=%s token=%s (%s)"
                    % (why, provider, token[:12] + "..", why))
        return n


def start_cleaner() -> None:
    """后台定时清理。AUTO_CLEAN=0 时完全不启动。"""
    if not AUTO_CLEAN:
        log("自动清理已关闭 (SHARE_AUTO_CLEAN=0)")
        return

    def loop():
        while True:
            time.sleep(max(30, CLEAN_INTERVAL))
            try:
                cleanup_once()
            except Exception as e:  # noqa: BLE001
                log("cleanup 异常: %s" % e)

    # 启动时先清一次: 上次停机期间失效的记录不该等到下个周期
    try:
        n = cleanup_once()
        if n:
            log("启动清理: 删除 %d 条已失效记录" % n)
    except Exception as e:  # noqa: BLE001
        log("启动清理异常: %s" % e)

    t = threading.Thread(target=loop, name="cleaner", daemon=True)
    t.start()
    log("自动清理已启用: 每 %ds 一次, 宽限期 %ds (用完/过期的记录会被删除)"
        % (CLEAN_INTERVAL, CLEAN_GRACE))


# =============================================================
# HTTP
# =============================================================
class Handler(BaseHTTPRequestHandler):
    server_version = "proxy-share-service/" + VERSION
    protocol_version = "HTTP/1.1"

    # ---------- 基础工具 ----------
    def log_message(self, fmt, *a):
        log("%s - %s" % (self.address_string(), fmt % a))

    def _send(self, code: int, body: bytes = b"",
              ctype: str = "text/plain; charset=utf-8", extra: dict | None = None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)

    def _json(self, code: int, obj):
        self._send(code, json.dumps(obj, ensure_ascii=False).encode("utf-8"),
                   "application/json; charset=utf-8")

    def _peer_is_loopback(self) -> bool:
        ip = self.client_address[0] if self.client_address else ""
        return ip in ("127.0.0.1", "::1") or ip.startswith("127.") \
            or ip.startswith("::ffff:127.")

    def _admin_ok(self) -> bool:
        """管理 API 的两道门: 来源必须是回环 + Bearer 必须对。"""
        if ADMIN_LOOPBACK_ONLY and not self._peer_is_loopback():
            return False
        want = load_admin_token()
        if not want:
            return False
        got = self.headers.get("Authorization", "")
        if not got.startswith("Bearer "):
            return False
        return hmac.compare_digest(got[7:].strip(), want)

    def _read_json(self):
        try:
            n = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None
        if n <= 0 or n > MAX_CONTENT + 65536:
            return None
        try:
            return json.loads(self.rfile.read(n).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return None

    def _qs(self):
        if "?" not in self.path:
            return {}
        from urllib.parse import parse_qs
        return {k: v[0] for k, v in parse_qs(self.path.split("?", 1)[1]).items()}

    # ---------- 公开: 健康 ----------
    def _health(self):
        provs = {}
        for p in iter_providers():
            recs = list_records(p)
            now = int(time.time())
            provs[p] = {
                "total": len(recs),
                "active": sum(1 for r in recs if effective_state(r, now) == "active"),
                "node": sum(1 for r in recs if r.get("type") == "node"),
                "config": sum(1 for r in recs if r.get("type") == "config"),
            }
        self._json(200, {
            "status": "ok",
            "service": "proxy-share-service",
            "version": VERSION,
            "api_version": API_VERSION,
            "port": PORT,
            "types": list(VALID_TYPES),
            "admin_configured": bool(load_admin_token()),
            "providers": provs,
        })

    # ---------- 公开: 分享访问 ----------
    def _serve_share(self, token: str):
        if not TOKEN_RE.match(token):
            return self._send(404, b"not found\n")
        with share_lock():
            rec = None
            provider = ""
            # token 全局唯一但存在 provider 子目录下 —— 需要找到它属于谁。
            # 这里不引入索引文件: 记录数量是几十级, 扫一遍足够且没有一致性负担。
            for p in iter_providers():
                rec = load_record(p, token)
                if rec is not None:
                    provider = p
                    break
            if rec is None:
                return self._send(404, b"not found\n")

            state = effective_state(rec, int(time.time()))
            if state == "disabled":
                return self._send(410, b"disabled\n")
            if state == "expired":
                return self._send(410, b"expired\n")
            if state == "used_up":
                return self._send(410, b"used up\n")

            content = rec.get("content", "")
            if not content:
                return self._send(503, b"content unavailable\n")

            if self.command == "HEAD":
                # 只做存在性预检: 不消耗额度
                return self._send(200, b"", rec.get("content_type", "text/yaml"))

            # 提交消费: 在发出响应体之前扣减 —— 拿到 200 必然拿到完整 body
            rec["used_count"] = int(rec.get("used_count", 0)) + 1
            rec["last_used_at"] = int(time.time())
            save_record(rec)

            body = content.encode("utf-8")
            return self._send(200, body,
                              rec.get("content_type", "text/yaml; charset=utf-8"))

    # ---------- 管理: 创建 ----------
    def _create(self):
        data = self._read_json()
        if not isinstance(data, dict):
            return self._json(400, {"error": "invalid json"})

        provider = str(data.get("provider", "")).strip()
        rtype = str(data.get("type", "node")).strip()
        content = data.get("content", "")

        if not LABEL_RE.match(provider):
            return self._json(400, {"error": "invalid provider"})
        if rtype not in VALID_TYPES:
            return self._json(400, {"error": "invalid type",
                                    "allowed": list(VALID_TYPES)})
        if not isinstance(content, str) or not content:
            return self._json(400, {"error": "content required"})
        if len(content.encode("utf-8")) > MAX_CONTENT:
            return self._json(413, {"error": "content too large"})

        meta = data.get("meta", {})
        if not isinstance(meta, dict):
            return self._json(400, {"error": "meta must be an object"})

        now = int(time.time())
        try:
            ttl = int(data.get("ttl", 0))
            max_uses = int(data.get("max_uses", 0))
        except (TypeError, ValueError):
            return self._json(400, {"error": "ttl/max_uses must be integers"})
        if ttl < 0 or max_uses < 0:
            return self._json(400, {"error": "ttl/max_uses must be >= 0"})

        # expires_at: 绝对到期时间, 优先于 ttl。
        #
        # ★ 这是**迁移**必需的: 内核把旧实现里的分享导进来时, 有些记录**已经
        #   过期**了 —— 用 ttl 表达不了"过去的时间点"(ttl 只能是非负数),
        #   按 `ttl = 旧expires - now` 算会得到 0, 而 0 的语义是**永久**,
        #   于是过期分享会被复活成永久链接。实测踩到。
        if data.get("expires_at") is not None:
            try:
                expires_at = int(data["expires_at"])
            except (TypeError, ValueError):
                return self._json(400, {"error": "expires_at must be an integer"})
            if expires_at < 0:
                return self._json(400, {"error": "expires_at must be >= 0"})
        else:
            expires_at = (now + ttl) if ttl else 0

        # token: 一般由服务生成。允许管理侧**指定**是为了迁移 ——
        # 内核把旧实现里的分享导入进来时必须沿用原 token, 否则已经发出去的
        # 链接会全部失效。形状与唯一性都在这里校验。
        token = str(data.get("token", "")).strip().lower()
        if token:
            if not TOKEN_RE.match(token):
                return self._json(400, {"error": "invalid token (expect 32 hex)"})
            with share_lock():
                for p_ in iter_providers():
                    if load_record(p_, token) is not None:
                        return self._json(409, {"error": "token already exists",
                                                "provider": p_})
        else:
            token = secrets.token_hex(16)

        rec = {
            "token": token,
            "provider": provider,
            "type": rtype,
            "content": content,
            "content_type": str(data.get("content_type", "text/yaml; charset=utf-8")),
            "meta": meta,
            "created_at": now,
            "expires_at": expires_at,
            "max_uses": max_uses,
            "used_count": 0,
            "enabled": True,
            "last_used_at": 0,
        }
        with share_lock():
            save_record(rec)
        log("created provider=%s type=%s token=%s ttl=%s max_uses=%s"
            % (provider, rtype, rec["token"], ttl, max_uses))
        self._json(201, public_view(rec, now))

    # ---------- 管理: 列表 ----------
    def _list(self):
        q = self._qs()
        provider = q.get("provider", "").strip()
        if not provider:
            # 不给"默认全部"的余地 —— 那样 A 内核就能看到 B 内核的分享
            return self._json(400, {"error": "provider is required"})
        if not LABEL_RE.match(provider):
            return self._json(400, {"error": "invalid provider"})
        rtype = q.get("type", "").strip()
        if rtype and rtype not in VALID_TYPES:
            return self._json(400, {"error": "invalid type"})
        now = int(time.time())
        recs = [public_view(r, now) for r in list_records(provider, rtype)]
        recs.sort(key=lambda r: r.get("created_at", 0), reverse=True)
        self._json(200, {"provider": provider, "count": len(recs), "shares": recs})

    # ---------- 管理: 单条 ----------
    def _get_one(self, token: str):
        q = self._qs()
        provider = q.get("provider", "").strip()
        if not LABEL_RE.match(provider):
            return self._json(400, {"error": "provider is required"})
        with share_lock():
            rec = load_record(provider, token)
        if rec is None:
            return self._json(404, {"error": "not found"})
        self._json(200, public_view(rec, int(time.time())))

    # ---------- 管理: 更新 ----------
    def _update(self, token: str):
        data = self._read_json()
        if not isinstance(data, dict):
            return self._json(400, {"error": "invalid json"})
        q = self._qs()
        provider = str(data.get("provider", q.get("provider", ""))).strip()
        if not LABEL_RE.match(provider):
            return self._json(400, {"error": "provider is required"})
        with share_lock():
            rec = load_record(provider, token)
            if rec is None:
                return self._json(404, {"error": "not found"})
            if "content" in data:
                c = data["content"]
                if not isinstance(c, str) or not c:
                    return self._json(400, {"error": "invalid content"})
                if len(c.encode("utf-8")) > MAX_CONTENT:
                    return self._json(413, {"error": "content too large"})
                rec["content"] = c
            if "content_type" in data:
                rec["content_type"] = str(data["content_type"])
            if "meta" in data and isinstance(data["meta"], dict):
                rec["meta"] = data["meta"]
            if "enabled" in data:
                rec["enabled"] = bool(data["enabled"])
            if "max_uses" in data:
                rec["max_uses"] = max(0, int(data["max_uses"]))
            # 使用次数也允许管理侧直接设定 —— "重新生成 Token" 时用它把计数
            # 带过去, 保持与旧实现 (改文件名保留计数) 一致的用户可见行为。
            if "used_count" in data:
                rec["used_count"] = max(0, int(data["used_count"]))
            if "ttl" in data:
                ttl = max(0, int(data["ttl"]))
                rec["expires_at"] = (int(time.time()) + ttl) if ttl else 0
            save_record(rec)
        self._json(200, public_view(rec, int(time.time())))

    # ---------- 管理: 删除 ----------
    def _delete(self, token: str):
        q = self._qs()
        provider = q.get("provider", "").strip()
        if not LABEL_RE.match(provider):
            return self._json(400, {"error": "provider is required"})
        with share_lock():
            ok = delete_record(provider, token)
        if not ok:
            return self._json(404, {"error": "not found"})
        log("deleted provider=%s token=%s" % (provider, token))
        self._json(200, {"deleted": token, "provider": provider})

    # ---------- 路由 ----------
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/v1/health":
            return self._health()
        if path == "/api/v1/shares":
            if not self._admin_ok():
                return self._json(401, {"error": "unauthorized"})
            return self._list()
        m = re.match(r"^/api/v1/shares/([^/]+)$", path)
        if m:
            if not self._admin_ok():
                return self._json(401, {"error": "unauthorized"})
            return self._get_one(m.group(1))
        if path.startswith("/share/"):
            return self._serve_share(path[len("/share/"):])
        return self._send(404, b"not found\n")

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/api/v1/shares":
            return self._send(404, b"not found\n")
        if not self._admin_ok():
            return self._json(401, {"error": "unauthorized"})
        return self._create()

    def do_PUT(self):
        m = re.match(r"^/api/v1/shares/([^/]+)$", self.path.split("?", 1)[0])
        if not m:
            return self._send(404, b"not found\n")
        if not self._admin_ok():
            return self._json(401, {"error": "unauthorized"})
        return self._update(m.group(1))

    def do_DELETE(self):
        m = re.match(r"^/api/v1/shares/([^/]+)$", self.path.split("?", 1)[0])
        if not m:
            return self._send(404, b"not found\n")
        if not self._admin_ok():
            return self._json(401, {"error": "unauthorized"})
        return self._delete(m.group(1))


# =============================================================
# 监听 —— 含端口回避
# =============================================================
class Srv6(socketserver.ThreadingTCPServer):
    address_family = socket.AF_INET6
    allow_reuse_address = True
    daemon_threads = True

    def server_bind(self):
        try:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except OSError:
            pass
        super().server_bind()


class Srv4(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def try_bind(port: int):
    """尝试绑定。返回 (server, family) 或 (None, None)。"""
    for cls, addr in ((Srv6, "::"), (Srv4, "0.0.0.0")):
        if BIND_ADDR not in ("::", "0.0.0.0") and addr != BIND_ADDR:
            continue
        try:
            return cls((addr, port), Handler), cls.address_family
        except OSError:
            continue
    return None, None


def write_port_file(port: int) -> None:
    try:
        os.makedirs(os.path.dirname(PORT_FILE), exist_ok=True)
        with open(PORT_FILE, "w", encoding="utf-8") as fh:
            fh.write(str(port))
    except OSError as e:
        log("写端口文件失败 %s: %s" % (PORT_FILE, e))


def main() -> int:
    global PORT
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--data-dir", default=DATA_DIR)
    ap.add_argument("--print-port", action="store_true",
                    help="只做端口探测并打印可用端口, 不启动服务")
    ap.add_argument("--cleanup", action="store_true",
                    help="只清理一次 (过期/用尽的记录) 然后退出")
    args = ap.parse_args()

    if args.cleanup:
        n = cleanup_once()
        print(n)
        return 0

    if args.print_port:
        srv, _ = try_bind(args.port)
        if srv:
            srv.server_close()
            print(args.port)
            return 0
        for p in range(args.port + 1, args.port + PORT_SCAN_RANGE + 1):
            srv, _ = try_bind(p)
            if srv:
                srv.server_close()
                print(p)
                return 0
        sys.stderr.write("端口区间内无可用端口\n")
        return 1

    PORT = args.port
    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(SHARES, exist_ok=True)
    open(LOCK, "a").close()

    srv, fam = try_bind(PORT)
    if srv is None:
        # ★ 端口回避: 首选端口被占时向后找一个空闲的。
        #   找**连续**的空闲端口而不是随机, 这样日志里能给出可预期的范围;
        #   实际端口写进 PORT_FILE, 内核侧据此发现, 不必靠猜。
        log("首选端口 %d 被占用, 开始端口回避" % PORT)
        for p in range(PORT + 1, PORT + PORT_SCAN_RANGE + 1):
            srv, fam = try_bind(p)
            if srv:
                log("端口回避: %d -> %d" % (PORT, p))
                PORT = p
                break
    if srv is None:
        log("端口 %d 起的 %d 个端口全部不可用" % (PORT, PORT_SCAN_RANGE))
        return 1

    write_port_file(PORT)
    start_cleaner()
    log("已启动 端口 %d (%s)  数据目录 %s" %
        (PORT, "双栈 IPv4+IPv6" if fam == socket.AF_INET6 else "仅 IPv4", DATA_DIR))
    if not load_admin_token():
        log("警告: 未配置管理密钥 (%s) —— 管理 API 将拒绝一切请求"
            % ADMIN_TOKEN_FILE)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
