# ⚡ Void Linux Hybrid RAM-OS Builder (Trading Edition)

A production-grade, automated deployment script that converts a standard Void Linux installation into an immutable, hyper-fast, RAM-loaded operating system.

This architecture is engineered specifically for latency-sensitive financial trading, algorithmic execution, and heavy multi-chart browser environments (like TradingView). By leveraging SquashFS, OverlayFS, and aggressive kernel-level performance tuning, this script gives you the persistence of a standard desktop combined with the blistering speed and amnesic security of a Live USB—running entirely out of your physical RAM.
🚀 Enterprise Features
Core Architecture

    Live-Snapshotting (Rsync): Safely clones your running Base System into a temporary staging area without risking file-tearing or locking issues.

    ZSTD Compression: Utilizes multi-threaded ZSTD (Level 15) compression for the optimal balance between small image size and hyper-fast RAM decompression.

    OverlayFS RAM Boot: Bypasses legacy device-mapper snapshots to mount the file system directly into RAM for native read/write speeds.

    Self-Installing: Automatically installs itself to /usr/local/sbin/update-void-live upon its first successful run.

    Dynamic GRUB Generation: Automatically detects your boot partition UUID and the newest installed kernel to generate a flawless GRUB menu, including a permanent fallback to your Base System.

Trading Performance Optimizations

    ZRAM Memory Multiplication: On-the-fly RAM compression (zstd, 50% capacity) to gracefully handle massive browser memory spikes without touching a physical swap drive.

    Hardware-Enforced CPU Tuning: Injects a native runit service into the Live OS to lock all CPU cores to the performance governor immediately upon boot.

    EarlyOOM Browser Protection: Configured to strictly avoid killing trading browsers (chrome, brave, firefox, librewolf) while aggressively terminating background tasks if RAM drops below 5%.

    Volatile Logging: Disables Void's native socklog and nanoklogd in the live environment to prevent background CPU cycles and RAM consumption from system logs.

    Sysctl Overcommit: Tweaks overcommit_memory and swappiness to prioritize active charting data over background caching.

Stateless Security & Sanitization

    Hardware Agnostic: Strips UUID= and PARTUUID= from fstab to guarantee bootability.

    Network & Identity Purging: Deletes Machine IDs, SSH Host Keys, NetworkManager states, and DHCP leases before compression to prevent network collisions and ensure cryptographic uniqueness on every boot.

    Hardcoded DNS: Enforces Cloudflare (1.1.1.1) and Google (8.8.8.8) DNS to prevent broker connection drops.

📋 System Requirements

    Base OS: Void Linux (glibc or musl) installed on an SSD/NVMe.

    Memory: Minimum 16GB RAM (32GB+ highly recommended for heavy charting).

    Boot Space: At least 1.5GB to 2GB of free space in your /boot partition (or / if /boot is not a separate partition) to store the .sfs image.

    Dependencies: The script will attempt to install these automatically, but ensure your system has access to the Void repos: squashfs-tools, rsync, earlyoom, zramen.

🛠️ Installation & First Run

    Boot into your standard Void Linux Base System.

    Configure everything exactly how you want your trading environment (install your browsers, set your wallpapers, arrange your bookmarks, save your Wi-Fi passwords).

    Download or create the script:
    Bash

    nano build-os.sh
    # Paste the V9 script contents here

    Make it executable:
    Bash

    chmod +x build-os.sh

    Execute the build process:
    Bash

    sudo ./build-os.sh

Upon a successful build, the script will automatically copy itself to your global binaries. You can delete build-os.sh from your local folder.
🔄 The Daily Workflow

Because this is a Hybrid system, you now have two operating systems accessible from your GRUB menu.
1. Trading Days (Boot to RAM)

Turn on your PC and select Void Trading OS (RAM Mode) from GRUB. The system will load entirely into your RAM. Trade securely with zero latency.

    ⚠️ Warning: Any files downloaded, settings changed, or charts saved locally while in RAM Mode will be permanently destroyed upon reboot. Save critical data to an external drive or cloud storage.

2. Updating the System (Boot to Base)

When you need to update Void Linux, change a persistent layout, or install a new trading app:

    Reboot into the Void Base System (Fallback).

    Run your updates (e.g., sudo xbps-install -Su) or configure your new apps.

    Open a terminal and run the global update command:
    Bash

    sudo update-void-live

    Wait 60 seconds for the system to re-compress the OS. Reboot back into RAM Mode to enjoy the upgraded system.

💡 Pro-Tip: "Pre-Warming" the Browser

Because the script uses rsync to take an exact snapshot of your current filesystem state, you can "pre-warm" your trading setup to eliminate load times entirely.

Before running sudo update-void-live:

    Open your browser.

    Log into your broker / TradingView.

    Load all of your heavy multi-chart layouts so the data caches locally.

    Close the browser.

    Run sudo update-void-live.

Your Live OS will now boot with those exact charts already cached in the browser profile, resulting in instant rendering the moment you open your browser in RAM Mode.
