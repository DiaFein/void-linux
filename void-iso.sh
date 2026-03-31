#!/bin/bash
# void-gnome-production-final.sh - Bulletproof Custom Void ISO Builder

set -euo pipefail

# --- CONFIGURATION ---
ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
WORKDIR="$ACTUAL_HOME/void-iso"

# Toggle this to 'false' if you want to force the default mirror
USE_FASTEST_MIRROR="true"
# ---------------------

echo "==> [0/6] Running Preflight Host Checks..."
REQUIRED_CMDS="git make curl tar xz sudo gzip bzip2 awk"
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
    
    # Standard Tier 1 Global Mirrors
    MIRRORS=(
        "https://repo-default.voidlinux.org"
        "https://repo-fi.voidlinux.org"
        "https://repo-us.voidlinux.org"
        "https://repo-fastly.voidlinux.org"
        "https://mirrors.servercentral.com/voidlinux"
    )

    for m in "${MIRRORS[@]}"; do
        # Enforce C locale to ensure curl outputs decimal dots (not commas) for awk comparison
        # Use a 2-second timeout (-m 2) so dead mirrors don't hang the script
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

echo "==> [3/6] Setting up GNOME Wayland/Autologin & Installer overlay..."
rm -rf custom-overlay
mkdir -p custom-overlay/etc/gdm
mkdir -p custom-overlay/usr/sbin

cat <<EOF > custom-overlay/etc/gdm/custom.conf
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=anon
WaylandEnable=true
EOF

if [ ! -f installer.sh ]; then
    echo "    [!] Error: installer.sh not found in the void-mklive repository!"
    exit 1
fi
cp installer.sh custom-overlay/usr/sbin/void-installer
chmod +x custom-overlay/usr/sbin/void-installer

echo "==> [4/6] Defining finalized package list..."
APPS="gnome-core gnome-terminal chromium NetworkManager network-manager-applet elogind xdg-user-dirs xdg-utils dialog"
VIRT="qemu-ga spice-vdagent"
UTILS="dhcpcd iproute2 bash-completion nano htop wget curl grub-x86_64-efi os-prober cryptsetup lvm2 mdadm btrfs-progs xfsprogs dosfstools e2fsprogs"
FIRMWARE="linux-firmware linux-firmware-network linux-firmware-amd linux-firmware-intel linux-firmware-nvidia intel-ucode"
DRIVERS="mesa mesa-dri mesa-vulkan-radeon mesa-vulkan-intel vulkan-loader void-repo-nonfree"

ALL_PKGS="$APPS $VIRT $UTILS $FIRMWARE $DRIVERS"

echo "==> [5/6] Validating package list against $REPO_URL..."
XBPS_BIN_DIR=$(find "$PWD" -type d -name "bin" | grep "xbps" | head -n 1 || true)
if [ -n "$XBPS_BIN_DIR" ]; then
    export PATH="$XBPS_BIN_DIR:$PATH"
fi

if command -v xbps-install >/dev/null 2>&1; then
    DUMMY_ROOT=$(mktemp -d)
    
    sudo xbps-install -S -r "$DUMMY_ROOT" \
        --repository="$REPO_URL/current" \
        --repository="$REPO_URL/current/nonfree" > /dev/null 2>&1 || true

    MISSING_PKGS=""
    for pkg in $ALL_PKGS; do
        if ! sudo xbps-install -n -r "$DUMMY_ROOT" \
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
        echo "    Aborting build."
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
