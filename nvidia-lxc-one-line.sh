#!/bin/bash
# NVIDIA GPU Passthrough for Proxmox LXC Containers
# One-Line Helper Script v2.1 (refined menu & config handling, fixed GPU block)
# Author: Rafael Muniz
# GitHub:  https://github.com/rafaelfmuniz/proxmox-nvidia-lxc

###############################################################################
# Global settings & colors
###############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_VERSION="2.1"
SCRIPT_URL="https://github.com/rafaelfmuniz/proxmox-nvidia-lxc"
LOGFILE="/var/log/proxmox-nvidia-lxc.log"

VERBOSE=0

HOST_GPU_SUMMARY=""
LEGACY_RUN_FLAG=0

LIB_NVIDIA_ML_SRC=""
LIB_CUDA_SRC=""

SELECTED_CTID=""
SELECTED_CTNAME=""
SELECTED_CTSTATUS=""

###############################################################################
# Utility helpers
###############################################################################

log() {
  # Simple colored log on host shell (kept, you liked the [INFO]/[OK] style)
  local level="$1"
  local msg="$2"
  local ts
  ts=$(date '+%H:%M:%S')
  case "$level" in
    ERROR)   echo -e "${RED}[$ts] [ERROR] $msg${NC}" ;;
    WARN)    echo -e "${YELLOW}[$ts] [WARN]  $msg${NC}" ;;
    OK)      echo -e "${GREEN}[$ts] [OK]    $msg${NC}" ;;
    INFO|*)  echo -e "${BLUE}[$ts] [INFO]  $msg${NC}" ;;
  esac
}

run_cmd() {
  # Wrapper to respect VERBOSE and log everything
  # Usage: run_cmd "command arg1 arg2"
  local cmd="$1"

  if [[ "$VERBOSE" -eq 1 ]]; then
    echo -e "${YELLOW}+ $cmd${NC}"
    eval "$cmd"
  else
    eval "$cmd" >>"$LOGFILE" 2>&1
  fi
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}❌ This script must be run as root.${NC}"
    exit 1
  fi
}

require_proxmox() {
  if [[ ! -f /etc/pve/.version ]]; then
    echo -e "${RED}❌ This script must be run on a Proxmox VE host.${NC}"
    exit 1
  fi
}

ensure_whiptail() {
  if ! command -v whiptail >/dev/null 2>&1; then
    log INFO "whiptail not found. Installing..."
    run_cmd "apt-get update"
    run_cmd "apt-get install -y whiptail"
  fi
}

show_banner() {
  clear
  echo -e "${BLUE}"
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║  NVIDIA GPU Passthrough for Proxmox LXC Containers       ║"
  echo "║  One-Line Helper Script v${SCRIPT_VERSION}               ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "Project: ${YELLOW}${SCRIPT_URL}${NC}"
  echo
}

ask_verbose_mode() {
  if whiptail --title "Output mode" \
      --yesno "Do you want to enable VERBOSE mode?\n\nYES  = show commands and logs in the shell.\nNO   = keep shell cleaner and log details to:\n       ${LOGFILE}" 15 70; then
    VERBOSE=1
    log INFO "Verbose mode ENABLED."
  else
    VERBOSE=0
    log INFO "Verbose mode DISABLED. Detailed output in $LOGFILE"
  fi
}

###############################################################################
# Host NVIDIA inspection
###############################################################################

detect_legacy_run() {
  LEGACY_RUN_FLAG=0
  if [[ -x /usr/bin/nvidia-uninstall ]] || \
     [[ -f /var/log/nvidia-installer.log ]] || \
     [[ -d /usr/local/nvidia ]]; then
    LEGACY_RUN_FLAG=1
  fi
}

detect_nvidia_libraries() {
  # Try to locate libnvidia-ml.so.1 and libcuda.so.1 via ldconfig
  LIB_NVIDIA_ML_SRC=""
  LIB_CUDA_SRC=""

  if command -v ldconfig >/dev/null 2>&1; then
    local path

    path=$(ldconfig -p 2>/dev/null | awk '/libnvidia-ml\.so\.1/ {print $NF; exit}')
    if [[ -n "$path" ]]; then
      LIB_NVIDIA_ML_SRC=$(readlink -f "$path" 2>/dev/null || echo "$path")
    fi

    path=$(ldconfig -p 2>/dev/null | awk '/libcuda\.so\.1/ {print $NF; exit}')
    if [[ -n "$path" ]]; then
      LIB_CUDA_SRC=$(readlink -f "$path" 2>/dev/null || echo "$path")
    fi
  fi

  if [[ -n "$LIB_NVIDIA_ML_SRC" ]]; then
    log OK "Host libnvidia-ml.so.1 found at: $LIB_NVIDIA_ML_SRC"
  else
    log WARN "Host libnvidia-ml.so.1 not found via ldconfig."
  fi

  if [[ -n "$LIB_CUDA_SRC" ]]; then
    log OK "Host libcuda.so.1 found at: $LIB_CUDA_SRC"
  else
    log WARN "Host libcuda.so.1 not found via ldconfig."
  fi
}

scan_host_nvidia() {
  log INFO "Checking NVIDIA status on host..."

  local gpu_line driver modules msg

  gpu_line=$(lspci | grep -i ' VGA ' | grep -i nvidia | head -n1 || true)
  if nvidia-smi >/dev/null 2>&1; then
    driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || echo "unknown")
  else
    driver="(nvidia-smi not working)"
  fi

  modules=$(lsmod | awk '/^nvidia/ {printf "%s(use=%s) ", $1, $3}' || true)

  detect_legacy_run
  detect_nvidia_libraries

  HOST_GPU_SUMMARY="GPU: ${gpu_line:-no NVIDIA GPU detected}
Driver: ${driver}
Kernel modules: ${modules:-none}"

  msg="Host NVIDIA status:

- ${HOST_GPU_SUMMARY}

"

  if [[ "$LEGACY_RUN_FLAG" -eq 1 ]]; then
    msg+="⚠ Possible legacy NVIDIA .run installer leftovers detected.

Detected one or more of:
- /usr/bin/nvidia-uninstall
- /var/log/nvidia-installer.log
- /usr/local/nvidia

This script WILL NOT automatically run 'nvidia-uninstall'.
If you really installed drivers using the .run file in the past,
run 'nvidia-uninstall' manually on the host and reboot afterwards."
  else
    msg+="No legacy NVIDIA .run installer files detected on the host."
  fi

  whiptail --title "Host NVIDIA status" --msgbox "$msg" 20 78
}

###############################################################################
# LXC container selection & info
###############################################################################

update_selected_container_status() {
  if [[ -z "$SELECTED_CTID" ]]; then
    SELECTED_CTSTATUS=""
    SELECTED_CTNAME=""
    return
  fi

  local line
  line=$(pct list 2>/dev/null | awk -v id="$SELECTED_CTID" 'NR>1 && $1==id {print}')
  if [[ -z "$line" ]]; then
    SELECTED_CTSTATUS="unknown"
    SELECTED_CTNAME=""
    return
  fi

  SELECTED_CTSTATUS=$(echo "$line" | awk '{print $2}')
  SELECTED_CTNAME=$(echo "$line" | awk '{print $3}')
}

select_container_dialog() {
  local list
  list=$(pct list 2>/dev/null | awk 'NR>1 {print}')
  if [[ -z "$list" ]]; then
    whiptail --title "Select LXC container" --msgbox "No LXC containers found on this Proxmox host." 10 60
    return 1
  fi

  local options=()
  while read -r line; do
    local id status name desc
    id=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $2}')
    name=$(echo "$line" | awk '{print $3}')
    [[ -z "$name" ]] && name="(no-name)"
    desc="${id} (${name}) - ${status}"
    options+=("$id" "$desc" "OFF")
  done <<< "$list"

  local choice
  choice=$(whiptail --title "Select LXC container" \
    --radiolist "Choose the LXC container that will receive NVIDIA GPU passthrough.

Host:
  $HOST_GPU_SUMMARY

Use ARROWS to move, SPACE to select, ENTER to confirm." \
    20 80 10 \
    "${options[@]}" \
    3>&1 1>&2 2>&3)

  if [[ $? -ne 0 || -z "$choice" ]]; then
    return 1
  fi

  SELECTED_CTID="$choice"
  update_selected_container_status

  if [[ "$SELECTED_CTSTATUS" != "running" ]]; then
    if whiptail --title "Start container" --yesno "Container $SELECTED_CTID ($SELECTED_CTNAME) is not running.\n\nStart it now?" 10 60; then
      run_cmd "pct start $SELECTED_CTID"
      sleep 2
      update_selected_container_status
    fi
  fi

  return 0
}

require_selected_container() {
  if [[ -z "$SELECTED_CTID" ]]; then
    whiptail --title "No container selected" \
      --msgbox "You must select a target LXC container first." 10 60
    if ! select_container_dialog; then
      return 1
    fi
  fi
  return 0
}

###############################################################################
# LXC config manipulation (main section only, no comments, no duplicates)
###############################################################################

update_lxc_config_gpu_block() {
  local ctid="$1"
  local conf="/etc/pve/lxc/${ctid}.conf"

  if [[ ! -f "$conf" ]]; then
    log ERROR "LXC config not found: $conf"
    whiptail --title "Error" --msgbox "LXC config not found:\n$conf" 10 60
    return 1
  fi

  # Backup for safety
  cp "$conf" "${conf}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true

  # Detect end of main section (before first [snapshot] header)
  local first_section main_end total
  first_section=$(grep -n '^\[' "$conf" | head -n1 | cut -d: -f1 || true)
  total=$(wc -l < "$conf")

  if [[ -n "$first_section" ]]; then
    main_end=$(( first_section - 1 ))
  else
    main_end="$total"
  fi

  local tmp_main tmp_tail tmp_clean
  tmp_main=$(mktemp)
  tmp_tail=$(mktemp)
  tmp_clean=$(mktemp)

  # Split config
  sed -n "1,${main_end}p" "$conf" > "$tmp_main"
  sed -n "$((main_end+1)),${total}p" "$conf" > "$tmp_tail"

  # Remove any previous NVIDIA-related block or lines in main section
  # 1) Old versions with markers "# PROXMOX-NVIDIA-LXC..." (including %3A bug)
  local tmp_no_markers
  tmp_no_markers=$(mktemp)
  sed '/^# PROXMOX-NVIDIA-LXC: begin$/,/^# PROXMOX-NVIDIA-LXC: end$/d' "$tmp_main" \
    | sed '/^# PROXMOX-NVIDIA-LXC%3A begin$/,/^# PROXMOX-NVIDIA-LXC%3A end$/d' > "$tmp_no_markers"

  # 2) Any leftover direct lines for NVIDIA devices / mounts
  sed \
    -e '/^lxc.cgroup2\.devices\.allow: c 195:/d' \
    -e '/^lxc.cgroup2\.devices\.allow: c 509:/d' \
    -e '/^lxc.cgroup2\.devices\.allow: c 511:/d' \
    -e '/^dev[0-9]\+: \/dev\/nvidia/d' \
    -e '/^lxc\.mount\.entry: .*\/usr\/bin\/nvidia-smi/d' \
    -e '/^lxc\.mount\.entry: .*libnvidia.*\.so/d' \
    -e '/^lxc\.mount\.entry: .*libcuda\.so/d' \
    "$tmp_no_markers" > "$tmp_clean"

  rm -f "$tmp_no_markers"

  {
    # New clean section with our GPU block appended (no comments)
    cat "$tmp_clean"
    echo "lxc.cgroup2.devices.allow: c 195:* rwm"
    echo "lxc.cgroup2.devices.allow: c 509:* rwm"
    echo "lxc.cgroup2.devices.allow: c 511:* rwm"
    echo "dev0: /dev/nvidia0,mode=0666"
    echo "dev1: /dev/nvidiactl,mode=0666"
    echo "dev2: /dev/nvidia-modeset,mode=0666"
    echo "dev3: /dev/nvidia-uvm,mode=0666"
    echo "dev4: /dev/nvidia-uvm-tools,mode=0666"
    if [[ -e /dev/nvidia-caps/nvidia-cap1 ]]; then
      echo "dev5: /dev/nvidia-caps/nvidia-cap1,mode=0666"
    fi
    if [[ -e /dev/nvidia-caps/nvidia-cap2 ]]; then
      echo "dev6: /dev/nvidia-caps/nvidia-cap2,mode=0666"
    fi
    if [[ -n "$LIB_NVIDIA_ML_SRC" ]]; then
      echo "lxc.mount.entry: $LIB_NVIDIA_ML_SRC usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 none bind,ro,create=file 0 0"
    fi
    if [[ -n "$LIB_CUDA_SRC" ]]; then
      echo "lxc.mount.entry: $LIB_CUDA_SRC usr/lib/x86_64-linux-gnu/libcuda.so.1 none bind,ro,create=file 0 0"
    fi
    echo "lxc.mount.entry: /usr/bin/nvidia-smi usr/bin/nvidia-smi none bind,ro,create=file 0 0"
  } > "$tmp_main"

  # Reassemble
  {
    cat "$tmp_main"
    cat "$tmp_tail"
  } > "${conf}.new"

  mv "${conf}.new" "$conf"

  rm -f "$tmp_main" "$tmp_tail" "$tmp_clean"

  log OK "Updated NVIDIA GPU block in $conf"
  return 0
}

###############################################################################
# Container operations
###############################################################################

configure_container_gpu() {
  require_selected_container || return 1

  local msg
  msg="This will configure container $SELECTED_CTID ($SELECTED_CTNAME)
for NVIDIA GPU passthrough (LXC).

Changes:
- Adds /dev/nvidia* devices to the container config
- Adds required cgroup2 rules
- Binds libnvidia-ml.so.1 and libcuda.so.1 from the host (if found)
- Binds /usr/bin/nvidia-smi into the container

Snapshots sections ([...]) will NOT be touched.

Proceed?"
  if ! whiptail --title "Confirm GPU configuration" --yesno "$msg" 18 78; then
    return 0
  fi

  log INFO "Configuring container $SELECTED_CTID for NVIDIA GPU passthrough..."

  # Stop container before editing config
  if [[ "$SELECTED_CTSTATUS" == "running" ]]; then
    log INFO "Stopping container $SELECTED_CTID..."
    run_cmd "pct stop $SELECTED_CTID"
    sleep 2
    update_selected_container_status
  fi

  # Update config
  update_lxc_config_gpu_block "$SELECTED_CTID" || return 1

  # Start container again
  log INFO "Starting container $SELECTED_CTID..."
  run_cmd "pct start $SELECTED_CTID"
  sleep 3
  update_selected_container_status

  # Quick test inside the container
  log INFO "Testing nvidia-smi inside container..."
  local output
  output=$(pct exec "$SELECTED_CTID" -- sh -c 'nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>&1' || true)

  if echo "$output" | grep -qi "NVIDIA"; then
    whiptail --title "GPU test inside container" --msgbox "nvidia-smi ran successfully inside container $SELECTED_CTID.

Output:
$output" 20 78
    log OK "nvidia-smi inside container looks OK."
  else
    whiptail --title "GPU test inside container" --msgbox "nvidia-smi did NOT run successfully inside container $SELECTED_CTID.

Output:
$output

Check logs and library mounts." 20 78
    log WARN "nvidia-smi inside container did not run successfully."
  fi
}

diagnose_container() {
  require_selected_container || return 1

  update_selected_container_status

  local cfg osinfo nvsmi msg

  cfg=$(pct config "$SELECTED_CTID" 2>&1 | \
        sed -n '/^lxc.cgroup2.devices.allow:/p;/^dev[0-9]: \/dev\/nvidia/p;/^lxc.mount.entry: .*nvidia/p' | \
        sed 's/^/  /' || true)

  osinfo=$(pct exec "$SELECTED_CTID" -- sh -c '
    if command -v lsb_release >/dev/null 2>&1; then
      lsb_release -ds
    elif [ -r /etc/os-release ]; then
      . /etc/os-release
      echo "$PRETTY_NAME"
    else
      echo "Unknown OS"
    fi
  ' 2>/dev/null | head -n1 || echo "Unknown OS")

  nvsmi=$(pct exec "$SELECTED_CTID" -- sh -c '
    if command -v nvidia-smi >/dev/null 2>&1; then
      nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null || nvidia-smi 2>/dev/null
    else
      echo "nvidia-smi not found in container."
    fi
  ' 2>/dev/null | sed 's/^/  /' || true)

  [[ -z "$cfg" ]] && cfg="  (no NVIDIA-related LXC entries found)"
  [[ -z "$nvsmi" ]] && nvsmi="  (no output)"

  msg="Container: $SELECTED_CTID ($SELECTED_CTNAME)
Status:   ${SELECTED_CTSTATUS:-unknown}

OS inside container:
  $osinfo

NVIDIA-related LXC config (host):
$cfg

nvidia-smi inside container:
$nvsmi"

  whiptail --title "Diagnose container" --scrolltext --msgbox "$msg" 22 80
}

install_nvidia_host_drivers() {
  # Install/update NVIDIA drivers on host using apt
  local msg
  msg="This will install or update NVIDIA drivers on the HOST using apt.

It will:
- Update package lists
- Ensure non-free repo is enabled (Debian-like)
- Install 'nvidia-driver' and firmware-misc-nonfree (or fallback packages)

A host reboot may be required afterwards.

Proceed?"
  if ! whiptail --title "Install NVIDIA drivers on host" --yesno "$msg" 18 78; then
    return 0
  fi

  log INFO "Updating package list on host..."
  run_cmd "apt-get update"

  log INFO "Ensuring 'non-free' is present in /etc/apt/sources.list (Debian/Proxmox)..."
  if ! grep -q "non-free" /etc/apt/sources.list 2>/dev/null; then
    run_cmd "sed -i 's/main$/main non-free/' /etc/apt/sources.list"
  fi
  run_cmd "apt-get update"

  log INFO "Installing nvidia-driver via apt..."
  if run_cmd "apt-get install -y nvidia-driver firmware-misc-nonfree"; then
    whiptail --title "Host driver installation" --msgbox "NVIDIA drivers installed successfully via apt.

A reboot of the HOST is recommended." 15 70
    log OK "NVIDIA drivers installed successfully via apt."
  else
    log WARN "Failed to install 'nvidia-driver'. Trying fallback packages..."
    if run_cmd "apt-get install -y nvidia-kernel-dkms nvidia-smi nvidia-settings"; then
      whiptail --title "Host driver installation" --msgbox "NVIDIA packages installed using fallback method.

A reboot of the HOST is recommended." 15 70
      log OK "NVIDIA packages installed via fallback."
    else
      whiptail --title "Host driver installation" --msgbox "Failed to install NVIDIA drivers via apt.

Check $LOGFILE for details." 15 70
      log ERROR "Failed to install NVIDIA drivers on host."
    fi
  fi
}

docker_gpu_helper() {
  require_selected_container || return 1

  # Check Docker inside container
  if ! pct exec "$SELECTED_CTID" -- sh -c 'command -v docker >/dev/null 2>&1' 2>/dev/null; then
    whiptail --title "Docker GPU helper" \
      --msgbox "Docker binary not found inside container $SELECTED_CTID.

Install Docker inside the container first, then re-run this helper." 15 70
    return 0
  fi

  local choice
  choice=$(whiptail --title "Docker GPU helper" \
    --radiolist "Container $SELECTED_CTID ($SELECTED_CTNAME)

Choose an action for Docker GPU support:

Use ARROWS to move, SPACE to select, ENTER to confirm." \
    18 78 5 \
    "1" "Install nvidia-container-toolkit (Debian/Ubuntu only)" OFF \
    "2" "Test GPU: docker run --gpus all nvidia/cuda:base nvidia-smi" OFF \
    "3" "Back to main menu" ON \
    3>&1 1>&2 2>&3)

  [[ $? -ne 0 || -z "$choice" ]] && return 0

  case "$choice" in
    1)
      whiptail --title "Install nvidia-container-toolkit" --msgbox \
"Will run inside container:

  apt-get update
  apt-get install -y nvidia-container-toolkit

Then we recommend configuring Docker's default runtime manually.

This is experimental and assumes a Debian/Ubuntu-based container." 18 78
      log INFO "Installing nvidia-container-toolkit inside container $SELECTED_CTID..."
      run_cmd "pct exec $SELECTED_CTID -- sh -c 'apt-get update && apt-get install -y nvidia-container-toolkit'"
      whiptail --title "nvidia-container-toolkit" --msgbox \
"nvidia-container-toolkit installation command has finished.

Review Docker configuration inside the container and restart Docker:

  systemctl restart docker

Then you can test GPU with option 2." 18 78
      ;;
    2)
      whiptail --title "Docker GPU test" --msgbox \
"This will run:

  docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu24.04 nvidia-smi

inside container $SELECTED_CTID.

It may download a large image on first run." 18 78
      log INFO "Running docker GPU test in container $SELECTED_CTID..."
      local out
      out=$(pct exec "$SELECTED_CTID" -- sh -c 'docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu24.04 nvidia-smi 2>&1' || true)
      whiptail --title "Docker GPU test output" --scrolltext --msgbox "$out" 20 78
      ;;
    *)
      ;;
  esac
}

nvtop_helper() {
  require_selected_container || return 1

  local msg
  msg="This will install 'nvtop' inside container $SELECTED_CTID ($SELECTED_CTNAME).

Command:
  apt-get update
  apt-get install -y nvtop

Proceed?"
  if ! whiptail --title "nvtop helper" --yesno "$msg" 15 70; then
    return 0
  fi

  log INFO "Installing nvtop inside container $SELECTED_CTID..."
  run_cmd "pct exec $SELECTED_CTID -- sh -c 'apt-get update && apt-get install -y nvtop'"

  whiptail --title "nvtop helper" --msgbox \
"'nvtop' installation command finished inside the container.

You can run:

  pct exec $SELECTED_CTID -- nvtop

to watch GPU usage from the host shell." 18 70
}

###############################################################################
# Main dialog loop
###############################################################################

main_menu_loop() {
  while true; do
    update_selected_container_status

    local ct_line
    if [[ -n "$SELECTED_CTID" ]]; then
      ct_line="Container: $SELECTED_CTID (${SELECTED_CTNAME:-unknown}) - ${SELECTED_CTSTATUS:-unknown}"
    else
      ct_line="Container: (none selected)"
    fi

    local vmode
    if [[ "$VERBOSE" -eq 1 ]]; then
      vmode="Verbose: ON"
    else
      vmode="Verbose: OFF"
    fi

    local choice
    choice=$(whiptail --title "NVIDIA LXC Helper" \
      --radiolist "Host:  ${HOST_GPU_SUMMARY}
$ct_line
$vmode

Select an action:
(Use ARROWS to move, SPACE to select, ENTER to confirm)" \
      20 80 8 \
      "1" "Configure container for NVIDIA GPU passthrough" OFF \
      "2" "Diagnose container (LXC config + nvidia-smi)" OFF \
      "3" "Check / install NVIDIA drivers on host" OFF \
      "4" "Docker GPU helper (inside container)" OFF \
      "5" "nvtop helper (inside container)" OFF \
      "6" "Change selected container" OFF \
      "7" "Toggle verbose mode" OFF \
      "8" "Exit" OFF \
      3>&1 1>&2 2>&3)

    if [[ $? -ne 0 || -z "$choice" ]]; then
      # User pressed Cancel or Esc -> Exit
      break
    fi

    case "$choice" in
      1) configure_container_gpu ;;
      2) diagnose_container ;;
      3) install_nvidia_host_drivers ;;
      4) docker_gpu_helper ;;
      5) nvtop_helper ;;
      6) select_container_dialog ;;
      7)
        if [[ "$VERBOSE" -eq 1 ]]; then
          VERBOSE=0
          log INFO "Verbose mode DISABLED."
        else
          VERBOSE=1
          log INFO "Verbose mode ENABLED."
        fi
        ;;
      8) break ;;
      *) ;;
    esac
  done
}

###############################################################################
# Entry point
###############################################################################

main() {
  require_root
  require_proxmox
  touch "$LOGFILE" 2>/dev/null || true

  show_banner
  ensure_whiptail
  ask_verbose_mode
  scan_host_nvidia

  # Force user to pick a container before main menu
  if ! select_container_dialog; then
    whiptail --title "No container selected" --msgbox "No container selected. Exiting." 10 60
    exit 0
  fi

  main_menu_loop

  echo
  log OK "Exiting NVIDIA LXC helper script."
  echo
}

main "$@"
