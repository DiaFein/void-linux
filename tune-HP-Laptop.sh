#!/bin/bash

# ==============================================================================
# Void Linux + GNOME Wayland - MOBILE APU PROFILE (HP 15-fc1004au) v3.0
# Optimized for AMD Ryzen 5 7535HS, 8GB RAM, and 41Wh battery.
# Relies on TLP + tlp-pd for GNOME UI power management (no cpupower conflicts).
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run as root."
  exit 1
fi

TIMESTAMP=$(date +%F_%H-%M-%S)
BACKUP_DIR="/root/void-tune-backups-$TIMESTAMP"
mkdir -p "$BACKUP_DIR"

safe_replace() {
    local target="$1"
    local temp_file="$2"
    if [ ! -f "$target" ] || ! cmp -s "$target" "$temp_file"; then
        [ -f "$target" ] && cp "$target" "$BACKUP_DIR/$(basename "$target").bak" 2>/dev/null
        mv "$temp_file" "$target"
        return 0
    fi
    rm "$temp_file"
    return 1
}

# ------------------------------------------------------------------------------
# 1. Repositories, Dependencies & Firmware
# ------------------------------------------------------------------------------
echo -e "\n--- Synchronizing Firmware & Core Dependencies ---"
xbps-install -Sy void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree

# Removed cpupower. Added dbus, tlp, and required AMD firmware.
xbps-install -Sy linux-firmware-amd linux-firmware-network amd-ucode \
                 mesa-dri vulkan-loader mesa-vulkan-radeon mesa-vaapi mesa-vdpau \
                 linux-tools dbus zramen tlp

# ------------------------------------------------------------------------------
# 2. GRUB: APU Power Efficiency & Fixes
# ------------------------------------------------------------------------------
echo -e "\n--- Tuning GRUB (AMD P-State & iGPU fixes) ---"
GRUB_FILE="/etc/default/grub"
TMP_GRUB=$(mktemp)
cp "$GRUB_FILE" "$TMP_GRUB"

add_grub_param() {
    local param="$1"
    local param_key="${param%%=*}"
    local current_cmdline=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "$TMP_GRUB" | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"/\1/')
    
    if ! echo "$current_cmdline" | grep -qE "(^|[[:space:]])${param_key}(=|[[:space:]]|$)"; then
        sed -i -E "s/^(GRUB_CMDLINE_LINUX_DEFAULT=\".*)\"/\1 $param\"/" "$TMP_GRUB"
    fi
}

add_grub_param "nowatchdog"
add_grub_param "zswap.enabled=0"
add_grub_param "amd_pstate=active"
add_grub_param "amdgpu.sg_display=0"

if safe_replace "$GRUB_FILE" "$TMP_GRUB"; then
    update-grub
fi

# ------------------------------------------------------------------------------
# 3. Sysctl: 8GB RAM Aggressive Optimization
# ------------------------------------------------------------------------------
echo -e "\n--- Tuning Sysctl for 8GB RAM constraints ---"
SYSCTL_CONF="/etc/sysctl.d/99-void-perf.conf"
touch "$SYSCTL_CONF"
TMP_SYSCTL=$(mktemp)
cp "$SYSCTL_CONF" "$TMP_SYSCTL"

apply_sysctl() {
    local key="$1"
    local val="$2"
    if grep -q "^${key}[[:space:]]*=" "$TMP_SYSCTL"; then
        sed -i -E "s/^${key}[[:space:]]*=.*$/$key = $val/" "$TMP_SYSCTL"
    else
        echo "$key = $val" >> "$TMP_SYSCTL"
    fi
}

apply_sysctl "net.core.default_qdisc" "fq"
apply_sysctl "net.ipv4.tcp_congestion_control" "bbr"
apply_sysctl "vm.swappiness" "150"
apply_sysctl "vm.watermark_scale_factor" "125"
apply_sysctl "vm.page-cluster" "0"

safe_replace "$SYSCTL_CONF" "$TMP_SYSCTL" && sysctl --system >/dev/null

# ------------------------------------------------------------------------------
# 4. ZRAM: 100% Sizing for 8GB Memory
# ------------------------------------------------------------------------------
ZRAM_CONF="/etc/default/zramen"
mkdir -p $(dirname "$ZRAM_CONF")
TMP_ZRAM=$(mktemp)

cat <<EOF > "$TMP_ZRAM"
SIZE=100
COMP_ALGORITHM=zstd
MAX_STREAMS=$(nproc)
EOF

if safe_replace "$ZRAM_CONF" "$TMP_ZRAM"; then
    sv restart zramen 2>/dev/null || ln -sf /etc/sv/zramen /var/service/
else
    [ ! -L /var/service/zramen ] && ln -sf /etc/sv/zramen /var/service/
fi

# ------------------------------------------------------------------------------
# 5. GNOME TLP-PD Power Management Integration
# ------------------------------------------------------------------------------
echo -e "\n--- Integrating TLP with GNOME Power Slider ---"

# 1. Clean up any old cpupower conflicts in rc.local if they exist
RC_LOCAL="/etc/rc.local"
if [ -f "$RC_LOCAL" ]; then
    sed -i '/cpupower frequency-set/d' "$RC_LOCAL"
fi

# 2. Disable default power-profiles-daemon to prevent fighting with TLP
if [ -L /var/service/power-profiles-daemon ]; then
    echo "Disabling default power-profiles-daemon to prevent TLP conflicts..."
    rm -f /var/service/power-profiles-daemon
    sv down power-profiles-daemon 2>/dev/null
fi

# 3. Create a clean drop-in config for TLP tailored to the 3 GNOME states
mkdir -p /etc/tlp.d
TLP_GNOME_CONF="/etc/tlp.d/99-amd-gnome.conf"
TMP_TLP=$(mktemp)

cat <<EOF > "$TMP_TLP"
# GNOME Slider: "Performance"
CPU_SCALING_GOVERNOR_ON_AC=schedutil
CPU_ENERGY_PERF_POLICY_ON_AC=performance
CPU_BOOST_ON_AC=1
PLATFORM_PROFILE_ON_AC=performance

# GNOME Slider: "Balanced"
CPU_SCALING_GOVERNOR_ON_BAT=schedutil
CPU_ENERGY_PERF_POLICY_ON_BAT=balance_performance
CPU_BOOST_ON_BAT=1
PLATFORM_PROFILE_ON_BAT=balanced

# GNOME Slider: "Power Saver"
CPU_SCALING_GOVERNOR_ON_SAV=schedutil
CPU_ENERGY_PERF_POLICY_ON_SAV=power
CPU_BOOST_ON_SAV=0
PLATFORM_PROFILE_ON_SAV=low-power
EOF

if safe_replace "$TLP_GNOME_CONF" "$TMP_TLP"; then
    echo "TLP configuration mapped to GNOME power profiles."
fi

# Enable TLP service
[ ! -L /var/service/tlp ] && ln -sf /etc/sv/tlp /var/service/
sv restart tlp 2>/dev/null

# ------------------------------------------------------------------------------
# 6. Wayland Environment & AMD APU
# ------------------------------------------------------------------------------
echo -e "\n--- Tuning Wayland Environment ---"
ENV_FILE="/etc/environment"
TMP_ENV=$(mktemp)
cp "$ENV_FILE" "$TMP_ENV"

add_env() {
    local key="$1"
    local val="$2"
    if grep -q "^${key}=" "$TMP_ENV"; then
        sed -i -E "s/^${key}=.*$/$key=$val/" "$TMP_ENV"
    else
        echo "$key=$val" >> "$TMP_ENV"
    fi
}

add_env "MOZ_ENABLE_WAYLAND" "1"
add_env "QT_QPA_PLATFORM" "\"wayland;xcb\""
add_env "QT_WAYLAND_DISABLE_WINDOWDECORATION" "1"
add_env "MUTTER_DEBUG_KMS_THREAD_TYPE" "user"
add_env "RADV_PERFTEST" "gpl"
add_env "GBM_BACKEND" "radeonsi"

safe_replace "$ENV_FILE" "$TMP_ENV"

# ------------------------------------------------------------------------------
# 7. GNOME Debloating & UI Snappiness
# ------------------------------------------------------------------------------
echo -e "\n--- Applying GNOME Telemetry, Tracker Debloat & UI Tweaks ---"
PRIMARY_USER=$(id -un 1000 2>/dev/null)
if [ -n "$PRIMARY_USER" ]; then
    run_gsettings() { sudo -u "$PRIMARY_USER" dbus-launch gsettings "$@" 2>/dev/null; }

    run_gsettings set org.gnome.mutter experimental-features "['scale-monitor-framebuffer']"
    
    # Disable animations for massive UI performance boost on 8GB RAM
    run_gsettings set org.gnome.desktop.interface enable-animations false
    
    # Tracker disable
    run_gsettings set org.freedesktop.Tracker3.Miner.Files crawling-interval -2
    run_gsettings set org.freedesktop.Tracker3.Miner.Files enable-monitors false
    run_gsettings set org.freedesktop.Tracker3.Miner.Files index-recursive-directories "[]"

    USER_AUTOSTART="/home/$PRIMARY_USER/.config/autostart"
    mkdir -p "$USER_AUTOSTART"
    for tracker_service in tracker-miner-fs-3 tracker-extract-3; do
        if [ -f "/etc/xdg/autostart/$tracker_service.desktop" ]; then
            cp "/etc/xdg/autostart/$tracker_service.desktop" "$USER_AUTOSTART/"
            echo "Hidden=true" >> "$USER_AUTOSTART/$tracker_service.desktop"
        fi
    done
    chown -R "$PRIMARY_USER:$PRIMARY_USER" "/home/$PRIMARY_USER/.config"

    # Telemetry disable
    run_gsettings set org.gnome.desktop.privacy report-technical-problems false
    run_gsettings set org.gnome.desktop.privacy send-software-usage-stats false
    run_gsettings set org.gnome.software download-updates false
    run_gsettings set org.gnome.software allow-updates false
fi

echo -e "\n=============================================================================="
echo "💻 HP 15 OPTIMIZATION APPLIED (V3 TLP-PD READY)."
echo "Please reboot your laptop to finalize kernel and TLP power states."
echo "=============================================================================="
