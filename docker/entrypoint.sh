#!/bin/sh
###############################################################################
# OpenWrt 容器 entrypoint
#
# 作用：把 docker run / compose 传入的环境变量刷进 UCI，然后 exec /sbin/init。
#
# 为什么需要它：镜像的 CMD 是 /sbin/init（procd），OpenWrt 本身不会去读
# Docker 注入的环境变量。没有这一层的话，compose 里写的 environment 对
# OpenWrt 一点用都没有，改 LAN IP 只能重新编译固件。
#
# 生效时机由 OPENWRT_APPLY_ENV 控制：
#   auto   （默认）只在首次启动应用一次，之后完全交给 LuCI 管理
#   always 每次启动都应用，compose 的 environment 说了算
#   never  完全不应用
#
# 例外：root 密码每次启动都设置。/etc/shadow 通常不在持久化卷里，
#       容器重建后会回到镜像默认值，不重设就用改过的密码登不进去。
#
# 另外负责"空卷初始化"：compose 用 bind mount（挂载宿主机 data/ 目录），
# 而 bind mount 不像命名卷那样会自动带入镜像里的初始内容。宿主机目录为空
# 时，容器内 /etc/config 会被盖成空的，UCI 读不到配置、LuCI 进不去。
# 所以启动先检查：挂载目录为空就从镜像内置的
# /usr/share/openwrt-defaults（构建时备份）恢复初始内容。
# 目录已非空 = 用户已在使用，一律不动，绝不覆盖已有配置。
###############################################################################
set -u

MARK=/etc/config/.docker-env-applied
DEFAULTS_DIR=/usr/share/openwrt-defaults

log() { printf 'openwrt-entrypoint: %s\n' "$*"; }

uci_set() {
    # uci_set <config> <section> <option> <value>
    uci -q set "${1}.${2}.${3}=${4}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# root 密码：每次都设（/etc/shadow 一般不持久化）
# ---------------------------------------------------------------------------
set_root_password() {
    [ -n "${ROOT_PASSWORD:-}" ] || return 0
    command -v openssl >/dev/null 2>&1 || return 0

    hash="$(openssl passwd -1 "$ROOT_PASSWORD" 2>/dev/null)" || return 0
    [ -n "$hash" ] || return 0

    # $hash 含 $ 符号，用 # 作分隔符避免转义问题
    sed -i "s#^root:[^:]*:#root:${hash}:#" /etc/shadow 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 系统：主机名 / 时区
# ---------------------------------------------------------------------------
apply_system() {
    if [ -n "${OPENWRT_HOSTNAME:-}" ]; then
        uci -q set "system.@system[0].hostname=${OPENWRT_HOSTNAME}" 2>/dev/null || true
    fi
    if [ -n "${OPENWRT_TIMEZONE:-}" ]; then
        uci -q set "system.@system[0].timezone=${OPENWRT_TIMEZONE}" 2>/dev/null || true
    fi
    if [ -n "${OPENWRT_ZONENAME:-}" ]; then
        uci -q set "system.@system[0].zonename=${OPENWRT_ZONENAME}" 2>/dev/null || true
    fi
    uci -q commit system 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# LuCI：主题 / 语言
# ---------------------------------------------------------------------------
apply_luci() {
    if [ -f /etc/config/luci ] && [ -n "${LUCI_THEME:-}" ]; then
        uci -q set "luci.main.mediaurlbase=/luci-static/${LUCI_THEME}" 2>/dev/null || true
    fi
    if [ -f /etc/config/luci ] && [ -n "${LUCI_LANG:-}" ]; then
        uci -q set "luci.main.lang=${LUCI_LANG}" 2>/dev/null || true
        uci -q set "luci.main.lang_auto=0" 2>/dev/null || true
    fi
    uci -q commit luci 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# LAN 网络
# ---------------------------------------------------------------------------
apply_network() {
    [ -f /etc/config/network ] || return 0

    [ -n "${LAN_IP:-}" ]      && uci_set network lan ipaddr  "$LAN_IP"
    [ -n "${LAN_NETMASK:-}" ] && uci_set network lan netmask "$LAN_NETMASK"
    [ -n "${LAN_GATEWAY:-}" ] && uci_set network lan gateway "$LAN_GATEWAY"

    if [ -n "${LAN_DNS:-}" ]; then
        uci -q delete network.lan.dns 2>/dev/null || true
        for d in $LAN_DNS; do
            uci -q add_list "network.lan.dns=$d" 2>/dev/null || true
        done
    fi

    # 容器里 eth0 已由 macvlan 提供，不能再套 br-lan 桥。
    # 光改 lan.device 不够：netifd 会按配置把 eth0 塞进 br-lan，
    # 结果 LAN 拿不到地址，所以桥接设备段也要删掉。
    # 物理机刷机时保持原样（没有 /.dockerenv）。
    if [ -f /.dockerenv ]; then
        uci -q set network.lan.device=eth0 2>/dev/null || true
        uci -q delete network.@device[0] 2>/dev/null || true
    fi

    uci -q commit network 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 容器内 Docker 的数据目录
# ---------------------------------------------------------------------------
apply_dockerd() {
    [ -n "${DOCKER_DATA_ROOT:-}" ] || return 0

    mkdir -p "$DOCKER_DATA_ROOT" 2>/dev/null || true

    if [ -f /etc/config/dockerd ]; then
        uci -q set "dockerd.globals.data_root=${DOCKER_DATA_ROOT}" 2>/dev/null || true
        uci -q commit dockerd 2>/dev/null || true
    fi
    if [ -f /etc/config/dockerman ]; then
        uci -q set "dockerman.local.daemon_data_root=${DOCKER_DATA_ROOT}" 2>/dev/null || true
        uci -q commit dockerman 2>/dev/null || true
    fi
}

apply_all() {
    apply_system
    apply_luci
    apply_network
    apply_dockerd
}

# ---------------------------------------------------------------------------
# 空卷初始化：bind mount 到宿主机空目录时恢复镜像内的初始内容
# ---------------------------------------------------------------------------
seed_dir() {
    # seed_dir <容器内目录>
    target="$1"
    src="${DEFAULTS_DIR}/$(printf '%s' "$target" | tr '/' '_')"

    # 镜像里没备份过（构建时该目录不存在或被裁掉）→ 只保证目录存在
    if [ ! -d "$src" ]; then
        mkdir -p "$target" 2>/dev/null || true
        return 0
    fi

    mkdir -p "$target" 2>/dev/null || true

    # 非空 = 已在使用，直接跳过。这一步是安全底线，不能覆盖用户配置。
    # 注意必须判断"输出是否为空"而不是 ls 的退出码：
    # ls -A 对空目录同样返回 0（成功列出了零个条目），用退出码判断会
    # 误以为目录非空，导致初始化永远不触发。
    if [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
        return 0
    fi

    cp -a "$src/." "$target/" 2>/dev/null || true
    log "初始化空挂载目录 ${target}（从镜像内置默认配置恢复）"
}

seed_volumes() {
    # 关掉就完全不自动初始化（比如你想自己 docker cp 进来）
    case "${OPENWRT_SEED_AUTO:-1}" in
        0|no|false|never) return 0 ;;
    esac
    [ -d "$DEFAULTS_DIR" ] || return 0

    dirs="${OPENWRT_SEED_DIRS:-/etc/config /etc/openclash /etc/AdGuardHome /etc/mosdns /usr/share/nftables.d /root /var/log}"
    [ -n "${DOCKER_DATA_ROOT:-}" ] && dirs="${dirs} ${DOCKER_DATA_ROOT}"

    for d in $dirs; do
        seed_dir "$d"
    done
}

# ---------------------------------------------------------------------------
main() {
    # 必须在所有 UCI 操作之前：/etc/config 若为空，uci 什么都读不到
    seed_volumes

    # 密码不进 /etc/config，容器重建就丢，所以每次都要设
    set_root_password

    case "${OPENWRT_APPLY_ENV:-auto}" in
        always|1|true)
            apply_all
            ;;
        never|0|false)
            ;;
        auto|*)
            # 配置卷持久化后，标记文件会留下来 → 后续启动不再覆盖 LuCI 里的改动
            if [ ! -f "$MARK" ]; then
                apply_all
                touch "$MARK" 2>/dev/null || true
            fi
            ;;
    esac

    exec /sbin/init
}

main "$@"
