#!/bin/bash
# void-gnome-production.sh - Production-Grade Custom Void ISO Builder

set -euo pipefail

# Define the central working directory
WORKDIR="/home/void-iso"

echo "==> [0/5] Running Preflight Host Checks..."

# Required host tools (including gzip and bzip2 for rootfs archives)
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
        sudo apt-get update
        sudo apt-get install -y $APT_PKGS
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
# Create the directory and ensure the current user owns it to prevent 'make' permission errors
sudo mkdir -p "$WORKDIR"
sudo chown "$USER":"$USER" "$WORKDIR"
cd "$WORKDIR"

# Clone the repository into our dedicated workspace
if [ ! -d "void-mklive" ]; then
    git clone https://github.com/void-linux/void-mklive.git
fi
cd void-mklive

# Compile static xbps binaries
make 

echo "==> [2/5] Setting up GNOME Wayland/Autologin overlay..."
rm -rf custom-overlay
mkdir -p custom-overlay/etc/gdm
cat <<EOF > custom-overlay/etc/gdm/custom.conf
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=anon
WaylandEnable=true
EOF

echo "==> [3/5] Defining finalized package list..."

# Desktop & GUI Apps (NetworkManager binary is pulled via -S flag)
APPS="gnome-core gnome-terminal chromium network-manager-applet elogind xdg-user-dirs xdg-utils void-installer dialog"

# Virtualization Support (Guest agents for QEMU/KVM/Libvirt)
VIRT="qemu-ga-files spice-vdagent"

# Usability, Fallback Networking & Bootloading
UTILS="dhcpcd iproute2 bash-completion nano htop wget curl grub-x86_64-efi os-prober"

# Firmware (Free & Non-Free)
FIRMWARE="linux-firmware linux-firmware-network linux-firmware-amd linux-firmware-intel linux-firmware-nvidia intel-ucode amd-ucode"

# Graphics & Vulkan (Mainline Wayland approach)
DRIVERS="mesa mesa-dri mesa-vulkan-radeon mesa-vulkan-intel vulkan-loader void-repo-nonfree"

ALL_PKGS="$APPS $VIRT $UTILS $FIRMWARE $DRIVERS"

echo "==> [4/5] Baking the ISO..."

# Execute the build process
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
echo "    All temporary build files are safely contained within: $WORKDIR"
