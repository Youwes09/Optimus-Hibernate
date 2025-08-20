#!/bin/bash
# Enhanced Lid low-power mode for G14 - Maximum efficiency with AMD support
# Run as root via systemd service

LID_STATE="/proc/acpi/button/lid/LID0/state"
LOCK_FILE="/tmp/nvidia_lock"
LOG_FILE="/var/log/lid-lowpower.log"
STATE_FILE="/tmp/lid-power-state"

# Minimal logging - only errors and state changes
log() {
    echo "$(date +'%F %T') $1" >> "$LOG_FILE"
}

# Enhanced display detection and control
get_display_session() {
    # Try to find active display session
    if [[ -z "$DISPLAY" ]]; then
        # Try common display numbers
        for disp in :0 :1; do
            if [[ -S "/tmp/.X11-unix/X${disp#:}" ]]; then
                export DISPLAY="$disp"
                break
            fi
        done
        
        # Try loginctl for wayland/x11 sessions
        if [[ -z "$DISPLAY" ]]; then
            local session=$(loginctl list-sessions --no-legend | awk '{print $1}' | head -1)
            if [[ -n "$session" ]]; then
                local session_display=$(loginctl show-session "$session" -p Display --value 2>/dev/null)
                [[ -n "$session_display" ]] && export DISPLAY="$session_display"
            fi
        fi
    fi
}

# AMD/Intel CPU detection and optimization
detect_cpu_type() {
    if grep -q "AMD" /proc/cpuinfo; then
        CPU_TYPE="amd"
        # Check for amd-pstate driver
        if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver ]]; then
            local driver=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null)
            [[ "$driver" == "amd-pstate" ]] && AMD_PSTATE=true
        fi
    elif grep -q "Intel" /proc/cpuinfo; then
        CPU_TYPE="intel"
    else
        CPU_TYPE="unknown"
    fi
}

# Enhanced GPU detection and handling
detect_gpu_setup() {
    GPU_TYPE="unknown"
    
    # Check for NVIDIA with supergfxctl
    if command -v supergfxctl >/dev/null 2>&1; then
        GPU_TYPE="nvidia_hybrid"
        return
    fi
    
    # Check for AMD hybrid graphics
    if lspci | grep -i "amd.*vga" >/dev/null && [[ -f /sys/kernel/debug/vgaswitcheroo/switch ]]; then
        GPU_TYPE="amd_hybrid"
        return
    fi
    
    # Single GPU setups
    if lspci | grep -i "nvidia.*vga" >/dev/null; then
        GPU_TYPE="nvidia_single"
    elif lspci | grep -i "amd.*vga" >/dev/null; then
        GPU_TYPE="amd_single"
    fi
}

# Initial system detection and state capture
init_system_state() {
    detect_cpu_type
    detect_gpu_setup
    get_display_session
    
    # Create persistent state file
    mkdir -p "$(dirname "$STATE_FILE")"
    
    # Initial state capture
    CPU_GOV=$(cpupower frequency-info -p 2>/dev/null | awk '{print $4}' || echo "performance")
    
    # Store initial brightness if available
    if [[ -f /sys/class/leds/asus::kbd_backlight/brightness ]]; then
        INITIAL_KBD_BRIGHTNESS=$(cat /sys/class/leds/asus::kbd_backlight/brightness 2>/dev/null || echo "3")
    fi
    
    # Store display brightness if available
    if [[ -d /sys/class/backlight ]]; then
        for bl in /sys/class/backlight/*/brightness; do
            if [[ -r "$bl" ]]; then
                INITIAL_DISPLAY_BRIGHTNESS=$(cat "$bl" 2>/dev/null)
                DISPLAY_BACKLIGHT_PATH="$bl"
                break
            fi
        done
    fi
}

# Enhanced state persistence
save_state() {
    local key="$1"
    local value="$2"
    echo "${key}=${value}" >> "${STATE_FILE}.tmp"
}

load_state() {
    local key="$1"
    local default="$2"
    if [[ -f "$STATE_FILE" ]]; then
        grep "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2- || echo "$default"
    else
        echo "$default"
    fi
}

commit_state() {
    [[ -f "${STATE_FILE}.tmp" ]] && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# Enhanced GPU switching
gpu_to_integrated() {
    case "$GPU_TYPE" in
        nvidia_hybrid)
            local current_gpu=$(supergfxctl -g 2>/dev/null || echo "unknown")
            save_state "gpu_state" "$current_gpu"
            if [[ "$current_gpu" != "Integrated" ]] && [[ "$current_gpu" != "unknown" ]]; then
                supergfxctl -m Integrated >/dev/null 2>&1
                log "GPU: Switched to integrated ($current_gpu -> Integrated)"
            fi
            ;;
        amd_hybrid)
            if [[ -w /sys/kernel/debug/vgaswitcheroo/switch ]]; then
                local current=$(cat /sys/kernel/debug/vgaswitcheroo/switch 2>/dev/null | grep "^0:" | cut -d':' -f2)
                save_state "gpu_state" "$current"
                echo "IGD" > /sys/kernel/debug/vgaswitcheroo/switch 2>/dev/null
                log "GPU: Switched to integrated via vgaswitcheroo"
            fi
            ;;
    esac
}

gpu_restore() {
    case "$GPU_TYPE" in
        nvidia_hybrid)
            local saved_gpu=$(load_state "gpu_state" "unknown")
            if [[ -n "$saved_gpu" ]] && [[ "$saved_gpu" != "unknown" ]]; then
                local current_gpu=$(supergfxctl -g 2>/dev/null || echo "unknown")
                if [[ "$saved_gpu" != "$current_gpu" ]]; then
                    supergfxctl -m "$saved_gpu" >/dev/null 2>&1
                    log "GPU: Restored to $saved_gpu"
                fi
            fi
            ;;
        amd_hybrid)
            local saved_gpu=$(load_state "gpu_state" "")
            if [[ -n "$saved_gpu" ]] && [[ -w /sys/kernel/debug/vgaswitcheroo/switch ]]; then
                echo "DIS" > /sys/kernel/debug/vgaswitcheroo/switch 2>/dev/null
                log "GPU: Restored via vgaswitcheroo"
            fi
            ;;
    esac
}

# Enhanced wireless state handling
save_wireless_state() {
    # WiFi state
    local wifi_state=$(nmcli -t -f WIFI general status 2>/dev/null || echo "unknown")
    save_state "wifi_state" "$wifi_state"
    
    # Bluetooth state - check if blocked
    local bt_blocked="unknown"
    if command -v rfkill >/dev/null 2>&1; then
        # rfkill returns "yes" for blocked, "no" for unblocked
        bt_blocked=$(rfkill list bluetooth 2>/dev/null | grep 'Soft blocked' | awk '{print $3}' | head -1)
        [[ -z "$bt_blocked" ]] && bt_blocked="unknown"
    fi
    save_state "bt_blocked" "$bt_blocked"
}

restore_wireless_state() {
    # Restore WiFi
    local saved_wifi=$(load_state "wifi_state" "unknown")
    if [[ "$saved_wifi" == "enabled" ]]; then
        nmcli radio wifi on 2>/dev/null
    fi
    
    # Restore Bluetooth - unblock if it was originally unblocked
    local saved_bt=$(load_state "bt_blocked" "unknown")
    if [[ "$saved_bt" == "no" ]]; then
        rfkill unblock bluetooth 2>/dev/null
    fi
}

# Enhanced display and backlight control
turn_off_display() {
    # Turn off keyboard backlight
    if [[ -w /sys/class/leds/asus::kbd_backlight/brightness ]]; then
        save_state "kbd_brightness" "$INITIAL_KBD_BRIGHTNESS"
        echo 0 > /sys/class/leds/asus::kbd_backlight/brightness
    fi

    # Try proper display off via DPMS or Wayland
    local display_off=false

    # X11
    if [[ -n "$DISPLAY" ]]; then
        export XAUTHORITY=/home/shozikan/.Xauthority
        if xset dpms force off 2>/dev/null; then
            display_off=true
            log "Display turned off via X11 DPMS"
        fi

    # Hyprland
    elif pgrep -x "Hyprland" >/dev/null; then
        if sudo -u shozikan hyprctl dispatch dpms off 2>/dev/null; then
            display_off=true
            log "Display turned off via Hyprland DPMS"
        fi

    # Sway
    elif pgrep -x "sway" >/dev/null; then
        if sudo -u shozikan swaymsg "output * dpms off" 2>/dev/null; then
            display_off=true
            log "Display turned off via Sway DPMS"
        fi
    fi

    # Fallback vbetool
    if [[ "$display_off" == false ]] && command -v vbetool >/dev/null; then
        if vbetool dpms off 2>/dev/null; then
            display_off=true
            log "Display turned off via vbetool"
        fi
    fi

    # Final fallback: dim backlight to 1%
    if [[ "$display_off" == false ]] && [[ -w "$DISPLAY_BACKLIGHT_PATH" ]]; then
        local max_brightness=$(cat "${DISPLAY_BACKLIGHT_PATH%/*}/max_brightness")
        local min_brightness=$((max_brightness / 100))
        [[ "$min_brightness" -lt 1 ]] && min_brightness=1
        echo "$min_brightness" > "$DISPLAY_BACKLIGHT_PATH"
        log "Display dimmed to minimum (DPMS unavailable)"
    fi
}


restore_display() {
    # Restore keyboard backlight
    local saved_kbd=$(load_state "kbd_brightness" "$INITIAL_KBD_BRIGHTNESS")
    if [[ -w /sys/class/leds/asus::kbd_backlight/brightness ]]; then
        echo "$saved_kbd" > /sys/class/leds/asus::kbd_backlight/brightness
    fi

    local display_restored=false

    # X11
    if [[ -n "$DISPLAY" ]]; then
        export XAUTHORITY=/home/shozikan/.Xauthority
        if xset dpms force on 2>/dev/null; then
            display_restored=true
            log "Display restored via X11 DPMS"
        fi

    # Hyprland
    elif pgrep -x "Hyprland" >/dev/null; then
        if sudo -u shozikan hyprctl dispatch dpms on 2>/dev/null; then
            display_restored=true
            log "Display restored via Hyprland DPMS"
        fi

    # Sway
    elif pgrep -x "sway" >/dev/null; then
        if sudo -u shozikan swaymsg "output * dpms on" 2>/dev/null; then
            display_restored=true
            log "Display restored via Sway DPMS"
        fi
    fi

    # Fallback vbetool
    if [[ "$display_restored" == false ]] && command -v vbetool >/dev/null; then
        if vbetool dpms on 2>/dev/null; then
            display_restored=true
            log "Display restored via vbetool"
        fi
    fi

    # Restore backlight brightness after waking display
    local saved_brightness=$(load_state "display_brightness" "")
    if [[ -n "$saved_brightness" ]] && [[ -w "$DISPLAY_BACKLIGHT_PATH" ]]; then
        sleep 0.2
        echo "$saved_brightness" > "$DISPLAY_BACKLIGHT_PATH"
        log "Display backlight restored"
    fi
}


# Enhanced battery and thermal awareness
get_battery_state() {
    local battery_status=$(cat /sys/class/power_supply/BAT*/status 2>/dev/null | head -1)
    local battery_level=$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null | head -1)
    
    # Check if on battery and low power
    if [[ "$battery_status" == "Discharging" ]] && [[ -n "$battery_level" ]] && [[ "$battery_level" -lt 30 ]]; then
        AGGRESSIVE_POWER=true
    else
        AGGRESSIVE_POWER=false
    fi
}

get_cpu_temp() {
    # Try various temperature sensors
    local temp_files=(
        /sys/class/hwmon/hwmon*/temp*_input
        /sys/class/thermal/thermal_zone*/temp
    )
    
    for temp_file in "${temp_files[@]}"; do
        if [[ -r "$temp_file" ]]; then
            local temp=$(cat "$temp_file" 2>/dev/null)
            if [[ -n "$temp" ]] && [[ "$temp" -gt 0 ]]; then
                echo "$temp"
                return
            fi
        fi
    done
    echo "50000"  # Default safe temperature
}

lid_close() {
    log "CLOSE: Entering low-power mode"
    
    # Clear previous temp state
    rm -f "${STATE_FILE}.tmp"
    
    get_battery_state
    local cpu_temp=$(get_cpu_temp)
    
    # Save current states
    save_wireless_state
    
    # Apply power settings
    cpupower frequency-set -g powersave >/dev/null 2>&1
    
    # Enhanced CPU power management for AMD
    if [[ "$CPU_TYPE" == "amd" ]] && [[ "$AMD_PSTATE" == true ]]; then
        # AMD P-State specific optimizations
        for cpu in /sys/devices/system/cpu/cpu*/cpufreq/; do
            [[ -w "${cpu}energy_performance_preference" ]] && 
                echo "power" > "${cpu}energy_performance_preference" 2>/dev/null
        done
    fi
    
    # USB autosuspend (skip wireless and input devices)
    for usb in /sys/bus/usb/devices/*/power/control; do
        if [[ -w "$usb" ]]; then
            local usb_path="${usb%/power/control}"
            # Skip if it's a wireless adapter or input device
            if ! grep -q -E "(wireless|input|keyboard|mouse)" "${usb_path}/modalias" 2>/dev/null; then
                echo "auto" > "$usb" 2>/dev/null
            fi
        fi
    done
    
    # Conservative power management with write checks
    if [[ -w /sys/module/pcie_aspm/parameters/policy ]]; then
        echo "powersave" > /sys/module/pcie_aspm/parameters/policy 2>/dev/null
    fi
    
    for sata in /sys/class/scsi_host/host*/link_power_management_policy; do
        [[ -w "$sata" ]] && echo "medium_power" > "$sata" 2>/dev/null
    done
    
    # NVMe power management
    for nvme in /sys/class/nvme/nvme*/power/control; do
        [[ -w "$nvme" ]] && echo "auto" > "$nvme" 2>/dev/null
    done
    
    # Disable radios
    local wifi_state=$(load_state "wifi_state" "unknown")
    [[ "$wifi_state" == "enabled" ]] && nmcli radio wifi off 2>/dev/null
    
    local bt_blocked=$(load_state "bt_blocked" "unknown")
    [[ "$bt_blocked" == "no" ]] && rfkill block bluetooth 2>/dev/null
    
    # GPU switch if safe and needed
    if [[ ! -f "$LOCK_FILE" ]] && ! pgrep -f "(steam|game|vulkan|opengl|amdgpu|rocm)" >/dev/null; then
        gpu_to_integrated
    fi

    USER_SESSION=$(loginctl list-sessions | awk '/shozikan/ {print $1; exit}')
    sudo -u shozikan loginctl lock-session "$USER_SESSION"
    log "Screen locked via loginctl (session $USER_SESSION)"
    
    # Turn off displays and backlights
    turn_off_display
    
    # Commit all state changes
    commit_state
}

lid_open() {
    log "OPEN: Restoring normal mode"
    
    # Restore CPU governor
    cpupower frequency-set -g "$CPU_GOV" >/dev/null 2>&1
    
    # Restore AMD P-State preferences
    if [[ "$CPU_TYPE" == "amd" ]] && [[ "$AMD_PSTATE" == true ]]; then
        for cpu in /sys/devices/system/cpu/cpu*/cpufreq/; do
            [[ -w "${cpu}energy_performance_preference" ]] && 
                echo "balance_performance" > "${cpu}energy_performance_preference" 2>/dev/null
        done
    fi
    
    # Restore USB power
    for usb in /sys/bus/usb/devices/*/power/control; do
        [[ -w "$usb" ]] && echo "on" > "$usb" 2>/dev/null
    done
    
    # Restore power policies with write checks
    if [[ -w /sys/module/pcie_aspm/parameters/policy ]]; then
        echo "default" > /sys/module/pcie_aspm/parameters/policy 2>/dev/null
    fi
        
    for sata in /sys/class/scsi_host/host*/link_power_management_policy; do
        [[ -w "$sata" ]] && echo "max_performance" > "$sata" 2>/dev/null
    done
    
    # Restore NVMe
    for nvme in /sys/class/nvme/nvme*/power/control; do
        [[ -w "$nvme" ]] && echo "on" > "$nvme" 2>/dev/null
    done
    
    # Restore wireless
    restore_wireless_state
    
    # Restore GPU
    gpu_restore
    
    # Restore display and backlights
    restore_display
}

# Enhanced lid state detection with debouncing
check_lid() {
    local state1 state2
    state1=$(awk '{print $2}' "$LID_STATE" 2>/dev/null)
    sleep 0.3  # Reduced debounce time for better responsiveness
    state2=$(awk '{print $2}' "$LID_STATE" 2>/dev/null)
    [[ "$state1" == "$state2" ]] && echo "$state1"
}

# Verify root and initialize
[[ $EUID -ne 0 ]] && { log "ERROR: Must run as root"; exit 1; }

# Initialize system detection and state
init_system_state

log "Started (PID: $$, CPU: $CPU_TYPE, GPU: $GPU_TYPE)"
PREV_STATE="open"

# Cleanup function
cleanup() {
    log "Shutting down (PID: $$)"
    rm -f "${STATE_FILE}" "${STATE_FILE}.tmp"
    exit 0
}

trap cleanup EXIT TERM INT

# Main loop with enhanced responsiveness
while true; do
    [[ ! -f "$LID_STATE" ]] && { sleep 5; continue; }
    
    if STATE=$(check_lid); then
        if [[ "$STATE" == "closed" && "$PREV_STATE" == "open" ]]; then
            lid_close
            PREV_STATE="closed"
        elif [[ "$STATE" == "open" && "$PREV_STATE" == "closed" ]]; then
            lid_open  
            PREV_STATE="open"
        fi
    fi
    
    # Adaptive sleep - shorter when lid events are happening
    if [[ "$PREV_STATE" != "$STATE" ]] 2>/dev/null; then
        sleep 2  # Faster polling after state change
    else
        sleep 4  # Normal polling interval
    fi
done
