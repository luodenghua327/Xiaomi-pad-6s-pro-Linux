#!/bin/bash
set -e

# ========================================================
# 🛡️ 异常守护：确保脚本退出或中断时，一定会卸载挂载点
# ========================================================
cleanup() {
    echo "🧹 执行挂载点安全清理..."
    umount -l rootdir/dev/pts 2>/dev/null || true
    umount -l rootdir/dev 2>/dev/null || true
    umount -l rootdir/proc 2>/dev/null || true
    umount -l rootdir/sys 2>/dev/null || true
    umount -l rootdir 2>/dev/null || true
}
trap cleanup EXIT ERR

IMAGE_SIZE="8G"
FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"

UBUNTU_SUITE="resolute"
# 🚀 优化 1：构建期间使用全球加速官方源（防止 GitHub Azure 机房跨国拉取超时）
BUILD_MIRROR="http://archive.ubuntu.com/ubuntu"
# 🇨🇳 交付给用户的最终国内源
TARGET_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/ubuntu"

usage() {
    echo "用法: $0 <kernel_version> <desktop_environment>"
    echo "desktop_environment: gnome, kde 或 xfce"
    exit 1
}

if [ $# -ne 2 ]; then
    usage
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root权限运行"
    exit 1
fi

KERNEL=$1
DESKTOP_ENV=$2

if [[ ! "$DESKTOP_ENV" =~ ^(gnome|kde|xfce)$ ]]; then
    echo "错误: desktop_environment 必须是 gnome, kde 或 xfce"
    exit 1
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ROOTFS_IMG="ubuntu26_${DESKTOP_ENV}_${TIMESTAMP}.img"

echo "=========================================="
echo "⚡ 开始极速构建 Ubuntu 26.04 LTS (Resolute) RootFS"
echo "桌面环境: $DESKTOP_ENV"
echo "内核版本: $KERNEL"
echo "=========================================="

truncate -s $IMAGE_SIZE "$ROOTFS_IMG"
mkfs.ext4 "$ROOTFS_IMG"
mkdir -p rootdir
mount -o loop "$ROOTFS_IMG" rootdir

# 使用官方加速源进行基础系统引导
debootstrap --arch=arm64 "$UBUNTU_SUITE" rootdir "$BUILD_MIRROR"

mount --bind /dev rootdir/dev
mount --bind /dev/pts rootdir/dev/pts
mount -t proc proc rootdir/proc
mount -t sysfs sys rootdir/sys

# 基础软件源 (构建期)
printf "deb %s %s main restricted universe multiverse\n" "$BUILD_MIRROR" "$UBUNTU_SUITE" > rootdir/etc/apt/sources.list
printf "deb %s %s-updates main restricted universe multiverse\n" "$BUILD_MIRROR" "$UBUNTU_SUITE" >> rootdir/etc/apt/sources.list
printf "deb %s %s-backports main restricted universe multiverse\n" "$BUILD_MIRROR" "$UBUNTU_SUITE" >> rootdir/etc/apt/sources.list
printf "deb %s %s-security main restricted universe multiverse\n" "$BUILD_MIRROR" "$UBUNTU_SUITE" >> rootdir/etc/apt/sources.list

# 🚀 优化 2：注入全局非交互环境变量，防止安装时弹窗卡死 CI
export DEBIAN_FRONTEND=noninteractive

chroot rootdir apt-get update

# 🚀 优化 3：安装 eatmydata，强制关闭 dpkg 的 fsync I/O 同步，速度起飞
chroot rootdir apt-get install -y --no-install-recommends eatmydata

if ls *.deb 1> /dev/null 2>&1; then
    cp *.deb rootdir/tmp/
    chroot rootdir eatmydata bash -c 'apt-get install -y /tmp/*.deb'
fi

# 基础核心依赖 (增加 parted 和 e2fsprogs 用于扩容)
chroot rootdir eatmydata apt-get install -y --no-install-recommends \
    systemd sudo vim-tiny wget curl \
    network-manager openssh-server \
    wpasupplicant wireless-regdb dbus parted e2fsprogs

# 设置英文语言环境
chroot rootdir bash -c "echo 'LANG=en_US.UTF-8' > /etc/default/locale"
chroot rootdir locale-gen en_US.UTF-8

# root 用户初始化
chroot rootdir bash -c "echo -e '1234\n1234' | passwd root"
echo "ubuntu26-${DESKTOP_ENV}" > rootdir/etc/hostname

# ========================================================
# 📦 桌面环境分支流转 (全程使用 eatmydata 加速解压)
# ========================================================
if [ "$DESKTOP_ENV" = "gnome" ]; then
    chroot rootdir eatmydata apt-get install -y --no-install-recommends ubuntu-desktop-minimal gnome-terminal firefox gdm3
    DM="gdm3"
elif [ "$DESKTOP_ENV" = "kde" ]; then
    chroot rootdir eatmydata apt-get install -y --no-install-recommends plasma-desktop sddm konsole firefox plasma-workspace systemsettings discover packagekit
    DM="sddm"
elif [ "$DESKTOP_ENV" = "xfce" ]; then
    chroot rootdir eatmydata apt-get install -y --no-install-recommends xfce4 xfce4-terminal lightdm lightdm-gtk-greeter firefox mousepad thunar
    DM="lightdm"
fi

# 创建普通用户 luser
chroot rootdir useradd -m -s /bin/bash luser
echo "luser:luser" | chroot rootdir chpasswd
chroot rootdir usermod -aG sudo,audio,video,render,input,plugdev luser

# ========================================================
# ⚙️ 底层硬件自愈与触控校准
# ========================================================
chroot rootdir bash -c "echo 'ttyMSM0' >> /etc/securetty"
ln -sf /lib/systemd/system/getty@.service rootdir/etc/systemd/system/getty.target.wants/getty@ttyMSM0.service
chroot rootdir systemctl enable systemd-resolved
ln -sf /run/systemd/resolve/stub-resolv.conf rootdir/etc/resolv.conf

mkdir -p rootdir/etc/udev/rules.d/
printf 'ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{LIBINPUT_CALIBRATION_MATRIX}="1 0 0 0 1 0 0 0 1"\n' > rootdir/etc/udev/rules.d/99-touchscreen-sheng.rules

# ========================================================
# 🔒 自动登录与桌面加固配置
# ========================================================

if [ "$DM" = "gdm3" ]; then
    mkdir -p rootdir/etc/gdm3
    printf "[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=luser\n" > rootdir/etc/gdm3/daemon.conf
    chroot rootdir systemctl enable gdm3
fi

if [ "$DM" = "sddm" ]; then
    mkdir -p rootdir/etc/sddm.conf.d
    printf "[General]\nDisplayServer=x11\nInputMethod=\n" > rootdir/etc/sddm.conf.d/ubuntu-defaults.conf
    printf "[Autologin]\nUser=luser\nSession=plasma\n" > rootdir/etc/sddm.conf.d/autologin.conf
    
    if chroot rootdir id -u sddm >/dev/null 2>&1; then
        chroot rootdir usermod -aG video,render,input sddm || true
    fi
    
    mkdir -p rootdir/etc/xdg
    printf "[PowerManagement]\nScreenBlanking=false\nDisplaySleep=0\n" > rootdir/etc/xdg/plasmarc
    chroot rootdir systemctl enable sddm
fi

if [ "$DM" = "lightdm" ]; then
    mkdir -p rootdir/etc/lightdm/lightdm.conf.d
    printf "[Seat:*]\nautologin-user=luser\nautologin-user-timeout=0\n" > rootdir/etc/lightdm/lightdm.conf.d/autologin.conf
    chroot rootdir systemctl enable lightdm
fi

chroot rootdir systemctl set-default graphical.target

# 🚀 优化 4：为目标系统替换回国内源（方便国内最终用户）
echo "🌐 正在为目标系统写入清华大学开源镜像站..."
printf "deb %s %s main restricted universe multiverse\n" "$TARGET_MIRROR" "$UBUNTU_SUITE" > rootdir/etc/apt/sources.list
printf "deb %s %s-updates main restricted universe multiverse\n" "$TARGET_MIRROR" "$UBUNTU_SUITE" >> rootdir/etc/apt/sources.list
printf "deb %s %s-backports main restricted universe multiverse\n" "$TARGET_MIRROR" "$UBUNTU_SUITE" >> rootdir/etc/apt/sources.list
printf "deb %s %s-security main restricted universe multiverse\n" "$TARGET_MIRROR" "$UBUNTU_SUITE" >> rootdir/etc/apt/sources.list

# 🚀 优化 5：自动扩容服务 x-systemd.growfs，开机自动扩展 8G 分区到整个磁盘
printf "PARTLABEL=linux / ext4 defaults,noatime,errors=remount-ro,x-systemd.growfs 0 1\n" > rootdir/etc/fstab

# 卸载加速器并清理缓存
chroot rootdir apt-get purge -y eatmydata
chroot rootdir apt-get autoremove -y
chroot rootdir apt-get clean
chroot rootdir rm -rf /tmp/*.deb

# 手动卸载（配合 trap 守护）
cleanup

tune2fs -U $FILESYSTEM_UUID "$ROOTFS_IMG"

echo "✅ 镜像生成完成: $ROOTFS_IMG"

# 🚀 优化 6：开启 7z 多线程 (-mmt=on)，平衡压缩率与速度 (-mx=5)
echo "🗜️ 正在生成多线程压缩包..."
7z a -t7z -m0=lzma2 -mx=5 -mmt=on "ubuntu26_${DESKTOP_ENV}_${TIMESTAMP}.7z" "$ROOTFS_IMG"
rm -f "$ROOTFS_IMG"

echo "🎉 Ubuntu 26.04 构建与压缩全部完成！"
