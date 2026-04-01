#!/bin/bash
# ==============================================================================
# VOID LINUX PRODUCTION ISO BUILDER (GOLD MASTER V2)
# Target: Custom GNOME ISO with High-Performance Trading Installer
# Fixes: Reordered Live-CD cleanup to prevent /etc/shadow password wiping
# ==============================================================================

set -euo pipefail

# --- CONFIGURATION ---
ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
WORKDIR="$ACTUAL_HOME/void-iso"
USE_FASTEST_MIRROR="true"
# ---------------------

echo "==> [0/6] Running Preflight Host Checks..."
REQUIRED_CMDS="git make curl tar xz sudo gzip bzip2 awk sed ping"
MISSING_CMDS=""

for cmd in $REQUIRED_CMDS; do
    if ! command -v "$cmd" &> /dev/null; then
        MISSING_CMDS="$MISSING_CMDS $cmd"
    fi
done

if [ -n "$MISSING_CMDS" ]; then
    echo "    Missing required host tools:$MISSING_CMDS"
    echo "    Attempting to install missing packages automatically..."
    
    if command -v apt-get &> /dev/null; then
        APT_PKGS=${MISSING_CMDS//xz/xz-utils}
        sudo apt-get update && sudo apt-get install -y $APT_PKGS
    elif command -v pacman &> /dev/null; then
        sudo pacman -Sy --noconfirm $MISSING_CMDS
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y $MISSING_CMDS
    elif command -v xbps-install &> /dev/null; then
        sudo xbps-install -Sy $MISSING_CMDS
    elif command -v zypper &> /dev/null; then
        sudo zypper install -y $MISSING_CMDS
    else
        echo "    [!] Error: Unrecognized package manager."
        exit 1
    fi
    echo "    Preflight resolution complete."
else
    echo "    All host dependencies are present. Proceeding..."
fi

echo "==> [1/6] Setting up workspace at $WORKDIR..."
sudo -u "$ACTUAL_USER" mkdir -p "$WORKDIR"
cd "$WORKDIR"

if [ ! -d "void-mklive" ]; then
    echo "    Cloning repository..."
    sudo -u "$ACTUAL_USER" git clone https://github.com/void-linux/void-mklive.git
fi
cd void-mklive

echo "    Cleaning up root-owned build artifacts from previous runs..."
rm -rf custom-overlay xbps-cachedir-* builddir *.iso

echo "    Syncing toolchain to the latest stable master branch..."
sudo -u "$ACTUAL_USER" git fetch origin
sudo -u "$ACTUAL_USER" git reset --hard origin/master
sudo -u "$ACTUAL_USER" git clean -fdx

make 

echo "==> [2/6] Selecting Void Linux Repository Mirror..."
REPO_URL="https://repo-default.voidlinux.org"

if [ "$USE_FASTEST_MIRROR" = "true" ]; then
    echo "    Pinging Tier 1 mirrors to find the fastest response time..."
    BEST_TIME=999
    
    MIRRORS=(
        "https://repo-default.voidlinux.org"
        "https://repo-fi.voidlinux.org"
        "https://repo-us.voidlinux.org"
        "https://repo-fastly.voidlinux.org"
        "https://mirrors.servercentral.com/voidlinux"
    )

    for m in "${MIRRORS[@]}"; do
        TEST_TIME=$(LC_NUMERIC=C curl -s -o /dev/null -w "%{time_total}" -m 2 "$m/current/x86_64-repodata" || echo "999")
        
        if awk "BEGIN {exit !($TEST_TIME < $BEST_TIME)}"; then
            BEST_TIME=$TEST_TIME
            REPO_URL=$m
        fi
    done
    echo "    [+] Selected Mirror: $REPO_URL (Response time: ${BEST_TIME}s)"
else
    echo "    Using default mirror: $REPO_URL"
fi

echo "==> [3/6] Setting up Overlay and Injected Scripts..."
rm -rf custom-overlay
mkdir -p custom-overlay/etc/gdm
mkdir -p custom-overlay/usr/bin

# 1. GDM Autologin Config
cat <<EOF > custom-overlay/etc/gdm/custom.conf
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=anon
WaylandEnable=true
EOF

# 2. Live ISO Welcome Message
cat <<EOF > custom-overlay/etc/issue
\S \r (\l)

==================================================
 Welcome to the Custom Void Linux Live System!
 
 To begin the installation, type: void-setup
==================================================

EOF

# 3. Standard Native Installer
if [ ! -f installer.sh ]; then
    echo "    [!] Error: installer.sh not found in the void-mklive repository!"
    exit 1
fi
cp installer.sh custom-overlay/usr/bin/void-installer
chmod +x custom-overlay/usr/bin/void-installer

# 4. Interactive UX Launcher
cat << 'EOF_LAUNCHER' > custom-overlay/usr/bin/void-setup
#!/bin/bash
clear
echo "======================================================================"
echo "                   VOID LINUX SYSTEM INSTALLER                        "
echo "======================================================================"
echo ""
echo " Please select your deployment method:"
echo " 1) Standard Void Installer (Official ncurses UI, Manual Config)"
echo " 2) High-Performance Trading Deployer (Automated LUKS/LVM/Mainline)"
echo " 3) Exit to shell"
echo ""
read -rp " Enter choice [1-3]: " setup_choice

case $setup_choice in
    1) sudo void-installer ;;
    2) sudo void-trading-install ;;
    *) echo "Exiting. Type 'void-setup' to return to this menu." ;;
esac
EOF_LAUNCHER
chmod +x custom-overlay/usr/bin/void-setup

# 5. The High-Performance Deployer
echo "    [+] Injecting Custom Trading Installer (Gold Master V2)..."
cat << 'EOF_TRADER' > custom-overlay/usr/bin/void-trading-install
#!/bin/bash
set -euo pipefail

LOGFILE="/tmp/void-install.log"
exec > >(tee -i "$LOGFILE")
exec 2>&1

clear
echo "======================================================================"
echo "      VOID HIGH-PERFORMANCE DEPLOYMENT (GOLD MASTER)                  "
echo "======================================================================"

echo -e "\n[*] Available Storage Devices:"
lsblk -d -o NAME,SIZE,FSTYPE,MODEL | grep -v "loop"

echo ""
read -rp "Target disk (e.g. /dev/sda, /dev/vda, /dev/nvme0n1): " DISK

echo -e "\n[*] Installation Source"
echo "1) Local ISO Clone (Lightning Fast - Copies live environment to disk)"
echo "2) Network Install (Slower - Downloads latest from fastest mirror)"
read -rp "Select source [1 or 2, Default: 1]: " INSTALL_SOURCE
INSTALL_SOURCE=${INSTALL_SOURCE:-1}

echo -e "\n[*] Partition & Volume Sizing"
read -rp "EFI partition size in MiB [Default: 512]: " EFI_SIZE
EFI_SIZE=${EFI_SIZE:-512}
read -rp "BOOT partition size in MiB [Default: 1024]: " BOOT_SIZE
BOOT_SIZE=${BOOT_SIZE:-1024}
read -rp "LVM SWAP volume size in GiB [Default: 4]: " SWAP_SIZE
SWAP_SIZE=${SWAP_SIZE:-4}
read -rp "LVM ROOT (/) volume size in GiB [Default: 30]: " ROOT_LV_SIZE
ROOT_LV_SIZE=${ROOT_LV_SIZE:-30}

echo -e "\n[*] Credentials & Config"
read -rsp "Enter LUKS encryption password: " LUKS_PASS; echo
read -rp "Enter new username: " SYS_USER
read -rsp "Enter user password (also used for root): " SYS_PASS; echo
read -rp "Enter hostname [void-trading]: " HOST_NAME
HOST_NAME=${HOST_NAME:-void-trading}

read -rp "Enable SSD TRIM for LUKS? [y/N]: " TRIM_PROMPT
CRYPT_OPTS=$([[ "$TRIM_PROMPT" =~ ^[Yy]$ ]] && echo "luks,discard" || echo "luks")

echo -e "\n⚠️  WARNING: ALL DATA ON $DISK WILL BE PERMANENTLY ERASED!"
read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Aborted."; exit 1; }

# Partitioning
[[ "$DISK" =~ [0-9]$ ]] && P="${DISK}p" || P="${DISK}"
EFI="${P}1"; BOOT="${P}2"; ROOT_PART="${P}3"

echo "[*] Wiping and partitioning $DISK..."
wipefs -a "$DISK"
parted -s "$DISK" mklabel gpt
EFI_END=$(( 1 + EFI_SIZE ))
BOOT_END=$(( EFI_END + BOOT_SIZE ))
parted -s "$DISK" mkpart ESP fat32 1MiB ${EFI_END}MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart BOOT ext4 ${EFI_END}MiB ${BOOT_END}MiB
parted -s "$DISK" mkpart ROOT ${BOOT_END}MiB 100%
partprobe "$DISK"; sleep 2

mkfs.vfat -F32 "$EFI"
mkfs.ext4 -F "$BOOT"

echo "[*] Setting up Encryption & LVM..."
printf "%s" "$LUKS_PASS" | cryptsetup luksFormat "$ROOT_PART" -
printf "%s" "$LUKS_PASS" | cryptsetup open "$ROOT_PART" cryptroot -
pvcreate /dev/mapper/cryptroot; vgcreate voidvg /dev/mapper/cryptroot
lvcreate -L "${SWAP_SIZE}G" voidvg -n swap
lvcreate -L "${ROOT_LV_SIZE}G" voidvg -n root
lvcreate -l 100%FREE voidvg -n home
mkfs.ext4 -F /dev/voidvg/root; mkfs.ext4 -F /dev/voidvg/home; mkswap /dev/voidvg/swap

echo "[*] Mounting filesystems..."
mount /dev/voidvg/root /mnt
mkdir -p /mnt/{boot,home,etc/xbps.d,var/db/xbps/keys}
mount "$BOOT" /mnt/boot
mkdir -p /mnt/boot/efi; mount "$EFI" /mnt/boot/efi
mount /dev/voidvg/home /mnt/home; swapon /dev/voidvg/swap

# UUID Collection
BOOT_UUID=$(blkid -s UUID -o value "$BOOT")
EFI_UUID=$(blkid -s UUID -o value "$EFI")
ROOT_LV_UUID=$(blkid -s UUID -o value /dev/voidvg/root)
HOME_LV_UUID=$(blkid -s UUID -o value /dev/voidvg/home)
SWAP_LV_UUID=$(blkid -s UUID -o value /dev/voidvg/swap)
CRYPT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

# Base Installation Prep
UCODE=""
grep -q "GenuineIntel" /proc/cpuinfo && UCODE="intel-ucode"

echo "ignorepkg=linux" > /mnt/etc/xbps.d/10-ignore.conf
echo "ignorepkg=linux-headers" >> /mnt/etc/xbps.d/10-ignore.conf

if [ "$INSTALL_SOURCE" = "1" ] && [ -d "/repo" ]; then
    echo "[*] Cloning RootFS (Lightning Mode)..."
    tar -cpf - -C / bin etc home lib lib32 lib64 opt root sbin usr var | tar -xpf - -C /mnt
    tar -cpf - -C /boot . | tar -xpf - -C /mnt/boot
    mkdir -p /mnt/{dev,proc,sys,tmp,run,mnt,media}; chmod 1777 /mnt/tmp
    REPO_FLAGS="-i -R /repo"
else
    echo "[*] Network Install Mode..."
    echo "[*] Verifying network connectivity..."
    if ! ping -c 2 8.8.8.8 >/dev/null 2>&1; then
        echo "[!] CRITICAL: No internet connection detected."
        exit 1
    fi
    REPO_FLAGS="-R __REPO_URL__/current -R __REPO_URL__/current/nonfree"
fi

cp -a /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ || true

echo "[*] Installing/Verifying base system packages..."
xbps-install -Sy -c /var/cache/xbps $REPO_FLAGS -r /mnt \
    base-system linux-mainline linux-mainline-headers binutils $UCODE cryptsetup lvm2 grub-x86_64-efi sudo \
    linux-firmware-amd mesa-dri mesa-vaapi mesa-vulkan-radeon \
    gnome-core gnome-terminal nano mousepad chromium gdm dbus elogind NetworkManager \
    ethtool pciutils zramen irqbalance lm_sensors cpupower dconf haveged preload parted

mount --rbind /dev /mnt/dev; mount --rbind /proc /mnt/proc; mount --rbind /sys /mnt/sys
cp /etc/resolv.conf /mnt/etc/resolv.conf

echo "[*] Entering secured chroot environment..."
chroot /mnt /usr/bin/env HOST_NAME="$HOST_NAME" CRYPT_UUID="$CRYPT_UUID" CRYPT_OPTS="$CRYPT_OPTS" \
    ROOT_LV_UUID="$ROOT_LV_UUID" HOME_LV_UUID="$HOME_LV_UUID" BOOT_UUID="$BOOT_UUID" \
    EFI_UUID="$EFI_UUID" SWAP_LV_UUID="$SWAP_LV_UUID" SYS_USER="$SYS_USER" SYS_PASS="$SYS_PASS" DISK="$DISK" \
    INSTALL_SOURCE="$INSTALL_SOURCE" /bin/bash << 'CHROOT_EOF'
set -euo pipefail

# === Bulletproof directory creation ===
mkdir -p /etc/sysctl.d /etc/modules-load.d /etc/security/limits.d /etc/default /etc/chromium /etc/dracut.conf.d /etc/X11/xorg.conf.d /usr/local/bin

echo "$HOST_NAME" > /etc/hostname
echo "cryptroot UUID=$CRYPT_UUID none $CRYPT_OPTS" > /etc/crypttab
cat <<FSTAB > /etc/fstab
UUID=$ROOT_LV_UUID  /         ext4    defaults 0 1
UUID=$HOME_LV_UUID  /home     ext4    defaults 0 2
UUID=$BOOT_UUID     /boot     ext4    defaults 0 2
UUID=$EFI_UUID      /boot/efi vfat    defaults 0 2
UUID=$SWAP_LV_UUID  none      swap    defaults 0 0
tmpfs               /tmp      tmpfs   defaults,noatime,mode=1777 0 0
FSTAB

# Timezone & US Keyboard Hardcode
echo "en_US.UTF-8 UTF-8" >> /etc/default/libc-locales; xbps-reconfigure -f glibc-locales
ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime

sed -i 's/^#KEYMAP=.*/KEYMAP="us"/' /etc/rc.conf || echo 'KEYMAP="us"' >> /etc/rc.conf
cat <<XKB > /etc/X11/xorg.conf.d/00-keyboard.conf
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "us"
EndSection
XKB

# === CRITICAL PASSWORD & USER FIX ===
# Nuke the Live ISO packages FIRST so they don't overwrite our shadow files
if [ "$INSTALL_SOURCE" = "1" ]; then
    xbps-remove -Ry void-live >/dev/null 2>&1 || true
    userdel -f -r anon >/dev/null 2>&1 || true
fi

# Force repair the shadow file structures
pwconv
grpconv

# Safely inject the permanent users and explicit SHA512 passwords
useradd -m -G wheel,audio,video,input -s /bin/bash "$SYS_USER"
echo "$SYS_USER:$SYS_PASS" | chpasswd -c SHA512
echo "root:$SYS_PASS" | chpasswd -c SHA512
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
# =====================================

# Kernel & Boot
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="amd_pstate=active audit=0 nowatchdog nmi_watchdog=0 rcu_nocbs=all quiet loglevel=3 /' /etc/default/grub
echo 'add_dracutmodules+=" crypt lvm "' > /etc/dracut.conf.d/crypt.conf
echo 'hostonly="yes"' > /etc/dracut.conf.d/hostonly.conf

for k_dir in /lib/modules/*; do
    KVER=$(basename "$k_dir")
    dracut -f --kver "$KVER"
done

if [ -d /sys/firmware/efi ]; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Void --recheck
else
    grub-install --target=i386-pc --recheck "$DISK"
fi
grub-mkconfig -o /boot/grub/grub.cfg

# === Performance Tuning Restoration ===
cat <<SYSCTL > /etc/sysctl.d/99-trading-ultra.conf
kernel.timer_migration=0
kernel.sched_wakeup_granularity_ns=1500000
kernel.sched_autogroup_enabled=0
vm.swappiness=10
vm.dirty_ratio=10
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_fastopen=3
net.core.busy_read=50
net.core.busy_poll=50
SYSCTL

echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

cat <<LIMITS > /etc/security/limits.d/99-trading-limits.conf
* soft nofile 500000
* hard nofile 1048576
root soft nofile 500000
root hard nofile 1048576
LIMITS

echo 'zram_size=50%' > /etc/default/zramen

cat <<CHROMIUM > /etc/chromium/custom-flags.conf
--ignore-gpu-blocklist
--enable-gpu-rasterization
--enable-zero-copy
--use-vulkan
--enable-features=Vulkan
--ozone-platform-hint=auto
CHROMIUM

echo 'CHROMIUM_FLAGS="$(cat /etc/chromium/custom-flags.conf | tr "\n" " ")"' > /etc/chromium/default

cat <<BOOTINIT > /usr/local/bin/trading-boot-init.sh
#!/bin/bash
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
command -v cpupower >/dev/null && cpupower frequency-set -g performance >/dev/null 2>&1
if [ -f /sys/class/drm/card0/device/power_dpm_force_performance_level ]; then
  echo high > /sys/class/drm/card0/device/power_dpm_force_performance_level
fi
BOOTINIT
chmod +x /usr/local/bin/trading-boot-init.sh

touch /etc/rc.local
chmod +x /etc/rc.local
if ! grep -q "trading-boot-init.sh" /etc/rc.local; then
    echo "/usr/local/bin/trading-boot-init.sh" >> /etc/rc.local
fi

# Services
for s in dbus elogind NetworkManager zramen irqbalance gdm lvm haveged fstrim preload udevd dhcpcd; do
    [ -d "/etc/sv/$s" ] && ln -sfn "/etc/sv/$s" /etc/runit/runsvdir/default/
done

xbps-remove -Fy tracker3-miners || true
CHROOT_EOF

umount -R /mnt; swapoff -a
echo "======================================================================"
echo "   INSTALL COMPLETE: Reboot, enter LUKS pass, and enjoy the speed.    "
echo "======================================================================"
EOF_TRADER

chmod +x custom-overlay/usr/bin/void-trading-install
sed -i "s|__REPO_URL__|$REPO_URL|g" custom-overlay/usr/bin/void-trading-install

echo "==> [4/6] Defining finalized package list..."
APPS="gnome-core gnome-terminal chromium NetworkManager network-manager-applet elogind xdg-user-dirs xdg-utils dialog mousepad"
VIRT="qemu-ga spice-vdagent"
UTILS="dhcpcd iproute2 bash-completion nano htop wget curl grub-x86_64-efi os-prober cryptsetup lvm2 mdadm btrfs-progs xfsprogs dosfstools e2fsprogs parted binutils"
FIRMWARE="linux-firmware linux-firmware-network linux-firmware-amd linux-firmware-intel linux-firmware-nvidia intel-ucode"
DRIVERS="mesa mesa-dri mesa-vaapi mesa-vulkan-radeon mesa-vulkan-intel vulkan-loader void-repo-nonfree"

ALL_PKGS="$APPS $VIRT $UTILS $FIRMWARE $DRIVERS"

echo "==> [5/6] Validating package list against $REPO_URL..."
XBPS_CMD=$(command -v xbps-install || echo "$PWD/xbps-static/usr/bin/xbps-install")
if [ -f "$XBPS_CMD" ] || command -v xbps-install >/dev/null 2>&1; then
    DUMMY_ROOT=$(mktemp -d)
    sudo mkdir -p "$DUMMY_ROOT/var/db/xbps/keys"
    sudo cp keys/* "$DUMMY_ROOT/var/db/xbps/keys/"
    sudo env XBPS_ARCH=x86_64 "$XBPS_CMD" -S -r "$DUMMY_ROOT" --repository="$REPO_URL/current" --repository="$REPO_URL/current/nonfree" > /dev/null
    MISSING_PKGS=""
    for pkg in $ALL_PKGS; do
        if ! sudo env XBPS_ARCH=x86_64 "$XBPS_CMD" -n -r "$DUMMY_ROOT" --repository="$REPO_URL/current" --repository="$REPO_URL/current/nonfree" "$pkg" > /dev/null 2>&1; then
            MISSING_PKGS="$MISSING_PKGS $pkg"
        fi
    done
    sudo rm -rf "$DUMMY_ROOT"
    if [ -n "$MISSING_PKGS" ]; then
        echo "    [!] CRITICAL ERROR: The following packages do NOT exist: $MISSING_PKGS"
        exit 1
    fi
fi

echo "==> [6/6] Baking the ISO..."
sudo ./mklive.sh \
    -a x86_64 \
    -o void-custom-gnome-production.iso \
    -v linux-mainline \
    -S "dbus elogind NetworkManager gdm qemu-ga" \
    -p "$ALL_PKGS" \
    -r "$REPO_URL/current" \
    -r "$REPO_URL/current/nonfree" \
    -I custom-overlay

echo "==> SUCCESS! Your ISO is at: $WORKDIR/void-mklive/void-custom-gnome-production.iso"
