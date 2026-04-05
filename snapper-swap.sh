#!/bin/bash
# ---------------------------------------------------------
# Modular Void Linux Setup: BTRFS Swap, Snapper, ZRAM
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
        
        echo "Setting strict permissions (chmod 600)..."
        chmod 600 /swap/swapfile
        
        echo "Enabling swap..."
        swapon /swap/swapfile
        
        echo "Adding swap to /etc/fstab..."
        if ! grep -q "/swap/swapfile" /etc/fstab; then
            echo "/swap/swapfile none swap defaults 0 0" >> /etc/fstab
        fi
        echo "✅ Swap configured safely and securely."
    else
        echo "⚠️ Directory /swap already exists. Skipping swap creation to prevent overwrites."
    fi
}

# ==========================================
# FUNCTION: 2. Setup Snapper & Automation
# ==========================================
setup_snapper() {
    echo -e "\n📸 --- Configuring Snapper & Automation ---"
    
    echo "Installing dependencies..."
    xbps-install -Suy snapper grub-btrfs inotify-tools cronie || { echo "❌ Failed to install dependencies"; return; }

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
        echo "⚠️ Snapper root config already exists. Skipping Snapper setup."
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

    echo "Creating ultra-safe 'xbps-up' system-wide wrapper script..."
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
    echo "❌ XBPS failed with status $STATUS. POST-snapshot skipped to preserve clean rollback state."
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
    xbps-install -Suy zramen || { echo "❌ Failed to install zramen"; return; }

    echo "Enabling zramen service..."
    if [ ! -L /var/service/zramen ]; then
        ln -s /etc/sv/zramen /var/service/
        echo "✅ ZRAM service enabled and started."
    else
        echo "⚠️ ZRAM service is already enabled."
    fi
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
    echo "  4) Execute ALL Setup Steps (1, 2, and 3)"
    echo "  5) Exit"
    echo "========================================================="
    read -p "Select an option [1-5]: " choice
    
    case $choice in
        1)
            setup_swap
            ;;
        2)
            setup_snapper
            ;;
        3)
            setup_zram
            ;;
        4)
            setup_swap
            setup_zram
            setup_snapper
            ;;
        5)
            echo "Exiting toolkit. Stay safe!"
            exit 0
            ;;
        *)
            echo "❌ Invalid option. Please try again."
            sleep 2
            show_menu
            ;;
    esac
    
    echo -e "\nPress [Enter] to return to the menu..."
    read
    show_menu
}

# Start the script
show_menu
