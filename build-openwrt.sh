#!/usr/bin/env bash
set -e
set -o pipefail

export FORCE_UNSAFE_CONFIGURE=1

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
###############################################################################

###############################################################################
# 基础配置
###############################################################################

WORKDIR="$HOME/openwrt-full-build"
REPO_URL="https://github.com/openwrt/openwrt.git"
BRANCH="openwrt-25.12"

LAN_IP="192.168.31.254"
LAN_NETMASK="255.255.255.0"
LAN_GATEWAY="192.168.31.1"
LAN_DNS1="223.5.5.5"
LAN_DNS2="119.29.29.29"

ROOT_PASSWORD="root"
DOCKER_DATA_ROOT="/opt/docker"

# 编译优化配置
# 用法：
#   ./build-openwrt-opkg-directhash.sh        # 默认模式 0：自动，使用全部 CPU 线程
#   ./build-openwrt-opkg-directhash.sh 1      # 模式 1：使用 CPU 线程的 2/3
#   ./build-openwrt-opkg-directhash.sh 2      # 模式 2：使用 CPU 线程的一半
#   ./build-openwrt-opkg-directhash.sh 3      # 模式 3：单线程
# 第一个参数为编译模式；不传则默认 0。不再读取其他线程参数。
BUILD_MODE="${1:-0}"
CPU_THREADS="$(nproc)"

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
    export CCACHE_MAXSIZE="5G"
    echo "✓ ccache 已启用，缓存目录: $CCACHE_DIR"
fi

###############################################################################
# 安装依赖（优化：添加 ccache 和加速编译工具）
###############################################################################

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

###############################################################################
# 下载源码（优化：使用浅克隆和单分支）
###############################################################################

mkdir -p "$WORKDIR"
cd "$WORKDIR"

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

echo "正在更新 feeds..."
# 优化：不清理所有 feeds，只更新必要的
./scripts/feeds update -a 2>&1 | tail -20
echo "正在安装 feeds 包..."
./scripts/feeds install -a 2>&1 | tail -20

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
# CONFIG_TARGET_ROOTFS_EXT4FS is not set
# CONFIG_TARGET_IMAGES_PAD is not set
CONFIG_GRUB_IMAGES=y
CONFIG_EFI_IMAGES=y
CONFIG_TARGET_ROOTFS_PARTSIZE=4096

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
# CONFIG_TARGET_ROOTFS_EXT4FS is not set
# CONFIG_TARGET_IMAGES_PAD is not set
CONFIG_TARGET_ROOTFS_PARTSIZE=4096

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

echo "正在生成最终配置..."
make defconfig
echo "✓ 配置生成完成"

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

echo
echo "================ 开始下载源码包 ================"
echo "使用 $DOWNLOAD_JOBS 个并行线程下载..."
echo

# 首次尝试并行下载
if make download -j"$DOWNLOAD_JOBS" V=s; then
    echo "✓ 所有源码包下载完成"
else
    echo "⚠ 部分下载失败，尝试单线程重试..."
    make download -j1 V=s || {
        echo "✗ 下载失败，请检查网络连接"
        exit 1
    }
fi

###############################################################################
# 预构建 LuCI host 工具（po2lmo / jsmin）
###############################################################################
# 第三方 LuCI 应用（package/custom/*）在 install 阶段会直接调用 po2lmo 把
# 中文 po 编成 lmo，但它们的 Makefile 通常没写
#     PKG_BUILD_DEPENDS:=luci-base/host
# make 就不会自动先把 luci-base 的 host 工具编出来。结果跑到它时才报
#     bash: line 1: po2lmo: command not found     → Error 127
# 而这时往往已经编译了两三个小时。这里显式先编一次，成本几秒。
echo
echo "================ 预构建 LuCI host 工具 ================"

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
    if make "${LUCIBASE_DIR}/host/compile" V=s; then
        if [ -x staging_dir/host/bin/po2lmo ]; then
            echo "✓ po2lmo 已就绪"
            [ -x staging_dir/host/bin/jsmin ] && echo "✓ jsmin 已就绪"
            if ! command -v po2lmo >/dev/null 2>&1; then
                export PATH="$PWD/staging_dir/host/bin:$PATH"
                echo "已把 staging_dir/host/bin 加入 PATH"
            fi
        else
            echo "⚠ host 工具编译完成，但 staging_dir/host/bin/po2lmo 不存在"
        fi
    else
        echo "⚠ luci-base host 工具构建失败：带中文语言包的第三方 LuCI 应用可能报 po2lmo: command not found"
    fi
else
    echo "⚠ 未找到 luci-base 目录，跳过 host 工具预构建"
fi

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
BUILD_LOG_DIR="$WORKDIR/openwrt/build-logs"
BUILD_LOG_STAMP=$(date '+%Y%m%d-%H%M%S')
PARALLEL_LOG="$BUILD_LOG_DIR/build-parallel-${BUILD_LOG_STAMP}.log"
SINGLE_LOG="$BUILD_LOG_DIR/build-single-${BUILD_LOG_STAMP}.log"
mkdir -p "$BUILD_LOG_DIR"
echo "编译开始时间: $START_TIME_TEXT"
echo "并行编译日志: $PARALLEL_LOG"
echo "单线程编译日志: $SINGLE_LOG"
echo

if make -j"${BUILD_THREADS}" V=s 2>&1 | tee "$PARALLEL_LOG"; then
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
    echo "⚠ 并行编译失败，尝试单线程编译以获取详细错误..."
    echo
    echo "================ 并行编译日志最后 120 行 ================"
    tail -n 120 "$PARALLEL_LOG" || true
    echo "========================================================="
    echo
    if make -j1 V=s 2>&1 | tee "$SINGLE_LOG"; then
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
        END_TIME=$(date +%s)
        END_TIME_TEXT=$(date '+%Y-%m-%d %H:%M:%S')
        ELAPSED=$((END_TIME - START_TIME))
        echo
        echo "================ 单线程编译日志最后 200 行 ================"
        tail -n 200 "$SINGLE_LOG" || true
        echo "==========================================================="
        echo
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
echo "构建线程：$BUILD_THREADS"
echo "固件目录：$OUTDIR"
echo

ls -lh "$OUTDIR"/*.img.gz 2>/dev/null || echo "未找到固件文件"
echo
echo "首次安装："
echo "$OUTDIR/openwrt-x86-64-generic-squashfs-combined-efi.img.gz"
echo
echo "后续 sysupgrade："
echo "$OUTDIR/openwrt-x86-64-generic-squashfs-combined-efi.img.gz"
echo
