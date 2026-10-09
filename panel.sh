#!/usr/bin/env bash
# =============================================================
# proxy-share-service · 管理面板
#
# 这是**公共基础服务自己的**面板 —— 与 M / SB / X 的面板是两回事:
#   内核面板 : 只管自己 provider 的记录 (跨 provider 看不到也删不掉)
#   本面板   : 管整个服务 (能看到全部 provider, 能装/卸/重启服务本身)
#
# ---------------------------------------------------------------
# 给调用方脚本的约定 (这是本文件存在的主要理由)
#
#   1. **非交互优先**: 每个动作都有子命令, 不需要喂 stdin。
#   2. **stdout 只放数据**, 提示/告警/进度一律走 stderr。
#      所以 `TOK=$(panel.sh create ...)` 拿到的一定是 token 本身。
#   3. **非 TTY 自动关色** (也认 NO_COLOR)。
#   4. **退出码有语义**, 调用方可以直接判断:
#         0  成功
#         1  失败 / 服务返回错误
#         2  用法错误 (参数缺失或非法)
#         3  服务不可达 (没装 / 没跑 / 端口不对)
#         4  记录不存在 (或 provider 不匹配)
#   5. `--json` 输出机器可读结果, 字段与 HTTP API 一致。
#   6. 端口不写死: 从 env 文件与运行时端口文件读 —— 服务可能因
#      **端口回避**而不是 9443。
#
# ---------------------------------------------------------------
# 用法:
#   bash panel.sh                      # 交互菜单 (仅 TTY)
#   bash panel.sh status [--json]
#   bash panel.sh health
#   bash panel.sh port
#   bash panel.sh info
#   bash panel.sh providers [--json]
#   bash panel.sh list [--provider P] [--json]
#   bash panel.sh show <token> --provider P [--json]
#   bash panel.sh url <token>
#   bash panel.sh create --provider P --file F [--type node|config]
#                        [--tag T] [--ttl H | --expires-at EPOCH]
#                        [--max-uses N] [--token TOK]
#   bash panel.sh set <token> --provider P [--file F]
#                        [--enable|--disable] [--used-count N]
#                        [--max-uses N] [--ttl H | --expires-at EPOCH]
#   bash panel.sh del <token> --provider P
#
#   bash panel.sh file <文件路径> [--provider file] [--ttl H] [--max-uses N]
#                        [--name 显示名] [--content-type T] [--binary]
#        —— 给一个路径, stdout 直接给分享 URL。文本按 utf-8 存 (浏览器可读),
#           二进制自动走 base64。默认 provider=file (不属于任何内核)。
#   bash panel.sh fetch <token> [--out 路径]
#        —— 把分享内容取回来; 不给 --out 就写 stdout。**走公开端点, 会消耗一次额度**。
#   bash panel.sh clean [--dry-run]
#   bash panel.sh check | install | upgrade | start | stop | restart | logs [N]
#   bash panel.sh uninstall [--force] [--purge]
#
# 环境变量:
#   PSS_PORT=<端口>   服务未安装时的兜底端口 (默认 9443)
#   NO_COLOR=1        关色
# =============================================================
set -uo pipefail

SERVICE=proxy-share-service
ETC=/etc/$SERVICE
ENV_FILE=$ETC/env
TOKEN_FILE=$ETC/admin.token
DATA_DIR=/var/lib/$SERVICE
INSTALL_DIR=/opt/$SERVICE
UNIT=/etc/systemd/system/$SERVICE.service
PORT_FILE=/run/$SERVICE/port
FALLBACK_PORT="${PSS_PORT:-9443}"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# ★ HTTP 状态码的传递通道。必须**在顶层**创建:
#   api() 是 `out=$(api ...)` 调用的, 跑在子 shell 里 —— 在里面创建的临时
#   文件或赋的变量都传不回父 shell, 于是状态码读回来永远是空
#   (表现: list 该出数据却报 "服务返回 HTTP ")。文件在顶层建好, 子 shell
#   往里写, 父 shell 读得到。
API_TMP="$(mktemp /tmp/.pss-api.XXXXXX 2>/dev/null || echo /tmp/.pss-api.$$)"
trap 'rm -f "$API_TMP"' EXIT

# ---------------------------------------------------------------- 输出
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_DIM=$'\033[90m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'
    C_ERR=$'\033[31m'; C_T=$'\033[95m\033[1m'; C_R=$'\033[0m'
else
    C_DIM=""; C_OK=""; C_WARN=""; C_ERR=""; C_T=""; C_R=""
fi
# 全部走 stderr —— stdout 是数据通道, 不能混进提示
msg()  { printf '%s\n' "$*" >&2; }
ok()   { printf '%s  ✓ %s%s\n' "$C_OK" "$*" "$C_R" >&2; }
warn() { printf '%s  ! %s%s\n' "$C_WARN" "$*" "$C_R" >&2; }
err()  { printf '%s  ✗ %s%s\n' "$C_ERR" "$*" "$C_R" >&2; }
title(){ printf '\n%s%s%s\n' "$C_T" "$*" "$C_R" >&2; }

die_usage() { err "$*"; exit 2; }
die_down()  { err "$*"; exit 3; }
die_miss()  { err "$*"; exit 4; }

need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die_usage "需要 root"; }

# ---------------------------------------------------------------- 端口 / 密钥
# 端口可能因端口回避而不是 9443: env 文件记的是配置值, 运行时端口文件记的是
# **实际绑定值** (服务启动时若发现端口被占会自己再回避一次)。以运行时为准。
svc_port() {
    local p=""
    [[ -f "$PORT_FILE" ]] && p=$(head -1 "$PORT_FILE" 2>/dev/null)
    if [[ -z "$p" && -f "$ENV_FILE" ]]; then
        p=$(sed -n 's/^SHARE_PORT=//p' "$ENV_FILE" | head -1)
    fi
    printf '%s' "${p:-$FALLBACK_PORT}"
}

svc_token() {
    local f="$TOKEN_FILE"
    [[ -f "$ENV_FILE" ]] && {
        local t; t=$(sed -n 's/^SHARE_ADMIN_TOKEN_FILE=//p' "$ENV_FILE" | head -1)
        [[ -n "$t" ]] && f="$t"
    }
    [[ -r "$f" ]] && { head -c 4096 "$f" | tr -d '\r\n'; return 0; }
    return 1
}

svc_active() { systemctl is-active --quiet "$SERVICE" 2>/dev/null; }
svc_installed() { [[ -f "$UNIT" ]]; }

# ---------------------------------------------------------------- HTTP
# ★ HTTP 状态码走**临时文件**传回来, 不用全局变量。
#   原因: `out=$(api ...)` 是命令替换, api 跑在子 shell 里 —— 在里面给
#   API_CODE 赋值, 父 shell 根本看不到, 于是所有状态码判断都拿到空串
#   (表现为 list 明明该出数据却报 "服务返回 HTTP ")。文件不受子 shell 影响。
api_code() { cat "$API_TMP" 2>/dev/null; }

_api_exec() { # _api_exec <path> <curl 参数...>  -> stdout 只放响应体
    local path="$1"; shift
    local out; out=$(curl "$@" -w $'\n%{http_code}' "http://127.0.0.1:$(svc_port)$path" 2>/dev/null) \
        || die_down "连不上服务 (127.0.0.1:$(svc_port)) —— 装了没跑? 端口对不对?"
    local code="${out##*$'\n'}"
    out="${out%$'\n'*}"
    printf '%s' "$code" > "$API_TMP"
    if [[ "$code" =~ ^4|^5 ]]; then
        local e; e=$(printf '%s' "$out" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("error",""))
except Exception: print("")' 2>/dev/null)
        [[ -n "$e" ]] && err "服务返回 $code: $e"
    fi
    printf '%s' "$out"
}

api() { # api <METHOD> <path> [json-body]  —— 小 body 走命令行
    local m="$1" path="$2" body="${3:-}" tok
    tok=$(svc_token) || die_down "读不到管理密钥 ($TOKEN_FILE)"
    local -a args=(-s --max-time 15 -X "$m" -H "Authorization: Bearer $tok")
    [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' --data-binary "$body")
    _api_exec "$path" "${args[@]}"
}

# 大 body (文件分享的 base64 可以到十几 MB) **必须**走文件。
# 塞进 argv 会撞 ARG_MAX —— 报错还是 "Argument list too long" 这种
# 跟业务毫无关系的错, 很难往这儿想。
api_f() { # api_f <METHOD> <path> <body-file>
    local m="$1" path="$2" bf="$3" tok
    tok=$(svc_token) || die_down "读不到管理密钥 ($TOKEN_FILE)"
    _api_exec "$path" -s --max-time 300 -X "$m" -H "Authorization: Bearer $tok" \
        -H 'Content-Type: application/json' --data-binary "@$bf"
}

api_or_die() { # 4xx/5xx 直接按语义退出 (返回码由调用方透传)
    local out; out=$(api "$@")
    local code; code=$(api_code)
    case "$code" in
        2*) printf '%s' "$out"; return 0 ;;
        404) die_miss "记录不存在 (或 provider 不匹配 —— 跨内核的记录在结构上就看不到)" ;;
        *)   err "服务返回 HTTP ${code:-?}"; exit 1 ;;
    esac
}

# ★ 必须这样调用: `out=$(api_or_die ...) || exit $?`
#   api_or_die 跑在命令替换的子 shell 里, 它的 exit 4 只结束子 shell ——
#   父 shell 看到的是"子 shell 非 0 退出"即 1。不加这行, 所有区分好的
#   退出码 (尤其 4=记录不存在) 都会被压成 1, 调用方就判断不出"是没找到"
#   还是"服务挂了"。

health_ok() { curl -s --max-time 5 "http://127.0.0.1:$(svc_port)/api/v1/health" 2>/dev/null | grep -q '"status"'; }

jq_py() { python3 -c "$1" 2>/dev/null; }

# ---------------------------------------------------------------- 参数解析
# 极简解析: 子命令 + 具名选项。不做组合短选项 —— 调用方是脚本, 可读性优先。
PROVIDER=""; FILE=""; TYPE="node"; TAG=""; TTL=""; MAXUSES=""; TOK=""; EXPIRES=""; WANT_JSON=0
NAME=""; CTYPE=""; OUT=""; BINARY=0
ENABLED=""; USEDCOUNT=""; N=""; DRYRUN=0; FORCE=0; PURGE=0; POS=()

parse_args() {
    while (( $# )); do
        case "$1" in
            --provider) PROVIDER="${2:-}"; shift 2 ;;
            --file)     FILE="${2:-}"; shift 2 ;;
            --type)     TYPE="${2:-}"; shift 2 ;;
            --tag)      TAG="${2:-}"; shift 2 ;;
            --ttl)      TTL="${2:-}"; shift 2 ;;
            --expires-at) EXPIRES="${2:-}"; shift 2 ;;
            --name)     NAME="${2:-}"; shift 2 ;;
            --content-type) CTYPE="${2:-}"; shift 2 ;;
            --out)      OUT="${2:-}"; shift 2 ;;
            --binary)   BINARY=1; shift ;;
            --max-uses) MAXUSES="${2:-}"; shift 2 ;;
            --token)    TOK="${2:-}"; shift 2 ;;
            --used-count) USEDCOUNT="${2:-}"; shift 2 ;;
            --enable)   ENABLED=true; shift ;;
            --disable)  ENABLED=false; shift ;;
            --json)     WANT_JSON=1; shift ;;
            --dry-run)  DRYRUN=1; shift ;;
            --force)    FORCE=1; shift ;;
            --purge)    PURGE=1; shift ;;
            -h|--help)  usage; exit 0 ;;
            -*)         die_usage "未知选项: $1" ;;
            *)          POS+=("$1"); shift ;;
        esac
    done
}

# provider 是本服务的**隔离边界**: 记录级操作必须显式给出,
# 不给就可能误伤别的内核的记录。服务端也是这么强制的 (不给 -> 400)。
# provider 名规则**必须**与服务端 LABEL_RE 一致 —— 面板早一步拦下, 调用方
# 拿到的是用法错误 (2); 不一致的话会漏到服务端换回一个 HTTP 400 (1),
# 调用方就分不清"我参数写错了"和"服务出问题了"。两处规则不一致时这里就是坑。
_provider_ok() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]]; }

need_provider() { # 记录级操作: 必须给
    [[ -n "$PROVIDER" ]] || die_usage "缺少 --provider (记录级操作必须指明属于哪个内核)"
    _provider_ok "$PROVIDER" \
        || die_usage "provider 非法: $PROVIDER (需字母/数字开头, 只含字母数字._-, 最长 32)"
}

opt_provider() { # 查询类操作: 给了就校验, 不给也行
    [[ -z "$PROVIDER" ]] || _provider_ok "$PROVIDER" \
        || die_usage "provider 非法: $PROVIDER (需字母/数字开头, 只含字母数字._-, 最长 32)"
}

usage() {
    sed -n '2,60p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------- 子命令
cmd_health() {
    if health_ok; then echo "ok"; return 0; fi
    echo "down"; return 1
}

cmd_port() { svc_port; echo; }

cmd_status() {
    local p; p=$(svc_port)
    local installed=0 active=0 h=""
    svc_installed && installed=1
    svc_active && active=1
    health_ok && h=$(api GET /api/v1/health)

    if (( WANT_JSON )); then
        python3 - "$installed" "$active" "$p" "${h:-}" <<'PY'
import json, sys
installed, active, port, h = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = {}
if h:
    try: d = json.loads(h)
    except Exception: d = {}
d.update({"installed": installed == "1", "active": active == "1", "port": int(port)})
print(json.dumps(d, ensure_ascii=False))
PY
        return 0
    fi
    printf '服务      : %s\n' "$SERVICE"
    printf '安装      : %s\n' "$( ((installed)) && echo "是 ($UNIT)" || echo "否" )"
    printf '运行      : %s\n' "$( ((active)) && echo "是" || echo "否" )"
    printf '端口      : %s\n' "$p"
    if [[ -n "$h" ]]; then
        printf '%s' "$h" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print("版本      : %s (api v%s)" % (d.get("version","?"), d.get("api_version","?")))
ps = d.get("providers", {})
print("内核分享  : %s" % (", ".join("%s=%d" % (k, v["total"]) for k, v in ps.items()) or "（无）"))
' 2>/dev/null
    else
        printf '健康检查  : 未通过\n'
    fi
}

cmd_info() {
    printf '服务      : %s\n' "$SERVICE"
    printf '单元      : %s%s\n' "$UNIT" "$( [[ -f "$UNIT" ]] || echo ' (不存在)' )"
    printf '配置      : %s%s\n' "$ENV_FILE" "$( [[ -f "$ENV_FILE" ]] || echo ' (不存在)' )"
    printf '数据      : %s\n' "$DATA_DIR"
    printf '代码      : %s/share_service.py\n' "$INSTALL_DIR"
    printf '端口文件  : %s\n' "$PORT_FILE"
    printf '实际端口  : %s\n' "$(svc_port)"
    if [[ -r "$TOKEN_FILE" ]]; then
        printf '管理密钥  : %s (存在, 权限 %s)\n' "$TOKEN_FILE" "$(stat -c '%a' "$TOKEN_FILE" 2>/dev/null)"
    else
        printf '管理密钥  : 缺失\n'
    fi
    [[ -f "$ENV_FILE" ]] && { echo "--- env ---"; sed 's/^/  /' "$ENV_FILE"; }
}

cmd_providers() {
    local h; health_ok || die_down "服务不可达 (端口 $(svc_port))"
    h=$(api GET /api/v1/health)
    if (( WANT_JSON )); then
        printf '%s' "$h" | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin).get("providers",{}),ensure_ascii=False))'
        return 0
    fi
    printf '%-14s %6s %6s %6s %6s\n' "PROVIDER" "总数" "活跃" "node" "config"
    printf '%s' "$h" | python3 -c '
import sys, json
ps = json.load(sys.stdin).get("providers", {})
if not ps: print("  （还没有任何内核登记过分享）")
for k, v in sorted(ps.items()):
    print("%-14s %6d %6d %6d %6d" % (k, v["total"], v.get("active", 0), v.get("node", 0), v.get("config", 0)))
'
}

# list 是**管理视角**: 不指定 provider 就列全部。
#
# ★ 服务端的 /api/v1/shares **强制**要求 provider (这是隔离边界, 不给就 400),
#   所以"列全部"不能在服务端一次拿到 —— 得先从 health 读出有哪些 provider,
#   再逐个查、在面板这边合并。别为了省事去给服务端开口子: 那个 400 正是
#   内核之间互不可见的保证。
cmd_list() {
    opt_provider
    health_ok || die_down "服务不可达 (端口 $(svc_port))"

    local merged="[]" p out code
    if [[ -n "$PROVIDER" ]]; then
        out=$(api GET "/api/v1/shares?provider=$PROVIDER")
        code=$(api_code)
        [[ "$code" == "400" ]] && die_usage "服务要求 provider 参数"
        [[ "$code" != 2* ]] && { err "服务返回 HTTP ${code:-?}"; exit 1; }
        merged=$(printf '%s' "$out" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(json.dumps(d.get("shares",d) if isinstance(d,dict) else d,ensure_ascii=False))')
    else
        local h provs
        h=$(api GET /api/v1/health)
        provs=$(printf '%s' "$h" | python3 -c 'import sys,json;print(" ".join(sorted(json.load(sys.stdin).get("providers",{}).keys())))' 2>/dev/null)
        if [[ -z "$provs" ]]; then
            (( WANT_JSON )) && { echo "[]"; return 0; }
            echo "（还没有任何内核登记过分享）"; return 0
        fi
        for p in $provs; do
            out=$(api GET "/api/v1/shares?provider=$p")
            code=$(api_code)
            [[ "$code" == 2* ]] || continue
            merged=$(python3 - "$merged" "$out" <<'MERGEPY'
import sys, json
acc = json.loads(sys.argv[1])
d = json.loads(sys.argv[2])
acc.extend(d.get("shares", d) if isinstance(d, dict) else d)
print(json.dumps(acc, ensure_ascii=False))
MERGEPY
)
        done
    fi

    if (( WANT_JSON )); then printf '%s\n' "$merged"; return 0; fi
    printf '%s' "$merged" | python3 -c '
import sys, json, time
recs = json.load(sys.stdin)
if not recs:
    print("（没有分享记录）"); raise SystemExit
print("%-4s %-14s %-10s %-9s %-14s %-8s %-19s %s" % ("#", "TOKEN", "PROVIDER", "TYPE", "TAG", "USES", "有效期", "状态"))
for i, r in enumerate(recs, 1):
    ex = int(r.get("expires_at", 0)); mu = int(r.get("max_uses", 0)); u = int(r.get("used_count", 0))
    exp = "永久" if not ex else time.strftime("%F %T", time.localtime(ex))
    tag = (r.get("meta") or {}).get("tag", "") or "-"
    print("%-4d %-14s %-10s %-9s %-14s %-8s %-19s %s" % (
        i, str(r.get("token",""))[:12] + "…", r.get("provider",""), r.get("type",""),
        tag, "%d/%s" % (u, mu if mu else "∞"), exp, r.get("state","?")))
'
}

cmd_show() {
    need_provider
    local tok="${POS[0]:-}"; [[ -n "$tok" ]] || die_usage "用法: panel.sh show <token> --provider P"
    health_ok || die_down "服务不可达"
    local out rc; out=$(api_or_die GET "/api/v1/shares/$tok?provider=$PROVIDER"); rc=$?
    (( rc == 0 )) || exit "$rc"
    if (( WANT_JSON )); then printf '%s' "$out"; echo; return 0; fi
    printf '%s' "$out" | python3 -c '
import sys, json, time
r = json.load(sys.stdin)
if isinstance(r, dict) and "share" in r: r = r["share"]
for k in ("token","provider","type","enabled","state","max_uses","used_count",
          "created_at","expires_at","last_used_at","content_bytes","content_type","content_sha256"):
    v = r.get(k)
    if k.endswith("_at") and isinstance(v, int) and v:
        v = "%d (%s)" % (v, time.strftime("%F %T", time.localtime(v)))
    print("%-15s: %s" % (k, v))
print("%-15s: %s" % ("tag", (r.get("meta") or {}).get("tag","")))
'
}

cmd_url() {
    local tok="${POS[0]:-}"; [[ -n "$tok" ]] || die_usage "用法: panel.sh url <token>"
    printf 'http://%s:%s/share/%s\n' "$(hostname -I 2>/dev/null | awk '{print $1}')" "$(svc_port)" "$tok"
}

cmd_create() {
    need_provider
    [[ -n "$FILE" ]] || die_usage "缺少 --file <内容文件> (内容是不透明字节, 服务不解析)"
    [[ -r "$FILE" ]] || die_usage "读不到内容文件: $FILE"
    health_ok || die_down "服务不可达"
    python3 - "$PROVIDER" "$TYPE" "$TAG" "$TTL" "$MAXUSES" "$TOK" "$FILE" "$EXPIRES" <<'PY' > /tmp/.pss-create.$$.json
import json, os, sys
provider, typ, tag, ttl, maxu, tok, path, exp = sys.argv[1:9]
body = {"provider": provider, "type": typ or "node"}
body["content"] = open(path, encoding="utf-8").read()
if tok: body["token"] = tok
if tag: body["meta"] = {"tag": tag}
if ttl != "": body["ttl"] = int(ttl) * 3600
# 绝对过期时间: 从旧实现迁移过来的记录手上就是绝对时间戳,
# 用相对 ttl 反推会算错 (而且已过期的记录会变成"永久", 这是踩过的坑)。
if exp != "": body["expires_at"] = int(exp)
if maxu != "": body["max_uses"] = int(maxu)
print(json.dumps(body, ensure_ascii=False))
PY
    local body; body=$(cat /tmp/.pss-create.$$.json); rm -f /tmp/.pss-create.$$.json
    local out rc; out=$(api_or_die POST /api/v1/shares "$body"); rc=$?
    (( rc == 0 )) || exit "$rc"
    [[ -n "$out" ]] || { err "服务没有返回内容"; exit 1; }
    if (( WANT_JSON )); then printf '%s' "$out"; echo; return 0; fi
    local tk
    tk=$(printf '%s' "$out" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("token",""))
except Exception: print("")' 2>/dev/null)
    [[ -n "$tk" ]] || { err "服务没有返回 token"; exit 1; }
    printf '%s\n' "$tk"
}

cmd_set() {
    need_provider
    local tok="${POS[0]:-}"; [[ -n "$tok" ]] || die_usage "用法: panel.sh set <token> --provider P [...]"
    health_ok || die_down "服务不可达"
    python3 - "$PROVIDER" "$TOK" "$FILE" "$ENABLED" "$USEDCOUNT" "$MAXUSES" "$TTL" "$tok" "$EXPIRES" <<'PY' > /tmp/.pss-set.$$.json
import json, sys
provider, _tokflag, path, enabled, used, maxu, ttl, token, exp = sys.argv[1:10]
body = {"provider": provider}
if path: body["content"] = open(path, encoding="utf-8").read()
if enabled != "": body["enabled"] = (enabled == "true")
if used != "": body["used_count"] = int(used)
if maxu != "": body["max_uses"] = int(maxu)
if ttl != "": body["ttl"] = int(ttl) * 3600
if exp != "": body["expires_at"] = int(exp)
print(json.dumps(body, ensure_ascii=False))
PY
    local body; body=$(cat /tmp/.pss-set.$$.json); rm -f /tmp/.pss-set.$$.json
    local out rc; out=$(api_or_die PUT "/api/v1/shares/$tok" "$body"); rc=$?
    (( rc == 0 )) || exit "$rc"
    (( WANT_JSON )) && { printf '%s' "$out"; echo; return 0; }
    ok "已更新 $tok"
}

cmd_del() {
    need_provider
    local tok="${POS[0]:-}"; [[ -n "$tok" ]] || die_usage "用法: panel.sh del <token> --provider P"
    health_ok || die_down "服务不可达"
    local out rc; out=$(api_or_die DELETE "/api/v1/shares/$tok?provider=$PROVIDER"); rc=$?
    (( rc == 0 )) || exit "$rc"
    # 回读确认: 静默失败在旧实现里踩过
    api GET "/api/v1/shares/$tok?provider=$PROVIDER" >/dev/null
    [[ "$(api_code)" == "404" ]] || { err "删除未生效 (记录仍在)"; exit 1; }
    (( WANT_JSON )) && { printf '%s' "${out:-{\"deleted\":true}}"; echo; return 0; }
    ok "已删除 $tok"
}

cmd_clean() {
    health_ok || die_down "服务不可达 (端口 $(svc_port))"
    [[ -f "$INSTALL_DIR/share_service.py" ]] || die_down "找不到 $INSTALL_DIR/share_service.py"

    # ★ 判据只有服务端那一份 (cleanup_once) —— 面板不另写一套"我猜会删谁"。
    #   实测的教训: 面板自己实现时把一条**已禁用**且过期的记录报成"待清理",
    #   而清理器按规则根本不碰它 (主动禁用是用户的记录, 不是垃圾)。
    #   两套规则一旦漂移, dry-run 就变成误导。
    (_pss_run() { set -a; [[ -f "$ENV_FILE" ]] && . "$ENV_FILE"; set +a
                  python3 "$INSTALL_DIR/share_service.py" --cleanup "$@"; }
     if (( DRYRUN )); then _pss_run --dry-run; else _pss_run; fi)
}

# ---------------------------------------------------------------- 文件分享
# 「给一个路径, 换一个链接」。
#
# 分工: **面板读路径, 服务存字节**。
#   不把路径交给服务端去读 —— 它跑在 root 下, 那等于给管理 API 开了一个
#   "读服务器上任意文件"的口子; 而且文件一移动/备份轮转, 链接就静默失效。
#   上传一次之后内容就是服务的, 跟原文件没关系了。
cmd_file() {
    local path="${POS[0]:-}"
    [[ -n "$path" ]] || die_usage "用法: panel.sh file <文件路径> [--provider file] [--ttl H] [--max-uses N] [--name 名]"
    [[ -e "$path" ]] || die_usage "路径不存在: $path"
    [[ -f "$path" ]] || die_usage "不是普通文件: $path"
    [[ -r "$path" ]] || die_usage "读不了: $path"

    # 文件分享不属于任何内核, 默认挂在一个独立的 provider 下 ——
    # 这样它既满足"记录必有 provider"的隔离不变量, 又不会混进内核的列表。
    [[ -n "$PROVIDER" ]] || PROVIDER="file"
    _provider_ok "$PROVIDER" || die_usage "provider 非法: $PROVIDER"
    TYPE="file"
    health_ok || die_down "服务不可达 (端口 $(svc_port))"

    local size; size=$(stat -c %s "$path" 2>/dev/null || echo 0)
    (( size > 0 )) || die_usage "文件是空的 (0 字节): $path"
    # 上限**问服务端要** (health 里的 max_file_bytes), 不各写一个默认值 ——
    # 两边默认值一旦不同, 面板就会放行一个注定被 413 的文件, 用户白等一场。
    # 拿不到才退回本地 env。
    local lim
    lim=$(curl -s --max-time 5 "http://127.0.0.1:$(svc_port)/api/v1/health" 2>/dev/null \
          | python3 -c 'import sys,json
try: print(int(json.load(sys.stdin).get("max_file_bytes", 0)))
except Exception: print(0)' 2>/dev/null)
    [[ "${lim:-0}" =~ ^[0-9]+$ ]] && (( lim > 0 )) || lim=$(( ${SHARE_MAX_FILE_MB:-16} * 1024 * 1024 ))
    if (( size > lim )); then
        die_usage "文件 ${size} 字节, 超过服务端上限 ${lim} 字节 ($(( lim / 1024 / 1024 )) MiB; 调 SHARE_MAX_FILE_MB 后 upgrade 生效)"
    fi

    # 文本 / 二进制: 能按 UTF-8 解出来且没有 NUL 就当文本 —— 这样文本文件
    # 用浏览器打开是可读的, 而不是一串 base64。
    local enc="utf-8"
    if (( BINARY )) || ! python3 -c '
import sys
try:
    b = open(sys.argv[1], "rb").read()
except OSError:
    sys.exit(1)
if b"\0" in b: sys.exit(1)
try: b.decode("utf-8")
except UnicodeDecodeError: sys.exit(1)
' "$path" 2>/dev/null; then
        enc="base64"
    fi

    local name; name="${NAME:-$(basename "$path")}"
    local ctype="$CTYPE"
    if [[ -z "$ctype" ]]; then
        ctype=$(python3 -c '
import mimetypes, sys
t, _ = mimetypes.guess_type(sys.argv[1])
print(t or "application/octet-stream")
' "$name" 2>/dev/null)
    fi
    # 文本类补上 charset, 否则浏览器可能按 latin-1 猜
    [[ "$ctype" == text/* && "$ctype" != *charset* ]] && ctype="$ctype; charset=utf-8"

    local bf; bf=$(mktemp /tmp/.pss-body.XXXXXX)
    if ! python3 - "$path" "$enc" "$PROVIDER" "$TYPE" "$NAME" "$TTL" "$MAXUSES" "$EXPIRES" "$ctype" "$name" "$bf" <<'PY'
import base64, json, sys
path, enc, provider, typ, _name, ttl, maxu, exp, ctype, fname, out = sys.argv[1:12]
with open(path, "rb") as fh:
    raw = fh.read()
body = {
    "provider": provider,
    "type": typ,
    "content": base64.b64encode(raw).decode("ascii") if enc == "base64" else raw.decode("utf-8"),
    "content_encoding": enc,
    "content_type": ctype,
    "filename": fname,
    "meta": {"tag": fname},
}
if ttl != "": body["ttl"] = int(ttl) * 3600
if maxu != "": body["max_uses"] = int(maxu)
if exp != "": body["expires_at"] = int(exp)
with open(out, "w", encoding="utf-8") as fh:
    json.dump(body, fh, ensure_ascii=False)
PY
    then
        rm -f "$bf"; err "组装请求失败"; exit 1
    fi

    local out rc; out=$(api_f POST /api/v1/shares "$bf"); rc=$?
    rm -f "$bf"
    (( rc == 0 )) || exit "$rc"
    local tk
    tk=$(printf '%s' "$out" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("token",""))
except Exception: print("")' 2>/dev/null)
    [[ -n "$tk" ]] || { err "服务没有返回 token"; exit 1; }

    if (( WANT_JSON )); then printf '%s\n' "$out"; return 0; fi
    # stdout 只放 URL —— 调用方 `U=$(panel.sh file x.pdf)` 直接就能用
    local host; host=$(hostname -I 2>/dev/null | awk '{print $1}')
    printf 'http://%s:%s/share/%s\n' "$host" "$(svc_port)" "$tk"
}

cmd_fetch() { # 从分享链接取回内容 (走公开端点, **会消耗一次额度**)
    local tok="${POS[0]:-}"
    [[ -n "$tok" ]] || die_usage "用法: panel.sh fetch <token> [--out 路径]"
    local url="http://127.0.0.1:$(svc_port)/share/$tok"
    if [[ -n "$OUT" ]]; then
        local code
        code=$(curl -s -o "$OUT" -w '%{http_code}' --max-time 120 "$url" 2>/dev/null)
        [[ "$code" == "200" ]] || { rm -f "$OUT"; err "下载失败 HTTP $code"; exit 1; }
        ok "已保存到 $OUT ($(stat -c %s "$OUT" 2>/dev/null) 字节)"
    else
        curl -sS --max-time 120 "$url" 2>/dev/null || { err "下载失败"; exit 1; }
    fi
}

# ---- 服务生命周期: 交给 install.sh, 不在这里重复实现一套 ----
svc_install_sh() {
    local sh="$SELF_DIR/install.sh"
    [[ -f "$sh" ]] || die_down "找不到 $SELF_DIR/install.sh"
    printf '%s' "$sh"
}

cmd_service() { # <install|uninstall|...>
    need_root
    local act="$1"; shift
    local sh; sh=$(svc_install_sh)
    case "$act" in
        install)   bash "$sh" ;;
        upgrade)   bash "$sh" upgrade ;;
        check)     bash "$sh" --check ;;
        uninstall)
            local -a a=(uninstall)
            (( FORCE )) && a+=(--force)
            (( PURGE )) && a+=(--purge)
            bash "$sh" "${a[@]}" ;;
        start)     systemctl start "$SERVICE"   && ok "已启动" ;;
        stop)      systemctl stop "$SERVICE"    && ok "已停止" ;;
        restart)   systemctl restart "$SERVICE" && ok "已重启" ;;
        *) die_usage "未知服务动作: $act" ;;
    esac
}

cmd_logs() {
    local n="${POS[0]:-40}"
    [[ "$n" =~ ^[0-9]+$ ]] || die_usage "行数必须是数字"
    journalctl -u "$SERVICE" -n "$n" --no-pager 2>/dev/null || die_down "读不到日志"
}

# ---------------------------------------------------------------- 交互菜单
interactive() {
    [[ -t 0 && -t 1 ]] || die_usage "非交互环境 —— 请用子命令 (bash panel.sh --help)"
    while true; do
        title "════ $SERVICE 管理面板 ════"
        cmd_status >&2
        printf '\n%s1)%s 列出全部分享      %s2)%s 查看单条\n' "$C_T" "$C_R" "$C_T" "$C_R" >&2
        printf '%s3)%s 删除单条          %s4)%s 启用/禁用\n' "$C_T" "$C_R" "$C_T" "$C_R" >&2
        printf '%s5)%s 按 provider 统计  %s6)%s 清理到期/用尽\n' "$C_T" "$C_R" "$C_T" "$C_R" >&2
        printf '%s7)%s 重启服务          %s8)%s 查看日志\n' "$C_T" "$C_R" "$C_T" "$C_R" >&2
        printf '%s9)%s 安装/修复服务     %s10)%s 卸载服务\n' "$C_T" "$C_R" "$C_T" "$C_R" >&2
        printf '%s11)%s 升级服务代码     %s12)%s 分享一个文件 (给路径换链接)\n' "$C_T" "$C_R" "$C_T" "$C_R" >&2
        printf '%s13)%s 取回分享内容\n' "$C_T" "$C_R" >&2
        printf '%s0)%s 退出\n' "$C_T" "$C_R" >&2
        local c=""; read -r -p "请选择: " c || return 0
        case "${c// /}" in
            1) cmd_list ;;
            2) read -r -p "  token: " t; read -r -p "  provider: " p
               PROVIDER="$p"; POS=("$t"); cmd_show ;;
            3) read -r -p "  token: " t; read -r -p "  provider: " p
               PROVIDER="$p"; POS=("$t"); cmd_del ;;
            4) read -r -p "  token: " t; read -r -p "  provider: " p
               read -r -p "  [e]启用 / [d]禁用: " e
               PROVIDER="$p"; POS=("$t")
               case "$e" in e|E) ENABLED=true ;; d|D) ENABLED=false ;; *) warn "取消"; continue ;; esac
               cmd_set ;;
            5) cmd_providers ;;
            6) cmd_clean ;;
            7) cmd_service restart ;;
            8) cmd_logs 40 ;;
            9) cmd_service install ;;
            10) cmd_service uninstall ;;
            11) cmd_service upgrade ;;
            12) read -r -p "  文件路径: " fp
                read -r -p "  有效期小时 (回车=24, 0=永久): " th; TTL="${th:-24}"
                read -r -p "  可拉取次数 (回车=0 不限): " mu; MAXUSES="${mu:-0}"
                POS=("$fp"); cmd_file ;;
            13) read -r -p "  token: " ft; read -r -p "  保存到: " fo
                POS=("$ft"); OUT="$fo"; cmd_fetch ;;
            0) return 0 ;;
            *) warn "无效选项 $c" ;;
        esac
        printf '\n' >&2; read -r -p "回车继续..." _ || return 0
    done
}

# ---------------------------------------------------------------- 入口
cmd="${1:-}"
[[ $# -gt 0 ]] && shift
case "$cmd" in
    status)    parse_args "$@"; cmd_status ;;
    health)    cmd_health ;;
    port)      cmd_port ;;
    info)      cmd_info ;;
    providers) parse_args "$@"; cmd_providers ;;
    list)      parse_args "$@"; cmd_list ;;
    show)      parse_args "$@"; cmd_show ;;
    url)       parse_args "$@"; cmd_url ;;
    create)    parse_args "$@"; cmd_create ;;
    set)       parse_args "$@"; cmd_set ;;
    del|delete) parse_args "$@"; cmd_del ;;
    file|share-file) parse_args "$@"; cmd_file ;;
    fetch|get) parse_args "$@"; cmd_fetch ;;
    clean)     parse_args "$@"; cmd_clean ;;
    logs)      parse_args "$@"; cmd_logs ;;
    check|install|upgrade|start|stop|restart|uninstall)
               parse_args "$@"; cmd_service "$cmd" ;;
    -h|--help) usage; exit 0 ;;
    "")        interactive ;;
    *)         die_usage "未知子命令: $cmd (见 panel.sh --help)" ;;
esac
