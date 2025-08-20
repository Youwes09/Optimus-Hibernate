#!/bin/bash
# Enhanced Lid low-power mode for Optimus laptops
# Supports NVIDIA/AMD hybrid graphics and integrated GPU
# Run as root via systemd service

# ---------- CONFIGURATION ----------
STATE_FILE="${STATE_FILE:-/tmp/lid-power-state}"
LOG_FILE="${LOG_FILE:-/var/log/lid-lowpower.log}"
LOCK_FILE="${LOCK_FILE:-/tmp/lid-lowpower.lock}"

# Auto-detect main user (first non-root login)
USER_SESSION=$(loginctl list-sessions --no-legend | awk '$3!="" && $3!="root" {print $3; exit}')
USER_HOME=$(getent passwd "$USER_SESSION" | cut -d: -f6)
XAUTHORITY="${XAUTHORITY:-$USER_HOME/.Xauthority}"

# Lid state path
LID_STATE="/proc/acpi/button/lid/LID0/state"

# ---------- LOGGING ----------
log() { echo "$(date +'%F %T') $1" >> "$LOG_FILE"; }

# ---------- SYSTEM DETECTION ----------
detect_cpu_type() {
    if grep -q "AMD" /proc/cpuinfo; then
        CPU_TYPE="amd"
        [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver ]] &&
            [[ "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver)" == "amd-pstate" ]] &&
            AMD_PSTATE=true
    elif grep -q "Intel" /proc/cpuinfo; then
        CPU_TYPE="intel"
    else
        CPU_TYPE="unknown"
    fi
}

detect_gpu_setup() {
    GPU_TYPE="unknown"
    if command -v supergfxctl >/dev/null 2>&1; then GPU_TYPE="nvidia_hybrid"; return; fi
    if lspci | grep -i "amd.*vga" >/dev/null && [[ -f /sys/kernel/debug/vgaswitcheroo/switch ]]; then GPU_TYPE="amd_hybrid"; return; fi
    if lspci | grep -i "nvidia.*vga" >/dev/null; then GPU_TYPE="nvidia_single"; 
    elif lspci | grep -i "amd.*vga" >/dev/null; then GPU_TYPE="amd_single"; fi
}

get_display_session() {
    [[ -n "$DISPLAY" ]] && return
    for disp in :0 :1; do [[ -S "/tmp/.X11-unix/X${disp#:}" ]] && export DISPLAY="$disp" && break; done
}

# ---------- STATE MANAGEMENT ----------
save_state() { echo "$1=$2" >> "${STATE_FILE}.tmp"; }
load_state() { [[ -f "$STATE_FILE" ]] && grep "^$1=" "$STATE_FILE" | cut -d'=' -f2- || echo "$2"; }
commit_state() { [[ -f "${STATE_FILE}.tmp" ]] && mv "${STATE_FILE}.tmp" "$STATE_FILE"; }

# ---------- DISPLAY & BACKLIGHT ----------
turn_off_display() {
    # X11
    if [[ -n "$DISPLAY" ]]; then export XAUTHORITY="$XAUTHORITY"; xset dpms force off 2>/dev/null && log "Display off via X11 DPMS"; return; fi
    # Wayland Hyprland
    pgrep -x "Hyprland" >/dev/null && sudo -u "$USER_SESSION" hyprctl dispatch dpms off 2>/dev/null && log "Display off via Hyprland DPMS"
}

restore_display() {
    [[ -n "$DISPLAY" ]] && export XAUTHORITY="$XAUTHORITY" && xset dpms force on 2>/dev/null && log "Display restored via X11 DPMS"
    pgrep -x "Hyprland" >/dev/null && sudo -u "$USER_SESSION" hyprctl dispatch dpms on 2>/dev/null && log "Display restored via Hyprland DPMS"
}

# ---------- LID HANDLERS ----------
lid_close() {
    log "LID CLOSED: Entering low-power mode"
    detect_cpu_type
    detect_gpu_setup
    get_display_session
    save_state "gpu_state" "$GPU_TYPE"
    turn_off_display
    commit_state
}

lid_open() {
    log "LID OPENED: Restoring normal mode"
    restore_display
}

check_lid() {
    local state1 state2
    state1=$(awk '{print $2}' "$LID_STATE" 2>/dev/null)
    sleep 0.3
    state2=$(awk '{print $2}' "$LID_STATE" 2>/dev/null)
    [[ "$state1" == "$state2" ]] && echo "$state1"
}

# ---------- MAIN LOOP ----------
[[ $EUID -ne 0 ]] && { log "ERROR: Must run as root"; exit 1; }

PREV_STATE="open"
trap 'log "Exiting"; rm -f "${STATE_FILE}" "${STATE_FILE}.tmp"; exit 0' EXIT TERM INT

while true; do
    [[ ! -f "$LID_STATE" ]] && sleep 5 && continue
    STATE=$(check_lid)
    if [[ "$STATE" == "closed" && "$PREV_STATE" == "open" ]]; then lid_close; PREV_STATE="closed"
    elif [[ "$STATE" == "open" && "$PREV_STATE" == "closed" ]]; then lid_open; PREV_STATE="open"; fi
    sleep 4
done
