#!/bin/bash
# ---------------------------------------------------------
# Master Void Linux Performance & Recovery Toolkit v3.0
# Includes: BTRFS Swap, Snapper, ZRAM, Plymouth (void10)
# ---------------------------------------------------------

# 0. Root Check
if [ "$EUID" -ne 0 ]; then
  echo "🚫 Error: Please run this script as root (using sudo)."
  exit 1
fi

# ==========================================
# FUNCTION: 1. Setup BTRFS Swapfile
# ==========================================
setup_swap() {
    echo -e "\n💾 --- Configuring BTRFS Swapfile ---"
    SWAP_SIZE="4G"

    if [ ! -d "/swap" ]; then
        echo "Creating /swap subvolume..."
        btrfs subvolume create /swap
        
        echo "Applying strict BTRFS swap rules (NoCOW, No Compression)..."
        chattr +C /swap
        btrfs property set /swap compression none
        
        echo "Creating a $SWAP_SIZE swapfile..."
        btrfs filesystem mkswapfile --size $SWAP_SIZE /swap/swapfile
        
        echo "Setting strict permissions..."
        chmod 600 /swap/swapfile
        
        echo "Enabling swap..."
        swapon /swap/swapfile
        
        echo "Adding swap to /etc/fstab..."
        if ! grep -q "/swap/swapfile" /etc/fstab; then
            echo "/swap/swapfile none swap defaults 0 0" >> /etc/fstab
        fi
        echo "✅ Swap configured safely and securely."
    else
        echo "⚠️ Directory /swap already exists. Skipping swap creation."
    fi
}

# ==========================================
# FUNCTION: 2. Setup Snapper & Automation
# ==========================================
setup_snapper() {
    echo -e "\n📸 --- Configuring Snapper & Automation ---"
    
    echo "Installing dependencies..."
    xbps-install -Sy snapper grub-btrfs inotify-tools cronie || { echo "❌ Failed to install dependencies"; return 1; }

    if [ ! -f "/etc/snapper/configs/root" ]; then
        echo "Creating Snapper root config..."
        snapper -c root create-config /
        
        echo "Applying strict timeline and number limits..."
        sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="yes"/' /etc/snapper/configs/root
        sed -i 's/^TIMELINE_CLEANUP=.*/TIMELINE_CLEANUP="yes"/' /etc/snapper/configs/root
        sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="0"/' /etc/snapper/configs/root
        sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="2"/' /etc/snapper/configs/root
        sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="1"/' /etc/snapper/configs/root
        sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="1"/' /etc/snapper/configs/root
        sed -i 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' /etc/snapper/configs/root
        
        sed -i 's/^NUMBER_CLEANUP=.*/NUMBER_CLEANUP="yes"/' /etc/snapper/configs/root
        sed -i 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="5"/' /etc/snapper/configs/root
        sed -i 's/^NUMBER_LIMIT_IMPORTANT=.*/NUMBER_LIMIT_IMPORTANT="3"/' /etc/snapper/configs/root
        echo "✅ Snapper configured successfully."
    else
        echo "⚠️ Snapper root config already exists. Skipping setup."
    fi

    echo "Generating GRUB configuration..."
    grub-mkconfig -o /boot/grub/grub.cfg

    echo "Enabling grub-btrfsd and cronie services..."
    [ ! -L /var/service/grub-btrfsd ] && ln -s /etc/sv/grub-btrfsd /var/service/
    [ ! -L /var/service/cronie ] && ln -s /etc/sv/cronie /var/service/

    echo "Creating cron jobs for Snapper timeline & cleanup..."
    cat << 'EOF' > /etc/cron.daily/snapper-timeline
#!/bin/sh
snapper -c root create --cleanup timeline --description "Daily timeline snapshot"
snapper -c root cleanup timeline
EOF
    chmod +x /etc/cron.daily/snapper-timeline

    cat << 'EOF' > /etc/cron.weekly/snapper-cleanup
#!/bin/sh
snapper -c root cleanup number
EOF
    chmod +x /etc/cron.weekly/snapper-cleanup

    echo "Creating ultra-safe 'xbps-up' wrapper script..."
    cat << 'EOF' > /usr/local/bin/xbps-up
#!/bin/sh
if [ "$EUID" -ne 0 ]; then
    echo "🚫 Error: Please run this command with sudo."
    exit 1
fi

echo "📸 Taking PRE-snapshot..."
snapper -c root create --description "PRE: xbps $*"

echo "📦 Running xbps-install $*..."
xbps-install "$@"
STATUS=$?

if [ $STATUS -ne 0 ]; then
    echo "❌ XBPS failed with status $STATUS. POST-snapshot skipped."
    exit $STATUS
fi

echo "📸 Taking POST-snapshot..."
snapper -c root create --description "POST: xbps $*"
EOF
    chmod +x /usr/local/bin/xbps-up
    echo "✅ Snapper automation complete!"
}

# ==========================================
# FUNCTION: 3. Setup ZRAM
# ==========================================
setup_zram() {
    echo -e "\n⚡ --- Configuring ZRAM ---"
    echo "Installing zramen..."
    xbps-install -Sy zramen || { echo "❌ Failed to install zramen"; return 1; }

    echo "Enabling zramen service..."
    if [ ! -L /var/service/zramen ]; then
        ln -s /etc/sv/zramen /var/service/
        echo "✅ ZRAM service enabled and started."
    else
        echo "⚠️ ZRAM service is already enabled."
    fi
}

# ==========================================
# FUNCTION: 4. Setup Plymouth & void10 Theme
# ==========================================
setup_plymouth() {
    echo -e "\n🎨 --- Configuring Plymouth & void10 Theme ---"

    echo "📦 Installing Plymouth and Git..."
    xbps-install -Sy plymouth git || { echo "❌ Failed to install plymouth/git"; return 1; }

    if [ ! -d /usr/share/plymouth/themes/void10 ]; then
        echo "⬇️ Cloning void10 Plymouth theme..."
        cd /tmp || return 1
        rm -rf void10
        git clone --depth=1 https://github.com/David-Castro16/void10.git || { echo "❌ Failed to clone theme"; return 1; }

        echo "📁 Installing theme..."
        cp -r void10 /usr/share/plymouth/themes/
    else
        echo "✔️ Theme already installed, skipping clone."
    fi

    echo "⚙️ Configuring GRUB boot parameters for silent boot..."
    SILENT_FLAGS="quiet splash loglevel=3 vt.global_cursor_default=0"

    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
        sed -i 's/ quiet//g; s/ splash//g; s/ loglevel=[0-9]//g; s/ vt.global_cursor_default=[0-9]//g' /etc/default/grub
        sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 $SILENT_FLAGS\"/" /etc/default/grub
    else
        echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$SILENT_FLAGS\"" >> /etc/default/grub
    fi

    sed -i 's/  / /g' /etc/default/grub

    echo "⚙️ Enabling Plymouth and AMD Early KMS in dracut..."
    mkdir -p /etc/dracut.conf.d
    cat <<EOF > /etc/dracut.conf.d/plymouth.conf
add_dracutmodules+=" plymouth "
force_drivers+=" amdgpu "
EOF

    echo "🎨 Setting default Plymouth theme..."
    plymouth-set-default-theme void10 -R

    echo "🔄 Rebuilding initramfs (full rebuild)..."
    dracut -f

    echo "🔄 Updating GRUB config..."
    if grub-mkconfig -o /boot/grub/grub.cfg; then
        echo "✔️ GRUB updated successfully."
    else
        echo "⚠️ GRUB update failed! Please check manually."
        return 1
    fi

    echo -e "\n🧪 Testing Plymouth output. You should see the splash screen for 3 seconds..."
    plymouthd
    plymouth --show-splash
    sleep 3
    plymouth --quit

    echo "✅ Plymouth setup complete! Reboot to see the splash screen."
}

# ==========================================
# MAIN MENU LOOP
# ==========================================
show_menu() {
    clear
    echo "========================================================="
    echo "       Void Linux Performance & Recovery Toolkit"
    echo "========================================================="
    echo "  1) Setup Disk Swap (BTRFS Swapfile)"
    echo "  2) Setup Snapper (Snapshots, GRUB, XBPS Wrapper)"
    echo "  3) Setup ZRAM (Compressed RAM Swap)"
    echo "  4) Setup Plymouth (Boot Splash, void10 Theme, AMD KMS)"
    echo "  5) Execute ALL Setup Steps (1, 2, 3, and 4)"
    echo "  6) Exit"
    echo "========================================================="
    read -p "Select an option [1-6]: " choice
    
    case $choice in
        1) setup_swap ;;
        2) setup_snapper ;;
        3) setup_zram ;;
        4) setup_plymouth ;;
        5) 
            setup_swap
            setup_zram
            setup_snapper
            setup_plymouth
            ;;
        6)
            echo "Exiting toolkit. Stay safe!"
            exit 0
            ;;
        *)
            echo "❌ Invalid option. Please try again."
            sleep 2
            ;;
    esac
    
    if [ "$choice" != "6" ]; then
        echo -e "\nPress [Enter] to return to the menu..."
        read -r
        show_menu
    fi
}

# Start the script
show_menu
