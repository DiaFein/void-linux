Void Linux Custom ISO Builder: Multi Edition 🚀

This repository contains a professional-grade build script for generating a customized Void Linux Live ISO. It is specifically engineered for high-performance  environments, featuring a pre-configured GNOME desktop and a dual-installer architecture.
🌟 Key Features

    GNOME Desktop: Pre-configured with Wayland, GDM autologin, and essential tools (gnome-terminal, mousepad, chromium).

    Dual-Installer UX:

        Native Installer: The standard void-installer for manual/standard setups.

        Trading Deployer: A custom, automated installer for advanced users.

    Lightning Mode (30s Install): The custom deployer can "clone" the Live ISO's root filesystem directly to your NVMe/SSD, bypassing the network for a near-instant installation.

    Advanced Storage: Automated LUKS2 Encryption and LVM volume management (Root, Swap, Home).

    Performance Tuned:

        Forced Linux Mainline Kernel.

        TCP BBR congestion control and low-latency sysctl tweaks.

        ZRAM enabled by default (50% of RAM).

        Hardware acceleration flags for Chromium.

    Global CDN Routing: Dynamically selects the fastest mirror but defaults to the Fastly Global CDN for maximum stability.

🛠️ Prerequisites

The builder script handles most dependencies automatically, but your host machine should ideally be running a Linux distribution with the following tools available:

    bash, sudo, curl, git, make, parted

    At least 20GB of free disk space for build artifacts.

🚀 How to Build

    Clone the workspace:
    The script will create a workspace at ~/void-iso/.

    Run the builder:
    Bash

    chmod +x build-void-iso.sh
    sudo ./build-void-iso.sh

    Find your ISO:
    Once the process completes (usually 10–20 minutes depending on your internet speed), the ISO will be located at:
    ~/void-iso/void-mklive/void-custom-gnome-production.iso

💻 Using the Live ISO

Once you flash the ISO to a USB drive and boot from it:

    The system will autologin to the GNOME Desktop.

    Open a terminal or switch to a TTY and type:
    Bash

    void-setup

    Choose Option 2 for the High-Performance Trading Deployer.

Installer Inputs Guide

    Target Disk: e.g., /dev/nvme0n1 or /dev/sda.

    Source: Choose Local ISO Clone for the fastest possible install (no internet required).

    Sizing: * EFI/Boot: Entered in MiB (e.g., 512, 1024).

        Swap/Root: Entered in GiB (e.g., 4, 30).

📂 Technical Architecture
Component	Choice	Reason
Kernel	linux-mainline	Latest hardware support and performance patches.
Initramfs	dracut	Hardened with LUKS and LVM modules.
Init System	runit	Blazing fast service management.
Encryption	LUKS2	Industry-standard full disk encryption.
Network	BBR + FQ	Optimized for high-frequency data throughput.
⚠️ Important Notes

    Keyboard Layout: The installer and the resulting system default to the US Keyboard Layout.

    Timezone: Automatically locked to Asia/Kolkata.

    User Credentials: You will be prompted for your LUKS, Root, and User passwords during the installation process. These are applied instantly to the new system.

    Peer-to-Peer Tip: If you encounter a strip warning during the build process, don't worry—the script now includes binutils to handle that natively. If your local clone feels "too fast," check /mnt—it's likely already done!
