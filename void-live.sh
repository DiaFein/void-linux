#!/bin/bash

# ==============================================================================
# Void Linux Hybrid RAM-OS Builder (V9 - Ultimate Performance)
# Features: Rsync Staging, ZRAM Compression, Runit CPU Tuning, EarlyOOM,
#           Idempotent tmpfs, Sysctl Overcommit, and Log Suppression.
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo "[-] Error: This script must be run as root. (Use sudo)"
  exit 1
fi

# Build Lock
LOCKFILE="/tmp/trading-build.lock"
if [ -f "$LOCKFILE" ]; then 
    echo "[-] Error: Build is already running! (Lockfile exists)"
    exit 1
fi
trap 'rm -f "$LOCKFILE"' EXIT INT TERM
touch "$LOCKFILE"

echo "[+] Starting V9 Ultimate Trading OS Build Process..."

# Pre-Flight Disk Space Check
SFS_OUT="/boot/trading.sfs"
SFS_BAK="/boot/trading.sfs.bak"
TARGET_DIR=$(dirname "$SFS_OUT")

FREE_SPACE=$(df -k "$TARGET_DIR" | awk 'NR==2 {print $4}')
if [ "$FREE_SPACE" -lt 1500000 ]; then
  echo "[-] CRITICAL: Not enough space in $TARGET_DIR! Need at least 1500 MB."
  exit 1
fi

# Dependency Check (Added earlyoom & zramen to ensure host has them)
if ! command -v mksquashfs &> /dev/null || ! command -v rsync &> /dev/null || ! command -v unsquashfs &> /dev/null || [ ! -d /etc/sv/zramen ]; then
    echo "[+] Installing required tools (squashfs, rsync, earlyoom, zramen)..."
    xbps-install -Sy squashfs-tools rsync earlyoom zramen
fi

# Dracut Live Configuration
LIVE_CONF="/etc/dracut.conf.d/live.conf"
if ! grep -q "dmsquash-live" "$LIVE_CONF" 2>/dev/null; then
    echo "[+] Configuring dracut for live boot modules..."
    mkdir -p /etc/dracut.conf.d/
    echo 'add_dracutmodules+=" dmsquash-live "' > "$LIVE_CONF"
    LATEST_KERNEL=$(ls /boot/vmlinuz-* | sort -V | tail -n1 | sed 's|/boot/vmlinuz-||')
    dracut -f --kver "$LATEST_KERNEL"
fi

# Safe System Cleanup
echo "[+] Cleaning xbps cache and dropping memory caches..."
xbps-remove -yO
sync
echo 3 > /proc/sys/vm/drop_caches

# The Rsync Snapshot
WORKDIR="/tmp/live-build"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

echo "[+] Creating stable read-only snapshot via rsync..."
rsync -aAXx --delete \
  --exclude={"/proc/*","/sys/*","/dev/*","/run/*","/tmp/*","/mnt/*","/media/*","/boot/*","/var/cache/*","/var/tmp/*","/var/log/*","/home/*/.cache/*"} \
  / "$WORKDIR/"

if [ $? -ne 0 ]; then
    echo "[-] Error: rsync snapshot failed. Aborting."
    exit 1
fi

# ==============================================================================
# V9 ADVANCED PERFORMANCE TUNING & SANITIZATION
# ==============================================================================
echo "[+] Sanitizing fstab and injecting idempotent tmpfs..."
sed -i '/^UUID=/d' "$WORKDIR/etc/fstab"
sed -i '/^PARTUUID=/d' "$WORKDIR/etc/fstab"
grep -q "/tmp tmpfs" "$WORKDIR/etc/fstab" || echo "tmpfs /tmp tmpfs defaults,noatime,mode=1777 0 0" >> "$WORKDIR/etc/fstab"

echo "[+] Resetting machine identity & cleaning keys..."
rm -f "$WORKDIR/etc/machine-id"
touch "$WORKDIR/etc/machine-id"
rm -f "$WORKDIR/etc/ssh/ssh_host_"* 2>/dev/null || true

echo "[+] Purging NetworkManager and DHCP states..."
rm -rf "$WORKDIR/var/lib/NetworkManager/"* 2>/dev/null || true
rm -f "$WORKDIR/var/lib/dhcp/"* 2>/dev/null || true

echo "[+] Hardcoding robust DNS (Cloudflare / Google)..."
rm -f "$WORKDIR/etc/resolv.conf"
cat << EOF > "$WORKDIR/etc/resolv.conf"
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

echo "[+] Enforcing strict timezone synchronization..."
if [ -L /etc/localtime ]; then
    cp --remove-destination "$(readlink -f /etc/localtime)" "$WORKDIR/etc/localtime"
fi

# ----------------- THE V9 PERFORMANCE INJECTIONS -----------------

echo "[+] Configuring ZRAM (zstd) for massive memory multiplication..."
mkdir -p "$WORKDIR/etc/default"
cat <<EOF > "$WORKDIR/etc/default/zramen"
ZRAM_PERCENT=50
ZRAM_ALGO=zstd
EOF
ln -sf /etc/sv/zramen "$WORKDIR/var/service/"

echo "[+] Creating native runit service for CPU Performance Governor..."
mkdir -p "$WORKDIR/etc/sv/cpu-performance"
cat << 'EOF' > "$WORKDIR/etc/sv/cpu-performance/run"
#!/bin/sh
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$cpu" 2>/dev/null
done
# Sleep infinity keeps the runit service 'up' without eating CPU
exec sleep infinity
EOF
chmod +x "$WORKDIR/etc/sv/cpu-performance/run"
ln -sf /etc/sv/cpu-performance "$WORKDIR/var/service/"

echo "[+] Injecting EarlyOOM threshold config..."
echo 'EARLYOOM_ARGS="-m 5 -s 5 --avoid '"'"'(^chrome$|^brave$|^firefox$)'"'"' --prefer '"'"'code|node|python'"'"'"' > "$WORKDIR/etc/default/earlyoom"
ln -sf /etc/sv/earlyoom "$WORKDIR/var/service/"

echo "[+] Baking sysctl OOM protection into the image..."
echo "vm.overcommit_memory=1" >> "$WORKDIR/etc/sysctl.conf"
echo "vm.swappiness=10" >> "$WORKDIR/etc/sysctl.conf"

echo "[+] Suppressing native runit logging to save RAM and CPU..."
# Void uses socklog, not systemd/journald. Unlinking these disables local logging.
rm -f "$WORKDIR/var/service/socklog-unix" 2>/dev/null || true
rm -f "$WORKDIR/var/service/nanoklogd" 2>/dev/null || true

echo "[+] Marking build version..."
date > "$WORKDIR/etc/trading-os-build"
# ==============================================================================

# The Build & Verification Phase
if [ -f "$SFS_OUT" ]; then
    mv "$SFS_OUT" "$SFS_BAK"
fi

echo "[+] Compressing staging area into $SFS_OUT..."
mksquashfs "$WORKDIR" "$SFS_OUT" \
    -comp zstd -Xcompression-level 15 -b 1M -processors $(nproc) \
    -noappend

if [ $? -ne 0 ]; then
    echo "[-] CRITICAL: mksquashfs failed. Restoring backup."
    mv "$SFS_BAK" "$SFS_OUT" 2>/dev/null
    rm -rf "$WORKDIR"
    exit 1
fi

echo "[+] Verifying SquashFS Integrity..."
if ! unsquashfs -t "$SFS_OUT" > /dev/null 2>&1; then
    echo "[-] CRITICAL: Image integrity check failed! Restoring backup."
    mv "$SFS_BAK" "$SFS_OUT" 2>/dev/null
    rm -rf "$WORKDIR"
    exit 1
fi

echo "[+] Final Image Size: $(du -h "$SFS_OUT" | awk '{print $1}')"
rm -rf "$WORKDIR"

# Dynamic GRUB Configuration
echo "[+] Configuring GRUB dynamically..."
BOOT_UUID=$(findmnt -n -o UUID -T /boot)
ROOT_UUID=$(findmnt -n -o UUID -T /)
KVER=$(ls /boot/vmlinuz-* | sort -V | tail -n1 | sed 's|/boot/vmlinuz-||')
GRUB_FILE="/etc/grub.d/41_trading_os"

if [ -f "$GRUB_FILE" ]; then
    cp "$GRUB_FILE" "${GRUB_FILE}.bak"
fi

cat << EOF > "$GRUB_FILE"
#!/bin/sh
cat << 'INNEREOF'
menuentry "Void Trading OS (RAM Mode - OverlayFS)" --class void {
    search --no-floppy --fs-uuid --set=root $BOOT_UUID
    linux /boot/vmlinuz-$KVER root=live:/dev/disk/by-uuid/$BOOT_UUID:/boot/trading.sfs ro rd.live.image rd.live.ram=1 rd.live.overlay.overlayfs=1 quiet rd.udev.log_level=3
    initrd /boot/initramfs-${KVER}.img
}

menuentry "Void Base System (Fallback / Maintenance)" --class void {
    search --no-floppy --fs-uuid --set=root $BOOT_UUID
    linux /boot/vmlinuz-$KVER root=UUID=$ROOT_UUID ro quiet
    initrd /boot/initramfs-${KVER}.img
}
INNEREOF
EOF

chmod +x "$GRUB_FILE"

# Update GRUB & Self-Install
echo "[+] Updating GRUB bootloader..."
grub-mkconfig -o /boot/grub/grub.cfg

TARGET_BIN="/usr/local/sbin/update-void-live"
SCRIPT_PATH=$(realpath "$0")

if [ "$SCRIPT_PATH" != "$TARGET_BIN" ]; then
    echo "----------------------------------------------------------------------"
    echo "[+] First-Run Automation: Installing script globally..."
    cp "$SCRIPT_PATH" "$TARGET_BIN"
    chmod 755 "$TARGET_BIN"
    echo "[!] Installed. Future updates can be executed via: sudo update-void-live"
fi

echo "=============================================================================="
echo "[+] SUCCESS: V9 Ultimate Trading OS is ready."
echo "=============================================================================="
