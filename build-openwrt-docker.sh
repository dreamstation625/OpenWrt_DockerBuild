#!/usr/bin/env bash
set -e
set -o pipefail

export FORCE_UNSAFE_CONFIGURE=1

###############################################################################
# OpenWrt x86_64 编译脚本（Docker 版）
#
# 与 build-openwrt.sh 的关系：
#   - 编译配置、插件清单、LAN/DNS/root 密码、files 默认配置、nftables 自定义
#     规则、编译日志、失败回退单线程等能力 100% 保留。
#   - 编译过程改为在 Docker 容器内执行（"openwrt 在 docker 中运行"），宿主机
#     只负责编排与产物收集。
#   - 工作目录 ./work 通过 volume 挂载进容器，源码 / feeds / dl / ccache 全部
#     持久化在宿主机，重复编译不需要重新下载，编译速度显著提升。
#
# 用法（宿主机）：
#   ./build-openwrt-docker.sh                    # 模式 0：自动，使用全部 CPU 线程
#   ./build-openwrt-docker.sh 1                  # 模式 1：使用 CPU 线程的 2/3
#   ./build-openwrt-docker.sh 2                  # 模式 2：使用 CPU 线程的一半
#   ./build-openwrt-docker.sh 3                  # 模式 3：单线程
#
#   --no-docker      不用 Docker，直接在宿主机编译（等价于原 build-openwrt.sh）
#   --in-container   容器内模式，由宿主机脚本自动带上，一般不用手写
#   --force-env      强制重建编译环境镜像
#   --env-image TAG  复用已有的编译环境镜像（CI 里配合 buildx 缓存使用）
#   --package-image  编译完成后打包成 OpenWrt 系统镜像
#   --package-only   跳过编译，直接用已有产物打包系统镜像
#   --push           打包后推送到 Docker Hub（隐含 --package-image）
#   --install-deps   容器内也重新安装一次依赖（一般不需要）
#
# GitHub Actions 适配：
#   检测到 CI=true / GITHUB_ACTIONS=true 自动进入 CI 模式：
#     - make 的完整输出写入 work/openwrt/build-logs/*.log，前台只打进度，
#       避免几十万行输出把 Actions 日志撑爆；
#     - Actions 日志折叠分组（::group::），失败时输出 ::error:: 注解；
#     - 产物目录生成 build-summary.md 并拷贝编译日志，失败也能下载排查。
#   CI 标识会透传进容器，真正跑 make 的是容器，这点必须传。
#
# 容器内手动执行：
#   docker run --rm -v "$PWD/work:/build" -v "$PWD/output:/output" \
#       -v "$PWD:/src:ro" openwrt-build-env:local \
#       bash /src/build-openwrt-docker.sh --in-container
###############################################################################

usage() {
    cat <<'USAGE'
OpenWrt x86_64 编译脚本（Docker 版）

用法（宿主机）：
  ./build-openwrt-docker.sh [模式] [选项]

  模式：
    0            自动，使用全部 CPU 线程（默认）
    1            使用 CPU 线程的 2/3
    2            使用 CPU 线程的一半
    3            单线程

  选项：
    --no-docker      不用 Docker，直接在宿主机编译（等价原 build-openwrt.sh）
    --in-container   容器内模式，由宿主机脚本自动带上，一般不用手写
    --force-env      强制重建编译环境镜像
    --env-image TAG  复用已有的编译环境镜像（CI 配合 buildx 缓存使用）
    --package-image  编译完成后打包成 OpenWrt 系统镜像
    --package-only   跳过编译，直接用已有产物打包系统镜像
    --push           打包后推送到 Docker Hub（隐含 --package-image）
    --install-deps   容器内也重新安装一次依赖（一般不需要）
    -h, --help       显示本帮助

可用环境变量覆盖：
    OPENWRT_VERSION  LAN_IP  LAN_NETMASK  LAN_GATEWAY  LAN_DNS1  LAN_DNS2
    ROOT_PASSWORD    DOCKER_DATA_ROOT     BUILD_MODE   DOWNLOAD_JOBS
    IMAGE_NAMESPACE  IMAGE_NAME           HOST_WORK_DIR HOST_OUTPUT_DIR
    ROOTFS_PARTSIZE  根分区大小（MiB，默认 2048）
    CCACHE_MAXSIZE   ccache 上限（默认 5G）
    LOG_TAIL_LINES   失败时回填的日志行数（CI 默认 400，本地 120）

GitHub Actions：
    检测到 CI=true / GITHUB_ACTIONS=true 时自动启用 CI 模式：
    日志写入文件不刷屏、Actions 日志折叠分组、失败时输出 ::error:: 注解，
    并在产物目录生成 build-summary.md 与编译日志。
    该标识会通过 docker run -e 透传进容器，容器内的 make 同样生效。

容器内手动执行：
    docker run --rm -v "$PWD/work:/build" -v "$PWD/output:/output" \
        -v "$PWD:/src:ro" openwrt-build-env:local \
        bash /src/build-openwrt-docker.sh --in-container
USAGE
}

###############################################################################
# 运行模式解析
###############################################################################
IN_CONTAINER=0
USE_DOCKER=1
FORCE_ENV=0
PACKAGE_IMAGE=0
PACKAGE_ONLY=0
PUSH_IMAGE=0
INSTALL_DEPS=0
ENV_IMAGE=""
MODE_ARG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --in-container)  IN_CONTAINER=1 ;;
        --no-docker)     USE_DOCKER=0 ;;
        --force-env)     FORCE_ENV=1 ;;
        --package-image) PACKAGE_IMAGE=1 ;;
        --package-only)  PACKAGE_ONLY=1; PACKAGE_IMAGE=1 ;;
        --push)          PUSH_IMAGE=1; PACKAGE_IMAGE=1 ;;
        --install-deps)  INSTALL_DEPS=1 ;;
        --env-image)     ENV_IMAGE="${2:-}"; shift ;;
        -h|--help)       usage; exit 0 ;;
        0|1|2|3)         MODE_ARG="$1" ;;
        *) printf '错误：未知参数 %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

###############################################################################
# 公共函数
###############################################################################
log()  { printf '%s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

###############################################################################
# GitHub Actions / CI 适配
###############################################################################
# CI 环境下有三个和本地不同的地方，必须特殊处理：
#   1) 日志量：OpenWrt 全量编译 V=s 有几十万行，直接打到 Actions 日志会被限流
#      甚至截断，失败时反而找不到关键报错。CI 下改为写入日志文件，前台只打
#      心跳，失败时再 tail 尾部（见 run_logged）。
#   2) 折叠分组：用 ::group:: / ::endgroup:: 让 Actions 日志可折叠。
#   3) 注解：失败时输出 ::error::，在 Actions 页面直接可见。
###############################################################################

ci_group_start() { [ "$IN_CI" = "1" ] && printf '::group::%s\n' "$*"; return 0; }
ci_group_end()   { [ "$IN_CI" = "1" ] && printf '::endgroup::\n';        return 0; }
ci_error()       { [ "$IN_CI" = "1" ] && printf '::error::%s\n' "$*";    return 0; }
ci_notice()      { [ "$IN_CI" = "1" ] && printf '::notice::%s\n' "$*";   return 0; }

# 失败时用多大的日志尾部（行）。CI 下默认给足，本地保持精简。
LOG_TAIL_LINES="${LOG_TAIL_LINES:-}"

# 在 CI 里执行耗时命令：完整输出进日志文件，前台只打印分钟级进度。
# 用法：run_logged <日志文件> <命令> [参数...]
run_logged() {
    local logfile="$1"; shift
    local rc=0 start elapsed

    # 本地：保持原来的实时 tee 行为，方便直接看编译过程
    if [ "$IN_CI" != "1" ]; then
        "$@" 2>&1 | tee "$logfile"
        return $?
    fi

    log "完整输出已写入: $logfile"
    log "（CI 模式：前台只打印进度，失败时会回填日志尾部）"

    # 记住调用方原本有没有开 errexit，退出前原样恢复。
    # 直接写 set -e 会在调用方本已关闭时把它强行打开。
    local errexit_on=0
    case "$-" in *e*) errexit_on=1 ;; esac

    start=$(date +%s)
    set +e
    "$@" >"$logfile" 2>&1 &
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 60
        if kill -0 "$pid" 2>/dev/null; then
            elapsed=$(( $(date +%s) - start ))
            log "[进行中] ${*} → 已跑 $((elapsed / 60)) 分 $((elapsed % 60)) 秒"
        fi
    done
    wait "$pid"
    rc=$?
    [ "$errexit_on" = "1" ] && set -e

    elapsed=$(( $(date +%s) - start ))
    log "[结束] 用时 $((elapsed / 60)) 分 $((elapsed % 60)) 秒，退出码 $rc"
    return $rc
}

# 失败时打印日志尾部；本地 120 行够看，CI 下给 400 行便于定位
fail_tail() {
    local logfile="$1"
    local lines="${LOG_TAIL_LINES:-}"
    [ -n "$lines" ] || { [ "$IN_CI" = "1" ] && lines=400 || lines=120; }
    [ -f "$logfile" ] || return 0
    echo "===== $logfile 最后 $lines 行 ====="
    tail -n "$lines" "$logfile" || true
    echo "=================================="
}

# 计算文件摘要，用于给编译环境镜像打 tag（Dockerfile 变了才重建）
file_digest() {
    if have sha256sum; then
        sha256sum "$1" | cut -c1-12
    elif have shasum; then
        shasum -a 256 "$1" | cut -c1-12
    else
        cksum "$1" | tr -d ' ' | cut -c1-12
    fi
}

# 把编译产物从工作目录收集到 ./output
collect_artifacts() {
    local src_dir="$1"
    local dst_dir="$2"

    [ -d "$src_dir" ] || { warn "未找到产物目录: $src_dir"; return 1; }

    mkdir -p "$dst_dir"
    local found=0
    local pattern
    for pattern in '*.img.gz' '*.img' '*.tar.gz' '*.squashfs' '*.vmdk' '*.vdi' 'packages' 'profiles.json' 'sha256sums'; do
        # shellcheck disable=SC2086
        for f in $src_dir/$pattern; do
            [ -e "$f" ] || continue
            cp -f "$f" "$dst_dir"/
            found=1
        done
    done

    if [ "$found" = "0" ]; then
        warn "产物目录中没有可收集的固件文件: $src_dir"
        return 1
    fi

    log "✓ 产物已收集到: $dst_dir"
    ls -lh "$dst_dir"/*.img.gz "$dst_dir"/*.tar.gz 2>/dev/null || true
}

# 用编译出的 rootfs.tar.gz 打包成 OpenWrt 系统镜像
package_system_image() {
    local rootfs="$1"

    [ -f "$rootfs" ] || die "未找到 rootfs: $rootfs"

    have docker || die "打包镜像需要 docker"

    local ctx
    ctx="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$ctx'" RETURN

    cp "$PROJECT_DIR/docker/Dockerfile.image" "$ctx/Dockerfile"
    cp "$rootfs" "$ctx/rootfs.tar.gz"

    # entrypoint 会被 COPY 进镜像，缺了它 compose 的 environment 就不生效
    [ -f "$PROJECT_DIR/docker/entrypoint.sh" ] || die "缺少 docker/entrypoint.sh"
    cp "$PROJECT_DIR/docker/entrypoint.sh" "$ctx/entrypoint.sh"

    local repo="${IMAGE_REPO}:${OPENWRT_VERSION}"
    log "正在打包 OpenWrt 系统镜像: $repo"

    ci_group_start "打包 OpenWrt 系统镜像 $repo"
    docker build \
        -f "$ctx/Dockerfile" \
        --build-arg "OPENWRT_VERSION=$OPENWRT_VERSION" \
        --build-arg "OPENWRT_BRANCH=$BRANCH" \
        -t "$repo" \
        -t "${IMAGE_REPO}:latest" \
        "$ctx"
    ci_group_end

    log "✓ 镜像打包完成: $repo (同时打了 ${IMAGE_REPO}:latest)"

    if [ "$PUSH_IMAGE" = "1" ]; then
        # 给了凭据就自己登录（本地用法）；没给就假定已登录
        # （CI 里由 docker/login-action 完成，避免重复登录）。
        if [ -n "${DOCKERHUB_USERNAME:-}" ] && [ -n "${DOCKERHUB_TOKEN:-}" ]; then
            printf '%s' "$DOCKERHUB_TOKEN" | \
                docker login -u "$DOCKERHUB_USERNAME" --password-stdin
        fi
        ci_group_start "推送镜像到 Docker Hub"
        docker push "$repo"
        docker push "${IMAGE_REPO}:latest"
        ci_group_end
        log "✓ 已推送到 Docker Hub: $repo"
        ci_notice "已推送 ${repo} 与 ${IMAGE_REPO}:latest"
    fi
}

###############################################################################
# 编译优化说明
###############################################################################
# 本脚本已进行以下优化以缩短编译时间：
# 1. 启用 ccache 缓存（如已安装），加速重复编译
# 2. 使用并行下载（8线程）加速源码包下载
# 3. 支持编译线程模式参数：0 自动，1 为 2/3，2 为一半，3 为单线程
# 4. 减少不必要的清理操作，避免重复工作
# 5. 使用浅克隆（--depth=1）减少 Git 下载量
# 6. 智能跳过已存在的资源（主题、源码等）
# 7. 编译失败时自动切换到单线程模式查看详细错误
# 8. Docker 模式下源码 / feeds / dl / ccache 持久化在宿主机 ./work，
#    容器只提供编译环境，重复编译无需重新下载与重建工具链
###############################################################################

###############################################################################
# 基础配置
###############################################################################

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# CI 环境检测。容器内也要能识别，所以这个值会通过 docker run -e 传进去。
IN_CI=0
if [ "${CI:-}" = "true" ] || [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    IN_CI=1
fi

# 版本号：环境变量优先，其次读取仓库根目录的 VERSION 文件
if [ -z "${OPENWRT_VERSION:-}" ] && [ -f "$PROJECT_DIR/VERSION" ]; then
    OPENWRT_VERSION="$(tr -d ' \t\r\n' < "$PROJECT_DIR/VERSION")"
fi
OPENWRT_VERSION="${OPENWRT_VERSION:-0.0.0}"

# Docker 镜像（推送到 Docker Hub）
IMAGE_NAMESPACE="${IMAGE_NAMESPACE:-dreamstation625}"
IMAGE_NAME="${IMAGE_NAME:-openwrt}"
IMAGE_REPO="${IMAGE_NAMESPACE}/${IMAGE_NAME}"

# 编译环境镜像（本地使用；CI 里可用 --env-image 复用 buildx 构建结果）
ENV_IMAGE_PREFIX="${ENV_IMAGE_PREFIX:-openwrt-build-env}"

# 宿主机工作目录 / 产物目录 / 镜像构建上下文
HOST_WORK_DIR="${HOST_WORK_DIR:-$PROJECT_DIR/work}"
HOST_OUTPUT_DIR="${HOST_OUTPUT_DIR:-$PROJECT_DIR/output}"

# 工作目录：容器内固定为 /build；--no-docker 时沿用原来的 $HOME/openwrt-full-build
if [ "$IN_CONTAINER" = "1" ] || [ "$USE_DOCKER" = "1" ]; then
    WORKDIR="${WORKDIR:-/build}"
else
    WORKDIR="${WORKDIR:-$HOME/openwrt-full-build}"
fi

REPO_URL="${REPO_URL:-https://github.com/openwrt/openwrt.git}"
BRANCH="${BRANCH:-openwrt-25.12}"

LAN_IP="${LAN_IP:-192.168.31.254}"
LAN_NETMASK="${LAN_NETMASK:-255.255.255.0}"
LAN_GATEWAY="${LAN_GATEWAY:-192.168.31.1}"
LAN_DNS1="${LAN_DNS1:-223.5.5.5}"
LAN_DNS2="${LAN_DNS2:-119.29.29.29}"

ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-/opt/docker}"

# 根文件系统分区大小（MiB）。影响 combined/ext4 镜像里 rootfs 分区的容量。
# 默认 2048（2G），刷机后在 LuCI 里看到的可用空间由它决定。
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-2048}"

# 编译优化配置
# 用法：
#   ./build-openwrt-docker.sh        # 默认模式 0：自动，使用全部 CPU 线程
#   ./build-openwrt-docker.sh 1      # 模式 1：使用 CPU 线程的 2/3
#   ./build-openwrt-docker.sh 2      # 模式 2：使用 CPU 线程的一半
#   ./build-openwrt-docker.sh 3      # 模式 3：单线程
# 第一个参数为编译模式；不传则默认 0。不再读取其他线程参数。
BUILD_MODE="${BUILD_MODE:-${MODE_ARG:-0}}"
if have nproc; then
    CPU_THREADS="$(nproc)"
else
    CPU_THREADS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
fi

case "$BUILD_MODE" in
    0)
        DEFAULT_BUILD_THREADS="$CPU_THREADS"
        BUILD_MODE_DESC="自动"
        ;;
    1)
        DEFAULT_BUILD_THREADS=$(((CPU_THREADS * 2 + 2) / 3))
        BUILD_MODE_DESC="2/3 线程"
        ;;
    2)
        DEFAULT_BUILD_THREADS=$((CPU_THREADS / 2))
        BUILD_MODE_DESC="一半线程"
        ;;
    3)
        DEFAULT_BUILD_THREADS=1
        BUILD_MODE_DESC="单线程"
        ;;
    *)
        echo "错误：未知编译模式 '$BUILD_MODE'，可选值：0=自动，1=2/3，2=一半，3=单线程"
        exit 1
        ;;
esac

[ "$DEFAULT_BUILD_THREADS" -lt 1 ] && DEFAULT_BUILD_THREADS=1
[ "$DEFAULT_BUILD_THREADS" -gt "$CPU_THREADS" ] && DEFAULT_BUILD_THREADS="$CPU_THREADS"

BUILD_THREADS="$DEFAULT_BUILD_THREADS"
DOWNLOAD_JOBS="${DOWNLOAD_JOBS:-8}"

###############################################################################
# 只打包：拿现有工作目录里已经编好的 rootfs 打包镜像，不重新编译
###############################################################################
if [ "$PACKAGE_ONLY" = "1" ]; then
    ROOTFS_TAR="$(ls -1 "$HOST_WORK_DIR"/openwrt/bin/targets/*/*/*rootfs.tar.gz 2>/dev/null | head -n 1 || true)"
    [ -n "$ROOTFS_TAR" ] || die "未找到 rootfs.tar.gz，请先完成一次编译"
    log "使用 rootfs: $ROOTFS_TAR"
    package_system_image "$ROOTFS_TAR"
    exit 0
fi

###############################################################################
# Docker 编排：宿主机不直接编译，而是交给容器执行
###############################################################################
if [ "$IN_CONTAINER" = "0" ] && [ "$USE_DOCKER" = "1" ]; then

    have docker || die "未找到 docker。请安装 Docker，或改用 --no-docker 在宿主机直接编译"

    # 编译环境镜像：Dockerfile.build 内容变了才需要重建
    if [ -z "$ENV_IMAGE" ]; then
        ENV_IMAGE="${ENV_IMAGE_PREFIX}:$(file_digest "$PROJECT_DIR/docker/Dockerfile.build")"
    fi

    if [ "$FORCE_ENV" = "1" ] || ! docker image inspect "$ENV_IMAGE" >/dev/null 2>&1; then
        echo "正在构建编译环境镜像: $ENV_IMAGE"
        docker build -f "$PROJECT_DIR/docker/Dockerfile.build" -t "$ENV_IMAGE" "$PROJECT_DIR"
        echo "✓ 编译环境镜像就绪"
    else
        echo "✓ 编译环境镜像已存在，跳过构建: $ENV_IMAGE"
    fi

    mkdir -p "$HOST_WORK_DIR" "$HOST_OUTPUT_DIR"

    DOCKER_RUN_ARGS=(
        --rm
        -v "$HOST_WORK_DIR:/build"
        -v "$HOST_OUTPUT_DIR:/output"
        -v "$PROJECT_DIR:/src:ro"
        -e "HOME=/build"
        -e "OPENWRT_VERSION=$OPENWRT_VERSION"
        -e "BUILD_MODE=$BUILD_MODE"
        -e "DOWNLOAD_JOBS=$DOWNLOAD_JOBS"
        -e "REPO_URL=$REPO_URL"
        -e "BRANCH=$BRANCH"
        -e "LAN_IP=$LAN_IP"
        -e "LAN_NETMASK=$LAN_NETMASK"
        -e "LAN_GATEWAY=$LAN_GATEWAY"
        -e "LAN_DNS1=$LAN_DNS1"
        -e "LAN_DNS2=$LAN_DNS2"
        -e "ROOT_PASSWORD=$ROOT_PASSWORD"
        -e "DOCKER_DATA_ROOT=$DOCKER_DATA_ROOT"
        -e "ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE"
        -e "CCACHE_MAXSIZE=${CCACHE_MAXSIZE:-5G}"
        -w /build
    )

    # CI 标识必须透传进容器：真正的 make 是在容器里跑的，
    # 容器不知道自己在 CI 就不会走日志静默与分组逻辑。
    if [ "$IN_CI" = "1" ]; then
        DOCKER_RUN_ARGS+=(
            -e "CI=true"
            -e "GITHUB_ACTIONS=${GITHUB_ACTIONS:-true}"
            -e "GITHUB_RUN_ID=${GITHUB_RUN_ID:-}"
            -e "GITHUB_SHA=${GITHUB_SHA:-}"
        )
        if [ -n "${LOG_TAIL_LINES:-}" ]; then
            DOCKER_RUN_ARGS+=( -e "LOG_TAIL_LINES=$LOG_TAIL_LINES" )
        fi
    fi

    # Linux 下用当前用户身份编译，避免 ./work 里出现 root 属主文件
    if [ "$(uname -s)" = "Linux" ]; then
        DOCKER_RUN_ARGS+=( --user "$(id -u):$(id -g)" )
    fi

    echo "=========================================="
    echo "  OpenWrt 编译（Docker 模式）"
    echo "=========================================="
    echo "版本号    : $OPENWRT_VERSION"
    echo "环境镜像  : $ENV_IMAGE"
    echo "产品镜像  : ${IMAGE_REPO}:${OPENWRT_VERSION}"
    echo "工作目录  : $HOST_WORK_DIR -> /build"
    echo "产物目录  : $HOST_OUTPUT_DIR -> /output"
    echo "编译模式  : $BUILD_MODE ($BUILD_MODE_DESC)"
    echo "编译线程  : $BUILD_THREADS"
    echo "下载线程  : $DOWNLOAD_JOBS"
    echo "=========================================="

    ci_group_start "OpenWrt 编译（容器内 $ENV_IMAGE）"
    docker run "${DOCKER_RUN_ARGS[@]}" "$ENV_IMAGE" \
        bash /src/build-openwrt-docker.sh --in-container
    ci_group_end

    echo
    echo "✓ 容器内编译完成，产物目录: $HOST_OUTPUT_DIR"

    if [ "$PACKAGE_IMAGE" = "1" ]; then
        ROOTFS_TAR="$(ls -1 "$HOST_WORK_DIR"/openwrt/bin/targets/*/*/*rootfs.tar.gz 2>/dev/null | head -n 1 || true)"
        if [ -z "$ROOTFS_TAR" ]; then
            die "未找到 rootfs.tar.gz，无法打包系统镜像（请确认 CONFIG_TARGET_ROOTFS_TARGZ=y）"
        fi
        package_system_image "$ROOTFS_TAR"
    else
        echo
        echo "如需打包成可直接 docker compose 部署的 OpenWrt 系统镜像，执行："
        echo "  ./build-openwrt-docker.sh --package-image"
        echo "如需打包并推送到 Docker Hub，执行："
        echo "  ./build-openwrt-docker.sh --push"
    fi

    exit 0
fi

echo "=========================================="
echo "  OpenWrt 快速编译脚本（优化版）"
echo "=========================================="
echo "CPU 核心数: $CPU_THREADS"
echo "编译模式: $BUILD_MODE ($BUILD_MODE_DESC)"
echo "编译线程数: $BUILD_THREADS"
echo "下载线程数: $DOWNLOAD_JOBS"
if command -v ccache &>/dev/null; then
    echo "ccache: 已启用 ✓"
else
    echo "ccache: 未安装（建议安装以加速编译: apt install ccache）"
fi
echo "=========================================="
echo

# 启用 ccache 加速编译（如果已安装）
if command -v ccache &>/dev/null; then
    export USE_CCACHE=1
    export CCACHE_DIR="$WORKDIR/.ccache"
    export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-5G}"
    echo "✓ ccache 已启用，缓存目录: $CCACHE_DIR"
fi

###############################################################################
# 安装依赖（容器内已由编译环境镜像预装，默认跳过）
###############################################################################

if [ "$IN_CONTAINER" = "1" ] && [ "$INSTALL_DEPS" = "0" ]; then
    echo "✓ 依赖由编译环境镜像提供，跳过安装"
    for tool in git make gcc python3 rsync; do
        have "$tool" || die "编译环境镜像缺少 $tool，请用 --force-env 重建镜像"
    done
else
    echo "正在安装编译依赖..."
    apt update -qq

    apt install -y \
    build-essential clang flex bison g++ gawk gcc-multilib gettext git \
    libncurses5-dev libssl-dev python3 python3-distutils python3-setuptools \
    rsync unzip zlib1g-dev file wget curl zstd libelf-dev ecj fastjar \
    java-propose-classpath libxml-parser-perl ocaml-nox ocaml ocaml-findlib \
    libpcre3-dev subversion swig time xsltproc openssl \
    ccache quilt

    echo "✓ 依赖安装完成"
fi

###############################################################################
# 下载源码（优化：使用浅克隆和单分支）
###############################################################################

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# 容器内可能以与挂载目录不同的 uid 运行，git 会拒绝操作，这里显式放行
git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$WORKDIR/openwrt" || \
    git config --global --add safe.directory "$WORKDIR/openwrt" 2>/dev/null || true

if [ ! -d openwrt ]; then
    echo "正在克隆 OpenWrt 源码（浅克隆，仅当前分支）..."
    git clone --depth=1 --single-branch -b "$BRANCH" "$REPO_URL" openwrt
    echo "✓ 源码克隆完成"
else
    echo "✓ 源码已存在，跳过克隆"
fi

cd openwrt

# 仅在需要时更新（节省时间）
echo "检查源码更新..."
git fetch --depth=1 origin "$BRANCH" 2>/dev/null || true
git reset --hard "origin/$BRANCH" 2>/dev/null || true
echo "✓ 源码更新检查完成"

###############################################################################
# feeds（优化：减少清理操作，加速更新）
###############################################################################

cat > feeds.conf.default <<'EOF'
src-git packages https://github.com/openwrt/packages.git;openwrt-25.12
src-git luci https://github.com/openwrt/luci.git;openwrt-25.12
src-git routing https://github.com/openwrt/routing.git;openwrt-25.12

# OpenClash
src-git openclash https://github.com/vernesong/OpenClash.git

# Docker 管理界面
src-git dockerman https://github.com/lisaac/luci-app-dockerman.git

# 磁盘管理
src-git diskman https://github.com/lisaac/luci-app-diskman.git

# 高级设置
src-git advancedplus https://github.com/sirpdboy/luci-app-advancedplus.git

# 系统控制
src-git syscontrol https://github.com/bobbyunknown/luci-app-syscontrol.git

# AdGuard Home is provided by the official luci feed on openwrt-25.12

# MosDNS
src-git mosdns https://github.com/sbwml/luci-app-mosdns.git
EOF

ci_group_start "更新并安装 feeds"
echo "正在更新 feeds..."
# 优化：不清理所有 feeds，只更新必要的
./scripts/feeds update -a 2>&1 | tail -20
echo "正在安装 feeds 包..."
./scripts/feeds install -a 2>&1 | tail -20
ci_group_end

FIREWALL_MENU="package/feeds/luci/luci-app-firewall/root/usr/share/luci/menu.d/luci-app-firewall.json"
if [ -f "$FIREWALL_MENU" ]; then
    python3 - <<'PY'
import json
from pathlib import Path

menu_path = Path("package/feeds/luci/luci-app-firewall/root/usr/share/luci/menu.d/luci-app-firewall.json")
data = json.loads(menu_path.read_text(encoding="utf-8"))
data["admin/network/firewall/custom"] = {
    "title": "自定义规则",
    "order": 90,
    "action": {
        "type": "view",
        "path": "firewall/custom"
    },
    "depends": {
        "acl": [ "luci-app-firewall" ]
    }
}
menu_path.write_text(json.dumps(data, ensure_ascii=False, indent="\t") + "\n", encoding="utf-8")
PY
fi

FIREWALL_ACL="package/feeds/luci/luci-app-firewall/root/usr/share/rpcd/acl.d/luci-app-firewall.json"
if [ -f "$FIREWALL_ACL" ]; then
    python3 - <<'PY'
import json
from pathlib import Path

acl_path = Path("package/feeds/luci/luci-app-firewall/root/usr/share/rpcd/acl.d/luci-app-firewall.json")
data = json.loads(acl_path.read_text(encoding="utf-8"))
app = data.setdefault("luci-app-firewall", {})
read = app.setdefault("read", {})
write = app.setdefault("write", {})
read.setdefault("file", {})["/usr/share/nftables.d/chain-pre/mangle_prerouting/99-custom.nft"] = [ "read" ]
write.setdefault("file", {})["/usr/share/nftables.d/chain-pre/mangle_prerouting/99-custom.nft"] = [ "write" ]
write.setdefault("ubus", {})["file"] = [ "exec" ]
acl_path.write_text(json.dumps(data, ensure_ascii=False, indent="\t") + "\n", encoding="utf-8")
PY
fi

# Use the classic AdGuardHome LuCI UI with core update and redirect controls.
# The official luci feed also provides a package with the same name, so remove
# both its source and feed symlink before adding the custom UI.
rm -rf feeds/luci/applications/luci-app-adguardhome
rm -rf package/feeds/luci/luci-app-adguardhome
rm -rf tmp/info/.packageinfo-feeds_luci_luci-app-adguardhome
echo "✓ feeds 更新完成"

###############################################################################
# Argon 主题（优化：仅在不存在时克隆）
###############################################################################

mkdir -p package/custom
if [ ! -d package/custom/luci-theme-argon ]; then
    echo "正在克隆 Argon 主题..."
    git clone --depth=1 \
    https://github.com/jerrykuku/luci-theme-argon.git \
    package/custom/luci-theme-argon
    echo "✓ Argon 主题克隆完成"
else
    echo "✓ Argon 主题已存在，跳过克隆"
fi

echo "Installing classic AdGuardHome LuCI UI..."
rm -rf package/custom/luci-app-adguardhome
git clone --depth=1 \
https://github.com/rufengsuixing/luci-app-adguardhome.git \
package/custom/luci-app-adguardhome
echo "Classic AdGuardHome LuCI UI installed"

# Force OpenWrt to rebuild package metadata after replacing the same-name LuCI app.
rm -rf tmp/info tmp/.packageinfo* tmp/.config-package.in

###############################################################################
# .config 配置生成与修正
###############################################################################

echo "正在生成初始配置..."

cd "$WORKDIR/openwrt"

rm -f .config

cat > .config <<'EOF'
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_x86_64_DEVICE_generic=y

CONFIG_TARGET_IMAGES_GZIP=y
CONFIG_TARGET_ROOTFS_SQUASHFS=y
CONFIG_TARGET_ROOTFS_TARGZ=y
# CONFIG_TARGET_ROOTFS_EXT4FS is not set
# CONFIG_TARGET_IMAGES_PAD is not set
CONFIG_GRUB_IMAGES=y
CONFIG_EFI_IMAGES=y
CONFIG_TARGET_ROOTFS_PARTSIZE=2048

###############################################################################
# 软件包管理：OpenWrt 25.12 使用 apk
###############################################################################

CONFIG_USE_APK=y
CONFIG_PACKAGE_apk=y

###############################################################################
# LuCI 基础
###############################################################################

CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-light=y
CONFIG_PACKAGE_luci-base=y

CONFIG_PACKAGE_luci-mod-admin-full=y
CONFIG_PACKAGE_luci-mod-status=y
CONFIG_PACKAGE_luci-mod-system=y
CONFIG_PACKAGE_luci-mod-network=y
CONFIG_PACKAGE_luci-mod-rpc=y

CONFIG_PACKAGE_luci-compat=y
CONFIG_PACKAGE_luci-lib-fs=y

CONFIG_PACKAGE_rpcd=y
CONFIG_PACKAGE_rpcd-mod-file=y
CONFIG_PACKAGE_rpcd-mod-iwinfo=y
CONFIG_PACKAGE_rpcd-mod-luci=y
CONFIG_PACKAGE_rpcd-mod-rrdns=y

###############################################################################
# LuCI Web 服务
###############################################################################

CONFIG_PACKAGE_luci-nginx=y

###############################################################################
# 主题
###############################################################################

CONFIG_PACKAGE_luci-theme-argon=y

###############################################################################
# LuCI 管理页面
###############################################################################

CONFIG_PACKAGE_luci-app-firewall=y
CONFIG_PACKAGE_luci-app-firewall4=y
# opkg 软件包管理
CONFIG_PACKAGE_luci-app-package-manager=y
CONFIG_PACKAGE_luci-app-filemanager=y
CONFIG_PACKAGE_luci-app-upnp=y
CONFIG_PACKAGE_luci-app-ttyd=y

###############################################################################
# 第三方插件
###############################################################################

CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-app-diskman=y
CONFIG_PACKAGE_luci-app-advancedplus=y
CONFIG_PACKAGE_luci-app-syscontrol=y

# AdGuard Home
CONFIG_PACKAGE_luci-app-adguardhome=y

# MosDNS
CONFIG_PACKAGE_luci-app-mosdns=y

# 磁盘工具
CONFIG_PACKAGE_luci-app-hd-idle=y

###############################################################################
# DNS 相关工具
###############################################################################

# AdGuard Home
CONFIG_PACKAGE_adguardhome=y

# MosDNS
CONFIG_PACKAGE_mosdns=y
CONFIG_PACKAGE_v2ray-geoip=y
CONFIG_PACKAGE_v2ray-geosite=y

###############################################################################
# Docker
###############################################################################

CONFIG_PACKAGE_docker=y
CONFIG_PACKAGE_dockerd=y

###############################################################################
# 网络 / 协议
###############################################################################

CONFIG_PACKAGE_dnsmasq-full=y
# CONFIG_PACKAGE_dnsmasq is not set
CONFIG_PACKAGE_ip-full=y
CONFIG_PACKAGE_conntrack=y
CONFIG_PACKAGE_kmod-nf-conntrack-netlink=y
CONFIG_PACKAGE_resolveip=y
CONFIG_PACKAGE_ppp=y
CONFIG_PACKAGE_ppp-mod-pppoe=y
CONFIG_PACKAGE_ds-lite=y
CONFIG_PACKAGE_luci-proto-wireguard=y
CONFIG_PACKAGE_miniupnpd=y

###############################################################################
# USB / 文件系统
###############################################################################

CONFIG_PACKAGE_kmod-usb-storage=y
CONFIG_PACKAGE_kmod-usb3=y
CONFIG_PACKAGE_kmod-usb-hid=y
CONFIG_PACKAGE_block-mount=y
CONFIG_PACKAGE_e2fsprogs=y
CONFIG_PACKAGE_kmod-fs-ext4=y
CONFIG_PACKAGE_kmod-fs-f2fs=y
CONFIG_PACKAGE_kmod-fs-vfat=y
CONFIG_PACKAGE_kmod-fs-exfat=y
CONFIG_PACKAGE_kmod-fs-ntfs3=y
CONFIG_PACKAGE_exfat-mkfs=y
CONFIG_PACKAGE_ntfs3-mount=y
CONFIG_PACKAGE_mkf2fs=y
CONFIG_PACKAGE_parted=y
CONFIG_PACKAGE_gdisk=y
CONFIG_PACKAGE_cfdisk=y
CONFIG_PACKAGE_sgdisk=y
CONFIG_PACKAGE_wipefs=y
CONFIG_PACKAGE_blockdev=y
CONFIG_PACKAGE_smartmontools=y
CONFIG_PACKAGE_hdparm=y
CONFIG_PACKAGE_hd-idle=y
CONFIG_PACKAGE_blkid=y

###############################################################################
# 常用网卡驱动
###############################################################################

CONFIG_PACKAGE_kmod-e1000=y
CONFIG_PACKAGE_kmod-e1000e=y
CONFIG_PACKAGE_kmod-igb=y
CONFIG_PACKAGE_kmod-igc=y
CONFIG_PACKAGE_kmod-ixgbe=y
CONFIG_PACKAGE_kmod-r8125=y
CONFIG_PACKAGE_kmod-r8126=y
CONFIG_PACKAGE_kmod-r8168=y
CONFIG_PACKAGE_kmod-vmxnet3=y
CONFIG_PACKAGE_kmod-tg3=y
CONFIG_PACKAGE_kmod-atlantic=y

###############################################################################
# firewall4 + nftables
###############################################################################

CONFIG_PACKAGE_firewall4=y
CONFIG_PACKAGE_nftables=y
CONFIG_PACKAGE_kmod-nft-tproxy=y
CONFIG_PACKAGE_kmod-nft-socket=y

###############################################################################
# 常用工具
###############################################################################

CONFIG_PACKAGE_bash=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_wget-ssl=y
CONFIG_PACKAGE_nano=y
CONFIG_PACKAGE_unzip=y
CONFIG_PACKAGE_htop=y
CONFIG_PACKAGE_xz=y
CONFIG_PACKAGE_lsblk=y
CONFIG_PACKAGE_fdisk=y
CONFIG_PACKAGE_partx-utils=y
CONFIG_PACKAGE_pciutils=y
CONFIG_PACKAGE_usbutils=y
CONFIG_PACKAGE_openssh-sftp-server=y
CONFIG_PACKAGE_zram-swap=y
CONFIG_PACKAGE_lm-sensors-detect=y
CONFIG_PACKAGE_coremark=y
CONFIG_PACKAGE_openssl-util=y
CONFIG_PACKAGE_ca-bundle=y
CONFIG_PACKAGE_ca-certificates=y

###############################################################################
# 中文语言包
###############################################################################

CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
CONFIG_PACKAGE_luci-i18n-firewall-zh-cn=y
CONFIG_PACKAGE_luci-i18n-firewall4-zh-cn=y
CONFIG_PACKAGE_luci-i18n-package-manager-zh-cn=y
CONFIG_PACKAGE_luci-i18n-system-zh-cn=y
CONFIG_PACKAGE_luci-i18n-nginx-zh-cn=y
CONFIG_PACKAGE_luci-i18n-dockerman-zh-cn=y
CONFIG_PACKAGE_luci-i18n-diskman-zh-cn=y
CONFIG_PACKAGE_luci-i18n-filemanager-zh-cn=y
CONFIG_PACKAGE_luci-i18n-ttyd-zh-cn=y
CONFIG_PACKAGE_luci-i18n-upnp-zh-cn=y
CONFIG_PACKAGE_luci-i18n-hd-idle-zh-cn=y
CONFIG_PACKAGE_luci-i18n-advancedplus-zh-cn=y
CONFIG_PACKAGE_luci-i18n-syscontrol-zh-cn=y
CONFIG_PACKAGE_luci-i18n-mosdns-zh-cn=y

CONFIG_LUCI_LANG_zh-cn=y
CONFIG_LUCI_LANG_zh_Hans=y
EOF

make defconfig

###############################################################################
# 强制修正配置
###############################################################################

echo "正在强制修正配置..."

sed -i '/^CONFIG_TARGET_ROOTFS_SQUASHFS=/d' .config
sed -i '/^CONFIG_TARGET_ROOTFS_TARGZ=/d' .config
sed -i '/^CONFIG_TARGET_ROOTFS_EXT4FS=/d' .config
sed -i '/^# CONFIG_TARGET_ROOTFS_EXT4FS is not set/d' .config
sed -i '/^CONFIG_TARGET_IMAGES_PAD=/d' .config
sed -i '/^# CONFIG_TARGET_IMAGES_PAD is not set/d' .config
sed -i '/^CONFIG_TARGET_ROOTFS_PARTSIZE=/d' .config

sed -i '/^CONFIG_USE_APK=/d' .config
sed -i '/^# CONFIG_USE_APK is not set/d' .config
sed -i '/^CONFIG_PACKAGE_apk=/d' .config
sed -i '/^# CONFIG_PACKAGE_apk is not set/d' .config
sed -i '/^CONFIG_PACKAGE_opkg=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-app-opkg=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-app-package-manager=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-app-diskman=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-app-hd-idle=/d' .config
sed -i '/^CONFIG_PACKAGE_pbr=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-app-pbr=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-i18n-diskman-zh-cn=/d' .config

sed -i '/^CONFIG_PACKAGE_luci-i18n-base-zh-cn=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-i18n-firewall-zh-cn=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-i18n-firewall4-zh-cn=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-i18n-opkg-zh-cn=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-i18n-package-manager-zh-cn=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-i18n-system-zh-cn=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-i18n-nginx-zh-cn=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-i18n-dockerman-zh-cn=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-i18n-filemanager-zh-cn=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-i18n-ttyd-zh-cn=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-i18n-upnp-zh-cn=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-i18n-pbr-zh-cn=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-i18n-hd-idle-zh-cn=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-i18n-advancedplus-zh-cn=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-i18n-syscontrol-zh-cn=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-i18n-adguardhome-zh-cn=/d' .config
sed -i '/^CONFIG_PACKAGE_luci-i18n-mosdns-zh-cn=/d' .config
sed -i '/^CONFIG_LUCI_LANG_zh-cn=/d' .config
sed -i '/^CONFIG_LUCI_LANG_zh_Hans=/d' .config

cat >> .config <<'EOF'

CONFIG_TARGET_ROOTFS_SQUASHFS=y
CONFIG_TARGET_ROOTFS_TARGZ=y
# CONFIG_TARGET_ROOTFS_EXT4FS is not set
# CONFIG_TARGET_IMAGES_PAD is not set
CONFIG_TARGET_ROOTFS_PARTSIZE=2048

###############################################################################
# apk + 常用管理插件
###############################################################################

CONFIG_USE_APK=y
CONFIG_PACKAGE_apk=y
CONFIG_PACKAGE_luci-app-package-manager=y
CONFIG_PACKAGE_luci-app-diskman=y
CONFIG_PACKAGE_luci-app-hd-idle=y
CONFIG_PACKAGE_ip-full=y
CONFIG_PACKAGE_conntrack=y
CONFIG_PACKAGE_kmod-nf-conntrack-netlink=y

###############################################################################
# 强制中文语言包
###############################################################################

CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
CONFIG_PACKAGE_luci-i18n-firewall-zh-cn=y
CONFIG_PACKAGE_luci-i18n-firewall4-zh-cn=y
CONFIG_PACKAGE_luci-i18n-package-manager-zh-cn=y
CONFIG_PACKAGE_luci-i18n-system-zh-cn=y
CONFIG_PACKAGE_luci-i18n-nginx-zh-cn=y
CONFIG_PACKAGE_luci-i18n-dockerman-zh-cn=y
CONFIG_PACKAGE_luci-i18n-diskman-zh-cn=y
CONFIG_PACKAGE_luci-i18n-filemanager-zh-cn=y
CONFIG_PACKAGE_luci-i18n-ttyd-zh-cn=y
CONFIG_PACKAGE_luci-i18n-upnp-zh-cn=y
CONFIG_PACKAGE_luci-i18n-hd-idle-zh-cn=y
CONFIG_PACKAGE_luci-i18n-advancedplus-zh-cn=y
CONFIG_PACKAGE_luci-i18n-syscontrol-zh-cn=y
CONFIG_PACKAGE_luci-i18n-mosdns-zh-cn=y

CONFIG_LUCI_LANG_zh-cn=y
CONFIG_LUCI_LANG_zh_Hans=y
EOF

# 根分区大小统一覆盖：heredoc 里写的是默认值 2048，
# 这里再按 ROOTFS_PARTSIZE 环境变量刷一遍，改分区不用动脚本。
sed -i "s/^CONFIG_TARGET_ROOTFS_PARTSIZE=.*/CONFIG_TARGET_ROOTFS_PARTSIZE=${ROOTFS_PARTSIZE}/" .config
echo "✓ 根分区大小: ${ROOTFS_PARTSIZE} MiB"

echo "正在生成最终配置..."
make defconfig
echo "✓ 配置生成完成"

# 构建版本号写进 .config，include/version.mk 会读取，
# 最终体现在固件 /etc/openwrt_release 的 DISTRIB_RELEASE 上。
{
    echo ""
    echo "CONFIG_VERSION_NUMBER=\"${OPENWRT_VERSION}\""
    echo "CONFIG_VERSION_CODE=\"\""
} >> .config
echo "✓ 构建版本号: ${OPENWRT_VERSION}"

# 显示配置统计信息
if [ -f .config ]; then
    TOTAL_PACKAGES=$(grep -c "^CONFIG_PACKAGE_" .config || true)
    ENABLED_PACKAGES=$(grep -c "^CONFIG_PACKAGE_.*=y$" .config || true)
    echo "✓ 总包数: $TOTAL_PACKAGES, 启用包数: $ENABLED_PACKAGES"
fi

###############################################################################
# 默认配置 files
###############################################################################

echo "正在配置默认文件..."

rm -rf files
mkdir -p files/etc/config
mkdir -p files/etc/init.d
mkdir -p files/etc/uci-defaults
mkdir -p files/usr/share/rpcd/acl.d
mkdir -p files/usr/share/nftables.d/chain-pre/mangle_prerouting
mkdir -p files/www/luci-static/resources/view/firewall

# 把构建版本号落到设备上，方便开机后核对（cat /etc/openwrt-build-version）
printf '%s\n' "${OPENWRT_VERSION}" > files/etc/openwrt-build-version

cat > files/etc/config/network <<EOF
config interface 'loopback'
        option device 'lo'
        option proto 'static'
        option ipaddr '127.0.0.1'
        option netmask '255.0.0.0'

config globals 'globals'
        option ula_prefix 'auto'

config device
        option name 'br-lan'
        option type 'bridge'
        list ports 'eth0'

config interface 'lan'
        option device 'br-lan'
        option proto 'static'
        option ipaddr '${LAN_IP}'
        option netmask '${LAN_NETMASK}'
        option gateway '${LAN_GATEWAY}'
        list dns '${LAN_DNS1}'
        list dns '${LAN_DNS2}'
EOF

cat > files/etc/uci-defaults/99-default-settings <<EOF
#!/bin/sh

# 主机名 / 时区 / 主题 / 语言 / 密码 / LAN 在容器里由 /usr/bin/openwrt-entrypoint.sh
# 按环境变量设置。uci-defaults 是在 /sbin/init 之后才执行的，这里如果再设一遍，
# 会把容器里已经持久化并改过的配置覆盖掉。
# 所以这些默认值只在物理机（刷机）场景应用，容器场景交给 entrypoint。
if [ ! -f /.dockerenv ] && ! grep -qaE 'docker|containerd|kubepods' /proc/1/cgroup 2>/dev/null; then
        PASSWD=\$(openssl passwd -1 '${ROOT_PASSWORD}')
        sed -i "s#^root::#root:\${PASSWD}:#g" /etc/shadow

        uci set system.@system[0].hostname='OpenWrt'
        uci set system.@system[0].zonename='Asia/Shanghai'
        uci set system.@system[0].timezone='CST-8'

        uci set luci.main.mediaurlbase='/luci-static/argon'
        uci set luci.main.lang='zh-cn'
        uci set luci.main.lang_auto='0'

        uci commit system
        uci commit luci
fi

# 容器网络适配（LAN 直连 eth0、去掉 br-lan 桥）已移到 entrypoint：
# 它在 /sbin/init 之前跑，能保证 macvlan 场景下网络正确。这里不再重复处理。

if [ -f /etc/config/nginx ]; then
        uci -q delete nginx._lan.redirect_https
        uci -q delete nginx._lan.listen_https
        uci -q delete nginx._lan.ssl_certificate
        uci -q delete nginx._lan.ssl_certificate_key
        uci -q delete nginx._lan2
        uci add_list nginx._lan.listen='0.0.0.0:80'
        uci add_list nginx._lan.listen='[::]:80'
        uci commit nginx
fi

if [ -f /etc/config/uhttpd ]; then
        uci -q delete uhttpd.main.redirect_https
        uci -q delete uhttpd.main.listen_https
        uci -q delete uhttpd.main.cert
        uci -q delete uhttpd.main.key
        uci commit uhttpd
fi

mkdir -p '${DOCKER_DATA_ROOT}'
if [ -f /etc/config/dockerd ]; then
        uci set dockerd.globals.data_root='${DOCKER_DATA_ROOT}'
        uci commit dockerd
fi

if [ -f /etc/config/dockerman ]; then
        uci set dockerman.local.daemon_data_root='${DOCKER_DATA_ROOT}'
        uci commit dockerman
fi

touch /etc/sysupgrade.conf
for backup_path in \
        /etc/config/dockerd \
        /etc/config/dockerman \
        '${DOCKER_DATA_ROOT}'
do
        grep -qxF "\${backup_path}" /etc/sysupgrade.conf || echo "\${backup_path}" >> /etc/sysupgrade.conf
done

# 25.12 uses apk repositories. Third-party feeds built into this firmware do not
# have package repositories on downloads.openwrt.org, so keep only real feeds.
if [ -f /etc/apk/repositories.d/distfeeds.list ]; then
        sed -i \
                -e '/\/openclash\/packages\.adb$/d' \
                -e '/\/dockerman\/packages\.adb$/d' \
                -e '/\/diskman\/packages\.adb$/d' \
                -e '/\/advancedplus\/packages\.adb$/d' \
                -e '/\/syscontrol\/packages\.adb$/d' \
                -e '/\/mosdns\/packages\.adb$/d' \
                /etc/apk/repositories.d/distfeeds.list
fi

rm -rf /tmp/luci-*

/etc/init.d/nginx enable >/dev/null 2>&1 || true
/etc/init.d/uhttpd enable >/dev/null 2>&1 || true
/etc/init.d/dockerd enable >/dev/null 2>&1 || true
/etc/init.d/AdGuardHome enable >/dev/null 2>&1 || true
/etc/init.d/adguardhome enable >/dev/null 2>&1 || true

exit 0
EOF

chmod +x files/etc/uci-defaults/99-default-settings

###############################################################################
# 自定义 nftables 防火墙规则
# 说明：
# 1）OpenWrt 25.x 默认使用 firewall4/nftables。
# 2）fw4 会自动加载 /usr/share/nftables.d 下的 *.nft 片段。
# 3）这里默认创建 mangle_prerouting 的自定义片段，可在 LuCI 自定义规则页编辑。
###############################################################################

cat > files/usr/share/nftables.d/chain-pre/mangle_prerouting/99-custom.nft <<'EOF'
# Custom nftables rules for fw4 mangle_prerouting.
# This file is included inside: table inet fw4 chain mangle_prerouting.
# Write raw rule expressions only, without "nft add rule".
# Example: redirect LAN DNS to the router.
# iifname "br-lan" udp dport 53 redirect to :53
EOF

cat > files/usr/share/rpcd/acl.d/luci-app-firewall-custom.json <<'EOF'
{
  "luci-app-firewall-custom": {
    "description": "Grant access to custom nftables firewall rules",
    "read": {
      "file": {
        "/usr/share/nftables.d/chain-pre/mangle_prerouting/99-custom.nft": [ "read" ]
      }
    },
    "write": {
      "file": {
        "/usr/share/nftables.d/chain-pre/mangle_prerouting/99-custom.nft": [ "write" ]
      },
      "ubus": {
        "file": [ "exec" ]
      }
    }
  }
}
EOF

cat > files/www/luci-static/resources/view/firewall/custom.js <<'EOF'
'use strict';
'require view';
'require fs';
'require ui';

var RULES_FILE = '/usr/share/nftables.d/chain-pre/mangle_prerouting/99-custom.nft';

return view.extend({
        load: function() {
                return fs.read(RULES_FILE).catch(function() {
                        return '# Custom nftables rules for fw4 mangle_prerouting.\n';
                });
        },

        render: function(content) {
                var textarea = E('textarea', {
                        'class': 'cbi-input-textarea',
                        'style': 'width:100%; min-height:380px; font-family:monospace',
                        'spellcheck': 'false',
                        'wrap': 'off'
                }, [ content || '' ]);

                return E('div', { 'class': 'cbi-map' }, [
                        E('h2', {}, [ _('防火墙 - 自定义规则') ]),
                        E('div', { 'class': 'cbi-map-descr' }, [
                                _('自定义规则会写入 fw4 自动加载的 nftables 片段。这里只填写规则表达式，不要写 nft add rule。保存后会重载 firewall。')
                        ]),
                        E('div', { 'class': 'cbi-section' }, [ textarea ])
                ]);
        },

        handleSaveApply: null,
        handleReset: null,

        handleSave: function(ev) {
                var textarea = document.querySelector('textarea.cbi-input-textarea');
                var data = textarea ? textarea.value : '';

                return fs.write(RULES_FILE, data).then(function() {
                        return fs.exec('/etc/init.d/firewall', [ 'reload' ]).catch(function() {});
                }).then(function() {
                        ui.addNotification(null, E('p', {}, [ _('自定义 nftables 规则已保存。') ]), 'info');
                });
        }
});
EOF

echo "✓ 默认配置文件配置完成"

###############################################################################
# 修复 opkg 源码包哈希不匹配
###############################################################################

echo "OpenWrt 25.12 uses apk; skipping legacy opkg source hash workaround."

###############################################################################
# 下载源码包（优化：并行下载，失败时重试）
###############################################################################

# 编译日志目录：下载 / 并行编译 / 单线程编译各一份，CI 下靠它定位失败原因
BUILD_LOG_DIR="$WORKDIR/openwrt/build-logs"
BUILD_LOG_STAMP=$(date '+%Y%m%d-%H%M%S')
DOWNLOAD_LOG="$BUILD_LOG_DIR/download-${BUILD_LOG_STAMP}.log"
PARALLEL_LOG="$BUILD_LOG_DIR/build-parallel-${BUILD_LOG_STAMP}.log"
SINGLE_LOG="$BUILD_LOG_DIR/build-single-${BUILD_LOG_STAMP}.log"
mkdir -p "$BUILD_LOG_DIR"

echo
echo "================ 开始下载源码包 ================"
echo "使用 $DOWNLOAD_JOBS 个并行线程下载..."
echo "下载日志: $DOWNLOAD_LOG"
echo

ci_group_start "下载源码包"
# 首次尝试并行下载
if run_logged "$DOWNLOAD_LOG" make download -j"$DOWNLOAD_JOBS" V=s; then
    echo "✓ 所有源码包下载完成"
else
    echo "⚠ 部分下载失败，尝试单线程重试..."
    if run_logged "$DOWNLOAD_LOG" make download -j1 V=s; then
        echo "✓ 单线程重试下载完成"
    else
        ci_error "源码包下载失败，详见 $DOWNLOAD_LOG"
        fail_tail "$DOWNLOAD_LOG"
        die "下载失败，请检查网络连接"
    fi
fi
ci_group_end

###############################################################################
# 预构建 LuCI host 工具（po2lmo / jsmin）
###############################################################################
# 第三方 LuCI 应用（package/custom/*）在 install 阶段会直接调用 po2lmo 把
# 中文 po 编成 lmo，但它们的 Makefile 通常没写
#     PKG_BUILD_DEPENDS:=luci-base/host
# make 就不会自动先把 luci-base 的 host 工具编出来。结果跑到它时才报
#     bash: line 1: po2lmo: command not found     → Error 127
# 而这时往往已经编译了两三个小时。这里显式先编一次，成本几秒。
ci_group_start "预构建 LuCI host 工具（po2lmo/jsmin）"
LUCIBASE_DIR=""
for candidate in \
    package/feeds/luci/luci-base \
    package/feeds/luci/modules/luci-base \
    package/luci-base; do
    if [ -d "$candidate" ]; then
        LUCIBASE_DIR="$candidate"
        break
    fi
done

if [ -n "$LUCIBASE_DIR" ]; then
    HOSTTOOLS_LOG="$BUILD_LOG_DIR/host-tools-${BUILD_LOG_STAMP}.log"
    if run_logged "$HOSTTOOLS_LOG" make "${LUCIBASE_DIR}/host/compile" V=s; then
        if [ -x staging_dir/host/bin/po2lmo ]; then
            echo "✓ po2lmo 已就绪"
            [ -x staging_dir/host/bin/jsmin ] && echo "✓ jsmin 已就绪"
            # 正常情况下 OpenWrt 自己会把 staging_dir/host/bin 放进 PATH。
            # 万一没有，这里补上，避免第三方包调用 po2lmo 时找不到。
            if ! command -v po2lmo >/dev/null 2>&1; then
                export PATH="$PWD/staging_dir/host/bin:$PATH"
                echo "已把 staging_dir/host/bin 加入 PATH"
            fi
        else
            warn "host 工具编译完成，但 staging_dir/host/bin/po2lmo 不存在"
        fi
    else
        warn "luci-base host 工具构建失败：带中文语言包的第三方 LuCI 应用可能报 po2lmo: command not found"
        fail_tail "$HOSTTOOLS_LOG"
    fi
else
    warn "未找到 luci-base 目录，跳过 host 工具预构建"
fi
ci_group_end

###############################################################################
# 编译（优化：启用详细输出和错误处理）
###############################################################################

echo
echo "================ 开始编译 ================"
echo "使用 $BUILD_THREADS 个编译线程"
if [ -n "$USE_CCACHE" ]; then
    echo "ccache 已启用，将加速重复编译"
fi
echo

# 首次尝试并行编译
START_TIME=$(date +%s)
START_TIME_TEXT=$(date '+%Y-%m-%d %H:%M:%S')
mkdir -p "$BUILD_LOG_DIR"
echo "编译开始时间: $START_TIME_TEXT"
echo "并行编译日志: $PARALLEL_LOG"
echo "单线程编译日志: $SINGLE_LOG"
echo

ci_group_start "并行编译 -j${BUILD_THREADS}"
if run_logged "$PARALLEL_LOG" make -j"${BUILD_THREADS}" V=s; then
    ci_group_end
    END_TIME=$(date +%s)
    END_TIME_TEXT=$(date '+%Y-%m-%d %H:%M:%S')
    ELAPSED=$((END_TIME - START_TIME))
    echo
    echo "✓ 编译成功！"
    echo "编译开始时间: $START_TIME_TEXT"
    echo "编译结束时间: $END_TIME_TEXT"
    echo "编译用时: $((ELAPSED / 3600)) 小时 $(((ELAPSED % 3600) / 60)) 分 $((ELAPSED % 60)) 秒"
    echo "编译日志: $PARALLEL_LOG"
else
    ci_group_end
    echo "⚠ 并行编译失败，尝试单线程编译以获取详细错误..."
    echo
    fail_tail "$PARALLEL_LOG"
    echo
    ci_group_start "单线程编译（定位错误）"
    if run_logged "$SINGLE_LOG" make -j1 V=s; then
        ci_group_end
        END_TIME=$(date +%s)
        END_TIME_TEXT=$(date '+%Y-%m-%d %H:%M:%S')
        ELAPSED=$((END_TIME - START_TIME))
        echo
        echo "✓ 单线程编译成功！"
        echo "编译开始时间: $START_TIME_TEXT"
        echo "编译结束时间: $END_TIME_TEXT"
        echo "编译用时: $((ELAPSED / 3600)) 小时 $(((ELAPSED % 3600) / 60)) 分 $((ELAPSED % 60)) 秒"
        echo "并行编译日志: $PARALLEL_LOG"
        echo "单线程编译日志: $SINGLE_LOG"
    else
        ci_group_end
        END_TIME=$(date +%s)
        END_TIME_TEXT=$(date '+%Y-%m-%d %H:%M:%S')
        ELAPSED=$((END_TIME - START_TIME))
        echo
        fail_tail "$SINGLE_LOG"
        echo
        ci_error "OpenWrt 编译失败（并行日志 $PARALLEL_LOG / 单线程日志 $SINGLE_LOG）"
        echo "✗ 编译失败"
        echo "编译开始时间: $START_TIME_TEXT"
        echo "编译结束时间: $END_TIME_TEXT"
        echo "编译用时: $((ELAPSED / 3600)) 小时 $(((ELAPSED % 3600) / 60)) 分 $((ELAPSED % 60)) 秒"
        echo "并行编译日志: $PARALLEL_LOG"
        echo "单线程编译日志: $SINGLE_LOG"
        exit 1
    fi
fi

###############################################################################
# 输出结果
###############################################################################

OUTDIR="$WORKDIR/openwrt/bin/targets/x86/64"

echo
echo "================ 编译完成 ================"
echo "构建版本：$OPENWRT_VERSION"
echo "构建线程：$BUILD_THREADS"
echo "固件目录：$OUTDIR"
echo

ls -lh "$OUTDIR"/*.img.gz "$OUTDIR"/*.tar.gz 2>/dev/null || echo "未找到固件文件"
echo
echo "首次安装："
echo "$OUTDIR/openwrt-x86-64-generic-squashfs-combined-efi.img.gz"
echo
echo "后续 sysupgrade："
echo "$OUTDIR/openwrt-x86-64-generic-squashfs-combined-efi.img.gz"
echo

###############################################################################
# 收集产物
###############################################################################

if [ "$IN_CONTAINER" = "1" ]; then
    collect_artifacts "$OUTDIR" /output || warn "产物收集失败，请手动从 $OUTDIR 取固件"
else
    collect_artifacts "$OUTDIR" "$HOST_OUTPUT_DIR" || warn "产物收集失败，请手动从 $OUTDIR 取固件"
fi
echo

###############################################################################
# CI：写一份 Markdown 摘要到产物目录
# 容器里没有 $GITHUB_STEP_SUMMARY 那个路径，所以落到 /output，
# 由 workflow 再 cat 进 Actions 的 Summary 页面。
###############################################################################
if [ "$IN_CI" = "1" ]; then
    if [ "$IN_CONTAINER" = "1" ]; then
        SUMMARY_DIR="/output"
    else
        SUMMARY_DIR="$HOST_OUTPUT_DIR"
    fi
    mkdir -p "$SUMMARY_DIR"
    {
        echo "### OpenWrt 编译产物"
        echo ""
        echo "| 项 | 值 |"
        echo "| --- | --- |"
        echo "| 构建版本 | \`${OPENWRT_VERSION}\` |"
        echo "| 目标平台 | x86/64（generic） |"
        echo "| 根分区大小 | ${ROOTFS_PARTSIZE} MiB |"
        echo "| 编译线程 | ${BUILD_THREADS}（模式 ${BUILD_MODE}：${BUILD_MODE_DESC}） |"
        echo "| 编译用时 | $((ELAPSED / 3600)) 小时 $(((ELAPSED % 3600) / 60)) 分 $((ELAPSED % 60)) 秒 |"
        echo "| 固件目录 | \`${OUTDIR}\` |"
        echo ""
        echo "编译日志：\`${PARALLEL_LOG}\`"
    } > "$SUMMARY_DIR/build-summary.md"
    log "✓ CI 摘要已写入: $SUMMARY_DIR/build-summary.md"
fi

# 产物目录里的日志文件也拷一份，方便 CI 失败后直接下载查看
if [ "$IN_CI" = "1" ] && [ -d "$BUILD_LOG_DIR" ]; then
    if [ "$IN_CONTAINER" = "1" ]; then
        cp -f "$BUILD_LOG_DIR"/*.log /output/ 2>/dev/null || true
    fi
fi
