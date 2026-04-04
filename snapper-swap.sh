#!/bin/bash
# ---------------------------------------------------------
# Void Linux BTRFS Swap, Snapper & GRUB Auto-Setup
# ---------------------------------------------------------

# 0. Root Check
if [ "$EUID" -ne 0 ]; then
  echo "🚫 Error: Please run this script as root (using sudo)."
  exit 1
fi

echo "📦 1. Updating system and installing dependencies..."
xbps-install -Suy snapper grub-btrfs inotify-tools cronie || { echo "Failed to install dependencies"; exit 1; }

echo -e "\n💾 2. Configuring BTRFS Swapfile..."
SWAP_SIZE="4G" # Edit this variable if you want a different size

if [ ! -d "/swap" ]; then
    echo "Creating /swap subvolume..."
    btrfs subvolume create /swap
    
    echo "Disabling Copy-on-Write for /swap..."
    chattr +C /swap
    
    echo "Creating a $SWAP_SIZE swapfile..."
    btrfs filesystem mkswapfile --size $SWAP_SIZE /swap/swapfile
    
    echo "Enabling swap..."
    swapon /swap/swapfile
    
    echo "Adding swap to /etc/fstab..."
    if ! grep -q "/swap/swapfile" /etc/fstab; then
        echo "/swap/swapfile none swap defaults 0 0" >> /etc/fstab
    fi
    echo "✅ Swap configured successfully."
else
    echo "⚠️ Directory /swap already exists. Skipping swap creation to prevent overwrites."
fi

echo -e "\n📸 3. Configuring Snapper with Optimized Limits..."
if [ ! -f "/etc/snapper/configs/root" ]; then
    echo "Creating Snapper root config..."
    snapper -c root create-config /
    
    echo "Applying optimized timeline and number limits..."
    # Timeline config
    sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="yes"/' /etc/snapper/configs/root
    sed -i 's/^TIMELINE_CLEANUP=.*/TIMELINE_CLEANUP="yes"/' /etc/snapper/configs/root
    sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="0"/' /etc/snapper/configs/root
    sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="2"/' /etc/snapper/configs/root
    sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="1"/' /etc/snapper/configs/root
    sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="1"/' /etc/snapper/configs/root
    sed -i 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' /etc/snapper/configs/root
    
    # Number cleanup config (for our package manager snapshots)
    sed -i 's/^NUMBER_CLEANUP=.*/NUMBER_CLEANUP="yes"/' /etc/snapper/configs/root
    sed -i 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="5"/' /etc/snapper/configs/root
    sed -i 's/^NUMBER_LIMIT_IMPORTANT=.*/NUMBER_LIMIT_IMPORTANT="3"/' /etc/snapper/configs/root
    echo "✅ Snapper configured successfully."
else
    echo "⚠️ Snapper root config already exists. Skipping Snapper setup."
fi

echo -e "\n⚙️ 4. Configuring GRUB and Background Services..."
echo "Generating GRUB configuration..."
grub-mkconfig -o /boot/grub/grub.cfg

echo "Enabling grub-btrfsd service (auto-updates GRUB menu)..."
if [ ! -L /var/service/grub-btrfsd ]; then
    ln -s /etc/sv/grub-btrfsd /var/service/
fi

echo "Enabling cronie service (for timeline cleanup)..."
if [ ! -L /var/service/cronie ]; then
    ln -s /etc/sv/cronie /var/service/
fi

echo -e "\n⏳ 5. Setting up Timeline Automation & Package Hooks..."
echo "Creating hourly cron job for Snapper timeline..."
cat << 'EOF' > /etc/cron.hourly/snapper-timeline
#!/bin/sh
snapper -c root create --cleanup timeline --description "Timeline snapshot"
snapper -c root cleanup timeline
EOF
chmod +x /etc/cron.hourly/snapper-timeline

echo "Creating 'xbps-up' system-wide wrapper script..."
cat << 'EOF' > /usr/local/bin/xbps-up
#!/bin/sh

# Ensure user is running the wrapper as root
if [ "$EUID" -ne 0 ]; then
    echo "🚫 Error: Please run this command with sudo."
    exit 1
fi

# Pre-transaction snapshot
echo "📸 Taking pre-xbps snapshot..."
snapper -c root create --description "pre-xbps: $*"

# Run the actual XBPS command, passing along any arguments (like -Su or package names)
echo "📦 Running xbps-install $*..."
xbps-install "$@"

# Post-transaction snapshot
echo "📸 Taking post-xbps snapshot..."
snapper -c root create --description "post-xbps: $*"
EOF
chmod +x /usr/local/bin/xbps-up

echo -e "\n🎉 Setup Complete!"
echo "---------------------------------------------------------"
echo "Your system is now fully configured. From now on, use:"
echo "👉 sudo xbps-up -Su      (To update your whole system)"
echo "👉 sudo xbps-up firefox  (To install a specific package)"
echo "---------------------------------------------------------"
