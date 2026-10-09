#!/usr/bin/env bash
# =============================================================
# proxy-share-service · 安装 / 升级 / 卸载
#
# 这是一个**公共基础服务**, 不属于任何内核。M / SB / X 都只是它的调用方:
#
#     M ─┐
#     SB ├──→ proxy-share-service  (只做 Token/TTL/max_uses/存储/访问)
#     X ─┘
#
# 三条设计原则:
#   1. **幂等**: 已装过就只做检查, 不重装、不改端口、不碰数据。
#      SB/X 后装时必须能直接复用 M 装好的那一份。
#   2. **端口回避**: 首选端口被占就自动往后找一个空闲的, 并把实际端口
#      落到 env 文件 —— 服务器上已经有别的服务占着 9443 也不会装不上。
#   3. **内核不拥有它**: 卸载内核时不删它。只有这里能卸载。
#
# 用法:
#   bash install.sh               # 安装或升级 (幂等)
#   bash install.sh --check       # 只检查状态, 不做任何改动
#   bash install.sh uninstall     # 卸载服务 (数据默认保留)
#   bash install.sh uninstall --purge   # 连数据一起删
#
# 环境变量:
#   PSS_SRC_DIR=<目录>   从本地目录取源码 (不下载); 默认用脚本自身所在目录
#   PSS_PORT=<端口>      首选端口, 默认 9443
#   PSS_REPO_RAW=<URL>   从远端取源码时的 raw 前缀
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
PREFERRED_PORT="${PSS_PORT:-9443}"
REPO_RAW="${PSS_REPO_RAW:-https://raw.githubusercontent.com/mi1314cat/Share-Service/main}"

_c(){ [[ -t 1 ]] && printf '\033[%sm%s\033[0m\n' "$1" "$2" || printf '%s\n' "$2"; }
ok(){ _c 32 "  ✓ $1"; }
warn(){ _c 33 "  ! $1"; }
err(){ _c 31 "  ✗ $1"; }
dim(){ _c 90 "    $1"; }

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || { err "需要 root"; exit 1; }; }

# ---------------------------------------------------------------- 端口工具
#
# 用**真正 bind 一次**来判断, 而不是 grep ss:
#   - ss 会把 TIME_WAIT 也算成"占用", 于是明明能绑却说不行
#   - 反过来说, 只 listen 在 IPv4 的进程不挡 IPv6 绑定, 只看 ss 容易误判
port_free() { # <port>  0=空闲
    python3 - "$1" <<'PY' 2>/dev/null
import socket, sys
p = int(sys.argv[1])
for fam, addr in ((socket.AF_INET6, "::"), (socket.AF_INET, "0.0.0.0")):
    try:
        s = socket.socket(fam, socket.SOCK_STREAM)
        if fam == socket.AF_INET6:
            try: s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            except OSError: pass
        s.bind((addr, p)); s.close()
    except OSError:
        sys.exit(1)
sys.exit(0)
PY
}

pick_port() { # <preferred> -> 打印一个空闲端口
    local p="$1" i
    if port_free "$p"; then printf '%s' "$p"; return 0; fi
    for ((i = p + 1; i <= p + 200; i++)); do
        if port_free "$i"; then printf '%s' "$i"; return 0; fi
    done
    return 1
}

port_in_use_by() { # <port> -> 打印占用者 (尽力而为, 仅用于提示)
    ss -lntp 2>/dev/null | awk -v p=":$2" '$4 ~ p"$" {print $6}' | head -1
}

# ---------------------------------------------------------------- 运行状态
svc_active(){ systemctl is-active --quiet "$SERVICE" 2>/dev/null; }
svc_installed(){ [[ -f "$UNIT" ]]; }
current_port(){
    # env 文件里的端口优先; 运行时端口文件是实际绑定值 (端口回避后可能不同)
    local p=""
    [[ -f "$ENV_FILE" ]] && p=$(sed -n 's/^SHARE_PORT=//p' "$ENV_FILE" | head -1)
    [[ -z "$p" && -f "$PORT_FILE" ]] && p=$(head -1 "$PORT_FILE" 2>/dev/null)
    printf '%s' "${p:-$PREFERRED_PORT}"
}
health_json(){ curl -s --max-time 5 "http://127.0.0.1:$(current_port)/api/v1/health" 2>/dev/null; }

do_check() {
    echo "════ $SERVICE 状态 ════"
    if svc_installed; then ok "已安装 ($UNIT)"; else warn "未安装"; return 1; fi
    local p; p=$(current_port)
    printf '  端口      : %s\n' "$p"
    if [[ -f "$PORT_FILE" ]] && [[ "$(head -1 "$PORT_FILE" 2>/dev/null)" != "$p" ]]; then
        printf '  实际端口  : %s (端口回避后的值)\n' "$(head -1 "$PORT_FILE")"
    fi
    if svc_active; then ok "运行中"; else err "未运行"; fi
    local h; h=$(health_json)
    if [[ -n "$h" ]]; then
        ok "健康检查通过"
        printf '  API 版本  : %s\n' "$(printf '%s' "$h" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("api_version","?"))' 2>/dev/null)"
        printf '  版本      : %s\n' "$(printf '%s' "$h" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("version","?"))' 2>/dev/null)"
        printf '  各内核分享: %s\n' "$(printf '%s' "$h" | python3 -c 'import sys,json;d=json.load(sys.stdin).get("providers",{});print(", ".join("%s=%d"%(k,v["total"]) for k,v in d.items()) or "（无）")' 2>/dev/null)"
    else
        warn "健康检查未通过 (端口可能还没起来)"
    fi
    [[ -f "$TOKEN_FILE" ]] && ok "管理密钥已配置" || warn "管理密钥缺失"
}

# ---------------------------------------------------------------- 取源码
fetch_src() { # <目标目录>
    local dest="$1" self_dir
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local src="${PSS_SRC_DIR:-$self_dir}"
    mkdir -p "$dest"
    if [[ -f "$src/src/share_service.py" ]]; then
        cp -f "$src/src/share_service.py" "$dest/share_service.py" || return 1
        return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 30 "$REPO_RAW/src/share_service.py" -o "$dest/share_service.py" && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -qO "$dest/share_service.py" --timeout=30 "$REPO_RAW/src/share_service.py" && return 0
    fi
    return 1
}

# ---------------------------------------------------------------- 安装
do_install() {
    echo "════ 安装 $SERVICE ════"

    # ---- 幂等: 已装过就只做检查 ----
    #
    # ★ 这是"多内核共存"的关键路径: SB/X 后装时必须直接复用 M 装好的那一份。
    #   所以**只要服务在跑且健康, 就绝不重装、不改端口、不碰数据**。
    if svc_installed; then
        local h; h=$(health_json)
        if [[ -n "$h" && "$h" == *'"status"'* ]]; then
            ok "已存在且运行正常 —— 直接复用, 未做任何改动"
            local p; p=$(current_port)
            printf '  端口: %s\n' "$p"
            printf '  版本: %s\n' "$(printf '%s' "$h" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("version","?"))' 2>/dev/null)"
            dim "（内核侧只需读取 $ENV_FILE 里的 SHARE_PORT 即可接入）"
            return 0
        fi
        warn "已安装但健康检查未通过 —— 将修复 (端口与数据保持不变)"
    fi

    # ---- 端口 ----
    #
    # ★ 端口回避: 首选端口被别人占了就自动换一个。
    #   已装过的机器**沿用 env 里记着的端口**, 不能每次升级都换
    #   —— 否则所有已发出去的分享链接全废。
    local port
    if [[ -f "$ENV_FILE" ]]; then
        port=$(sed -n 's/^SHARE_PORT=//p' "$ENV_FILE" | head -1)
    fi
    if [[ -z "${port:-}" ]]; then
        if port_free "$PREFERRED_PORT"; then
            port="$PREFERRED_PORT"
            ok "端口 $port 可用"
        else
            local who; who=$(port_in_use_by "$PREFERRED_PORT" "$PREFERRED_PORT")
            warn "首选端口 $PREFERRED_PORT 已被占用${who:+ ($who)}"
            port=$(pick_port "$PREFERRED_PORT") || { err "端口区间内无可用端口"; return 1; }
            ok "端口回避: $PREFERRED_PORT -> $port"
        fi
    else
        ok "沿用已有端口 $port"
        if ! port_free "$port"; then
            local who; who=$(port_in_use_by "$port" "$port")
            warn "端口 $port 当前不可用${who:+ (被 $who 占用)} —— 服务启动时会自行回避"
        fi
    fi

    # ---- 目录与密钥 ----
    mkdir -p "$ETC" "$DATA_DIR" "$INSTALL_DIR" /run/$SERVICE
    chmod 700 "$ETC"

    if [[ ! -f "$TOKEN_FILE" ]]; then
        # 32 字节 hex, 权限 0600。管理 API 与公开访问靠它分离。
        ( umask 077; openssl rand -hex 32 > "$TOKEN_FILE" ) 2>/dev/null \
            || ( umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$TOKEN_FILE" )
        chmod 600 "$TOKEN_FILE"
        ok "已生成管理密钥 $TOKEN_FILE"
    else
        ok "沿用已有管理密钥"
    fi

    # ---- 代码 ----
    if ! fetch_src "$INSTALL_DIR"; then
        err "取不到 share_service.py (本地没有, 远端也拉不到)"
        return 1
    fi
    chmod 755 "$INSTALL_DIR/share_service.py"
    ok "服务代码已就位 $INSTALL_DIR/share_service.py"
    dim "版本: $(grep -m1 '^VERSION' "$INSTALL_DIR/share_service.py" | cut -d'"' -f2)"

    # ---- env ----
    cat > "$ENV_FILE" <<EOF
# proxy-share-service 配置 (由 install.sh 维护)
# 内核侧接入时读这里的 SHARE_PORT —— 端口回避后的实际值就在这
SHARE_PORT=$port
SHARE_DATA_DIR=$DATA_DIR
SHARE_ADMIN_TOKEN_FILE=$TOKEN_FILE
SHARE_PORT_FILE=$PORT_FILE
SHARE_ADMIN_LOOPBACK_ONLY=1
SHARE_BIND=::
SHARE_PUBLIC_BASE=
EOF
    chmod 600 "$ENV_FILE"

    # ---- systemd ----
    cat > "$UNIT" <<EOF
# 由 install.sh 生成
[Unit]
Description=Proxy Share Service (token/TTL/max_uses; provider-agnostic)
Documentation=https://github.com/mi1314cat/Share-Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
RuntimeDirectory=$SERVICE
ExecStart=/usr/bin/python3 $INSTALL_DIR/share_service.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE" >/dev/null 2>&1
    systemctl restart "$SERVICE" >/dev/null 2>&1
    sleep 1

    if svc_active && [[ -n "$(health_json)" ]]; then
        ok "服务已启动并通过健康检查 (端口 $port)"
        if [[ -f "$PORT_FILE" ]]; then
            dim "实际绑定端口: $(head -1 "$PORT_FILE")"
        fi
    else
        err "服务未通过健康检查 —— 看 journalctl -u $SERVICE -n 30"
        return 1
    fi

    echo
    echo "  内核侧接入方式 (以 M 为例):"
    printf '    端口     : 读 %s 的 SHARE_PORT\n' "$ENV_FILE"
    printf '    管理密钥 : %s\n' "$TOKEN_FILE"
    printf '    创建分享 : POST http://127.0.0.1:<端口>/api/v1/shares\n'
    echo
    dim "卸载: bash install.sh uninstall      (数据默认保留)"
    dim "卸载最后一个内核**不会**删除本服务 —— 只有这里能卸载"
    return 0
}

# ---------------------------------------------------------------- 卸载
do_uninstall() {
    local purge="${1:-}"
    echo "════ 卸载 $SERVICE ════"

    local n=0
    if [[ -d "$DATA_DIR/shares" ]]; then
        n=$(find "$DATA_DIR/shares" -name '*.json' 2>/dev/null | wc -l)
    fi
    if (( n > 0 )) && [[ "$purge" != "--purge" ]]; then
        warn "还有 $n 条分享记录在使用中"
        dim "内核 (M/SB/X) 可能仍在引用它们 —— 卸载服务后这些链接会全部失效。"
        dim "确定要继续: bash install.sh uninstall --purge"
        return 1
    fi

    systemctl stop "$SERVICE" 2>/dev/null
    systemctl disable "$SERVICE" 2>/dev/null
    rm -f "$UNIT"
    systemctl daemon-reload 2>/dev/null
    ok "服务已移除"

    if [[ "$purge" == "--purge" ]]; then
        rm -rf "$DATA_DIR" "$ETC" "$INSTALL_DIR"
        ok "数据与配置已删除"
    else
        dim "数据保留在 $DATA_DIR (要连数据一起删: --purge)"
    fi
    return 0
}

# ---------------------------------------------------------------- 入口
need_root
case "${1:-}" in
    --check)   do_check ;;
    uninstall) shift; do_uninstall "${1:-}" ;;
    "")        do_install ;;
    *)         err "未知参数: $1"; exit 2 ;;
esac
