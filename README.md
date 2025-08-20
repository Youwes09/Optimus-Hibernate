# Hibernate - Low-Power Mode for Optimus Laptops

Enhanced lid-functional low-power mode script for laptops with hybrid graphics (NVIDIA/AMD + integrated GPU), focused on energy efficiency and hardware longevity.

---

## Disclaimer

**This code was tested on an ASUS Zephyrus G14 with Hyprland**
If you find issues (or missing dependencies) please let me know or make a pull request with your fix.
My goal is to make an **Optimus** friendly linux environment for future users who may come across the same problems.


## Features

- **Automatic GPU Switching**  
  Switches from discrete GPU to integrated GPU on lid close for maximum power saving. Supports:
  - NVIDIA Optimus / PRIME setups
  - AMD hybrid graphics via `vgaswitcheroo`

- **Adaptive CPU Power Management**  
  Optimizes CPU frequency and power settings based on CPU type:
  - AMD P-State support (`energy_performance_preference`)
  - Intel CPU governor management
  - Aggressive power saving when battery is low (<30%)

- **Wireless & Bluetooth Management**  
  Saves and restores WiFi/Bluetooth state on lid close/open.

- **Display & Backlight Control**  
  Turns off display and keyboard backlight safely using:
  - X11 DPMS
  - Wayland compositors (Hyprland, Sway)
  - Fallback: `vbetool` or minimum backlight

- **USB and PCI Power Optimizations**  
  Autosuspends USB devices (excluding input/wireless devices) and configures PCIe/SATA/NVMe power policies.

- **Screen Locking**  
  Automatically locks the user session when lid closes.

- **Debounced Lid Detection**  
  Reduces false triggers with improved responsiveness.

---

## Installation Requirements

- **Root privileges** (script must run as root)
- `cpupower` package (for CPU governor management)
- `nmcli` (NetworkManager CLI)
- `rfkill` (optional, for Bluetooth management)
- `supergfxctl` (optional, for NVIDIA hybrid GPU control)
- `vbetool` (optional fallback for display control)
- Systemd for service management

---

## Installation

1. Copy script to a system path and make executable:

```bash
sudo cp lid-lowpower.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/lid-lowpower.sh
```
## Credits
This code was reviewed by Claude for debugging and adding comments!
Hopefully that made my code more readable than it would be without, feel free to reach out if you have improvement ideas or questions!
