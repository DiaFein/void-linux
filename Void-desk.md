Void Linux High-Performance 

An aggressive, idempotent deployment script designed to optimize Void Linux for ultra-low latency, web-based algorithmic trading, and high-frequency charting (e.g., TradingView, web broker terminals).

This setup is specifically engineered for GNOME on Wayland using AMD graphics, enabling fluid multi-monitor arrays (up to 4x 4K @ 120Hz) without the screen tearing or micro-stutters associated with legacy X11 environments.
Core Features
🌐 Network & WebSocket Optimization

    TCP BBR Congestion Control: Loads the BBR module and enforces it via sysctl for maximum throughput and reduced packet loss.

    Network Latency Tuning: Enables device polling (busy_poll, busy_read), lowers TCP retries, and disables timer migration to reduce kernel jitter.

    Maximized File Descriptors: Raises the system file descriptor limit to 1,048,576 to ensure persistent WebSocket connections (live Level 2 data, tick feeds) never drop during heavy sessions.

🖥️ UI & Browser Hardware Acceleration

    Chromium/Brave Optimization: Injects global environment variables (/etc/chromium/custom-flags.conf) to bypass GPU blocklists, forcing Vulkan rendering, zero-copy rasterization, and native Wayland composition (Ozone).

    GNOME Debloat: Strips out background file indexers (tracker3-miners) and enforces global dconf rules to disable UI animations and background software updates.

⚙️ Kernel & Hardware Tuning

    Idempotent GRUB Hardening: Applies amd_pstate=active, disables watchdogs (nowatchdog, nmi_watchdog=0), and disables auditing for lower kernel overhead.

    Boot-Time Hardware Initialization (/etc/rc.local): * Disables Transparent Huge Pages (THP) to prevent memory latency spikes.

        Forces the CPU governor to performance.

        Locks the AMD GPU dynamic power management (DPM) state to high/performance.

        Optimizes block device request affinity for NVMe/SSD storage.

    Custom TuneD Profile: Deploys and activates a bespoke trading-ultra profile tailored for deterministic execution.

Hardware Requirements

    OS: Void Linux (glibc or musl).

    GPU: AMD Radeon (RX series recommended for multi-4K).

    Display Topology: Direct connections only (DisplayPort 1.4+ or HDMI 2.1). Do not daisy-chain displays via DP-MST.

    Desktop Environment: GNOME (must be running Wayland).

Installation & Usage

1. Prepare the Script
Save the script as void-trading-init.sh and make it executable:
Bash

chmod +x void-trading-init.sh

2. Execute as Root
The script modifies boot parameters, system limits, and hardware states. It must be run with root privileges. It is strictly idempotent and safe to run multiple times.
Bash

sudo ./void-trading-init.sh

3. Reboot
A system reboot is mandatory to apply the new GRUB parameters, load the TCP BBR kernel module, and initialize the Wayland session correctly.
Bash

sudo reboot

Post-Installation (Crucial User-Space Steps)

System-wide performance tweaks are handled by the script, but your specific multi-monitor workflow requires manual configuration within your user session. Do not run these commands as root.

Once you log back into GNOME, open a standard terminal:
1. Enable Variable Refresh Rate (VRR / FreeSync)

Unlock FreeSync support in GNOME to smooth out chart panning and reduce tearing:
Bash

gsettings set org.gnome.mutter experimental-features "['variable-refresh-rate']"

Note: You must log out and log back in to see the new VRR toggle in Settings -> Displays.
2. Lock Workspaces to the Primary Monitor

Prevent your secondary charting screens or broker terminals from shifting when you switch workspaces on your main screen:
Bash

gsettings set org.gnome.mutter workspaces-only-on-primary true

3. Configure Displays

Navigate to GNOME Settings -> Displays:

    Ensure each 4K monitor is explicitly set to 120Hz (GNOME defaults to 60Hz for newly connected displays).

    Enable Fractional Scaling if required for text readability. Native Wayland browser scaling will keep charts razor-sharp.

⚠️ Important Hardware Notice: The AMD MCLK Quirk

When driving dual or quad 4K monitors at 120Hz, your AMD GPU's memory clock (mclk) will remain locked at its maximum frequency permanently. This is intentional driver behavior; the "blanking interval" of a 4K 120Hz signal is too short to allow the VRAM to downclock without causing the displays to flicker or crash.

    Result: The GPU will idle at a higher power draw (typically 30W - 60W).

    Action Required: Ensure your PC case has adequate airflow. Do not attempt to force the VRAM clocks lower via sysfs scripts, as this will destabilize your trading session.
