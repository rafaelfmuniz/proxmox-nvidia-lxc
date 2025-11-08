# Proxmox NVIDIA GPU LXC Setup Script

![Proxmox](https://img.shields.io/badge/Proxmox-VE-orange)
![NVIDIA](https://img.shields.io/badge/NVIDIA-GPU-green)
![LXC](https://img.shields.io/badge/LXC-Containers-blue)
![License](https://img.shields.io/badge/License-MIT-yellow)

A comprehensive, automated script to configure NVIDIA GPU passthrough for LXC containers in Proxmox VE.

## 🚀 Features

- **Automatic Driver Installation**: Detects and installs NVIDIA drivers on Proxmox host
- **Smart Container Configuration**: Automatically configures LXC containers for GPU access
- **Component Cleanup**: Safely removes conflicting NVIDIA components from containers
- **Diagnostic Tools**: Comprehensive diagnostics and testing
- **Multi-Container Support**: Configure multiple containers at once
- **nvtop Integration**: Easy installation of GPU monitoring tool

## 📋 Requirements

- Proxmox VE 7.x or 8.x
- NVIDIA GPU with compatible drivers
- LXC containers (tested with Ubuntu/Debian)
- Internet connection for driver installation

## 🛠 Quick Start

### One-line Installation & Execution

```bash
# Download the script
wget https://raw.githubusercontent.com/rafaelfmuniz/proxmox-nvidia-lxc/main/nvidia-lxc-setup.sh

# Make it executable
chmod +x nvidia-lxc-setup.sh

# Run the script
./nvidia-lxc-setup.sh
