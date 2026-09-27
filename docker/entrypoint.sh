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
###############################################################################
set -u

MARK=/etc/config/.docker-env-applied

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
main() {
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
