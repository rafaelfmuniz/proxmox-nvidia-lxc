#!/bin/bash

# NVIDIA GPU Passthrough for LXC Proxmox - One Line Install
# Version: 2.1 - Docker Stack with GPU Support
# Author: Rafael Muniz
# GitHub: https://github.com/rafaelfmuniz/proxmox-nvidia-lxc

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script information
SCRIPT_VERSION="2.1"
SCRIPT_URL="https://github.com/rafaelfmuniz/proxmox-nvidia-lxc"

# Display welcome message
show_welcome() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║           NVIDIA GPU Passthrough for LXC Proxmox         ║"
    echo "║         Version 2.1 - Docker Stack with GPU Support      ║"
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
    local timestamp=$(date '+%H:%M:%S')
    case $level in
        "ERROR") echo -e "${RED}[$timestamp] $level: $message${NC}" ;;
        "INFO") echo -e "${BLUE}[$timestamp] $level: $message${NC}" ;;
        "SUCCESS") echo -e "${GREEN}[$timestamp] $level: $message${NC}" ;;
        "WARNING") echo -e "${YELLOW}[$timestamp] $level: $message${NC}" ;;
    esac
}

# Function to check and install NVIDIA drivers on the HOST
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
    
    # 3. Add non-free repository if necessary
    log "INFO" "Configuring repositories..."
    if ! grep -q "non-free" /etc/apt/sources.list; then
        log "INFO" "Adding non-free to repositories..."
        sed -i 's/main$/main non-free/' /etc/apt/sources.list
    fi
    
    apt-get update
    
    # 4. Install NVIDIA drivers (safe method for Proxmox)
    log "INFO" "Installing NVIDIA drivers via apt (safe method)..."
    
    # Try to install the latest driver
    if apt-get install -y nvidia-driver firmware-misc-nonfree; then
        log "SUCCESS" "NVIDIA drivers installed successfully"
    else
        log "WARNING" "Failed to install nvidia-driver, trying alternative method..."
        
        # Alternative method: install specific packages
        if apt-get install -y nvidia-kernel-dkms nvidia-smi nvidia-settings; then
            log "SUCCESS" "NVIDIA packages installed via alternative method"
        else
            log "ERROR" "Failed to install NVIDIA drivers"
            return 1
        fi
    fi
    
    # 5. Configure NVIDIA module to load automatically
    log "INFO" "Configuring NVIDIA module..."
    echo -e "\n# Load NVIDIA driver\nnvidia" >> /etc/modules
    echo -e "\n# Load NVIDIA UVM for CUDA\nnvidia-uvm" >> /etc/modules
    
    # 6. Update initramfs
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
        log "WARNING" "Drivers installed but require reboot"
        echo -e "${YELLOW}⚠️  REBOOT REQUIRED ⚠️${NC}"
        echo -e "${YELLOW}NVIDIA drivers have been installed, but a host reboot is required.${NC}"
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

# Function to check if container exists
container_exists() {
    pct list | grep -q "^$1"
}

# Function to check container status
container_is_running() {
    [ "$(pct status $1 | grep -o 'running')" == "running" ]
}

# Function to check for REAL NVIDIA components in the container
check_nvidia_components_in_container() {
    local CTID=$1
    
    log "INFO" "Checking for NVIDIA components in CT $CTID..."
    
    # Check if container is running
    if ! container_is_running $CTID; then
        log "WARNING" "Container is not running, cannot check components"
        return 1
    fi
    
    local has_components=0
    
    # 1. Check for NVIDIA DRIVER packages (not light libraries)
    if pct exec $CTID -- dpkg -l 2>/dev/null | grep -E '^ii.*nvidia-(driver|[0-9]|kernel|dkms|opencl|vdpau|compute)' | grep -q nvidia; then
        log "INFO" "📦 NVIDIA driver packages found in container"
        has_components=1
        return 0
    fi
    
    # 2. Check for NVIDIA binaries (ignoring nvidia-smi that we map)
    if pct exec $CTID -- find /usr/bin /usr/sbin /usr/local/bin -name "nvidia-*" -type f 2>/dev/null | grep -v nvidia-smi | head -1 | grep -q nvidia; then
        log "INFO" "🔧 NVIDIA binaries found in container"
        has_components=1
        return 0
    fi
    
    # 3. Check for NVIDIA CORE libraries (ignoring libnvidia-container)
    if pct exec $CTID -- find /usr/lib -name "libnvidia-*.so.*" -type f 2>/dev/null | grep -v libnvidia-container | head -1 | grep -q nvidia; then
        log "INFO" "📚 NVIDIA core libraries found"
        has_components=1
        return 0
    fi
    
    # 4. Check for NVIDIA driver directories
    if pct exec $CTID -- [ -d "/usr/lib/nvidia" ] || pct exec $CTID -- [ -d "/usr/lib/x86_64-linux-gnu/nvidia" ]; then
        log "INFO" "📁 NVIDIA driver directories found"
        has_components=1
        return 0
    fi
    
    # 5. Check for NVIDIA kernel modules
    if pct exec $CTID -- find /lib/modules -name "*nvidia*" -type f 2>/dev/null | head -1 | grep -q nvidia; then
        log "INFO" "⚙️ NVIDIA kernel modules found"
        has_components=1
        return 0
    fi
    
    # 6. Check for CUDA toolkit
    if pct exec $CTID -- [ -d "/usr/local/cuda" ] || pct exec $CTID -- which nvcc >/dev/null 2>&1; then
        log "INFO" "🔄 CUDA toolkit found"
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

# Function to clean NVIDIA components from container (AUTOMATIC - no questions)
clean_existing_nvidia_components() {
    local CTID=$1
    local container_name=$(pct config $CTID | grep -oP 'hostname: \K.*' || echo "N/A")
    
    log "INFO" "Checking for NVIDIA components in CT $CTID: $container_name"
    
    # First check for REAL NVIDIA components
    if ! check_nvidia_components_in_container $CTID; then
        log "SUCCESS" "✅ Container clean - no NVIDIA components found"
        return 0  # Continue without cleanup
    fi
    
    # IF WE REACH HERE, THERE ARE REAL NVIDIA COMPONENTS TO REMOVE
    # AUTOMATIC REMOVAL - NO USER PROMPTS
    log "INFO" "Automatically removing NVIDIA components from container..."
    
    # Stop container BEFORE anything
    if container_is_running $CTID; then
        log "INFO" "Stopping container $CTID..."
        pct stop $CTID
        sleep 3
    fi
    
    # Start container for cleanup
    log "INFO" "Starting container for cleanup..."
    if ! pct start $CTID; then
        log "ERROR" "Could not start container for cleanup"
        return 1
    fi
    sleep 5
    
    # 1. Stop NVIDIA services
    log "INFO" "Stopping NVIDIA services..."
    pct exec $CTID -- systemctl stop nvidia-persistenced 2>/dev/null || true
    pct exec $CTID -- systemctl disable nvidia-persistenced 2>/dev/null || true
    pct exec $CTID -- pkill -f nvidia 2>/dev/null || true
    
    # 2. Remove NVIDIA packages (Debian/Ubuntu)
    log "INFO" "Removing NVIDIA packages..."
    pct exec $CTID -- dpkg -l 2>/dev/null | grep nvidia | awk '{print $2}' > /tmp/nvidia_packages_$CTID.txt 2>/dev/null
    if [ -s /tmp/nvidia_packages_$CTID.txt ]; then
        log "INFO" "NVIDIA packages found:"
        cat /tmp/nvidia_packages_$CTID.txt
        pct exec $CTID -- apt-get remove --purge -y $(cat /tmp/nvidia_packages_$CTID.txt) 2>/dev/null
        log "SUCCESS" "NVIDIA packages removed"
    else
        log "INFO" "No NVIDIA packages found via dpkg"
    fi
    
    # 3. Remove CUDA packages
    log "INFO" "Removing CUDA packages..."
    pct exec $CTID -- dpkg -l 2>/dev/null | grep cuda | awk '{print $2}' > /tmp/cuda_packages_$CTID.txt 2>/dev/null
    if [ -s /tmp/cuda_packages_$CTID.txt ]; then
        log "INFO" "CUDA packages found:"
        cat /tmp/cuda_packages_$CTID.txt
        pct exec $CTID -- apt-get remove --purge -y $(cat /tmp/cuda_packages_$CTID.txt) 2>/dev/null
        log "SUCCESS" "CUDA packages removed"
    fi
    
    # 4. Clean NVIDIA repositories
    log "INFO" "Cleaning NVIDIA repositories..."
    pct exec $CTID -- rm -f /etc/apt/sources.list.d/cuda*.list 2>/dev/null || true
    pct exec $CTID -- rm -f /etc/apt/sources.list.d/nvidia*.list 2>/dev/null || true
    
    # 5. Remove NVIDIA files
    log "INFO" "Removing NVIDIA files and libraries..."
    
    # Remove NVIDIA files and links
    pct exec $CTID -- find /usr -name "*nvidia*" -exec rm -rf {} + 2>/dev/null || true
    pct exec $CTID -- find /usr -name "*cuda*" -exec rm -rf {} + 2>/dev/null || true
    pct exec $CTID -- find /opt -name "*nvidia*" -exec rm -rf {} + 2>/dev/null || true
    pct exec $CTID -- find /opt -name "*cuda*" -exec rm -rf {} + 2>/dev/null || true
    
    # Remove specific directories
    pct exec $CTID -- rm -rf /usr/local/cuda* 2>/dev/null || true
    pct exec $CTID -- rm -rf /opt/nvidia 2>/dev/null || true
    pct exec $CTID -- rm -rf /usr/lib/x86_64-linux-gnu/nvidia 2>/dev/null || true
    pct exec $CTID -- rm -rf /usr/lib/nvidia 2>/dev/null || true
    pct exec $CTID -- rm -rf /usr/share/nvidia 2>/dev/null || true
    pct exec $CTID -- rm -rf /usr/lib/firmware/nvidia 2>/dev/null || true
    
    # Remove nvidia-smi if it exists in container
    pct exec $CTID -- rm -f /usr/bin/nvidia-smi 2>/dev/null || true
    pct exec $CTID -- rm -f /usr/bin/nvidia-* 2>/dev/null || true
    
    # 6. Clean up dependencies
    log "INFO" "Cleaning unused dependencies..."
    pct exec $CTID -- apt-get autoremove -y 2>/dev/null
    pct exec $CTID -- apt-get clean 2>/dev/null
    
    # 7. Update database
    pct exec $CTID -- updatedb 2>/dev/null || true
    
    # 8. FINAL verification
    log "INFO" "Verifying all components have been removed..."
    local remaining_count=$(pct exec $CTID -- find /usr /opt -name "*nvidia*" 2>/dev/null | wc -l)
    if [ "$remaining_count" -gt 0 ]; then
        log "WARNING" "There are still $remaining_count NVIDIA files/directories:"
        pct exec $CTID -- find /usr /opt -name "*nvidia*" 2>/dev/null
    else
        log "SUCCESS" "✅ All NVIDIA components removed!"
    fi
    
    rm -f /tmp/nvidia_packages_$CTID.txt /tmp/cuda_packages_$CTID.txt 2>/dev/null
    
    # Stop container after cleanup
    pct stop $CTID
    sleep 2
    
    log "SUCCESS" "NVIDIA components cleanup completed"
}

# Function to check NVIDIA devices on HOST
check_host_nvidia_devices() {
    log "INFO" "Checking for NVIDIA devices on HOST..."
    
    local devices=()
    
    # Check main devices
    [ -e /dev/nvidia0 ] && devices+=("nvidia0")
    [ -e /dev/nvidiactl ] && devices+=("nvidiactl") 
    [ -e /dev/nvidia-modeset ] && devices+=("nvidia-modeset")
    [ -e /dev/nvidia-uvm ] && devices+=("nvidia-uvm")
    [ -e /dev/nvidia-uvm-tools ] && devices+=("nvidia-uvm-tools")
    
    # Check nvidia-caps
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

# Function to find and map NVIDIA libraries correctly
find_and_map_nvidia_libraries() {
    local CTID=$1
    log "INFO" "Mapping required NVIDIA libraries..."
    
    # List of needed libraries
    local needed_libs=("libnvidia-ml.so.1" "libcuda.so.1")
    
    for lib in "${needed_libs[@]}"; do
        # Find the library on host
        local lib_path=$(find /usr/lib -name "$lib" 2>/dev/null | head -1)
        
        if [ -n "$lib_path" ]; then
            # Check if it's a symbolic link
            if [ -L "$lib_path" ]; then
                local real_path=$(readlink -f "$lib_path")
                if [ -f "$real_path" ]; then
                    # Map the real file, not the link
                    echo "lxc.mount.entry: $real_path usr/lib/x86_64-linux-gnu/$lib none bind,ro,create=file 0 0" >> /etc/pve/lxc/${CTID}.conf
                    log "SUCCESS" "Mapped library: $lib (via link: $(basename $real_path))"
                else
                    log "WARNING" "Broken link: $lib_path -> $real_path"
                fi
            else
                # Map regular file
                echo "lxc.mount.entry: $lib_path usr/lib/x86_64-linux-gnu/$lib none bind,ro,create=file 0 0" >> /etc/pve/lxc/${CTID}.conf
                log "SUCCESS" "Mapped library: $lib"
            fi
        else
            log "WARNING" "Library not found: $lib"
        fi
    done
}

# Function to configure container CORRECTLY
configure_single_container_correct() {
    local CTID=$1
    local container_name=$(pct config $CTID | grep -oP 'hostname: \K.*' || echo "N/A")
    
    log "INFO" "Configuration for CT $CTID: $container_name"
    
    # First check devices on host
    if ! check_host_nvidia_devices; then
        log "ERROR" "NVIDIA devices not available on host"
        return 1
    fi
    
    # Clean NVIDIA components only if they exist (AUTOMATIC)
    # BUT NOW ONLY CLEANS IF REAL NVIDIA COMPONENTS EXIST
    if check_nvidia_components_in_container $CTID; then
        log "INFO" "NVIDIA components found, cleaning..."
        clean_existing_nvidia_components $CTID
    else
        log "INFO" "No NVIDIA components found, skipping cleanup"
    fi
    
    # Completely clear previous configurations
    log "INFO" "Cleaning previous container configurations..."
    cp /etc/pve/lxc/${CTID}.conf /etc/pve/lxc/${CTID}.conf.backup.$(date +%Y%m%d_%H%M%S)
    
    # Create temporary file without NVIDIA configurations
    # FIX: Remove ALL mount entries, including libraries
    grep -v -E "^(lxc.cgroup2.devices.allow:|dev[0-9]+: /dev/nvidia|lxc.mount.entry: /usr/(bin/nvidia-smi|lib/x86_64-linux-gnu/.*nvidia|lib/x86_64-linux-gnu/.*cuda)|# Nvidia GPU passthrough)" /etc/pve/lxc/${CTID}.conf > /etc/pve/lxc/${CTID}.conf.tmp
    mv /etc/pve/lxc/${CTID}.conf.tmp /etc/pve/lxc/${CTID}.conf
    
    # Apply CORRECT and COMPLETE configuration
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
        
        # Add nvidia-caps if exists
        if [ -e /dev/nvidia-caps/nvidia-cap1 ]; then
            echo "dev5: /dev/nvidia-caps/nvidia-cap1,mode=0666"
        fi
        if [ -e /dev/nvidia-caps/nvidia-cap2 ]; then
            echo "dev6: /dev/nvidia-caps/nvidia-cap2,mode=0666"
        fi
        
        echo "lxc.mount.entry: /usr/bin/nvidia-smi usr/bin/nvidia-smi none bind,ro,create=file 0 0"
    } >> /etc/pve/lxc/${CTID}.conf

    # Map required NVIDIA libraries
    find_and_map_nvidia_libraries $CTID
    
    log "SUCCESS" "Configuration applied"
    log "INFO" "Configuration content:"
    grep -E "^(lxc.cgroup2.devices.allow:|dev[0-9]+: /dev/nvidia|lxc.mount.entry)" /etc/pve/lxc/${CTID}.conf
    
    # Restart container to apply changes
    log "INFO" "Restarting container to apply changes..."
    if container_is_running $CTID; then
        log "INFO" "Container is running, stopping..."
        pct stop $CTID
        sleep 2
    fi
    
    # Start container
    log "INFO" "Starting container..."
    if pct start $CTID; then
        log "SUCCESS" "Container started successfully"
        
        # Wait for startup
        sleep 5
        
        # Test devices INSIDE container
        log "INFO" "Testing NVIDIA devices in container..."
        if pct exec $CTID -- ls /dev/nvidia0 >/dev/null 2>&1; then
            log "SUCCESS" "✅ Device /dev/nvidia0 detected in container"
        else
            log "ERROR" "❌ /dev/nvidia0 NOT detected in container"
            return 1
        fi
        
        # Test COMPLETE nvidia-smi (not just --help)
        log "INFO" "Testing nvidia-smi (complete test)..."
        if pct exec $CTID -- timeout 10s nvidia-smi > /dev/null 2>&1; then
            log "SUCCESS" "✅ nvidia-smi works COMPLETELY!"
            echo -e "${GREEN}🎉 COMPLETE CONFIGURATION WORKING!${NC}"
            return 0
        else
            log "WARNING" "nvidia-smi doesn't work completely (missing libraries)"
            
            # Try alternative solution: install only the required library
            log "INFO" "Installing libnvidia-ml1 in container..."
            if pct exec $CTID -- apt-get update && pct exec $CTID -- apt-get install -y libnvidia-ml1; then
                log "SUCCESS" "libnvidia-ml1 installed"
                if pct exec $CTID -- timeout 10s nvidia-smi > /dev/null 2>&1; then
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

# Function for COMPLETE diagnosis
diagnose_container() {
    local CTID=$1
    local container_name=$(pct config $CTID | grep -oP 'hostname: \K.*' || echo "N/A")
    
    echo
    echo -e "${BLUE}=== COMPLETE DIAGNOSIS CT $CTID: $container_name ===${NC}"
    
    # 1. Container status
    echo -e "\n${YELLOW}1. CONTAINER STATUS:${NC}"
    pct status $CTID
    
    # 2. Current NVIDIA configuration
    echo -e "\n${YELLOW}2. NVIDIA CONFIGURATION IN CONTAINER:${NC}"
    grep -E "^(lxc.cgroup2.devices.allow:|dev[0-9]+: /dev/nvidia|lxc.mount.entry)" /etc/pve/lxc/${CTID}.conf 2>/dev/null || echo "No NVIDIA configuration found"
    
    # 3. Devices on HOST
    echo -e "\n${YELLOW}3. NVIDIA DEVICES ON HOST:${NC}"
    ls -la /dev/nvidia* 2>/dev/null || echo "No NVIDIA devices on host"
    
    # 4. If container is running, check inside
    if container_is_running $CTID; then
        echo -e "\n${YELLOW}4. DEVICES INSIDE CONTAINER:${NC}"
        pct exec $CTID -- ls -la /dev/nvidia* 2>/dev/null || echo "No NVIDIA devices in container"
        
        echo -e "\n${YELLOW}5. NVIDIA-SMI IN CONTAINER:${NC}"
        if pct exec $CTID -- which nvidia-smi >/dev/null 2>&1; then
            echo "Testing nvidia-smi:"
            pct exec $CTID -- timeout 10s nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null && echo -e "${GREEN}✅ nvidia-smi WORKS${NC}" || echo -e "${RED}❌ nvidia-smi DOES NOT work completely${NC}"
        else
            echo "nvidia-smi not found"
        fi
        
        echo -e "\n${YELLOW}6. NVIDIA LIBRARIES IN CONTAINER:${NC}"
        pct exec $CTID -- find /usr -name "*nvidia*" 2>/dev/null | head -10 || echo "No NVIDIA libraries found"
        
        echo -e "\n${YELLOW}7. NVIDIA COMPONENTS:${NC}"
        check_nvidia_components_in_container $CTID
        
    else
        echo -e "\n${YELLOW}4. CONTAINER STOPPED - cannot check internally${NC}"
    fi
}

# Function to clean NVIDIA configuration from a specific container (FIXED)
clean_single_container() {
    local CTID=$1
    local container_name=$(pct config $CTID | grep -oP 'hostname: \K.*' || echo "N/A")
    
    log "INFO" "Cleaning NVIDIA configurations from CT $CTID: $container_name"
    
    # Stop container if running
    if container_is_running $CTID; then
        log "INFO" "Stopping container $CTID..."
        pct stop $CTID
        sleep 2
    fi
    
    # Remove NVIDIA configurations
    log "INFO" "Removing NVIDIA configurations..."
    
    # Create configuration backup
    cp /etc/pve/lxc/${CTID}.conf /etc/pve/lxc/${CTID}.conf.backup.$(date +%Y%m%d_%H%M%S)
    
    # FIX: Remove ALL entries related to NVIDIA, including mapped libraries
    grep -v -E "^(lxc.cgroup2.devices.allow: c (195|509|511):|dev[0-9]+: /dev/nvidia|lxc.mount.entry: /usr/(bin/nvidia-smi|lib/x86_64-linux-gnu/.*nvidia|lib/x86_64-linux-gnu/.*cuda)|# Nvidia GPU passthrough)" /etc/pve/lxc/${CTID}.conf > /etc/pve/lxc/${CTID}.conf.tmp
    mv /etc/pve/lxc/${CTID}.conf.tmp /etc/pve/lxc/${CTID}.conf
    
    # Remove specific comments too
    sed -i '/Nvidia GPU passthrough/d' /etc/pve/lxc/${CTID}.conf
    sed -i '/NVIDIA GPU Configuration/d' /etc/pve/lxc/${CTID}.conf
    
    log "SUCCESS" "NVIDIA configurations removed from CT $CTID"
    
    # Start container
    log "INFO" "Starting container $CTID..."
    if pct start $CTID; then
        log "SUCCESS" "Container $CTID started successfully"
    else
        log "ERROR" "Failed to start container $CTID"
        return 1
    fi
}

# Function to test GPU in specific container
test_single_container() {
    local CTID=$1
    local container_name=$(pct config $CTID | grep -oP 'hostname: \K.*' || echo "N/A")
    
    echo
    echo -e "${YELLOW}--- Testing CT $CTID: $container_name ---${NC}"
    
    if container_is_running $CTID; then
        log "INFO" "Container $CTID is running"
        
        # Test COMPLETE nvidia-smi
        if pct exec $CTID -- timeout 10s nvidia-smi > /dev/null 2>&1; then
            echo -e "${GREEN}✅ nvidia-smi works COMPLETELY in CT $CTID${NC}"
            echo "GPU details:"
            pct exec $CTID -- nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
        else
            echo -e "${RED}❌ nvidia-smi DOES NOT work completely in CT $CTID${NC}"
            echo "Basic test:"
            pct exec $CTID -- nvidia-smi --help > /dev/null 2>&1 && echo -e "${YELLOW}⚠️ nvidia-smi basic works, but missing libnvidia-ml.so.1 library${NC}" || echo -e "${RED}❌ nvidia-smi doesn't work${NC}"
        fi
        
        # Test devices
        echo "NVIDIA devices available:"
        pct exec $CTID -- ls -la /dev/ | grep nvidia || echo "No NVIDIA devices found"
        
    else
        echo -e "${YELLOW}⚠️ Container $CTID is stopped${NC}"
        read -p "Start container for testing? (y/N): " -r start_test
        if [[ "$start_test" =~ ^[Yy]$ ]]; then
            pct start $CTID
            sleep 5
            test_single_container $CTID
        fi
    fi
}

# Function to install nvtop in a container
install_nvtop_container() {
    local CTID=$1
    local container_name=$(pct config $CTID | grep -oP 'hostname: \K.*' || echo "N/A")
    
    log "INFO" "Installing nvtop in CT $CTID: $container_name"
    
    if ! container_is_running $CTID; then
        log "WARNING" "Container $CTID is not running, starting..."
        pct start $CTID
        sleep 5
    fi
    
    # Check if nvtop is already installed
    if pct exec $CTID -- which nvtop &>/dev/null; then
        log "INFO" "nvtop is already installed in CT $CTID"
        echo -e "${GREEN}✅ nvtop is already installed in container $CTID${NC}"
        return 0
    fi
    
    log "INFO" "Installing nvtop in container $CTID..."
    
    # Try different installation methods
    if pct exec $CTID -- apt-get update && pct exec $CTID -- apt-get install -y nvtop; then
        log "SUCCESS" "nvtop installed via apt-get"
        echo -e "${GREEN}✅ nvtop installed successfully in container $CTID${NC}"
        return 0
    else
        log "WARNING" "Failed to install via apt-get, trying alternative method..."
        
        # Try installation via snap or compilation
        if pct exec $CTID -- apt-get install -y git build-essential cmake libncurses5-dev; then
            log "INFO" "Compiling nvtop from source..."
            pct exec $CTID -- git clone https://github.com/Syllo/nvtop.git /tmp/nvtop
            pct exec $CTID -- mkdir -p /tmp/nvtop/build
            pct exec $CTID -- sh -c "cd /tmp/nvtop/build && cmake .. && make && make install"
            
            if pct exec $CTID -- which nvtop &>/dev/null; then
                log "SUCCESS" "nvtop compiled and installed successfully"
                echo -e "${GREEN}✅ nvtop installed via compilation in container $CTID${NC}"
                return 0
            fi
        fi
    fi
    
    log "ERROR" "Failed to install nvtop in CT $CTID"
    echo -e "${RED}❌ Failed to install nvtop in container $CTID${NC}"
    return 1
}

# Function to install Docker with GPU support
install_docker_stack() {
    local CTID=$1
    local container_name=$(pct config $CTID | grep -oP 'hostname: \K.*' || echo "N/A")
    
    echo
    echo -e "${BLUE}=== Docker Stack Installation for CT $CTID: $container_name ===${NC}"
    
    # Check if container is running
    if ! container_is_running $CTID; then
        log "ERROR" "Container $CTID is not running"
        return 1
    fi
    
    # Check if we have GPU access in the container
    log "INFO" "Checking GPU access in container..."
    if ! pct exec $CTID -- ls /dev/nvidia0 >/dev/null 2>&1; then
        log "ERROR" "GPU not accessible in container. Please configure GPU first using option 1."
        return 1
    fi
    
    log "SUCCESS" "GPU is accessible in container"
    
    # Check what's already installed
    log "INFO" "Checking existing installations..."
    local docker_installed=$(pct exec $CTID -- which docker >/dev/null 2>&1 && echo "yes" || echo "no")
    local compose_installed=$(pct exec $CTID -- which docker-compose >/dev/null 2>&1 && echo "yes" || echo "no")
    local portainer_running=$(pct exec $CTID -- docker ps --filter "name=portainer" --format "{{.Names}}" 2>/dev/null)
    
    echo
    echo -e "${YELLOW}Current Installation Status:${NC}"
    echo "  Docker: $docker_installed"
    echo "  Docker Compose: $compose_installed"
    echo "  Portainer: ${portainer_running:-not running}"
    echo
    
    # Installation choices
    echo -e "${YELLOW}Select components to install/repair:${NC}"
    echo "1) Docker + Docker Compose + Portainer CE (Full stack)"
    echo "2) Docker only"
    echo "3) Docker + Docker Compose" 
    echo "4) Repair existing installation"
    echo "5) Cancel"
    
    read -p "Choose option [1-5]: " docker_choice
    
    case $docker_choice in
        1)
            install_docker=true
            install_compose=true
            install_portainer=true
            repair_mode=false
            ;;
        2)
            install_docker=true
            install_compose=false
            install_portainer=false
            repair_mode=false
            ;;
        3)
            install_docker=true
            install_compose=true
            install_portainer=false
            repair_mode=false
            ;;
        4)
            install_docker=false
            install_compose=false
            install_portainer=false
            repair_mode=true
            ;;
        5)
            log "INFO" "Docker installation cancelled"
            return 0
            ;;
        *)
            log "ERROR" "Invalid option"
            return 1
            ;;
    esac
    
    # Start installation
    if [ "$repair_mode" = true ]; then
        log "INFO" "Starting Docker stack repair..."
    else
        log "INFO" "Starting Docker stack installation..."
    fi
    
    # Install Docker if requested or in repair mode and Docker is broken
    if [ "$install_docker" = true ] || [ "$repair_mode" = true ]; then
        # Check if Docker is already working
        if pct exec $CTID -- docker --version >/dev/null 2>&1; then
            log "INFO" "Docker is already installed and working"
            local docker_version=$(pct exec $CTID -- docker --version)
            log "INFO" "Docker version: $docker_version"
        else
            log "INFO" "Installing/Repairing Docker..."
            
            # Update system
            pct exec $CTID -- apt-get update
            
            # Install prerequisites
            pct exec $CTID -- apt-get install -y \
                ca-certificates \
                curl \
                gnupg \
                lsb-release
            
            # CORREÇÃO: Usar método oficial do Docker para Debian (não Ubuntu)
            log "INFO" "Setting up Docker repository for Debian..."
            
            # Add Docker's official GPG key
            pct exec $CTID -- install -m 0755 -d /etc/apt/keyrings
            pct exec $CTID -- curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
            pct exec $CTID -- chmod a+r /etc/apt/keyrings/docker.asc
            
            # Add the repository to Apt sources
            pct exec $CTID -- tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
            
            # Update and install Docker
            pct exec $CTID -- apt-get update
            pct exec $CTID -- apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            
            # Start and enable Docker
            pct exec $CTID -- systemctl start docker
            pct exec $CTID -- systemctl enable docker
            
            # Add users to docker group
            pct exec $CTID -- usermod -aG docker root
            
            # Verify installation
            if pct exec $CTID -- docker --version >/dev/null 2>&1; then
                log "SUCCESS" "Docker installed/repaired successfully"
            else
                log "ERROR" "Docker installation failed"
                return 1
            fi
        fi
    fi
    
    # Install Docker Compose (standalone - para compatibilidade)
    if [ "$install_compose" = true ] || ([ "$repair_mode" = true ] && [ "$compose_installed" = "no" ]); then
        if pct exec $CTID -- which docker-compose >/dev/null 2>&1; then
            log "INFO" "Docker Compose is already installed"
        else
            log "INFO" "Installing Docker Compose (standalone)..."
            
            # Download and install Docker Compose standalone
            pct exec $CTID -- curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
            pct exec $CTID -- chmod +x /usr/local/bin/docker-compose
            
            # Create symbolic link
            pct exec $CTID -- ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
            
            if pct exec $CTID -- docker-compose --version >/dev/null 2>&1; then
                log "SUCCESS" "Docker Compose installed successfully"
            else
                log "WARNING" "Docker Compose installation failed, but Docker Compose Plugin is available"
            fi
        fi
    fi
    
    # CORREÇÃO: Configuração do Docker para GPU support (método simplificado)
    log "INFO" "Configuring Docker for GPU support..."
    
    # Create Docker daemon configuration directory
    pct exec $CTID -- mkdir -p /etc/docker
    
    # CORREÇÃO: Criar daemon.json básico sem NVIDIA Container Toolkit (não disponível no Debian Trixie)
    pct exec $CTID -- bash -c 'cat > /etc/docker/daemon.json << "EOF"
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    }
}
EOF'
    
    # CORREÇÃO: Remover arquivos existentes do NVIDIA Container Toolkit SEM perguntas
    pct exec $CTID -- rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null || true
    pct exec $CTID -- rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list 2>/dev/null || true
    
    # CORREÇÃO: Tentar método alternativo para Debian Trixie
    log "INFO" "Setting up GPU access for Debian Trixie..."
    
    # Método 1: Tentar instalar via pacotes do Debian
    pct exec $CTID -- apt-get update
    if pct exec $CTID -- apt-cache search nvidia-container-toolkit | grep -q nvidia-container-toolkit; then
        log "INFO" "Installing NVIDIA Container Toolkit from Debian repositories..."
        pct exec $CTID -- apt-get install -y nvidia-container-toolkit
    else
        log "WARNING" "NVIDIA Container Toolkit not available in Debian Trixie repositories"
        log "INFO" "Using manual GPU device mapping method"
    fi
    
    # Reiniciar Docker para aplicar mudanças
    pct exec $CTID -- systemctl restart docker
    
    log "SUCCESS" "Docker configured successfully"
    
    # CORREÇÃO: Instalação do Portainer (resolvendo problema de permissão)
    if [ "$install_portainer" = true ] || ([ "$repair_mode" = true ] && [ -n "$portainer_running" ]); then
        log "INFO" "Setting up Portainer CE..."
        
        # Clean up any existing Portainer containers
        pct exec $CTID -- docker rm -f portainer 2>/dev/null || true
        
        # Create volume for Portainer
        pct exec $CTID -- docker volume create portainer_data 2>/dev/null || true
        
        # CORREÇÃO: Executar Portainer sem problemas de sysctl
        log "INFO" "Starting Portainer with adjusted settings..."
        
        # Método 1: Tentar com network host (evita problemas de bridge)
        if pct exec $CTID -- docker run -d \
            --name portainer \
            --restart unless-stopped \
            --network host \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v portainer_data:/data \
            portainer/portainer-ce:latest 2>/dev/null; then
            log "SUCCESS" "Portainer started with host network"
            portainer_started=true
        else
            # Método 2: Tentar com bridge mas sem mapeamento de portas problemáticas
            log "INFO" "Host network failed, trying bridge network..."
            pct exec $CTID -- docker rm -f portainer 2>/dev/null || true
            
            if pct exec $CTID -- docker run -d \
                --name portainer \
                --restart unless-stopped \
                -p 9443:9443 \
                -v /var/run/docker.sock:/var/run/docker.sock \
                -v portainer_data:/data \
                portainer/portainer-ce:latest 2>/dev/null; then
                log "SUCCESS" "Portainer started with bridge network (port 9443)"
                portainer_started=true
            else
                log "WARNING" "Portainer failed to start with both methods"
                portainer_started=false
            fi
        fi
        
        # Wait and check if Portainer is running
        sleep 5
        if pct exec $CTID -- docker ps --filter "name=portainer" --format "{{.Status}}" | grep -q "Up"; then
            log "SUCCESS" "Portainer CE is running"
            portainer_started=true
        else
            log "WARNING" "Portainer container exists but is not running"
            portainer_started=false
        fi
        
        if [ "$portainer_started" = true ]; then
            # Get container IP for Portainer access
            local container_ip=$(pct exec $CTID -- hostname -I | awk '{print $1}')
            
            echo
            echo -e "${GREEN}🎉 PORTAINER INSTALLATION COMPLETE!${NC}"
            echo -e "${YELLOW}================================${NC}"
            echo -e "${GREEN}🌐 Portainer Web UI:${NC}"
            echo -e "   HTTPS: https://${container_ip}:9443"
            echo
            echo -e "${GREEN}🔧 First-time setup:${NC}"
            echo -e "   1. Open https://${container_ip}:9443 in your browser"
            echo -e "   2. Create admin user account"
            echo -e "   3. Start managing your Docker environment!"
        else
            echo -e "${YELLOW}⚠️ Portainer installation may need manual intervention${NC}"
            echo -e "${YELLOW}You can try running manually inside container:${NC}"
            echo -e "docker run -d --name portainer --restart unless-stopped --network host -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest"
        fi
    fi
    
    # Test Docker functionality
    log "INFO" "Testing Docker installation..."
    
    # Test basic Docker command
    if pct exec $CTID -- docker --version >/dev/null 2>&1; then
        log "SUCCESS" "✅ Docker is working"
    else
        log "ERROR" "❌ Docker is not working"
    fi
    
    # Test Docker Compose if installed
    if pct exec $CTID -- which docker-compose >/dev/null 2>&1; then
        if pct exec $CTID -- docker-compose --version >/dev/null 2>&1; then
            log "SUCCESS" "✅ Docker Compose is working"
        else
            log "WARNING" "⚠️ Docker Compose installed but not working"
        fi
    fi
    
    # Test Docker Compose Plugin (sempre disponível com instalação moderna)
    if pct exec $CTID -- docker compose version >/dev/null 2>&1; then
        log "SUCCESS" "✅ Docker Compose Plugin is working"
    fi
    
    # CORREÇÃO: Teste de GPU com múltiplos métodos
    log "INFO" "Testing GPU access in Docker..."
    
    # Lista de imagens para testar (focando em Debian)
    local test_images=(
        "nvidia/cuda:12.0.0-base-ubuntu20.04"
        "nvidia/cuda:11.8.0-base-ubuntu20.04"
    )
    
    local gpu_working=false
    
    # Método 1: Testar com --gpus all (se NVIDIA Container Toolkit estiver disponível)
    for image in "${test_images[@]}"; do
        log "INFO" "Testing GPU with: $image"
        if pct exec $CTID -- timeout 30s docker run --rm --gpus all "$image" nvidia-smi >/dev/null 2>&1; then
            log "SUCCESS" "✅ GPU access working with --gpus all: $image"
            gpu_working=true
            break
        fi
    done
    
    # Método 2: Se --gpus all falhar, tentar mapeamento manual de dispositivos
    if [ "$gpu_working" = false ]; then
        log "INFO" "Trying manual device mapping..."
        for image in "${test_images[@]}"; do
            if pct exec $CTID -- timeout 30s docker run --rm \
                -v /dev/nvidia0:/dev/nvidia0 \
                -v /dev/nvidiactl:/dev/nvidiactl \
                -v /dev/nvidia-modeset:/dev/nvidia-modeset \
                -v /dev/nvidia-uvm:/dev/nvidia-uvm \
                "$image" nvidia-smi >/dev/null 2>&1; then
                log "SUCCESS" "✅ GPU access working with manual device mapping: $image"
                gpu_working=true
                break
            fi
        done
    fi
    
    if [ "$gpu_working" = false ]; then
        log "WARNING" "❌ GPU access test failed with all methods"
        echo -e "${YELLOW}⚠️ GPU access may need manual configuration${NC}"
        echo -e "${YELLOW}You can test manually inside container with:${NC}"
        echo -e "docker run --rm -v /dev/nvidia0:/dev/nvidia0 nvidia/cuda:12.0.0-base-ubuntu20.04 nvidia-smi"
    fi
    
    # Final summary
    echo
    echo -e "${GREEN}✅ Docker stack installation/repair completed!${NC}"
    echo
    echo -e "${YELLOW}Summary:${NC}"
    pct exec $CTID -- docker --version && echo -e "  ✅ Docker"
    pct exec $CTID -- which docker-compose >/dev/null 2>&1 && echo -e "  ✅ Docker Compose"
    pct exec $CTID -- docker compose version >/dev/null 2>&1 && echo -e "  ✅ Docker Compose Plugin"
    pct exec $CTID -- docker ps --filter "name=portainer" --format "{{.Names}}" | grep -q portainer && echo -e "  ✅ Portainer"
    [ "$gpu_working" = true ] && echo -e "  ✅ GPU Access" || echo -e "  ⚠️ GPU Access needs setup"
    
    echo
    echo -e "${YELLOW}Next steps:${NC}"
    local container_ip=$(pct exec $CTID -- hostname -I | awk '{print $1}')
    echo -e "  1. Access Portainer at: https://${container_ip}:9443"
    if [ "$gpu_working" = true ]; then
        echo -e "  2. GPU is working! Test with: docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu20.04 nvidia-smi"
    else
        echo -e "  2. To setup GPU access, run inside container:"
        echo -e "     docker run --rm -v /dev/nvidia0:/dev/nvidia0 nvidia/cuda:12.0.0-base-ubuntu20.04 nvidia-smi"
    fi
    echo -e "  3. Manage containers with: docker-compose OR docker compose"
    
    return 0
}

# Function to handle Docker installation for multiple containers
install_docker_stack_multiple() {
    echo -e "${BLUE}=== Docker Stack Installation ===${NC}"
    
    if [ ${#valid_containers[@]} -eq 0 ]; then
        log "ERROR" "No valid containers selected"
        return 1
    fi
    
    for CTID in "${valid_containers[@]}"; do
        echo
        echo -e "${YELLOW}--- Processing CT $CTID ---${NC}"
        if install_docker_stack $CTID; then
            echo -e "${GREEN}🎉 Docker stack installed successfully in CT $CTID${NC}"
        else
            echo -e "${RED}❌ Failed to install Docker stack in CT $CTID${NC}"
            if [ ${#valid_containers[@]} -gt 1 ]; then
                read -p "Continue with next container? (y/N): " -r continue_next
                if [[ ! "$continue_next" =~ ^[Yy]$ ]]; then
                    break
                fi
            fi
        fi
    done
}

# UPDATED main function
main() {
    show_welcome
    check_root
    check_proxmox
    
    echo -e "${BLUE}=== NVIDIA GPU Script for LXC Proxmox ===${NC}"
    echo "ONE-LINE INSTALL Version 2.1 - Docker Stack with GPU Support"
    echo
    
    # Check and install NVIDIA drivers on HOST if needed
    if ! install_nvidia_host_drivers; then
        log "ERROR" "Could not install or verify NVIDIA drivers on host"
        exit 1
    fi
    
    # Now drivers are installed, show GPU information
    GPU_INFO=$(nvidia-smi --query-gpu=gpu_name --format=csv,noheader | head -1)
    DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
    log "SUCCESS" "GPU on host: $GPU_INFO"
    log "INFO" "Driver version: $DRIVER_VERSION"
    
    # List containers
    log "INFO" "Available containers:"
    echo "ID    Status    Name"
    echo "----------------------"
    for CTID in $(pct list | grep -oP '^\s*\K[0-9]+(?=\s+)'); do
        STATUS=$(pct status $CTID | grep -o 'running\|stopped' | head -1)
        NAME=$(pct config $CTID | grep -oP 'hostname: \K.*' || echo "N/A")
        if [ "$STATUS" == "running" ]; then
            echo -e "${GREEN}$CTID   🟢 running  $NAME${NC}"
        else
            echo -e "${RED}$CTID   🔴 stopped  $NAME${NC}"
        fi
    done
    
    # Container selection
    echo
    echo "Container selection"
    read -p "Enter container IDs (ex: 100 101 102): " -a selected_containers
    
    if [ ${#selected_containers[@]} -eq 0 ]; then
        log "ERROR" "No containers selected"
        exit 1
    fi
    
    # Validate containers
    valid_containers=()
    for CTID in "${selected_containers[@]}"; do
        if container_exists $CTID; then
            container_name=$(pct config $CTID | grep -oP 'hostname: \K.*' || echo "N/A")
            log "INFO" "CT $CTID: $container_name"
            valid_containers+=($CTID)
        else
            log "ERROR" "CT $CTID does not exist"
        fi
    done
    
    if [ ${#valid_containers[@]} -eq 0 ]; then
        log "ERROR" "No valid containers selected"
        exit 1
    fi
    
    log "INFO" "Selected containers: ${valid_containers[*]}"
    
    # Main menu
    while true; do
        echo
        echo -e "${BLUE}=== Main Menu ===${NC}"
        echo "1) Configure NVIDIA GPU"
        echo "2) Clean NVIDIA configurations"
        echo "3) Test GPU in containers" 
        echo "4) Install nvtop (monitoring)"
        echo "5) 🆕 Install Docker Stack with GPU support"
        echo "6) Complete Container Diagnosis"
        echo "7) Exit"
        echo
        read -p "Choose an option [1-7]: " main_choice
        
        case $main_choice in
            1)
                echo -e "${BLUE}=== Configuring NVIDIA GPU ===${NC}"
                for CTID in "${valid_containers[@]}"; do
                    echo
                    echo -e "${YELLOW}--- Processing CT $CTID ---${NC}"
                    if configure_single_container_correct $CTID; then
                        echo -e "${GREEN}🎉 Container $CTID configured SUCCESSFULLY!${NC}"
                    else
                        echo -e "${RED}❌ Failed to configure CT $CTID${NC}"
                        echo -e "${YELLOW}Use option 6 (Diagnosis) to investigate.${NC}"
                        if [ ${#valid_containers[@]} -gt 1 ]; then
                            read -p "Continue with next container? (y/N): " -r continue_next
                            if [[ ! "$continue_next" =~ ^[Yy]$ ]]; then
                                break
                            fi
                        fi
                    fi
                done
                ;;
            2)
                echo -e "${YELLOW}=== Cleaning NVIDIA configurations ===${NC}"
                for CTID in "${valid_containers[@]}"; do
                    echo
                    echo -e "${YELLOW}--- Processing CT $CTID ---${NC}"
                    clean_single_container $CTID
                done
                ;;
            3)
                echo -e "${BLUE}=== Testing GPU in containers ===${NC}"
                for CTID in "${valid_containers[@]}"; do
                    test_single_container $CTID
                done
                ;;
            4)
                echo -e "${BLUE}=== Installing nvtop in containers ===${NC}"
                for CTID in "${valid_containers[@]}"; do
                    install_nvtop_container $CTID
                done
                ;;
            5)
                echo -e "${BLUE}=== Installing Docker Stack with GPU support ===${NC}"
                install_docker_stack_multiple
                ;;
            6)
                echo -e "${BLUE}=== Complete Container Diagnosis ===${NC}"
                for CTID in "${valid_containers[@]}"; do
                    diagnose_container $CTID
                done
                ;;
            7)
                log "INFO" "Exiting..."
                echo -e "${GREEN}✅ Script completed successfully!${NC}"
                exit 0
                ;;
            *)
                log "ERROR" "Invalid option"
                ;;
        esac
        
        echo
        read -p "Press Enter to continue..."
    done
}

# Execute main script directly - FIXED for one-line execution
main "$@"
