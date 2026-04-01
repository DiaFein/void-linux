#!/bin/bash
# ==============================================================================
# VOID LINUX PRODUCTION ISO BUILDER (TRUE FINAL ARCHITECTURE)
# Features: Dynamic Mirrors, Dual-Installer UX, Hardened Chroot, Safe Services,
#           Network Pre-Flight, BIOS/UEFI Fallback, Full Repo Scope.
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

echo "==> [3/6] Setting up Overlay, Custom UI, and Deployment Scripts..."
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

# 2. Live ISO Welcome Message (TTY UX bridge)
cat <<EOF > custom-overlay/etc/issue
\S \r (\l)

==================================================
 Welcome to the Custom Void Linux Live System!
 
 To begin the installation, type: void-setup
==================================================

EOF

# 3. Standard Installer
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
echo "    [+] Injecting Custom High-Performance Trading Installer..."
cat << 'EOF_TRADER' > custom-overlay/usr/bin/void-trading-install
#!/bin/bash
# ==============================================================================
# UNIFIED VOID LINUX AUTO-INSTALLER & PERFORMANCE TUNER (DYNAMIC STORAGE)
# ==============================================================================

set -euo pipefail

LOGFILE="/tmp/void-install.log"
exec > >(tee -i "$LOGFILE")
exec 2>&1

echo "[*] Installation logging started. Saving to $LOGFILE"

# CRITICAL FIX: Network Connectivity Check
echo "[*] Verifying network connectivity..."
if ! ping -c 2 8.8.8.8 >/dev/null 2>&1; then
    echo "[!] CRITICAL: No internet connection detected. Please connect to a network and try again."
    exit 1
fi

clear
echo "======================================================================"
echo "      VOID HIGH-PERFORMANCE DEPLOYMENT (UNIVERSAL STORAGE)            "
echo "======================================================================"

echo -e "\n[*] Available Storage Devices:"
lsblk -d -o NAME,SIZE,FSTYPE,MODEL | grep -v "loop"

echo ""
read -rp "Target disk (e.g. /dev/sda, /dev/vda, /dev/nvme0n1): " DISK

echo -e "\n[*] Partition & Volume Sizing"
read -rp "EFI partition size in MiB [Default: 512]: " EFI_SIZE
EFI_SIZE=${EFI_SIZE:-512}

read -rp "BOOT partition size in MiB [Default: 1024]: " BOOT_SIZE
BOOT_SIZE=${BOOT_SIZE:-1024}

echo "-> Note: LUKS Crypt will use the remaining physical disk space."

read -rp "LVM SWAP volume size in GiB [Default: 4]: " SWAP_SIZE
SWAP_SIZE=${SWAP_SIZE:-4}

read -rp "LVM ROOT (/) volume size in GiB [Default: 30]: " ROOT_LV_SIZE
ROOT_LV_SIZE=${ROOT_LV_SIZE:-30}

echo "-> Note: LVM HOME will automatically use the remaining encrypted space."

echo -e "\n[*] Credentials & Config"
read -rsp "Enter LUKS encryption password: " LUKS_PASS; echo
read -rp "Enter new username: " SYS_USER
read -rsp "Enter user password (also used for root): " SYS_PASS; echo

read -rp "Enter hostname [void-trading]: " HOST_NAME
HOST_NAME=${HOST_NAME:-void-trading}

read -rp "Enable SSD TRIM for LUKS (faster, slightly less secure)? [y/N]: " TRIM_PROMPT
if [[ "$TRIM_PROMPT" =~ ^[Yy]$ ]]; then
    CRYPT_OPTS="luks,discard"
else
    CRYPT_OPTS="luks"
fi

echo -e "\n⚠️  WARNING: ALL DATA ON $DISK WILL BE PERMANENTLY ERASED!"
read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Aborted by user."; exit 1; }

if [[ "$DISK" =~ [0-9]$ ]]; then
    P="${DISK}p"
else
    P="${DISK}"
fi
EFI="${P}1"
BOOT="${P}2"
ROOT_PART="${P}3"

echo "[*] Wiping and partitioning $DISK..."
wipefs -a "$DISK"
parted -s "$DISK" mklabel gpt

EFI_END=$(( 1 + EFI_SIZE ))
BOOT_END=$(( EFI_END + BOOT_SIZE ))

parted -s "$DISK" mkpart ESP fat32 1MiB ${EFI_END}MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart BOOT ext4 ${EFI_END}MiB ${BOOT_END}MiB
parted -s "$DISK" mkpart ROOT ${BOOT_END}MiB 100%

partprobe "$DISK"
sleep 2

mkfs.vfat -F32 "$EFI"
mkfs.ext4 -F "$BOOT"

printf "%s" "$LUKS_PASS" | cryptsetup luksFormat "$ROOT_PART" -
printf "%s" "$LUKS_PASS" | cryptsetup open "$ROOT_PART" cryptroot -

pvcreate /dev/mapper/cryptroot
vgcreate voidvg /dev/mapper/cryptroot

lvcreate -L "${SWAP_SIZE}G" voidvg -n swap
lvcreate -L "${ROOT_LV_SIZE}G" voidvg -n root
lvcreate -l 100%FREE voidvg -n home

mkfs.ext4 -F /dev/voidvg/root
mkfs.ext4 -F /dev/voidvg/home
mkswap /dev/voidvg/swap

mount /dev/voidvg/root /mnt
mkdir -p /mnt/{boot,boot/efi,home,etc/xbps.d}
mount "$BOOT" /mnt/boot
mount "$EFI" /mnt/boot/efi
mount /dev/voidvg/home /mnt/home
swapon /dev/voidvg/swap

BOOT_UUID=$(blkid -s UUID -o value "$BOOT")
EFI_UUID=$(blkid -s UUID -o value "$EFI")
ROOT_LV_UUID=$(blkid -s UUID -o value /dev/voidvg/root)
HOME_LV_UUID=$(blkid -s UUID -o value /dev/voidvg/home)
SWAP_LV_UUID=$(blkid -s UUID -o value /dev/voidvg/swap)
CRYPT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

UCODE=""
grep -q "AuthenticAMD" /proc/cpuinfo && UCODE="amd-ucode"
grep -q "GenuineIntel" /proc/cpuinfo && UCODE="intel-ucode"

echo "XBPS_FETCH_OPTIONS=\"--parallel=5\"" > /mnt/etc/xbps.d/00-fetch.conf
echo "virtualpkg=linux:linux-mainline" > /mnt/etc/xbps.d/10-kernel.conf

echo "[*] Using dynamically selected mirror: __REPO_URL__"
# CRITICAL FIX: Explicitly added current/nonfree to the installer scope
xbps-install -Sy --repository-cache /var/cache/xbps \
    -R "__REPO_URL__/current" \
    -R "__REPO_URL__/current/nonfree" \
    -r /mnt \
    base-system linux-mainline linux-mainline-headers linux-lts linux-lts-headers $UCODE cryptsetup lvm2 grub-x86_64-efi sudo \
    linux-firmware-amd mesa-dri mesa-vaapi mesa-vulkan-radeon \
    gnome-core gdm dbus elogind NetworkManager \
    ethtool pciutils zramen irqbalance lm_sensors cpupower dconf haveged preload

mount --rbind /dev /mnt/dev
mount --rbind /proc /mnt/proc
mount --rbind /sys /mnt/sys
cp /etc/resolv.conf /mnt/etc/resolv.conf

echo "[*] Entering strictly secured chroot environment..."
# Passed DISK into chroot for GRUB BIOS fallback
chroot /mnt /usr/bin/env HOST_NAME="$HOST_NAME" CRYPT_UUID="$CRYPT_UUID" CRYPT_OPTS="$CRYPT_OPTS" \
    ROOT_LV_UUID="$ROOT_LV_UUID" HOME_LV_UUID="$HOME_LV_UUID" BOOT_UUID="$BOOT_UUID" \
    EFI_UUID="$EFI_UUID" SWAP_LV_UUID="$SWAP_LV_UUID" SYS_USER="$SYS_USER" SYS_PASS="$SYS_PASS" DISK="$DISK" \
    /bin/bash << 'CHROOT_EOF'
set -euo pipefail

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

echo "en_US.UTF-8 UTF-8" >> /etc/default/libc-locales
xbps-reconfigure -f glibc-locales
ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime

useradd -m -G wheel,audio,video,input -s /bin/bash "$SYS_USER"
echo "$SYS_USER:$SYS_PASS" | chpasswd
echo "root:$SYS_PASS" | chpasswd
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="amd_pstate=active audit=0 nowatchdog nmi_watchdog=0 rcu_nocbs=all quiet loglevel=3 /' /etc/default/grub

grep -q "^GRUB_TIMEOUT=" /etc/default/grub \
  && sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' /etc/default/grub \
  || echo "GRUB_TIMEOUT=1" >> /etc/default/grub

grep -q "^GRUB_DISABLE_SUBMENU=" /etc/default/grub \
  && sed -i 's/^GRUB_DISABLE_SUBMENU=.*/GRUB_DISABLE_SUBMENU=y/' /etc/default/grub \
  || echo "GRUB_DISABLE_SUBMENU=y" >> /etc/default/grub

echo 'add_dracutmodules+=" crypt lvm "' > /etc/dracut.conf.d/crypt.conf
echo 'hostonly="yes"' > /etc/dracut.conf.d/hostonly.conf

for k_dir in /lib/modules/*; do
    if [ -d "$k_dir" ]; then
        KVER=$(basename "$k_dir")
        dracut -f --kver "$KVER"
    fi
done

# CRITICAL FIX: Safe GRUB Installation with BIOS Fallback
if [ -d /sys/firmware/efi ]; then
    echo "[*] UEFI detected. Installing x86_64-efi GRUB..."
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Void --recheck
else
    echo "[!] Legacy BIOS detected. Installing i386-pc GRUB to $DISK..."
    grub-install --target=i386-pc --recheck "$DISK"
fi
grub-mkconfig -o /boot/grub/grub.cfg

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

mkdir -p /etc/default
echo 'zram_size=50%' > /etc/default/zramen

mkdir -p /etc/chromium
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

for s in dbus elogind NetworkManager zramen irqbalance gdm lvm haveged fstrim preload udevd dhcpcd; do
    [ -d "/etc/sv/$s" ] && ln -sfn "/etc/sv/$s" /etc/runit/runsvdir/default/
done

xbps-remove -Fy tracker3-miners || true
CHROOT_EOF

cp "$LOGFILE" /mnt/root/void-install.log
umount -R /mnt
swapoff -a

echo "======================================================================"
echo "   INSTALL COMPLETE: Reboot, enter LUKS pass, and enjoy the speed.    "
echo "======================================================================"
EOF_TRADER

chmod +x custom-overlay/usr/bin/void-trading-install

# Bind the dynamically selected repo url to the installer script
sed -i "s|__REPO_URL__|$REPO_URL|g" custom-overlay/usr/bin/void-trading-install

echo "==> [4/6] Defining finalized package list..."
APPS="gnome-core gnome-terminal chromium NetworkManager network-manager-applet elogind xdg-user-dirs xdg-utils dialog"
VIRT="qemu-ga spice-vdagent"
UTILS="dhcpcd iproute2 bash-completion nano htop wget curl grub-x86_64-efi os-prober cryptsetup lvm2 mdadm btrfs-progs xfsprogs dosfstools e2fsprogs"
FIRMWARE="linux-firmware linux-firmware-network linux-firmware-amd linux-firmware-intel linux-firmware-nvidia intel-ucode"
DRIVERS="mesa mesa-dri mesa-vulkan-radeon mesa-vulkan-intel vulkan-loader void-repo-nonfree"

ALL_PKGS="$APPS $VIRT $UTILS $FIRMWARE $DRIVERS"

echo "==> [5/6] Validating package list against $REPO_URL..."

XBPS_CMD=$(command -v xbps-install || echo "$PWD/xbps-static/usr/bin/xbps-install")

if [ -f "$XBPS_CMD" ] || command -v xbps-install >/dev/null 2>&1; then
    DUMMY_ROOT=$(mktemp -d)
    
    sudo mkdir -p "$DUMMY_ROOT/var/db/xbps/keys"
    sudo cp keys/* "$DUMMY_ROOT/var/db/xbps/keys/"
    
    echo "    Syncing repository indices for dry-run verification..."
    sudo env XBPS_ARCH=x86_64 "$XBPS_CMD" -S -r "$DUMMY_ROOT" \
        --repository="$REPO_URL/current" \
        --repository="$REPO_URL/current/nonfree" > /dev/null

    MISSING_PKGS=""
    for pkg in $ALL_PKGS; do
        if ! sudo env XBPS_ARCH=x86_64 "$XBPS_CMD" -n -r "$DUMMY_ROOT" \
            --repository="$REPO_URL/current" \
            --repository="$REPO_URL/current/nonfree" \
            "$pkg" > /dev/null 2>&1; then
            MISSING_PKGS="$MISSING_PKGS $pkg"
        fi
    done
    
    sudo rm -rf "$DUMMY_ROOT"
    
    if [ -n "$MISSING_PKGS" ]; then
        echo "    [!] CRITICAL ERROR: The following packages do NOT exist:"
        for missing in $MISSING_PKGS; do
            echo "        -> $missing"
        done
        echo "    Aborting build. Please fix your package list."
        exit 1
    else
        echo "    [+] All packages verified successfully!"
    fi
else
    echo "    [?] Could not locate xbps-install. Skipping package validation."
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

echo "==> SUCCESS!"
echo "    Your ISO is located at: $WORKDIR/void-mklive/void-custom-gnome-production.iso"
