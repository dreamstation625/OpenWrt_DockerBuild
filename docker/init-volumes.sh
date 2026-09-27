#!/usr/bin/env bash
###############################################################################
# 预初始化持久化目录（把镜像里的默认配置复制到宿主机 ./data 下）
#
# 用途：
#   compose 用的是 bind mount（./data/xxx:/etc/xxx）。bind mount 不会像命名卷
#   那样自动带入镜像内容，宿主机目录为空时会把容器内目录盖成空的。
#   容器的 entrypoint 已经内置了"空目录自动恢复"兜底，所以本脚本是**可选**的。
#
#   但提前跑一遍有这些好处：
#     - 起容器前就能看到/备份默认配置
#     - 想改默认配置（比如预置 /etc/config/network）可以直接改文件
#     - 排查"配置没生效"时能确认宿主机目录里到底有没有东西
#
# 用法：
#   ./docker/init-volumes.sh                       # 用默认镜像
#   OPENWRT_IMAGE=xxx/openwrt:1.0.0 ./docker/init-volumes.sh
#   DATA_DIR=/volume1/docker/openwrt-data ./docker/init-volumes.sh
#
# 幂等：目录非空就跳过，不会覆盖已有配置。
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# 顺带读一下 .env，避免镜像 tag 跟 compose 用的不一致
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$PROJECT_DIR/.env"
    set +a
fi

IMAGE="${OPENWRT_IMAGE:-dreamstation625/openwrt:latest}"
DATA_DIR="${DATA_DIR:-./data}"
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-/opt/docker}"

# 冒号分隔：<宿主机子目录> : <容器内路径>
MAPPINGS=(
    "config:/etc/config"
    "openclash:/etc/openclash"
    # AdGuard Home 用官方 adguardhome 包，路径是全小写 /etc/adguardhome；
    # 运行时数据（过滤规则、统计库）在 /var/lib/adguardhome，必须持久化
    "adguardhome:/etc/adguardhome"
    "adguardhome-data:/var/lib/adguardhome"
    "mosdns:/etc/mosdns"
    "nftables.d:/usr/share/nftables.d"
    "docker:${DOCKER_DATA_ROOT}"
    "root:/root"
    "log:/var/log"
)

log() { printf '%s\n' "$*"; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "未找到 docker 命令"

mkdir -p "$DATA_DIR"

log "镜像: $IMAGE"
log "目标: $(cd "$DATA_DIR" && pwd)"
log

# 起一个不运行的容器，只为把文件拷出来（不需要真的启动 OpenWrt）
CID="$(docker create "$IMAGE" /bin/true 2>/dev/null)" \
    || die "创建容器失败，镜像存在吗？试试：docker pull $IMAGE"

cleanup() { docker rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

copied=0
skipped=0

for m in "${MAPPINGS[@]}"; do
    name="${m%%:*}"
    src="${m#*:}"
    dest="$DATA_DIR/$name"

    mkdir -p "$dest"

    # 非空就跳过，绝不覆盖已有配置
    if [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
        log "跳过  $name  (已有内容: $dest)"
        skipped=$((skipped + 1))
        continue
    fi

    if docker cp "$CID:$src/." "$dest/" >/dev/null 2>&1; then
        count="$(find "$dest" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
        log "已初始化  $name  ← $src  (${count} 个条目)"
        copied=$((copied + 1))
    else
        # 容器里没有这个目录（比如没装对应插件）→ 留空目录，让容器自己建
        log "跳过  $name  (镜像内不存在: $src)"
        skipped=$((skipped + 1))
    fi
done

log
log "完成：初始化 $copied 个，跳过 $skipped 个"
log
log "目录结构："
find "$DATA_DIR" -maxdepth 1 -mindepth 1 -type d -printf '  %p\n' 2>/dev/null \
    || ls -d "$DATA_DIR"/*/
log
log "接下来：docker compose up -d"
