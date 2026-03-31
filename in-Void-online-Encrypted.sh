#!/bin/bash
# ==============================================================================
# UNIFIED VOID LINUX AUTO-INSTALLER & PERFORMANCE TUNER (FINAL MASTER)
# Target: LUKS + LVM + GNOME + AMD GPU + Mainline/LTS Dual Boot
# Upgrades: xmirror Auto-Speed, Anti-404 Cache Clear, Global Logging
# ==============================================================================

set -euo pipefail

# --- 1. Initialize Global Logging ---
LOGFILE="/tmp/void-install.log"
exec > >(tee -i "$LOGFILE")
exec 2>&1

echo "[*] Installation logging started. Saving to $LOGFILE"

# --- 2. System Discovery & Inputs ---
clear
echo "======================================================================"
echo "      VOID HIGH-PERFORMANCE DEPLOYMENT (MASTER EDITION)               "
echo "======================================================================"

echo -e "\n[*] Available Storage Devices:"
lsblk -o NAME,SIZE,FSTYPE,MODEL,MOUNTPOINT | grep -v "loop"

echo ""
read -rp "Target disk (e.g. /dev/sda or /dev/nvme0n1): " DISK
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

# --- SAFETY GUARD ---
echo -e "\n⚠️  WARNING: ALL DATA ON $DISK WILL BE PERMANENTLY ERASED!"
read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Aborted by user."; exit 1; }

# Detect partition naming
if [[ $DISK == *nvme* ]]; then P="${DISK}p"; else P="${DISK}"; fi
EFI="${P}1"
BOOT="${P}2"
ROOT_PART="${P}3"

# --- 3. Disk Preparation ---
echo "[*] Wiping and partitioning $DISK..."
wipefs -a "$DISK"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart BOOT ext4 513MiB 1537MiB
parted -s "$DISK" mkpart ROOT 1537MiB 100%

echo "[*] Probing partitions..."
partprobe "$DISK"
sleep 2

echo "[*] Formatting hardware partitions..."
mkfs.vfat -F32 "$EFI"
mkfs.ext4 -F "$BOOT"

echo "[*] Setting up LUKS..."
printf "%s" "$LUKS_PASS" | cryptsetup luksFormat "$ROOT_PART" -
printf "%s" "$LUKS_PASS" | cryptsetup open "$ROOT_PART" cryptroot -

echo "[*] Setting up LVM..."
pvcreate /dev/mapper/cryptroot
vgcreate voidvg /dev/mapper/cryptroot
lvcreate -L 2G voidvg -n swap
lvcreate -L 30G voidvg -n root
lvcreate -l 100%FREE voidvg -n home

echo "[*] Formatting LVM volumes..."
mkfs.ext4 -F /dev/voidvg/root
mkfs.ext4 -F /dev/voidvg/home
mkswap /dev/voidvg/swap

echo "[*] Mounting filesystems..."
mount /dev/voidvg/root /mnt
mkdir -p /mnt/{boot,boot/efi,home,etc/xbps.d}
mount "$BOOT" /mnt/boot
mount "$EFI" /mnt/boot/efi
mount /dev/voidvg/home /mnt/home
swapon /dev/voidvg/swap

# --- Extract UUIDs ---
BOOT_UUID=$(blkid -s UUID -o value "$BOOT")
EFI_UUID=$(blkid -s UUID -o value "$EFI")
ROOT_LV_UUID=$(blkid -s UUID -o value /dev/voidvg/root)
HOME_LV_UUID=$(blkid -s UUID -o value /dev/voidvg/home)
SWAP_LV_UUID=$(blkid -s UUID -o value /dev/voidvg/swap)
CRYPT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

# --- 4. Mirror Optimization & Anti-404 Tweaks ---
echo "[*] Optimizing mirrors to prevent 404 errors and maximize speed..."

# 1. Sync live system enough to install xmirror safely
xbps-install -S || true
xbps-install -y xmirror

# 2. Automatically find and configure the lowest-latency mirror
echo "[*] Pinging Tier-1 mirrors to find the fastest route..."
xmirror -s

# 3. Extract the chosen mirror URL to explicitly pass to our target system
MIRROR_URL=$(grep 'repository=' /etc/xbps.d/00-repository-main.conf | head -n1 | cut -d= -f2)
echo "[+] Fastest mirror selected: $MIRROR_URL"

# 4. Persist this fast mirror to the newly installed system
cp /etc/xbps.d/00-repository-main.conf /mnt/etc/xbps.d/

# 5. Destroy the old cache to prevent hash mismatches and stale 404 drops
echo "[*] Flushing package cache to guarantee fresh downloads..."
rm -rf /var/cache/xbps/*

# --- 5. Base Installation ---
echo "[*] Detecting CPU architecture for microcode..."
UCODE=""
grep -q "AuthenticAMD" /proc/cpuinfo && UCODE="amd-ucode"
grep -q "GenuineIntel" /proc/cpuinfo && UCODE="intel-ucode"

echo "[*] Configuring XBPS Parallel Fetch..."
echo "XBPS_FETCH_OPTIONS=\"--parallel=5\"" > /mnt/etc/xbps.d/00-fetch.conf
echo "virtualpkg=linux:linux-mainline" > /mnt/etc/xbps.d/10-kernel.conf

echo "[*] Syncing repositories and installing base system..."
# Using -Syu guarantees the index is refreshed right before the download begins
xbps-install -Syu --repository-cache /var/cache/xbps -R "$MIRROR_URL" -r /mnt \
    base-system linux-mainline linux-mainline-headers linux-lts linux-lts-headers $UCODE cryptsetup lvm2 grub-x86_64-efi sudo \
    linux-firmware-amd mesa-dri mesa-vaapi mesa-vulkan-radeon \
    gnome-core gdm dbus elogind NetworkManager \
    ethtool pciutils zramen irqbalance lm_sensors cpupower dconf haveged preload

# --- 6. Chroot Configuration & Optimization ---
echo "[*] Entering system configuration..."
mount --rbind /dev /mnt/dev
mount --rbind /proc /mnt/proc
mount --rbind /sys /mnt/sys
cp /etc/resolv.conf /mnt/etc/resolv.conf

chroot /mnt /bin/bash <<CHROOT_EOF
set -euo pipefail

# --- A. Basic System Config ---
echo "$HOST_NAME" > /etc/hostname

# Portable CRYPTTAB with dynamic TRIM support
echo "cryptroot UUID=$CRYPT_UUID none $CRYPT_OPTS" > /etc/crypttab

cat <<FSTAB > /etc/fstab
UUID=$ROOT_LV_UUID  /         ext4    defaults 0 1
UUID=$HOME_LV_UUID  /home     ext4    defaults 0 2
UUID=$BOOT_UUID     /boot     ext4    defaults 0 2
UUID=$EFI_UUID      /boot/efi vfat    defaults 0 2
UUID=$SWAP_LV_UUID  none      swap    defaults 0 0
tmpfs               /tmp      tmpfs   defaults,noatime,mode=1777 0 0
FSTAB

# --- B. Locale & Timezone ---
echo "en_US.UTF-8 UTF-8" >> /etc/default/libc-locales
xbps-reconfigure -f glibc-locales
ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime

# --- C. User & Root Passwords ---
useradd -m -G wheel,audio,video,input -s /bin/bash "$SYS_USER"
echo "$SYS_USER:$SYS_PASS" | chpasswd
echo "root:$SYS_PASS" | chpasswd
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# --- D. Kernel, Dracut & GRUB Tuning ---
echo "[*] Tuning Kernel parameters..."
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="amd_pstate=active audit=0 nowatchdog nmi_watchdog=0 rcu_nocbs=all quiet loglevel=3 /' /etc/default/grub

# Idempotent GRUB timeout injection
grep -q "^GRUB_TIMEOUT=" /etc/default/grub \
  && sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' /etc/default/grub \
  || echo "GRUB_TIMEOUT=1" >> /etc/default/grub

# Flatten GRUB menu for easy LTS rescue selection
grep -q "^GRUB_DISABLE_SUBMENU=" /etc/default/grub \
  && sed -i 's/^GRUB_DISABLE_SUBMENU=.*/GRUB_DISABLE_SUBMENU=y/' /etc/default/grub \
  || echo "GRUB_DISABLE_SUBMENU=y" >> /etc/default/grub

echo 'add_dracutmodules+=" crypt lvm "' > /etc/dracut.conf.d/crypt.conf
echo 'hostonly="yes"' > /etc/dracut.conf.d/hostonly.conf

# Build initramfs for ALL installed kernels (Mainline + LTS)
for k_dir in /lib/modules/*; do
    if [ -d "\$k_dir" ]; then
        KVER=\$(basename "\$k_dir")
        echo "[*] Building initramfs for kernel: \$KVER"
        dracut -f --kver "\$KVER"
    fi
done

grub-install --target=x86_64-efi --efi-directory=/boot/efi
grub-mkconfig -o /boot/grub/grub.cfg

# --- E. Network & Latency Optimization (Sysctl) ---
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

# --- F. High-Load Limits (WebSockets) ---
cat <<LIMITS > /etc/security/limits.d/99-trading-limits.conf
* soft nofile 500000
* hard nofile 1048576
root soft nofile 500000
root hard nofile 1048576
LIMITS

# --- G. ZRAM Optimization ---
mkdir -p /etc/default
echo 'zram_size=50%' > /etc/default/zramen

# --- H. Browser Hardware Acceleration ---
mkdir -p /etc/chromium
cat <<CHROMIUM > /etc/chromium/custom-flags.conf
--ignore-gpu-blocklist
--enable-gpu-rasterization
--enable-zero-copy
--use-vulkan
--enable-features=Vulkan
--ozone-platform-hint=auto
CHROMIUM

echo 'CHROMIUM_FLAGS="\$(cat /etc/chromium/custom-flags.conf | tr \"\\n\" \" \")"' > /etc/chromium/default

# --- I. Hardware Boot Init Script ---
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

# --- J. Service Management ---
for s in dbus elogind NetworkManager zramen irqbalance gdm lvm haveged fstrim preload; do
    [ -d "/etc/sv/\$s" ] && ln -sfn "/etc/sv/\$s" /etc/runit/runsvdir/default/
done

# --- K. Final UI Cleanup ---
xbps-remove -Fy tracker3-miners || true

CHROOT_EOF

# --- 7. Finalize ---
echo "[*] Copying install log to the new system..."
cp "$LOGFILE" /mnt/root/void-install.log

echo "[*] Cleaning up mounts..."
umount -R /mnt
swapoff -a

echo "======================================================================"
echo "   INSTALL COMPLETE: Reboot, enter LUKS pass, and enjoy the speed.    "
echo "======================================================================"
