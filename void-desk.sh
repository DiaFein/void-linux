#!/bin/bash

# ==============================================================================
# VOID LINUX HIGH-PERFORMANCE TRADING DESK DEPLOYMENT
# Target: AMD GPU, Wayland, Multi-4K 120Hz, Web-Based Trading
# Execution: Run as ROOT
# ==============================================================================

# --- 0. Safety & Environment Guard ---
[ "$EUID" -eq 0 ] || { echo "[!] CRITICAL: This script must be run as root."; exit 1; }
[ -d /sys ] || { echo "[!] CRITICAL: /sys not detected. Environment is broken. Exiting."; exit 1; }
set -e # Exit immediately if a pipeline fails

echo "======================================================================"
echo "          INITIALIZING VOID TRADING DESK DEPLOYMENT                   "
echo "======================================================================"

# --- 1. Preflight: System Update & Dependency Check ---
echo "[+] Syncing repositories and updating base system..."
xbps-install -Sy void-repo-nonfree || true
xbps-install -Syu -y

REQUIRED_PKGS="linux-firmware-amd mesa-dri mesa-vaapi mesa-vulkan-radeon \
    gnome-core gdm dbus elogind NetworkManager \
    ethtool pciutils zramen irqbalance lm_sensors cpupower dconf"

echo "[+] Verifying and installing core hardware and UI packages..."
xbps-install -y $REQUIRED_PKGS

# --- 2. Purging GNOME Indexing Miners ---
echo "[+] Stripping background indexing bloat (tracker3)..."
if xbps-query -Rs tracker3-miners >/dev/null 2>&1; then
    xbps-remove -Fy tracker3-miners || true
fi

# --- 3. Hardening GRUB & Kernel Parameters ---
echo "[+] Tuning Kernel parameters for polling and latency..."
[ -f /etc/default/grub ] || printf 'GRUB_CMDLINE_LINUX_DEFAULT=""\n' > /etc/default/grub

# Deduplicate GRUB_CMDLINE lines to keep only the first occurrence
awk '/^GRUB_CMDLINE_LINUX_DEFAULT=/ { if (!seen++) print; next } 1' \
/etc/default/grub > /tmp/grub.tmp && mv /tmp/grub.tmp /etc/default/grub

add_grub_flag() {
    flag="$1"
    esc="$(printf '%s\n' "$flag" | sed -e 's/[]\/$*.^[]/\\&/g')"
    if ! grep -Eq "(^|[[:space:]])${esc}([[:space:]]|$)" /etc/default/grub; then
        sed -i -E "s|^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=\"|&${flag} |" /etc/default/grub
    fi
}

add_grub_flag "amd_pstate=active"
add_grub_flag "audit=0"
add_grub_flag "nowatchdog"
add_grub_flag "nmi_watchdog=0"

# Clean up multiple spaces
sed -i -E 's/  +/ /g' /etc/default/grub
[ -d /boot/grub ] && grub-mkconfig -o /boot/grub/grub.cfg

# --- 4. Native Sysctl Network & Latency Tuning ---
echo "[+] Applying static sysctl latency routing (TuneD alternative)..."
mkdir -p /etc/sysctl.d
cat <<'EOF' > /etc/sysctl.d/99-trading-ultra.conf
# Core kernel latency and scheduling
kernel.dmesg_restrict=1
kernel.timer_migration=0
kernel.sched_wakeup_granularity_ns=1500000
kernel.sched_autogroup_enabled=0
kernel.sched_child_runs_first=0

# VM and memory management
vm.stat_interval=10
vm.swappiness=10
vm.dirty_ratio=10
vm.dirty_background_ratio=5
vm.page-cluster=0

# TCP/IP and Network Queueing
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_retries2=8
net.core.busy_read=50
net.core.busy_poll=50
net.core.netdev_max_backlog=250000
EOF

sysctl --system >/dev/null 2>&1 || true
echo 2 > /proc/irq/default_smp_affinity 2>/dev/null || true

# --- 5. Enabling TCP BBR Congestion Control ---
echo "[+] Forcing TCP BBR Kernel Module..."
mkdir -p /etc/modules-load.d
echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

# --- 6. Raising WebSocket Limits (File Descriptors) ---
echo "[+] Raising File Descriptor limits for persistent WebSockets..."
mkdir -p /etc/security/limits.d
cat <<'EOF' > /etc/security/limits.d/99-trading-limits.conf
* soft nofile 500000
* hard nofile 1048576
root soft nofile 500000
root hard nofile 1048576
EOF

if ! grep -q "session required pam_limits.so" /etc/pam.d/system-auth; then
    echo "session required pam_limits.so" >> /etc/pam.d/system-auth
fi

# --- 7. Hardware Acceleration for Web Browsers ---
echo "[+] Configuring Chromium/Brave for Native Wayland & Vulkan..."
mkdir -p /etc/chromium
cat <<'EOF' > /etc/chromium/custom-flags.conf
--ignore-gpu-blocklist
--enable-gpu-rasterization
--enable-zero-copy
--use-vulkan
--enable-features=Vulkan
--js-flags="--max-opt=3"
--ozone-platform-hint=auto
--enable-wayland-ime
EOF

# Export globally so it applies regardless of how the browser is launched
echo 'export CHROMIUM_USER_FLAGS="$(cat /etc/chromium/custom-flags.conf | tr '\''\n'\'' '\'' '\'')" ' > /etc/profile.d/browser-perf.sh
chmod +x /etc/profile.d/browser-perf.sh

# --- 8. Global GNOME Performance (dconf) ---
echo "[+] Hardcoding GNOME to disable animations and background updates..."
mkdir -p /etc/dconf/profile
cat <<'EOF' > /etc/dconf/profile/user
user-db:user
system-db:local
EOF

mkdir -p /etc/dconf/db/local.d
cat <<'EOF' > /etc/dconf/db/local.d/00-trading-performance
[org/gnome/desktop/interface]
enable-animations=false

[org/gnome/software]
download-updates=false

[org/freedesktop/tracker3/miner/files]
enable-monitors=false
EOF
dconf update

# --- 9. Boot Optimizations (/etc/rc.local) ---
echo "[+] Staging bare-metal hardware initialization script..."
cat <<'EOF' > /usr/local/bin/trading-boot-init.sh
#!/bin/bash
# 1. Disable Transparent Huge Pages (Reduces memory latency spikes)
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null

# 2. Set CPU Governor to Maximum Readiness
command -v cpupower >/dev/null && cpupower frequency-set -g performance >/dev/null 2>&1

# 3. Lock AMD GPU to Performance State
if [ -f /sys/class/drm/card0/device/power_dpm_force_performance_level ]; then
  echo high > /sys/class/drm/card0/device/power_dpm_force_performance_level
elif [ -f /sys/class/drm/card0/device/power_dpm_state ]; then
  echo performance > /sys/class/drm/card0/device/power_dpm_state
fi

# 4. Optimize Block Device Affinity (Storage routing)
for dev in /sys/block/nvme* /sys/block/sd*; do
    [ -e "$dev" ] || continue
    [ -e "$dev/queue/rq_affinity" ] && echo 2 > "$dev/queue/rq_affinity" 2>/dev/null
done
EOF
chmod +x /usr/local/bin/trading-boot-init.sh

# Ensure rc.local executes our boot script natively via Void's runit
if [ ! -f /etc/rc.local ]; then
    echo '#!/bin/sh' > /etc/rc.local
fi
if ! grep -q "trading-boot-init.sh" /etc/rc.local; then
    echo "/usr/local/bin/trading-boot-init.sh" >> /etc/rc.local
fi
chmod +x /etc/rc.local

# --- 10. Enabling Core Services ---
echo "[+] Enabling core system services..."
for s in dbus elogind NetworkManager zramen irqbalance; do
    [ -d "/etc/sv/$s" ] && ln -sfn "/etc/sv/$s" /var/service/
done

# Start GDM last to avoid breaking the script execution environment
[ -d "/etc/sv/gdm" ] && ln -sfn "/etc/sv/gdm" /var/service/

echo "======================================================================"
echo "[SUCCESS] Build Finalized. Reboot your system to apply all changes."
echo "======================================================================"
