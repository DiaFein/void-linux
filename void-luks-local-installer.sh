#!/bin/bash
# ==============================================================================
# VOID LINUX HIGH-PERFORMANCE DEPLOYER (PRODUCTION MASTER)
# Target: LUKS + LVM + GNOME + AMD GPU + Mainline/LTS
# Audited: Fixed Chroot Directory Creation, Local/Network Install, Mirror Sync
# ==============================================================================

set -euo pipefail

# --- 1. Logging ---
LOGFILE="/tmp/void-install.log"
exec > >(tee -i "$LOGFILE")
exec 2>&1

echo "[*] Installation logging started. Saving to $LOGFILE"
clear
echo "======================================================================"
echo "      VOID HIGH-PERFORMANCE DEPLOYMENT (UNIVERSAL STORAGE)            "
echo "======================================================================"

# --- 2. System Discovery ---
echo -e "\n[*] Available Storage Devices:"
lsblk -d -o NAME,SIZE,FSTYPE,MODEL | grep -v "loop"

echo ""
read -rp "Target disk (e.g. /dev/sda, /dev/vda, /dev/nvme0n1): " DISK

# --- 3. Installation Source ---
echo -e "\n[*] Installation Source"
echo "1) Local ISO Clone (Lightning Fast - Copies live environment directly to disk)"
echo "2) Network Install (Slower - Downloads fresh packages from fastest mirror)"
read -rp "Select source [1 or 2, Default: 1]: " INSTALL_SOURCE
INSTALL_SOURCE=${INSTALL_SOURCE:-1}

# --- 4. Dynamic Sizing ---
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

# --- 5. Credentials ---
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

# --- 6. Partitioning Logic ---
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

echo "[*] Initializing LUKS Encryption..."
printf "%s" "$LUKS_PASS" | cryptsetup luksFormat "$ROOT_PART" -
printf "%s" "$LUKS_PASS" | cryptsetup open "$ROOT_PART" cryptroot -

echo "[*] Building LVM Architecture..."
pvcreate /dev/mapper/cryptroot
vgcreate voidvg /dev/mapper/cryptroot

lvcreate -L "${SWAP_SIZE}G" voidvg -n swap
lvcreate -L "${ROOT_LV_SIZE}G" voidvg -n root
lvcreate -l 100%FREE voidvg -n home

mkfs.ext4 -F /dev/voidvg/root
mkfs.ext4 -F /dev/voidvg/home
mkswap /dev/voidvg/swap

# --- 7. Secure Mount Sequence ---
echo "[*] Mounting filesystems securely..."
mount /dev/voidvg/root /mnt
mkdir -p /mnt/{boot,home,etc/xbps.d,var/db/xbps/keys}

mount "$BOOT" /mnt/boot
mkdir -p /mnt/boot/efi
mount "$EFI" /mnt/boot/efi

mount /dev/voidvg/home /mnt/home
swapon /dev/voidvg/swap

BOOT_UUID=$(blkid -s UUID -o value "$BOOT")
EFI_UUID=$(blkid -s UUID -o value "$EFI")
ROOT_LV_UUID=$(blkid -s UUID -o value /dev/voidvg/root)
HOME_LV_UUID=$(blkid -s UUID -o value /dev/voidvg/home)
SWAP_LV_UUID=$(blkid -s UUID -o value /dev/voidvg/swap)
CRYPT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

# --- 8. The Execution Engine (Local vs Network) ---
UCODE=""
grep -q "GenuineIntel" /proc/cpuinfo && UCODE="intel-ucode"
echo "virtualpkg=linux:linux-mainline" > /mnt/etc/xbps.d/10-kernel.conf

if [ "$INSTALL_SOURCE" = "1" ] && [ -d "/repo" ]; then
    echo "[*] Starting Lightning-Fast Local Installation..."
    
    DIRS=""
    for d in bin etc home lib lib32 lib64 opt root sbin usr var; do
        [ -e "/$d" ] && DIRS="$DIRS $d"
    done
    
    echo " -> Cloning root filesystem (this will only take a moment)..."
    tar -cpf - -C / $DIRS | tar -xpf - -C /mnt
    
    echo " -> Cloning boot partition..."
    tar -cpf - -C /boot . | tar -xpf - -C /mnt/boot
    
    echo " -> Staging virtual filesystems..."
    mkdir -p /mnt/{dev,proc,sys,tmp,run,mnt,media}
    chmod 1777 /mnt/tmp
    
    # -i ignores network configs and strictly uses the local path
    REPO_FLAGS="-i -R /repo"
    
    echo "[*] Repairing base system via local cache..."
    cp -a /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ || true
    xbps-install -Sy -c /var/cache/xbps $REPO_FLAGS -r /mnt \
        base-system linux-mainline linux-mainline-headers linux-lts linux-lts-headers $UCODE cryptsetup lvm2 grub-x86_64-efi sudo \
        linux-firmware-amd mesa-dri mesa-vaapi mesa-vulkan-radeon \
        gnome-core gdm dbus elogind NetworkManager \
        ethtool pciutils zramen irqbalance lm_sensors cpupower dconf haveged preload parted

else
    echo "[*] Starting Network Installation..."
    
    echo "[*] Verifying network connectivity..."
    if ! ping -c 2 8.8.8.8 >/dev/null 2>&1; then
        echo "[!] CRITICAL: No internet connection detected. Please connect to a network."
        exit 1
    fi
    
    echo "[*] Pinging Tier-1 mirrors to find the fastest connection..."
    BEST_TIME=999
    REPO_URL="https://repo-default.voidlinux.org"
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
    echo "[+] Fastest Mirror Selected: $REPO_URL (Response time: ${BEST_TIME}s)"
    
    echo "XBPS_FETCH_OPTIONS=\"--parallel=5\"" > /mnt/etc/xbps.d/00-fetch.conf
    REPO_FLAGS="-R $REPO_URL/current -R $REPO_URL/current/nonfree"

    echo "[*] Downloading and installing system base..."
    xbps-install -Sy -c /var/cache/xbps $REPO_FLAGS -r /mnt \
        base-system linux-mainline linux-mainline-headers linux-lts linux-lts-headers $UCODE cryptsetup lvm2 grub-x86_64-efi sudo \
        linux-firmware-amd mesa-dri mesa-vaapi mesa-vulkan-radeon \
        gnome-core gdm dbus elogind NetworkManager \
        ethtool pciutils zramen irqbalance lm_sensors cpupower dconf haveged preload parted
fi

# --- 9. Pre-flight Configurations ---
mount --rbind /dev /mnt/dev
mount --rbind /proc /mnt/proc
mount --rbind /sys /mnt/sys
cp /etc/resolv.conf /mnt/etc/resolv.conf

echo "[*] Entering strictly secured chroot environment..."
chroot /mnt /usr/bin/env HOST_NAME="$HOST_NAME" CRYPT_UUID="$CRYPT_UUID" CRYPT_OPTS="$CRYPT_OPTS" \
    ROOT_LV_UUID="$ROOT_LV_UUID" HOME_LV_UUID="$HOME_LV_UUID" BOOT_UUID="$BOOT_UUID" \
    EFI_UUID="$EFI_UUID" SWAP_LV_UUID="$SWAP_LV_UUID" SYS_USER="$SYS_USER" SYS_PASS="$SYS_PASS" DISK="$DISK" \
    INSTALL_SOURCE="$INSTALL_SOURCE" \
    /bin/bash << 'CHROOT_EOF'
set -euo pipefail

# === BULLETPROOF DIRECTORY CREATION ===
# Ensures all directories exist before configuration files are written
mkdir -p /etc/sysctl.d
mkdir -p /etc/modules-load.d
mkdir -p /etc/security/limits.d
mkdir -p /etc/default
mkdir -p /etc/chromium
mkdir -p /etc/dracut.conf.d
mkdir -p /usr/local/bin
mkdir -p /etc/xbps.d

# --- A. Core System Config ---
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

# Force future kernel updates to use mainline
echo "virtualpkg=linux:linux-mainline" > /etc/xbps.d/10-kernel.conf

# Set default robust mirrors
echo "repository=https://repo-default.voidlinux.org/current" > /etc/xbps.d/00-repository-main.conf
echo "repository=https://repo-default.voidlinux.org/current/nonfree" >> /etc/xbps.d/00-repository-main.conf

echo "en_US.UTF-8 UTF-8" >> /etc/default/libc-locales
xbps-reconfigure -f glibc-locales
ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime

# --- B. Users & Cleanups ---
useradd -m -G wheel,audio,video,input -s /bin/bash "$SYS_USER"
echo "$SYS_USER:$SYS_PASS" | chpasswd
echo "root:$SYS_PASS" | chpasswd
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Purge Live ISO remnants if using the Local Clone method
if [ "$INSTALL_SOURCE" = "1" ]; then
    xbps-remove -Ry void-live >/dev/null 2>&1 || true
    userdel -f -r anon >/dev/null 2>&1 || true
fi

# --- C. GRUB & Dracut Hardening ---
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
        echo "[*] Building initramfs for kernel: $KVER"
        dracut -f --kver "$KVER"
    fi
done

if [ -d /sys/firmware/efi ]; then
    echo "[*] UEFI detected. Installing x86_64-efi GRUB..."
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Void --recheck
else
    echo "[!] Legacy BIOS detected. Installing i386-pc GRUB to $DISK..."
    grub-install --target=i386-pc --recheck "$DISK"
fi
grub-mkconfig -o /boot/grub/grub.cfg

# --- D. Network & Latency Optimization ---
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

# --- E. Hardware Acceleration ---
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

# --- F. Service Enablement ---
for s in dbus elogind NetworkManager zramen irqbalance gdm lvm haveged fstrim preload udevd dhcpcd; do
    [ -d "/etc/sv/$s" ] && ln -sfn "/etc/sv/$s" /etc/runit/runsvdir/default/
done

xbps-remove -Fy tracker3-miners || true
CHROOT_EOF

# --- 10. Final Cleanup ---
cp "$LOGFILE" /mnt/root/void-install.log
umount -R /mnt
swapoff -a

echo "======================================================================"
echo "   INSTALL COMPLETE: Reboot, enter LUKS pass, and enjoy the speed.    "
echo "======================================================================"
