#!/bin/bash
# ==============================================================================
# VOID LINUX CUSTOM ISO BUILDER: HP 15 / Universal (No NVIDIA)
# Features: GNOME, PipeWire, AppArmor, ZRAM, Chrony, LVM+LUKS
# Fix: Void Linux runit service name for BlueZ is 'bluetoothd'
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
    if ! command -v "$cmd" &> /dev/null; then MISSING_CMDS="$MISSING_CMDS $cmd"; fi
done

if [ -n "$MISSING_CMDS" ]; then
    echo "    [!] Missing tools: $MISSING_CMDS. Please install them first."
    exit 1
fi

echo "==> [1/6] Setting up workspace at $WORKDIR..."
sudo -u "$ACTUAL_USER" mkdir -p "$WORKDIR"
cd "$WORKDIR"

if [ ! -d "void-mklive" ]; then
    sudo -u "$ACTUAL_USER" git clone https://github.com/void-linux/void-mklive.git
fi
cd void-mklive

echo "    Cleaning up root-owned build artifacts..."
rm -rf custom-overlay xbps-cachedir-* builddir *.iso
sudo -u "$ACTUAL_USER" git fetch origin
sudo -u "$ACTUAL_USER" git reset --hard origin/master
sudo -u "$ACTUAL_USER" git clean -fdx
make 

echo "==> [2/6] Selecting Void Linux Repository Mirror..."
REPO_URL="https://repo-default.voidlinux.org"
if [ "$USE_FASTEST_MIRROR" = "true" ]; then
    echo "    Pinging mirrors for fastest response..."
    BEST_TIME=999
    for m in "https://repo-default.voidlinux.org" "https://repo-us.voidlinux.org" "https://repo-fastly.voidlinux.org"; do
        TEST_TIME=$(LC_NUMERIC=C curl -s -o /dev/null -w "%{time_total}" -m 2 "$m/current/x86_64-repodata" || echo "999")
        if awk "BEGIN {exit !($TEST_TIME < $BEST_TIME)}"; then
            BEST_TIME=$TEST_TIME
            REPO_URL=$m
        fi
    done
    echo "    [+] Selected Mirror: $REPO_URL"
fi

echo "==> [3/6] Setting up Overlay and Injected Scripts..."
rm -rf custom-overlay
mkdir -p custom-overlay/etc/gdm custom-overlay/usr/bin custom-overlay/etc/skel

# Live ISO Autologin Config
cat <<EOF > custom-overlay/etc/gdm/custom.conf
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=anon
WaylandEnable=true
EOF

cat <<EOF > custom-overlay/etc/issue
\S \r (\l)
==================================================
 Welcome to the Custom Void Trading Live System!
 To begin the installation, type: void-setup
==================================================
EOF

cp installer.sh custom-overlay/usr/bin/void-installer
chmod +x custom-overlay/usr/bin/void-installer

# The UX Launcher
cat << 'EOF_LAUNCHER' > custom-overlay/usr/bin/void-setup
#!/bin/bash
clear
echo "======================================================================"
echo "                   VOID LINUX SYSTEM INSTALLER                        "
echo "======================================================================"
echo " 1) Standard Void Installer (Official ncurses UI)"
echo " 2) High-Performance Deployer (Automated LUKS/LVM/AppArmor)"
echo " 3) Exit to shell"
echo ""
read -rp " Enter choice [1-3]: " setup_choice
case $setup_choice in
    1) sudo void-installer ;;
    2) sudo void-trading-install ;;
    *) echo "Exiting." ;;
esac
EOF_LAUNCHER
chmod +x custom-overlay/usr/bin/void-setup

echo "    [+] Injecting Custom Installer..."
cat << 'EOF_TRADER' > custom-overlay/usr/bin/void-trading-install
#!/bin/bash
set -euo pipefail
LOGFILE="/tmp/void-install.log"
exec > >(tee -i "$LOGFILE")
exec 2>&1

clear
echo "======================================================================"
echo "      HIGH-PERFORMANCE DEPLOYMENT (LUKS + LVM + APPARMOR)             "
echo "======================================================================"

lsblk -d -o NAME,SIZE,FSTYPE,MODEL | grep -v "loop"
read -rp "Target disk (e.g. /dev/nvme0n1): " DISK

echo -e "\n[*] Installation Source"
echo "1) Local ISO Clone (Lightning Fast - Copies live environment to disk)"
echo "2) Network Install (Slower - Downloads latest from fastest mirror)"
read -rp "Select source [1 or 2, Default: 1]: " INSTALL_SOURCE
INSTALL_SOURCE=${INSTALL_SOURCE:-1}

read -rsp "Enter LUKS encryption password: " LUKS_PASS; echo
read -rp "Enter new username: " SYS_USER
read -rsp "Enter user password: " SYS_PASS; echo
HOST_NAME="void-trading"

echo -e "\n⚠️  WARNING: ALL DATA ON $DISK WILL BE ERASED!"
read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Aborted."; exit 1; }

[[ "$DISK" =~ [0-9]$ ]] && P="${DISK}p" || P="${DISK}"
EFI="${P}1"; BOOT="${P}2"; ROOT_PART="${P}3"

echo "[*] Wiping and partitioning $DISK..."
wipefs -a "$DISK"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart BOOT ext4 513MiB 1537MiB
parted -s "$DISK" mkpart ROOT 1537MiB 100%
partprobe "$DISK"; sleep 2

mkfs.vfat -F32 "$EFI"
mkfs.ext4 -F "$BOOT"

echo "[*] Setting up Encryption & LVM..."
printf "%s" "$LUKS_PASS" | cryptsetup luksFormat "$ROOT_PART" -
printf "%s" "$LUKS_PASS" | cryptsetup open "$ROOT_PART" cryptroot -
pvcreate /dev/mapper/cryptroot; vgcreate voidvg /dev/mapper/cryptroot
lvcreate -L 4G voidvg -n swap
lvcreate -L 40G voidvg -n root
lvcreate -l 100%FREE voidvg -n home
mkfs.ext4 -F /dev/voidvg/root; mkfs.ext4 -F /dev/voidvg/home; mkswap /dev/voidvg/swap

echo "[*] Mounting filesystems..."
mount /dev/voidvg/root /mnt
mkdir -p /mnt/{boot,home,etc/xbps.d,var/db/xbps/keys}
mount "$BOOT" /mnt/boot
mkdir -p /mnt/boot/efi; mount "$EFI" /mnt/boot/efi
mount /dev/voidvg/home /mnt/home; swapon /dev/voidvg/swap

BOOT_UUID=$(blkid -s UUID -o value "$BOOT")
EFI_UUID=$(blkid -s UUID -o value "$EFI")
ROOT_LV_UUID=$(blkid -s UUID -o value /dev/voidvg/root)
HOME_LV_UUID=$(blkid -s UUID -o value /dev/voidvg/home)
SWAP_LV_UUID=$(blkid -s UUID -o value /dev/voidvg/swap)
CRYPT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

echo "ignorepkg=linux" > /mnt/etc/xbps.d/10-ignore.conf
echo "ignorepkg=linux-headers" >> /mnt/etc/xbps.d/10-ignore.conf

if [ "$INSTALL_SOURCE" = "1" ] && [ -d "/repo" ]; then
    echo "[*] Cloning RootFS (Lightning Mode)..."
    DIRS=""
    for d in bin etc home lib lib32 lib64 opt root sbin usr var; do
        [ -e "/$d" ] && DIRS="$DIRS $d"
    done
    tar -cpf - -C / $DIRS | tar -xpf - -C /mnt
    tar -cpf - -C /boot . | tar -xpf - -C /mnt/boot
    REPO_FLAGS="-i -R /repo"
else
    echo "[*] Network Install Mode..."
    if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        echo "[!] CRITICAL: No internet connection detected."
        exit 1
    fi
    REPO_FLAGS="-R __REPO_URL__/current -R __REPO_URL__/current/nonfree -R __REPO_URL__/current/multilib -R __REPO_URL__/current/multilib/nonfree"
fi

echo "[*] Staging virtual filesystems..."
mkdir -p /mnt/{dev,proc,sys,tmp,run,mnt,media}
chmod 1777 /mnt/tmp
mount --rbind /dev /mnt/dev; mount --rbind /proc /mnt/proc; mount --rbind /sys /mnt/sys
cp /etc/resolv.conf /mnt/etc/resolv.conf
cp -a /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ || true

# Exact package list
CORE_PKGS="base-system linux-mainline linux-mainline-headers \
linux-firmware linux-firmware-network linux-firmware-amd linux-firmware-intel intel-ucode \
void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree \
mesa mesa-dri mesa-vaapi mesa-vulkan-radeon vulkan-loader libva-utils \
elogind dbus polkit NetworkManager network-manager-applet bluez blueman \
cups cups-filters system-config-printer xdg-user-dirs xdg-utils gvfs gvfs-mtp gvfs-smb bash-completion \
gnome-core gnome-terminal gnome-control-center gnome-system-monitor gnome-disk-utility gnome-tweaks \
nautilus file-roller eog evince gnome-shell-extensions tlp tlp-rdw powertop zramen cpupower \
curl wget rsync nftables chrony apparmor chromium htop btop neovim nano git unzip p7zip \
pipewire wireplumber alsa-pipewire alsa-ucm-conf libspa-bluetooth brightnessctl acpi lm_sensors \
flatpak noto-fonts-ttf noto-fonts-emoji dejavu-fonts-ttf dosfstools ntfs-3g exfatprogs \
cryptsetup lvm2 grub-x86_64-efi sudo parted e2fsprogs gdm"

echo "[*] Installing/Verifying system packages..."
xbps-install -Sy -c /var/cache/xbps $REPO_FLAGS -r /mnt $CORE_PKGS

echo "[*] Entering chroot for final configuration..."
chroot /mnt /usr/bin/env HOST_NAME="$HOST_NAME" CRYPT_UUID="$CRYPT_UUID" \
    ROOT_LV_UUID="$ROOT_LV_UUID" HOME_LV_UUID="$HOME_LV_UUID" BOOT_UUID="$BOOT_UUID" \
    EFI_UUID="$EFI_UUID" SWAP_LV_UUID="$SWAP_LV_UUID" SYS_USER="$SYS_USER" SYS_PASS="$SYS_PASS" DISK="$DISK" \
    INSTALL_SOURCE="$INSTALL_SOURCE" /bin/bash << 'CHROOT_EOF'
set -euo pipefail

mkdir -p /etc/sysctl.d /etc/modules-load.d /etc/security/limits.d /etc/default /etc/dracut.conf.d /usr/local/bin

echo "$HOST_NAME" > /etc/hostname
echo "cryptroot UUID=$CRYPT_UUID none luks,discard" > /etc/crypttab
cat <<FSTAB > /etc/fstab
UUID=$ROOT_LV_UUID  /          ext4    defaults 0 1
UUID=$HOME_LV_UUID  /home      ext4    defaults 0 2
UUID=$BOOT_UUID     /boot      ext4    defaults 0 2
UUID=$EFI_UUID      /boot/efi  vfat    defaults 0 2
UUID=$SWAP_LV_UUID  none       swap    defaults 0 0
tmpfs               /tmp       tmpfs   defaults,noatime,mode=1777 0 0
FSTAB

echo "en_US.UTF-8 UTF-8" >> /etc/default/libc-locales; xbps-reconfigure -f glibc-locales
ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
sed -i 's/^#KEYMAP=.*/KEYMAP="us"/' /etc/rc.conf || echo 'KEYMAP="us"' >> /etc/rc.conf

if [ "$INSTALL_SOURCE" = "1" ]; then
    xbps-remove -Ry void-live >/dev/null 2>&1 || true
    userdel -f -r anon >/dev/null 2>&1 || true
fi

pwconv; grpconv
useradd -m -G wheel,audio,video,input,bluetooth -s /bin/bash "$SYS_USER"
echo "$SYS_USER:$SYS_PASS" | chpasswd -c SHA512
echo "root:$SYS_PASS" | chpasswd -c SHA512
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

sed -i "s/AutomaticLogin=anon/AutomaticLogin=$SYS_USER/" /etc/gdm/custom.conf

[ -f /etc/default/grub ] || touch /etc/default/grub
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 apparmor=1 security=apparmor amd_pstate=active"/' /etc/default/grub
grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub || echo 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 apparmor=1 security=apparmor amd_pstate=active"' >> /etc/default/grub

echo 'add_dracutmodules+=" crypt lvm "' > /etc/dracut.conf.d/crypt.conf
echo 'hostonly="yes"' > /etc/dracut.conf.d/hostonly.conf

for k_dir in /lib/modules/*; do
    KVER=$(basename "$k_dir")
    dracut -f --kver "$KVER"
done

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Void --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# FIXED: 'bluetooth' changed to 'bluetoothd'
for s in dbus elogind NetworkManager bluetoothd cupsd tlp zramen chronyd apparmor gdm udevd; do
    [ -d "/etc/sv/$s" ] && ln -sfn "/etc/sv/$s" /etc/runit/runsvdir/default/
done

xbps-remove -Fy tracker3-miners || true
CHROOT_EOF

umount -R /mnt; swapoff -a
echo "======================================================================"
echo "   INSTALL COMPLETE: Reboot, enter LUKS pass, and log in.             "
echo "======================================================================"
EOF_TRADER

chmod +x custom-overlay/usr/bin/void-trading-install
sed -i "s|__REPO_URL__|$REPO_URL|g" custom-overlay/usr/bin/void-trading-install

echo "==> [4/6] Defining finalized package list for the ISO..."
ALL_PKGS="linux-mainline linux-mainline-headers \
linux-firmware linux-firmware-network linux-firmware-amd linux-firmware-intel intel-ucode \
void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree \
mesa mesa-dri mesa-vaapi mesa-vulkan-radeon vulkan-loader libva-utils \
elogind dbus polkit NetworkManager network-manager-applet bluez blueman \
cups cups-filters system-config-printer xdg-user-dirs xdg-utils gvfs gvfs-mtp gvfs-smb bash-completion \
gnome-core gnome-terminal gnome-control-center gnome-system-monitor gnome-disk-utility gnome-tweaks \
nautilus file-roller eog evince gnome-shell-extensions tlp tlp-rdw powertop zramen cpupower \
curl wget rsync nftables chrony apparmor chromium htop btop neovim nano git unzip p7zip \
pipewire wireplumber alsa-pipewire alsa-ucm-conf libspa-bluetooth brightnessctl acpi lm_sensors \
flatpak noto-fonts-ttf noto-fonts-emoji dejavu-fonts-ttf dosfstools ntfs-3g exfatprogs \
cryptsetup lvm2 grub-x86_64-efi sudo parted e2fsprogs gdm qemu-ga"


# ==============================================================================
# PREFLIGHT PACKAGE VERIFICATION
# ==============================================================================
echo "==> [4.5/6] Running Preflight Package Verification..."
DUMMY_ROOT=$(mktemp -d)
mkdir -p "$DUMMY_ROOT/var/db/xbps/keys"
cp /var/db/xbps/keys/* "$DUMMY_ROOT/var/db/xbps/keys/" 2>/dev/null || true

XBPS_CMD="sudo env XBPS_ARCH=x86_64 xbps-install -r $DUMMY_ROOT -c /var/cache/xbps -R $REPO_URL/current -R $REPO_URL/current/nonfree -R $REPO_URL/current/multilib -R $REPO_URL/current/multilib/nonfree"

echo "    Syncing repository metadata to test environment..."
$XBPS_CMD -S > /dev/null

echo "    Verifying availability of all defined packages..."
MISSING_PKGS=""
for pkg in $ALL_PKGS; do
    if ! $XBPS_CMD -n "$pkg" > /dev/null 2>&1; then
        MISSING_PKGS="$MISSING_PKGS $pkg"
    fi
done

sudo rm -rf "$DUMMY_ROOT"

if [ -n "$MISSING_PKGS" ]; then
    echo "    [!] CRITICAL ERROR: The following packages do NOT exist in the selected repositories:"
    for mpkg in $MISSING_PKGS; do
        echo "        - $mpkg"
    done
    echo "    [!] Build aborted to save time. Please fix the ALL_PKGS and CORE_PKGS lists."
    exit 1
else
    echo "    [+] All packages verified successfully. Proceeding to build."
fi
# ==============================================================================

echo "==> [5/6] Baking the ISO..."
# FIXED: 'bluetooth' changed to 'bluetoothd'
sudo ./mklive.sh \
    -a x86_64 \
    -o hp-void-gnome-trading.iso \
    -v linux-mainline \
    -S "dbus elogind NetworkManager gdm qemu-ga bluetoothd" \
    -p "$ALL_PKGS" \
    -r "$REPO_URL/current" \
    -r "$REPO_URL/current/nonfree" \
    -r "$REPO_URL/current/multilib" \
    -r "$REPO_URL/current/multilib/nonfree" \
    -I custom-overlay

echo "==> SUCCESS! Your ISO is at: $WORKDIR/void-mklive/hp-void-gnome-trading.iso"
