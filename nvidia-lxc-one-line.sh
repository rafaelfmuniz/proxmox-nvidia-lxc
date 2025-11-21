#!/bin/bash

# NVIDIA GPU Passthrough for LXC Proxmox - One Line Install
# Version: 2.0
# Author: Rafael Muniz
# GitHub: https://github.com/rafaelfmuniz/proxmox-nvidia-lxc

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script information
SCRIPT_VERSION="2.0"
SCRIPT_URL="https://github.com/rafaelfmuniz/proxmox-nvidia-lxc"

# Display welcome message
show_welcome() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║           NVIDIA GPU Passthrough for LXC Proxmox        ║"
    echo "║               One-Line Install - Version 2.0            ║"
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

# [AQUI VOCÊ COPIA TODO O RESTO DO CÓDIGO DO SCRIPT ORIGINAL]
# [COPIE TODAS AS FUNÇÕES: install_nvidia_host_drivers, container_exists, etc.]
# [COPIE A FUNÇÃO main COMPLETA]

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

# [CONTINUE COPIANDO TODAS AS OUTRAS FUNÇÕES DO SCRIPT ORIGINAL...]
# [container_exists, container_is_running, check_nvidia_components_in_container, etc...]
# [ATÉ CHEGAR NA FUNÇÃO main]

# UPDATED main function
main() {
    show_welcome
    check_root
    check_proxmox
    
    echo -e "${BLUE}=== NVIDIA GPU Script for LXC Proxmox ===${NC}"
    echo "ONE-LINE INSTALL Version 2.0"
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
        echo "5) Complete Container Diagnosis"
        echo "6) Exit"
        echo
        read -p "Choose an option [1-6]: " main_choice
        
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
                        echo -e "${YELLOW}Use option 5 (Diagnosis) to investigate.${NC}"
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
                echo -e "${BLUE}=== Complete Container Diagnosis ===${NC}"
                for CTID in "${valid_containers[@]}"; do
                    diagnose_container $CTID
                done
                ;;
            6)
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

# Execute main script if run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
