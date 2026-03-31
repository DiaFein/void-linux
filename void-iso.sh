#!/bin/bash
# void-gnome-production-final.sh - Bulletproof Custom Void ISO Builder

set -euo pipefail

# --- CONFIGURATION ---
# Detect the actual user running the script, even if executed with sudo
ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)

WORKDIR="$ACTUAL_HOME/void-iso"
# ---------------------

echo "==> [0/5] Running Preflight Host Checks..."
REQUIRED_CMDS="git make curl tar xz sudo gzip bzip2"
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
        echo "    Please manually install the following packages before continuing:$MISSING_CMDS"
        exit 1
    fi
    echo "    Preflight resolution complete."
else
    echo "    All host dependencies are present. Proceeding..."
fi

echo "==> [1/5] Setting up workspace at $WORKDIR..."
# Run mkdir as the actual user to prevent root-ownership lockouts later
sudo -u "$ACTUAL_USER" mkdir -p "$WORKDIR"
cd "$WORKDIR"

# Idempotent Git Setup
if [ ! -d "void-mklive" ]; then
    echo "    Cloning repository..."
    sudo -u "$ACTUAL_USER" git clone https://github.com/void-linux/void-mklive.git
fi
cd void-mklive

echo "    Syncing toolchain to the latest stable master branch..."
# Fetch the latest upstream changes and force our local folder to match them perfectly
sudo -u "$ACTUAL_USER" git fetch origin
sudo -u "$ACTUAL_USER" git reset --hard origin/master
# Nuke any untracked or partially built files from previous failed runs
sudo -u "$ACTUAL_USER" git clean -fdx

# Compile xbps tools from a guaranteed clean state (must be run as root/sudo for mklive)
make 

echo "==> [2/5] Setting up GNOME Wayland/Autologin & Installer overlay..."
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
    echo "    The upstream repository may have changed. Aborting build to prevent a broken ISO."
    exit 1
fi
cp installer.sh custom-overlay/usr/sbin/void-installer
chmod +x custom-overlay/usr/sbin/void-installer

echo "==> [3/5] Defining finalized package list..."

# Desktop & GUI Apps
APPS="gnome-core gnome-terminal chromium NetworkManager network-manager-applet elogind xdg-user-dirs xdg-utils dialog"

# Virtualization Support
VIRT="qemu-ga spice-vdagent"

# Usability, Bootloading & Installer Filesystem Tools
UTILS="dhcpcd iproute2 bash-completion nano htop wget curl grub-x86_64-efi os-prober cryptsetup lvm2 mdadm btrfs-progs xfsprogs dosfstools e2fsprogs"

# Firmware (Free & Non-Free)
FIRMWARE="linux-firmware linux-firmware-network linux-firmware-amd linux-firmware-intel linux-firmware-nvidia intel-ucode amd-ucode"

# Graphics & Vulkan
DRIVERS="mesa mesa-dri mesa-vulkan-radeon mesa-vulkan-intel vulkan-loader void-repo-nonfree"

ALL_PKGS="$APPS $VIRT $UTILS $FIRMWARE $DRIVERS"

echo "==> [4/5] Baking the ISO..."
sudo ./mklive.sh \
    -a x86_64 \
    -o void-custom-gnome-production.iso \
    -v linux-mainline \
    -S "dbus elogind NetworkManager gdm qemu-ga" \
    -p "$ALL_PKGS" \
    -r https://repo-default.voidlinux.org/current \
    -r https://repo-default.voidlinux.org/current/nonfree \
    -I custom-overlay

echo "==> [5/5] SUCCESS!"
echo "    Your ISO is located at: $WORKDIR/void-mklive/void-custom-gnome-production.iso"
