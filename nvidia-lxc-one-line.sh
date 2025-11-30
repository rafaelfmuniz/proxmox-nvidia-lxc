#!/bin/bash
# NVIDIA GPU Passthrough for LXC Proxmox - One Line Install
# Version: 2.2 - Docker Stack with GPU Support (PVE 9 fix)
# Author: Rafael Muniz
# GitHub: https://github.com/rafaelfmuniz/proxmox-nvidia-lxc

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script information
SCRIPT_VERSION="2.2"
SCRIPT_URL="https://github.com/rafaelfmuniz/proxmox-nvidia-lxc"

# ==========================
#  BASE UTIL FUNCTIONS
# ==========================

# Display welcome message
show_welcome() {
  echo -e "${BLUE}"
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║           NVIDIA GPU Passthrough for LXC Proxmox         ║"
  echo "║     Version ${SCRIPT_VERSION} - Docker Stack with GPU Support     ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "${YELLOW}GitHub: $SCRIPT_URL${NC}"
  echo
}

# Check if running as root
check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}❌ This script must be run as root${NC}"
    exit 1
  fi
}

# Check if running in Proxmox
check_proxmox() {
  if [[ ! -f /etc/pve/.version ]]; then
    echo -e "${RED}❌ This script must be run on a Proxmox VE system${NC}"
    exit 1
  fi
}

# Enhanced log function
log() {
  local level=$1
  local message=$2
  local timestamp
  timestamp=$(date '+%H:%M:%S')

  case $level in
    "ERROR")   echo -e "${RED}[$timestamp] $level: $message${NC}" ;;
    "INFO")    echo -e "${BLUE}[$timestamp] $level: $message${NC}" ;;
    "SUCCESS") echo -e "${GREEN}[$timestamp] $level: $message${NC}" ;;
    "WARNING") echo -e "${YELLOW}[$timestamp] $level: $message${NC}" ;;
  esac
}

# ==========================
#  HOST NVIDIA DRIVERS
# ==========================

install_nvidia_host_drivers() {
  log "INFO" "Checking for NVIDIA drivers on the HOST..."

  # Check if nvidia-smi works
  if nvidia-smi &>/dev/null; then
    log "SUCCESS" "NVIDIA drivers are already installed on the host"
    return 0
  fi

  echo -e "${YELLOW}🚗 NVIDIA drivers not found on the host.${NC}"
  echo -e "${YELLOW}The script will install NVIDIA drivers automatically.${NC}"
  read -p "Continue with installation? (y/N): " -r confirm_install
  if [[ ! "$confirm_install" =~ ^[Yy]$ ]]; then
    log "ERROR" "Installation cancelled by user"
    return 1
  fi

  log "INFO" "Starting installation of NVIDIA drivers on the host..."

  # 1. Update system
  log "INFO" "Updating package list..."
  apt-get update

  # 2. Detect NVIDIA GPU
  log "INFO" "Detecting NVIDIA GPU..."
  if lspci | grep -i nvidia &>/dev/null; then
    GPU_INFO=$(lspci | grep -i nvidia | head -1)
    log "INFO" "GPU detected: $GPU_INFO"
  else
    log "WARNING" "No NVIDIA GPU detected via lspci"
  fi

  # 3. Add non-free repository if necessary (DEFENSIVE for PVE 9)
  log "INFO" "Configuring repositories..."
  if [[ -f /etc/apt/sources.list ]]; then
    if ! grep -q "non-free" /etc/apt/sources.list; then
      log "INFO" "Adding non-free to /etc/apt/sources.list..."
      sed -i 's/main$/main non-free/' /etc/apt/sources.list
    fi
  else
    log "WARNING" "/etc/apt/sources.list not found, skipping direct modification (PVE 9 style)."
  fi
  apt-get update

  # 4. Install NVIDIA drivers (SAFE METHOD FOR PROXMOX)
  #
  # IMPORTANTE:
  #  - NÃO usar meta-pacote nvidia-driver em Proxmox, pois ele tenta remover proxmox-ve, kernels pve etc.
  #  - Em vez disso, instala diretamente nvidia-kernel-dkms + nvidia-smi + nvidia-settings.
  #
  log "INFO" "Installing NVIDIA drivers via apt (Proxmox-safe)..."

  if dpkg -l proxmox-ve &>/dev/null; then
    # Estamos em um host Proxmox "normal": usar somente os pacotes necessários
    if apt-get install -y nvidia-kernel-dkms nvidia-smi nvidia-settings; then
      log "SUCCESS" "NVIDIA DKMS + tools installed successfully (Proxmox-safe path)"
    else
      log "ERROR" "Failed to install NVIDIA DKMS packages"
      return 1
    fi
  else
    # Fallback para ambiente não-Proxmox (mantém comportamento antigo)
    if apt-get install -y nvidia-driver firmware-misc-nonfree; then
      log "SUCCESS" "NVIDIA drivers installed successfully (generic Debian path)"
    else
      log "WARNING" "Failed to install nvidia-driver, trying DKMS alternative..."
      if apt-get install -y nvidia-kernel-dkms nvidia-smi nvidia-settings; then
        log "SUCCESS" "NVIDIA packages installed via DKMS alternative"
      else
        log "ERROR" "Failed to install NVIDIA drivers"
        return 1
      fi
    fi
  fi

  # 4.1 Garantir que o DKMS compilou para o kernel atual
  if command -v dkms &>/dev/null; then
    CURRENT_KERNEL="$(uname -r)"
    log "INFO" "Forcing DKMS autoinstall for current kernel: ${CURRENT_KERNEL}"
    if dkms autoinstall -k "${CURRENT_KERNEL}"; then
      log "SUCCESS" "DKMS autoinstall completed for ${CURRENT_KERNEL}"
    else
      log "WARNING" "DKMS autoinstall reported issues (check dkms status manually se necessário)"
    fi
  else
    log "WARNING" "DKMS not found, skipping DKMS autoinstall"
  fi

  # 5. Configure NVIDIA module to load automatically (avoid duplicates)
  log "INFO" "Configuring NVIDIA module to load at boot..."

  if ! grep -q '^nvidia$' /etc/modules 2>/dev/null; then
    echo -e "\n# Load NVIDIA driver\nnvidia" >> /etc/modules
  fi

  if ! grep -q '^nvidia-uvm$' /etc/modules 2>/dev/null; then
    echo -e "\n# Load NVIDIA UVM for CUDA\nnvidia-uvm" >> /etc/modules
  fi

  # 6. Update initramfs for current kernel
  log "INFO" "Updating initramfs..."
  update-initramfs -u

  # 7. Verify installation
  log "INFO" "Verifying installation..."
  if modprobe nvidia && nvidia-smi &>/dev/null; then
    log "SUCCESS" "✅ NVIDIA drivers installed and working!"
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
    log "INFO" "GPU: $GPU_NAME"
    return 0
  else
    log "WARNING" "Drivers installed but may require reboot"
    echo -e "${YELLOW}⚠️  REBOOT REQUIRED ⚠️${NC}"
    echo -e "${YELLOW}NVIDIA drivers have been installed/updated, but a host reboot is likely required.${NC}"
    read -p "Reboot now? (y/N): " -r reboot_now
    if [[ "$reboot_now" =~ ^[Yy]$ ]]; then
      log "INFO" "Rebooting system..."
      reboot
    else
      log "WARNING" "Reboot pending. Please run 'reboot' when possible."
      return 1
    fi
  fi
}

# ==========================
#  LXC / CONTAINER HELPERS
# ==========================

container_exists() { pct list | awk '{print $1}' | grep -qx "$1"; }

container_is_running() {
  [ "$(pct status "$1" | grep -o 'running')" == "running" ]
}

# Check for REAL NVIDIA components in the container
check_nvidia_components_in_container() {
  local CTID=$1
  log "INFO" "Checking for NVIDIA components in CT $CTID..."

  if ! container_is_running "$CTID"; then
    log "WARNING" "Container is not running, cannot check components"
    return 1
  fi

  local has_components=0

  # 1) Driver packages
  if pct exec "$CTID" -- dpkg -l 2>/dev/null | \
     grep -E '^ii.*nvidia-(driver|[0-9]|kernel|dkms|opencl|vdpau|compute)' | grep -q nvidia; then
    log "INFO" " NVIDIA driver packages found in container"
    has_components=1
    return 0
  fi

  # 2) Binaries
  if pct exec "$CTID" -- find /usr/bin /usr/sbin /usr/local/bin -name "nvidia-*" -type f 2>/dev/null | \
     grep -v nvidia-smi | head -1 | grep -q nvidia; then
    log "INFO" " NVIDIA binaries found in container"
    has_components=1
    return 0
  fi

  # 3) Core libraries
  if pct exec "$CTID" -- find /usr/lib -name "libnvidia-*.so.*" -type f 2>/dev/null | \
     grep -v libnvidia-container | head -1 | grep -q nvidia; then
    log "INFO" " NVIDIA core libraries found"
    has_components=1
    return 0
  fi

  # 4) Directories
  if pct exec "$CTID" -- [ -d "/usr/lib/nvidia" ] || \
     pct exec "$CTID" -- [ -d "/usr/lib/x86_64-linux-gnu/nvidia" ]; then
    log "INFO" " NVIDIA driver directories found"
    has_components=1
    return 0
  fi

  # 5) Kernel modules
  if pct exec "$CTID" -- find /lib/modules -name "*nvidia*" -type f 2>/dev/null | \
     head -1 | grep -q nvidia; then
    log "INFO" "⚙️ NVIDIA kernel modules found"
    has_components=1
    return 0
  fi

  # 6) CUDA toolkit
  if pct exec "$CTID" -- [ -d "/usr/local/cuda" ] || pct exec "$CTID" -- which nvcc >/dev/null 2>&1; then
    log "INFO" " CUDA toolkit found"
    has_components=1
    return 0
  fi

  if [ $has_components -eq 1 ]; then
    log "WARNING" "NVIDIA components detected in container"
    return 0
  else
    log "SUCCESS" "No NVIDIA components found in container"
    return 1
  fi
}

# Clean NVIDIA components from container (AUTOMATIC)
clean_existing_nvidia_components() {
  local CTID=$1
  local container_name
  container_name=$(pct config "$CTID" | grep -oP 'hostname: \K.*' || echo "N/A")

  log "INFO" "Checking for NVIDIA components in CT $CTID: $container_name"

  if ! check_nvidia_components_in_container "$CTID"; then
    log "SUCCESS" "✅ Container clean - no NVIDIA components found"
    return 0
  fi

  log "INFO" "Automatically removing NVIDIA components from container..."

  if container_is_running "$CTID"; then
    log "INFO" "Stopping container $CTID..."
    pct stop "$CTID"
    sleep 3
  fi

  log "INFO" "Starting container for cleanup..."
  if ! pct start "$CTID"; then
    log "ERROR" "Could not start container for cleanup"
    return 1
  fi
  sleep 5

  # Stop NVIDIA services
  log "INFO" "Stopping NVIDIA services..."
  pct exec "$CTID" -- systemctl stop nvidia-persistenced 2>/dev/null || true
  pct exec "$CTID" -- systemctl disable nvidia-persistenced 2>/dev/null || true
  pct exec "$CTID" -- pkill -f nvidia 2>/dev/null || true

  # Remove NVIDIA packages
  log "INFO" "Removing NVIDIA packages..."
  pct exec "$CTID" -- dpkg -l 2>/dev/null | grep nvidia | awk '{print $2}' \
    > "/tmp/nvidia_packages_${CTID}.txt" 2>/dev/null
  if [ -s "/tmp/nvidia_packages_${CTID}.txt" ]; then
    log "INFO" "NVIDIA packages found:"
    cat "/tmp/nvidia_packages_${CTID}.txt"
    pct exec "$CTID" -- apt-get remove --purge -y $(cat "/tmp/nvidia_packages_${CTID}.txt") 2>/dev/null
    log "SUCCESS" "NVIDIA packages removed"
  else
    log "INFO" "No NVIDIA packages found via dpkg"
  fi

  # Remove CUDA packages
  log "INFO" "Removing CUDA packages..."
  pct exec "$CTID" -- dpkg -l 2>/dev/null | grep cuda | awk '{print $2}' \
    > "/tmp/cuda_packages_${CTID}.txt" 2>/dev/null
  if [ -s "/tmp/cuda_packages_${CTID}.txt" ]; then
    log "INFO" "CUDA packages found:"
    cat "/tmp/cuda_packages_${CTID}.txt"
    pct exec "$CTID" -- apt-get remove --purge -y $(cat "/tmp/cuda_packages_${CTID}.txt") 2>/dev/null
    log "SUCCESS" "CUDA packages removed"
  fi

  # Clean NVIDIA repos
  log "INFO" "Cleaning NVIDIA repositories..."
  pct exec "$CTID" -- rm -f /etc/apt/sources.list.d/cuda*.list 2>/dev/null || true
  pct exec "$CTID" -- rm -f /etc/apt/sources.list.d/nvidia*.list 2>/dev/null || true

  # Remove NVIDIA files
  log "INFO" "Removing NVIDIA files and libraries..."
  pct exec "$CTID" -- find /usr -name "*nvidia*" -exec rm -rf {} + 2>/dev/null || true
  pct exec "$CTID" -- find /usr -name "*cuda*"   -exec rm -rf {} + 2>/dev/null || true
  pct exec "$CTID" -- find /opt -name "*nvidia*" -exec rm -rf {} + 2>/dev/null || true
  pct exec "$CTID" -- find /opt -name "*cuda*"   -exec rm -rf {} + 2>/dev/null || true

  pct exec "$CTID" -- rm -rf /usr/local/cuda* 2>/dev/null || true
  pct exec "$CTID" -- rm -rf /opt/nvidia 2>/dev/null || true
  pct exec "$CTID" -- rm -rf /usr/lib/x86_64-linux-gnu/nvidia 2>/dev/null || true
  pct exec "$CTID" -- rm -rf /usr/lib/nvidia 2>/dev/null || true
  pct exec "$CTID" -- rm -rf /usr/share/nvidia 2>/dev/null || true
  pct exec "$CTID" -- rm -rf /usr/lib/firmware/nvidia 2>/dev/null || true

  pct exec "$CTID" -- rm -f /usr/bin/nvidia-smi 2>/dev/null || true
  pct exec "$CTID" -- rm -f /usr/bin/nvidia-*  2>/dev/null || true

  # Clean deps
  log "INFO" "Cleaning unused dependencies..."
  pct exec "$CTID" -- apt-get autoremove -y 2>/dev/null
  pct exec "$CTID" -- apt-get clean 2>/dev/null

  # Final verification
  log "INFO" "Verifying all components have been removed..."
  local remaining_count
  remaining_count=$(pct exec "$CTID" -- find /usr /opt -name "*nvidia*" 2>/dev/null | wc -l)

  if [ "$remaining_count" -gt 0 ]; then
    log "WARNING" "There are still $remaining_count NVIDIA files/directories:"
    pct exec "$CTID" -- find /usr /opt -name "*nvidia*" 2>/dev/null
  else
    log "SUCCESS" "✅ All NVIDIA components removed!"
  fi

  rm -f "/tmp/nvidia_packages_${CTID}.txt" "/tmp/cuda_packages_${CTID}.txt" 2>/dev/null || true

  pct stop "$CTID"
  sleep 2
  log "SUCCESS" "NVIDIA components cleanup completed"
}

# ==========================
#  HOST DEVICE & LIB MAPPING
# ==========================

check_host_nvidia_devices() {
  log "INFO" "Checking for NVIDIA devices on HOST..."
  local devices=()

  [ -e /dev/nvidia0 ]         && devices+=("nvidia0")
  [ -e /dev/nvidiactl ]       && devices+=("nvidiactl")
  [ -e /dev/nvidia-modeset ]  && devices+=("nvidia-modeset")
  [ -e /dev/nvidia-uvm ]      && devices+=("nvidia-uvm")
  [ -e /dev/nvidia-uvm-tools ]&& devices+=("nvidia-uvm-tools")

  if [ -d /dev/nvidia-caps ]; then
    devices+=("nvidia-caps")
    [ -e /dev/nvidia-caps/nvidia-cap1 ] && devices+=("nvidia-cap1")
    [ -e /dev/nvidia-caps/nvidia-cap2 ] && devices+=("nvidia-cap2")
  fi

  if [ ${#devices[@]} -eq 0 ]; then
    log "ERROR" "No NVIDIA devices found on HOST!"
    return 1
  else
    log "SUCCESS" "NVIDIA devices on host: ${devices[*]}"
    return 0
  fi
}

find_and_map_nvidia_libraries() {
  local CTID=$1
  log "INFO" "Mapping required NVIDIA libraries..."

  local needed_libs=("libnvidia-ml.so.1" "libcuda.so.1")

  for lib in "${needed_libs[@]}"; do
    local lib_path
    lib_path=$(find /usr/lib -name "$lib" 2>/dev/null | head -1)

    if [ -n "$lib_path" ]; then
      if [ -L "$lib_path" ]; then
        local real_path
        real_path=$(readlink -f "$lib_path")
        if [ -f "$real_path" ]; then
          echo "lxc.mount.entry: $real_path usr/lib/x86_64-linux-gnu/$lib none bind,ro,create=file 0 0" \
            >> "/etc/pve/lxc/${CTID}.conf"
          log "SUCCESS" "Mapped library: $lib (via link: $(basename "$real_path"))"
        else
          log "WARNING" "Broken link: $lib_path -> $real_path"
        fi
      else
        echo "lxc.mount.entry: $lib_path usr/lib/x86_64-linux-gnu/$lib none bind,ro,create=file 0 0" \
          >> "/etc/pve/lxc/${CTID}.conf"
        log "SUCCESS" "Mapped library: $lib"
      fi
    else
      log "WARNING" "Library not found: $lib"
    fi
  done
}

# ==========================
#  LXC GPU CONFIGURATION
# ==========================

configure_single_container_correct() {
  local CTID=$1
  local container_name
  container_name=$(pct config "$CTID" | grep -oP 'hostname: \K.*' || echo "N/A")

  log "INFO" "Configuration for CT $CTID: $container_name"

  if ! check_host_nvidia_devices; then
    log "ERROR" "NVIDIA devices not available on host"
    return 1
  fi

  if check_nvidia_components_in_container "$CTID"; then
    log "INFO" "NVIDIA components found, cleaning..."
    clean_existing_nvidia_components "$CTID"
  else
    log "INFO" "No NVIDIA components found, skipping cleanup"
  fi

  log "INFO" "Cleaning previous container configurations..."
  cp "/etc/pve/lxc/${CTID}.conf" "/etc/pve/lxc/${CTID}.conf.backup.$(date +%Y%m%d_%H%M%S)"

  # Remove previous NVIDIA lines
  grep -v -E "^(lxc.cgroup2.devices.allow:|dev[0-9]+: /dev/nvidia|lxc.mount.entry: /usr/(bin/nvidia-smi|lib/x86_64-linux-gnu/.*nvidia|lib/x86_64-linux-gnu/.*cuda)|# Nvidia GPU passthrough)" \
    "/etc/pve/lxc/${CTID}.conf" > "/etc/pve/lxc/${CTID}.conf.tmp"
  mv "/etc/pve/lxc/${CTID}.conf.tmp" "/etc/pve/lxc/${CTID}.conf"

  log "INFO" "Applying NVIDIA configuration..."
  {
    echo "# Nvidia GPU passthrough"
    echo "lxc.cgroup2.devices.allow: c 195:* rwm"
    echo "lxc.cgroup2.devices.allow: c 509:* rwm"
    echo "lxc.cgroup2.devices.allow: c 511:* rwm"
    echo "dev0: /dev/nvidia0,mode=0666"
    echo "dev1: /dev/nvidiactl,mode=0666"
    echo "dev2: /dev/nvidia-modeset,mode=0666"
    echo "dev3: /dev/nvidia-uvm,mode=0666"
    echo "dev4: /dev/nvidia-uvm-tools,mode=0666"
    if [ -e /dev/nvidia-caps/nvidia-cap1 ]; then
      echo "dev5: /dev/nvidia-caps/nvidia-cap1,mode=0666"
    fi
    if [ -e /dev/nvidia-caps/nvidia-cap2 ]; then
      echo "dev6: /dev/nvidia-caps/nvidia-cap2,mode=0666"
    fi
    echo "lxc.mount.entry: /usr/bin/nvidia-smi usr/bin/nvidia-smi none bind,ro,create=file 0 0"
  } >> "/etc/pve/lxc/${CTID}.conf"

  find_and_map_nvidia_libraries "$CTID"

  log "SUCCESS" "Configuration applied"
  log "INFO" "Configuration content:"
  grep -E "^(lxc.cgroup2.devices.allow:|dev[0-9]+: /dev/nvidia|lxc.mount.entry)" "/etc/pve/lxc/${CTID}.conf"

  log "INFO" "Restarting container to apply changes..."
  if container_is_running "$CTID"; then
    log "INFO" "Container is running, stopping..."
    pct stop "$CTID"
    sleep 2
  fi

  log "INFO" "Starting container..."
  if pct start "$CTID"; then
    log "SUCCESS" "Container started successfully"
    sleep 5

    log "INFO" "Testing NVIDIA devices in container..."
    if pct exec "$CTID" -- ls /dev/nvidia0 >/dev/null 2>&1; then
      log "SUCCESS" "✅ Device /dev/nvidia0 detected in container"
    else
      log "ERROR" "❌ /dev/nvidia0 NOT detected in container"
      return 1
    fi

    log "INFO" "Testing nvidia-smi (complete test)..."
    if pct exec "$CTID" -- timeout 10s nvidia-smi >/dev/null 2>&1; then
      log "SUCCESS" "✅ nvidia-smi works COMPLETELY!"
      echo -e "${GREEN} COMPLETE CONFIGURATION WORKING!${NC}"
      return 0
    else
      log "WARNING" "nvidia-smi doesn't work completely (maybe missing libnvidia-ml1)"
      log "INFO" "Installing libnvidia-ml1 in container..."
      if pct exec "$CTID" -- apt-get update && \
         pct exec "$CTID" -- apt-get install -y libnvidia-ml1; then
        log "SUCCESS" "libnvidia-ml1 installed"
        if pct exec "$CTID" -- timeout 10s nvidia-smi >/dev/null 2>&1; then
          log "SUCCESS" "✅ nvidia-smi NOW WORKS COMPLETELY!"
          return 0
        else
          log "ERROR" "Still not working after library installation"
        fi
      else
        log "ERROR" "Failed to install libnvidia-ml1"
      fi
      return 1
    fi
  else
    log "ERROR" "Failed to start container"
    return 1
  fi
}

# ==========================
#  DIAG / CLEAN / TEST / NVTOP / DOCKER
# ==========================

diagnose_container() {
  local CTID=$1
  local container_name
  container_name=$(pct config "$CTID" | grep -oP 'hostname: \K.*' || echo "N/A")

  echo
  echo -e "${BLUE}=== COMPLETE DIAGNOSIS CT $CTID: $container_name ===${NC}"

  echo -e "\n${YELLOW}1. CONTAINER STATUS:${NC}"
  pct status "$CTID"

  echo -e "\n${YELLOW}2. NVIDIA CONFIGURATION IN CONTAINER:${NC}"
  grep -E "^(lxc.cgroup2.devices.allow:|dev[0-9]+: /dev/nvidia|lxc.mount.entry)" \
    "/etc/pve/lxc/${CTID}.conf" 2>/dev/null || echo "No NVIDIA configuration found"

  echo -e "\n${YELLOW}3. NVIDIA DEVICES ON HOST:${NC}"
  ls -la /dev/nvidia* 2>/dev/null || echo "No NVIDIA devices on host"

  if container_is_running "$CTID"; then
    echo -e "\n${YELLOW}4. DEVICES INSIDE CONTAINER:${NC}"
    pct exec "$CTID" -- ls -la /dev/nvidia* 2>/dev/null || echo "No NVIDIA devices in container"

    echo -e "\n${YELLOW}5. NVIDIA-SMI IN CONTAINER:${NC}"
    if pct exec "$CTID" -- which nvidia-smi >/dev/null 2>&1; then
      echo "Testing nvidia-smi:"
      if pct exec "$CTID" -- timeout 10s \
         nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null; then
        echo -e "${GREEN}✅ nvidia-smi WORKS${NC}"
      else
        echo -e "${RED}❌ nvidia-smi DOES NOT work completely${NC}"
      fi
    else
      echo "nvidia-smi not found"
    fi

    echo -e "\n${YELLOW}6. NVIDIA LIBRARIES IN CONTAINER:${NC}"
    pct exec "$CTID" -- find /usr -name "*nvidia*" 2>/dev/null | head -10 || echo "No NVIDIA libraries found"

    echo -e "\n${YELLOW}7. NVIDIA COMPONENTS:${NC}"
    check_nvidia_components_in_container "$CTID"
  else
    echo -e "\n${YELLOW}4. CONTAINER STOPPED - cannot check internally${NC}"
  fi
}

clean_single_container() {
  local CTID=$1
  local container_name
  container_name=$(pct config "$CTID" | grep -oP 'hostname: \K.*' || echo "N/A")

  log "INFO" "Cleaning NVIDIA configurations from CT $CTID: $container_name"

  if container_is_running "$CTID"; then
    log "INFO" "Stopping container $CTID..."
    pct stop "$CTID"
    sleep 2
  fi

  log "INFO" "Removing NVIDIA configurations..."
  cp "/etc/pve/lxc/${CTID}.conf" "/etc/pve/lxc/${CTID}.conf.backup.$(date +%Y%m%d_%H%M%S)"

  grep -v -E "^(lxc.cgroup2.devices.allow: c (195|509|511):|dev[0-9]+: /dev/nvidia|lxc.mount.entry: /usr/(bin/nvidia-smi|lib/x86_64-linux-gnu/.*nvidia|lib/x86_64-linux-gnu/.*cuda)|# Nvidia GPU passthrough)" \
    "/etc/pve/lxc/${CTID}.conf" > "/etc/pve/lxc/${CTID}.conf.tmp"
  mv "/etc/pve/lxc/${CTID}.conf.tmp" "/etc/pve/lxc/${CTID}.conf"

  sed -i '/Nvidia GPU passthrough/d' "/etc/pve/lxc/${CTID}.conf"
  sed -i '/NVIDIA GPU Configuration/d' "/etc/pve/lxc/${CTID}.conf"

  log "SUCCESS" "NVIDIA configurations removed from CT $CTID"

  log "INFO" "Starting container $CTID..."
  if pct start "$CTID"; then
    log "SUCCESS" "Container $CTID started successfully"
  else
    log "ERROR" "Failed to start container $CTID"
    return 1
  fi
}

test_single_container() {
  local CTID=$1
  local container_name
  container_name=$(pct config "$CTID" | grep -oP 'hostname: \K.*' || echo "N/A")

  echo
  echo -e "${YELLOW}--- Testing CT $CTID: $container_name ---${NC}"

  if container_is_running "$CTID"; then
    log "INFO" "Container $CTID is running"

    if pct exec "$CTID" -- timeout 10s nvidia-smi >/dev/null 2>&1; then
      echo -e "${GREEN}✅ nvidia-smi works COMPLETELY in CT $CTID${NC}"
      echo "GPU details:"
      pct exec "$CTID" -- nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
    else
      echo -e "${RED}❌ nvidia-smi DOES NOT work completely in CT $CTID${NC}"
      echo "Basic test:"
      if pct exec "$CTID" -- nvidia-smi --help >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ nvidia-smi basic works, but missing libnvidia-ml.so.1 library${NC}"
      else
        echo -e "${RED}❌ nvidia-smi doesn't work${NC}"
      fi
    fi

    echo "NVIDIA devices available:"
    pct exec "$CTID" -- ls -la /dev/ | grep nvidia || echo "No NVIDIA devices found"
  else
    echo -e "${YELLOW}⚠️ Container $CTID is stopped${NC}"
    read -p "Start container for testing? (y/N): " -r start_test
    if [[ "$start_test" =~ ^[Yy]$ ]]; then
      pct start "$CTID"
      sleep 5
      test_single_container "$CTID"
    fi
  fi
}

install_nvtop_container() {
  local CTID=$1
  local container_name
  container_name=$(pct config "$CTID" | grep -oP 'hostname: \K.*' || echo "N/A")

  log "INFO" "Installing nvtop in CT $CTID: $container_name"

  if ! container_is_running "$CTID"; then
    log "WARNING" "Container $CTID is not running, starting..."
    pct start "$CTID"
    sleep 5
  fi

  if pct exec "$CTID" -- which nvtop &>/dev/null; then
    log "INFO" "nvtop is already installed in CT $CTID"
    echo -e "${GREEN}✅ nvtop is already installed in container $CTID${NC}"
    return 0
  fi

  log "INFO" "Installing nvtop in container $CTID..."
  if pct exec "$CTID" -- apt-get update && \
     pct exec "$CTID" -- apt-get install -y nvtop; then
    log "SUCCESS" "nvtop installed via apt-get"
    echo -e "${GREEN}✅ nvtop installed successfully in container $CTID${NC}"
    return 0
  fi

  log "WARNING" "Failed to install via apt-get, trying compilation..."
  if pct exec "$CTID" -- apt-get install -y git build-essential cmake libncurses5-dev && \
     pct exec "$CTID" -- git clone https://github.com/Syllo/nvtop.git /tmp/nvtop && \
     pct exec "$CTID" -- sh -c "cd /tmp/nvtop && mkdir -p build && cd build && cmake .. && make && make install"; then
    if pct exec "$CTID" -- which nvtop &>/dev/null; then
      log "SUCCESS" "nvtop compiled and installed successfully"
      echo -e "${GREEN}✅ nvtop installed via compilation in container $CTID${NC}"
      return 0
    fi
  fi

  log "ERROR" "Failed to install nvtop in CT $CTID"
  echo -e "${RED}❌ Failed to install nvtop in container $CTID${NC}"
  return 1
}

install_docker_stack() {
  local CTID=$1
  local container_name
  container_name=$(pct config "$CTID" | grep -oP 'hostname: \K.*' || echo "N/A")

  echo
  echo -e "${BLUE}=== Docker Stack Installation for CT $CTID: $container_name ===${NC}"

  if ! container_is_running "$CTID"; then
    log "ERROR" "Container $CTID is not running."
    return 1
  fi

  log "INFO" "Checking GPU access in container..."
  if ! pct exec "$CTID" -- ls /dev/nvidia0 >/dev/null 2>&1; then
    log "ERROR" "GPU not accessible in container. Configure GPU passthrough first."
    return 1
  fi

  log "INFO" "Installing Docker + NVIDIA Container Toolkit in CT $CTID..."

  pct exec "$CTID" -- apt-get update
  pct exec "$CTID" -- apt-get install -y ca-certificates curl gnupg lsb-release

  pct exec "$CTID" -- mkdir -p /etc/apt/keyrings
  pct exec "$CTID" -- sh -c \
    "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"

  pct exec "$CTID" -- sh -c \
    "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian \$(lsb_release -cs) stable\" \
> /etc/apt/sources.list.d/docker.list"

  pct exec "$CTID" -- apt-get update
  pct exec "$CTID" -- apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  log "SUCCESS" "Docker installed in CT $CTID"

  # NVIDIA Container Toolkit
  pct exec "$CTID" -- sh -c \
    "curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
  pct exec "$CTID" -- sh -c \
    "curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/\$(dpkg --print-architecture)/nvidia-container-toolkit.list \
| sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
> /etc/apt/sources.list.d/nvidia-container-toolkit.list"

  pct exec "$CTID" -- apt-get update
  pct exec "$CTID" -- apt-get install -y nvidia-container-toolkit

  pct exec "$CTID" -- nvidia-ctk runtime configure --runtime=docker
  pct exec "$CTID" -- systemctl restart docker

  log "SUCCESS" "Docker stack with NVIDIA GPU support installed in CT $CTID"
}

# ==========================
#  MAIN MENU / ENTRY POINT
# ==========================

prompt_ctid() {
  local CTID
  read -p "Enter CTID: " CTID
  if ! [[ "$CTID" =~ ^[0-9]+$ ]]; then
    log "ERROR" "Invalid CTID"
    return 1
  fi
  if ! container_exists "$CTID"; then
    log "ERROR" "Container $CTID does not exist"
    return 1
  fi
  echo "$CTID"
}

main_menu() {
  while true; do
    echo
    echo -e "${BLUE}===== NVIDIA GPU Passthrough for LXC Proxmox (v${SCRIPT_VERSION}) =====${NC}"
    echo "1) Install / fix NVIDIA drivers on HOST"
    echo "2) Configure single LXC container with NVIDIA GPU"
    echo "3) Diagnose LXC container GPU configuration"
    echo "4) Clean NVIDIA configuration from LXC container"
    echo "5) Test GPU inside LXC container"
    echo "6) Install nvtop inside LXC container"
    echo "7) Install Docker stack with GPU support in LXC"
    echo "0) Exit"
    echo

    read -p "Select an option: " opt
    case "$opt" in
      1)
        install_nvidia_host_drivers
        ;;
      2)
        CTID=$(prompt_ctid) || continue
        configure_single_container_correct "$CTID"
        ;;
      3)
        CTID=$(prompt_ctid) || continue
        diagnose_container "$CTID"
        ;;
      4)
        CTID=$(prompt_ctid) || continue
        clean_single_container "$CTID"
        ;;
      5)
        CTID=$(prompt_ctid) || continue
        test_single_container "$CTID"
        ;;
      6)
        CTID=$(prompt_ctid) || continue
        install_nvtop_container "$CTID"
        ;;
      7)
        CTID=$(prompt_ctid) || continue
        install_docker_stack "$CTID"
        ;;
      0)
        echo "Bye!"
        exit 0
        ;;
      *)
        echo -e "${YELLOW}Invalid option${NC}"
        ;;
    esac
  done
}

# ==========================
#  START
# ==========================

check_root
check_proxmox
show_welcome
main_menu
