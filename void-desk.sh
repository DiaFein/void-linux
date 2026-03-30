#!/bin/bash

# ==============================================================================
# VOID LINUX HIGH-PERFORMANCE TRADING DESK DEPLOYMENT
# Target: AMD GPU, Wayland, Multi-4K 120Hz, Web-Based Trading
# ==============================================================================

[ "$EUID" -eq 0 ] || { echo "[!] Please run as root."; exit 1; }
[ -d /sys ] || { echo "[!] No /sys detected. Exiting."; exit 1; }

echo "--- 1. Installing Core Packages ---"
xbps-install -Sy void-repo-nonfree
xbps-install -y \
    linux-firmware-amd mesa-dri mesa-vaapi mesa-vulkan-radeon \
    gnome-core gdm dbus elogind NetworkManager \
    tuned ethtool pciutils zramen irqbalance lm_sensors cpupower dconf

echo "--- 2. Purging GNOME Indexing Miners ---"
xbps-query -Rs tracker3-miners >/dev/null 2>&1 && xbps-remove -Fy tracker3-miners || true

echo "--- 3. Hardening GRUB & Kernel Parameters ---"
[ -f /etc/default/grub ] || printf 'GRUB_CMDLINE_LINUX_DEFAULT=""\n' > /etc/default/grub

# Deduplicate GRUB_CMDLINE lines
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

sed -i -E 's/  +/ /g' /etc/default/grub
[ -d /boot/grub ] && grub-mkconfig -o /boot/grub/grub.cfg

echo "--- 4. Sysctl Network & Latency Tuning ---"
[ -f /etc/sysctl.conf ] || touch /etc/sysctl.conf
add_sysctl() {
    key="$1"; val="$2"
    grep -q "^$key" /etc/sysctl.conf || echo "$key = $val" >> /etc/sysctl.conf
}
add_sysctl kernel.dmesg_restrict 1
add_sysctl vm.stat_interval 10
echo 2 > /proc/irq/default_smp_affinity 2>/dev/null || true
sysctl -e -p /etc/sysctl.conf >/dev/null 2>&1 || true

echo "--- 5. Enabling TCP BBR Congestion Control ---"
mkdir -p /etc/modules-load.d
echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

echo "--- 6. Raising WebSocket Limits (File Descriptors) ---"
mkdir -p /etc/security/limits.d
cat <<'EOF' > /etc/security/limits.d/99-trading-limits.conf
* soft nofile 500000
* hard nofile 1048576
root soft nofile 500000
root hard nofile 1048576
EOF
grep -q "session required pam_limits.so" /etc/pam.d/system-auth || echo "session required pam_limits.so" >> /etc/pam.d/system-auth

echo "--- 7. Hardware Acceleration for Web Browsers ---"
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
echo 'export CHROMIUM_USER_FLAGS="$(cat /etc/chromium/custom-flags.conf | tr '\''\n'\'' '\'' '\'')" ' > /etc/profile.d/browser-perf.sh
chmod +x /etc/profile.d/browser-perf.sh

echo "--- 8. Global GNOME Performance (dconf) ---"
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

echo "--- 9. Boot Optimizations (/etc/rc.local) ---"
cat <<'EOF' > /usr/local/bin/trading-boot-init.sh
#!/bin/bash
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
command -v cpupower >/dev/null && cpupower frequency-set -g performance >/dev/null 2>&1

if [ -f /sys/class/drm/card0/device/power_dpm_force_performance_level ]; then
  echo high > /sys/class/drm/card0/device/power_dpm_force_performance_level
elif [ -f /sys/class/drm/card0/device/power_dpm_state ]; then
  echo performance > /sys/class/drm/card0/device/power_dpm_state
fi

for dev in /sys/block/nvme* /sys/block/sd*; do
    [ -e "$dev" ] || continue
    [ -e "$dev/queue/rq_affinity" ] && echo 2 > "$dev/queue/rq_affinity" 2>/dev/null
done
EOF
chmod +x /usr/local/bin/trading-boot-init.sh

# Ensure rc.local executes the boot script
if [ ! -f /etc/rc.local ]; then
    echo '#!/bin/sh' > /etc/rc.local
fi
grep -q "trading-boot-init.sh" /etc/rc.local || echo "/usr/local/bin/trading-boot-init.sh" >> /etc/rc.local
chmod +x /etc/rc.local

echo "--- 10. Custom TuneD Profile ---"
mkdir -p /etc/tuned/trading-ultra
cat <<'EOF' > /etc/tuned/trading-ultra/tuned.conf
[main]
summary=Final Production Build for Low Latency Trading
include=network-latency
[cpu]
governor=performance
energy_performance_preference=performance
min_perf_pct=100
[sysctl]
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_retries2=8
net.core.busy_read=50
net.core.busy_poll=50
net.core.netdev_max_backlog=250000
kernel.timer_migration=0
kernel.sched_wakeup_granularity_ns=1500000
kernel.sched_autogroup_enabled=0
kernel.sched_child_runs_first=0
vm.swappiness=10
vm.dirty_ratio=10
vm.dirty_background_ratio=5
vm.page-cluster=0
EOF
echo "trading-ultra" > /etc/tuned/active_profile

echo "--- 11. Enabling Core Services ---"
mkdir -p /etc/sv/tuned
echo -e "#!/bin/sh\nexec tuned" > /etc/sv/tuned/run
chmod +x /etc/sv/tuned/run

for s in dbus elogind NetworkManager zramen irqbalance tuned; do
    [ -d "/etc/sv/$s" ] && ln -sfn "/etc/sv/$s" /var/service/
done

# Start GDM last to avoid interruption
[ -d "/etc/sv/gdm" ] && ln -sfn "/etc/sv/gdm" /var/service/

echo "--- Build Finalized. Reboot to apply kernel and Wayland changes. ---"
