#!/bin/bash
set -euo pipefail

# --- STANDALONE CONFIGURATION ---
# WAYLAND ONLY: Removed xorg-server and xf86-video-amdgpu, kept xorg-server-xwayland
ALL_PKGS="base-system linux-mainline linux-mainline-headers \
linux-firmware linux-firmware-network linux-firmware-amd \
void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree \
mesa mesa-dri mesa-vaapi mesa-vulkan-radeon vulkan-loader libva-utils \
xorg-server-xwayland \
elogind dbus polkit NetworkManager network-manager-applet \
cups cups-filters system-config-printer xdg-user-dirs xdg-utils gvfs gvfs-mtp gvfs-smb bash-completion \
gnome-core gnome-terminal gnome-control-center gnome-system-monitor gnome-disk-utility gnome-tweaks \
nautilus file-roller eog evince gnome-shell-extensions tlp tlp-rdw powertop zramen cpupower \
curl wget rsync nftables chrony apparmor chromium htop btop neovim nano git unzip p7zip \
pipewire wireplumber alsa-pipewire alsa-ucm-conf brightnessctl acpi lm_sensors rtkit pavucontrol \
flatpak noto-fonts-ttf noto-fonts-emoji dejavu-fonts-ttf dosfstools ntfs-3g exfatprogs \
cryptsetup btrfs-progs grub-x86_64-efi sudo parted e2fsprogs gdm qemu-ga"
# --------------------------------

LOGFILE="/tmp/void-install.log"
exec > >(tee -i "$LOGFILE")
exec 2>&1

clear
echo "======================================================================"
echo "      HIGH-PERFORMANCE DEPLOYMENT (LUKS + BTRFS + APPARMOR)           "
echo "======================================================================"

echo "[*] Selecting Void Linux Repository Mirror..."
REPO_URL="https://repo-default.voidlinux.org"
echo "    Pinging mirrors for fastest response..."
BEST_TIME=999
for m in "https://repo-default.voidlinux.org" "https://repo-us.voidlinux.org" "https://repo-fastly.voidlinux.org"; do
    # Using awk to handle floating point comparisons reliably
    TEST_TIME=$(LC_NUMERIC=C curl -s -o /dev/null -w "%{time_total}" -m 2 "$m/current/x86_64-repodata" || echo "999")
    if awk "BEGIN {exit !($TEST_TIME < $BEST_TIME)}"; then
        BEST_TIME=$TEST_TIME
        REPO_URL=$m
    fi
done
echo "    [+] Selected Mirror: $REPO_URL"

echo "[*] Running Pre-flight Package Availability Check..."
PKG_ARRAY=($ALL_PKGS)
echo "    Validating ${#PKG_ARRAY[@]} packages against selected mirror..."

REPO_ARGS="--repository=$REPO_URL/current --repository=$REPO_URL/current/nonfree --repository=$REPO_URL/current/multilib --repository=$REPO_URL/current/multilib/nonfree"
MISSING_REPO_PKGS=""

for pkg in "${PKG_ARRAY[@]}"; do
    if ! xbps-query -R $REPO_ARGS -p pkgver "$pkg" >/dev/null 2>&1; then
        MISSING_REPO_PKGS="$MISSING_REPO_PKGS $pkg"
    fi
done

if [ -n "$MISSING_REPO_PKGS" ]; then
    echo "    [!] FATAL: The following packages are NOT available in the repositories:"
    for mp in $MISSING_REPO_PKGS; do
        echo "        - $mp"
    done
    echo "    [!] Please correct the package names before continuing."
    exit 1
fi
echo "    [+] All packages verified successfully."
echo "----------------------------------------------------------------------"

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
HOST_NAME="void-amd-workstation"

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

echo "[*] Setting up Encryption & Btrfs..."
printf "%s" "$LUKS_PASS" | cryptsetup luksFormat "$ROOT_PART" -
printf "%s" "$LUKS_PASS" | cryptsetup open "$ROOT_PART" EBRAM -

mkfs.btrfs -f /dev/mapper/EBRAM
mount /dev/mapper/EBRAM /mnt

echo "[*] Creating Btrfs subvolumes..."
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@snapshots
umount /mnt

echo "[*] Mounting filesystems (Hierarchical strict creation)..."
BTRFS_OPTS="noatime,compress=zstd:1,ssd,discard=async,space_cache=v2,commit=120"

mount -o "$BTRFS_OPTS",subvol=@ /dev/mapper/EBRAM /mnt

mkdir -p /mnt/home
mkdir -p /mnt/var/{cache,log,tmp,db/xbps/keys}
mkdir -p /mnt/tmp
mkdir -p /mnt/.snapshots
mkdir -p /mnt/boot  
mkdir -p /mnt/etc/xbps.d

mount -o "$BTRFS_OPTS",subvol=@home /dev/mapper/EBRAM /mnt/home
mount -o "$BTRFS_OPTS",subvol=@cache /dev/mapper/EBRAM /mnt/var/cache
mount -o "$BTRFS_OPTS",subvol=@log /dev/mapper/EBRAM /mnt/var/log
mount -o "$BTRFS_OPTS",subvol=@snapshots /dev/mapper/EBRAM /mnt/.snapshots

mount "$BOOT" /mnt/boot
mkdir -p /mnt/boot/efi
mount "$EFI" /mnt/boot/efi

BOOT_UUID=$(blkid -s UUID -o value "$BOOT")
EFI_UUID=$(blkid -s UUID -o value "$EFI")
CRYPT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
BTRFS_UUID=$(blkid -s UUID -o value /dev/mapper/EBRAM)

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
    REPO_FLAGS="-R $REPO_URL/current -R $REPO_URL/current/nonfree -R $REPO_URL/current/multilib -R $REPO_URL/current/multilib/nonfree"
fi

echo "[*] Staging virtual filesystems..."
mkdir -p /mnt/{dev,proc,sys,run,mnt,media}
mount --rbind /dev /mnt/dev; mount --rbind /proc /mnt/proc; mount --rbind /sys /mnt/sys
cp /etc/resolv.conf /mnt/etc/resolv.conf
cp -a /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ || true

echo "[*] Installing/Verifying system packages..."
xbps-install -Sy -c /var/cache/xbps $REPO_FLAGS -r /mnt $ALL_PKGS

# =========================================================
# BULLETPROOF PASSWORD & USER CREATION (Executed on Host)
# =========================================================
echo "[*] Creating user and setting passwords..."
chroot /mnt pwconv
chroot /mnt grpconv
chroot /mnt useradd -m -G wheel,audio,video,input -s /bin/bash "$SYS_USER"
echo "$SYS_USER:$SYS_PASS" | chroot /mnt chpasswd -c SHA512
echo "root:$SYS_PASS" | chroot /mnt chpasswd -c SHA512

# Fix GDM Autologin strictly from host to ensure variable expansion
sed -i "s/AutomaticLogin=anon/AutomaticLogin=$SYS_USER/" /mnt/etc/gdm/custom.conf

echo "[*] Entering chroot for final configuration..."
chroot /mnt /usr/bin/env HOST_NAME="$HOST_NAME" CRYPT_UUID="$CRYPT_UUID" \
    BTRFS_UUID="$BTRFS_UUID" BTRFS_OPTS="$BTRFS_OPTS" BOOT_UUID="$BOOT_UUID" \
    EFI_UUID="$EFI_UUID" SYS_USER="$SYS_USER" /bin/bash << 'CHROOT_EOF'
set -euo pipefail

mkdir -p /etc/sysctl.d /etc/modules-load.d /etc/security/limits.d /etc/default /etc/dracut.conf.d /usr/local/bin

echo "$HOST_NAME" > /etc/hostname
echo "EBRAM UUID=$CRYPT_UUID none luks,discard" > /etc/crypttab

cat << 'FSTAB' > /etc/fstab
UUID=$BTRFS_UUID  /             btrfs   $BTRFS_OPTS,subvol=@ 0 0
UUID=$BTRFS_UUID  /home         btrfs   $BTRFS_OPTS,subvol=@home 0 0
UUID=$BTRFS_UUID  /var/cache    btrfs   $BTRFS_OPTS,subvol=@cache 0 0
UUID=$BTRFS_UUID  /var/log      btrfs   $BTRFS_OPTS,subvol=@log 0 0
UUID=$BTRFS_UUID  /.snapshots   btrfs   $BTRFS_OPTS,subvol=@snapshots 0 0
UUID=$BOOT_UUID   /boot         ext4    defaults 0 2
UUID=$EFI_UUID    /boot/efi     vfat    defaults 0 2
tmpfs             /tmp          tmpfs   defaults,noatime,mode=1777 0 0
tmpfs             /var/tmp      tmpfs   defaults,noatime,mode=1777 0 0
FSTAB
sed -i "s|\$BTRFS_UUID|$BTRFS_UUID|g" /etc/fstab
sed -i "s|\$BTRFS_OPTS|$BTRFS_OPTS|g" /etc/fstab
sed -i "s|\$BOOT_UUID|$BOOT_UUID|g" /etc/fstab
sed -i "s|\$EFI_UUID|$EFI_UUID|g" /etc/fstab

echo "en_US.UTF-8 UTF-8" >> /etc/default/libc-locales; xbps-reconfigure -f glibc-locales
ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
sed -i 's/^#KEYMAP=.*/KEYMAP="us"/' /etc/rc.conf || echo 'KEYMAP="us"' >> /etc/rc.conf

if [ -e "/var/db/xbps/pkgdir/void-live" ]; then
    xbps-remove -Ry void-live >/dev/null 2>&1 || true
    userdel -f -r anon >/dev/null 2>&1 || true
fi

sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# ---------------------------------------------------------
# AUDIO AUTOSTART (PIPEWIRE)
# ---------------------------------------------------------
echo "[*] Setting up Global XDG Autostart for PipeWire..."
mkdir -p /etc/xdg/autostart
ln -sf /usr/share/applications/pipewire.desktop /etc/xdg/autostart/pipewire.desktop
ln -sf /usr/share/applications/pipewire-pulse.desktop /etc/xdg/autostart/pipewire-pulse.desktop
ln -sf /usr/share/applications/wireplumber.desktop /etc/xdg/autostart/wireplumber.desktop

# ---------------------------------------------------------
# TRADING PERFORMANCE TUNING (NOCOW)
# ---------------------------------------------------------
echo "[*] Applying NOCOW attributes to high-I/O directories..."
mkdir -p /home/$SYS_USER/{trading-data,.cache,.config/chromium}

chattr +C /home/$SYS_USER/trading-data
chattr +C /home/$SYS_USER/.cache
chattr +C /home/$SYS_USER/.config/chromium

chown -R $SYS_USER:$SYS_USER /home/$SYS_USER

# ---------------------------------------------------------
# BTRFS SNAPSHOT HOOK
# ---------------------------------------------------------
cat << 'HOOK_EOF' > /usr/local/bin/safe-update
#!/bin/bash
set -euo pipefail
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo safe-update)"
    exit 1
fi
SNAP_NAME="pre-update-$(date +%Y%m%d_%H%M%S)"
echo "⚡ Creating Btrfs snapshot: /.snapshots/$SNAP_NAME"
btrfs subvolume snapshot / /.snapshots/$SNAP_NAME
echo "🚀 Updating system..."
xbps-install -Su
echo "✅ Update complete."
HOOK_EOF
chmod +x /usr/local/bin/safe-update

# ---------------------------------------------------------
# CRITICAL BOOT AND GRUB CONFIGURATION 
# ---------------------------------------------------------
[ -f /etc/default/grub ] || touch /etc/default/grub
sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=4 apparmor=1 security=apparmor amdgpu.ppfeaturemask=0xffffffff rd.luks.name=$CRYPT_UUID=EBRAM root=/dev/mapper/EBRAM rootflags=subvol=@\"|" /etc/default/grub
grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub || echo "GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=4 apparmor=1 security=apparmor amdgpu.ppfeaturemask=0xffffffff rd.luks.name=$CRYPT_UUID=EBRAM root=/dev/mapper/EBRAM rootflags=subvol=@\"" >> /etc/default/grub

echo 'add_dracutmodules+=" crypt btrfs "' > /etc/dracut.conf.d/crypt.conf
echo 'hostonly="yes"' > /etc/dracut.conf.d/hostonly.conf
echo 'force_drivers+=" amdgpu "' > /etc/dracut.conf.d/amdgpu.conf
echo 'omit_dracutmodules+=" nfs cifs network "' > /etc/dracut.conf.d/omit-net.conf

for k_dir in /lib/modules/*; do
    KVER=$(basename "$k_dir")
    dracut -f --kver "$KVER"
done

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Void --recheck
grub-mkconfig -o /boot/grub/grub.cfg

for s in dbus elogind NetworkManager cupsd tlp zramen chronyd apparmor gdm udevd; do
    [ -d "/etc/sv/$s" ] && ln -sfn "/etc/sv/$s" /etc/runit/runsvdir/default/
done

xbps-remove -Fy tracker3-miners || true
CHROOT_EOF

umount -R /mnt
echo "======================================================================"
echo "   INSTALL COMPLETE: Reboot, enter LUKS pass, and log in.             "
echo "======================================================================"
