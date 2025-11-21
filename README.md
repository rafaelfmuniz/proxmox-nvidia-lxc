
# 🚀 Proxmox NVIDIA GPU LXC Setup Script

![Proxmox](https://img.shields.io/badge/Proxmox-VE-orange)
![NVIDIA](https://img.shields.io/badge/NVIDIA-GPU-green)
![LXC](https://img.shields.io/badge/LXC-Containers-blue)
![Docker](https://img.shields.io/badge/Docker-Enabled-2496ED)
![License](https://img.shields.io/badge/License-MIT-yellow)
![Version](https://img.shields.io/badge/Version-2.1-brightgreen)

A comprehensive, automated script to configure NVIDIA GPU passthrough for LXC containers in Proxmox VE with full Docker stack support.

## ✨ What's New in v2.1

- 🐳 **Full Docker Stack Integration** - Complete Docker environment with GPU support
- 📦 **Docker Compose** - Container orchestration ready
- 🌐 **Portainer CE** - Web-based management interface
- 🎮 **NVIDIA Container Toolkit** - Native GPU support for Docker containers
- 🔍 **Automatic IP Detection** - Easy access to Portainer web interface
- ⚡ **One-Line Installation** - Fast and easy setup

## 🎯 Features

- **🚀 Automatic Driver Installation**: Detects and installs NVIDIA drivers on Proxmox host
- **🔧 Smart Container Configuration**: Automatically configures LXC containers for GPU access
- **🧹 Component Cleanup**: Safely removes conflicting NVIDIA components from containers
- **📊 Diagnostic Tools**: Comprehensive diagnostics and testing
- **🔢 Multi-Container Support**: Configure multiple containers at once
- **📈 nvtop Integration**: Easy installation of GPU monitoring tool
- **🐳 Docker Stack**: Complete Docker environment with GPU support
- **🌐 Portainer CE**: Web-based container management
- **⚡ One-Line Installation**: Fast deployment with single command

## 📋 Requirements

- Proxmox VE 7.x or higher
- NVIDIA GPU with compatible drivers
- LXC containers (tested with Ubuntu/Debian)
- Internet connection for driver installation
- Root access

## 🚀 Quick Installation

### Latest Version (v2.1) - One-Line Install (Recommended):
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rafaelfmuniz/proxmox-nvidia-lxc/main/nvidia-lxc-one-line.sh)"
```

### Specific Version Installation:

| Version | Features | Command |
|---------|----------|---------|
| **v2.1** | 🆕 Docker Stack + GPU Support | `bash -c "$(curl -fsSL https://raw.githubusercontent.com/rafaelfmuniz/proxmox-nvidia-lxc/v2.1/nvidia-lxc-one-line.sh)"` |
| **v2.0** | One-Line Install Fixed | `bash -c "$(curl -fsSL https://raw.githubusercontent.com/rafaelfmuniz/proxmox-nvidia-lxc/v2.0/nvidia-lxc-one-line.sh)"` |
| **v1.0** | Traditional Method | `wget https://raw.githubusercontent.com/rafaelfmuniz/proxmox-nvidia-lxc/v1.0/nvidia-lxc-setup.sh && chmod +x nvidia-lxc-setup.sh && ./nvidia-lxc-setup.sh` |

### Traditional Download Method:
```bash
# Download the script
wget https://raw.githubusercontent.com/rafaelfmuniz/proxmox-nvidia-lxc/main/nvidia-lxc-setup.sh

# Make it executable
chmod +x nvidia-lxc-setup.sh

# Run the script
./nvidia-lxc-setup.sh
```

## 📖 Usage Guide

### Main Menu Options

1. **🔧 Configure NVIDIA GPU** - Full GPU passthrough setup for selected containers
2. **🧹 Clean NVIDIA Configurations** - Remove GPU passthrough from containers
3. **✅ Test GPU in Containers** - Verify GPU functionality and access
4. **📊 Install nvtop** - GPU monitoring and performance tool
5. **🐳 Install Docker Stack with GPU Support** - 🆕 Complete Docker environment setup
6. **🔍 Complete Container Diagnosis** - Detailed system and GPU diagnostics
7. **🚪 Exit** - Close the script

### Docker Stack Installation (v2.1+)

When you choose option 5, you get:

**📦 Installation Options:**
- **Full Stack**: Docker + Docker Compose + Portainer CE
- **Docker Only**: Just the Docker engine
- **Docker + Compose**: Engine and orcheration tools

**🎯 What Gets Installed:**
- ✅ Docker CE with NVIDIA runtime
- ✅ Docker Compose for orchestration
- ✅ Portainer CE web management
- ✅ NVIDIA Container Toolkit
- ✅ Automatic GPU configuration for Docker

**🌐 Portainer Access:**
After installation, the script displays:
```
🎉 PORTAINER INSTALLATION COMPLETE!
🌐 Portainer Web UI:
   HTTPS: https://[CONTAINER_IP]:9443
   HTTP:  http://[CONTAINER_IP]:9000
```

## 🐳 Docker GPU Usage Examples

After Docker stack installation, run GPU-enabled containers:

```bash
# Test GPU access
docker run --rm --gpus all nvidia/cuda:11.0-base nvidia-smi

# Run with specific GPU count
docker run --rm --gpus 2 your-ai-app

# Use all GPUs
docker run --rm --gpus all your-gpu-app

# With Docker Compose
docker-compose up -d
```

## 🔧 Manual Configuration (Advanced)

If you need manual setup, the script handles:

- **Device Passthrough**: `/dev/nvidia*` devices
- **Library Mapping**: Essential NVIDIA libraries
- **CGroup Permissions**: Proper device access rights
- **Runtime Configuration**: Docker NVIDIA runtime setup

## 🛠 Troubleshooting

### Common Issues:

1. **GPU not detected in container**:
   - Run option 1 first to configure GPU passthrough
   - Check host drivers with `nvidia-smi`

2. **Docker GPU access fails**:
   - Ensure NVIDIA Container Toolkit is installed
   - Verify runtime: `docker info | grep -i runtime`

3. **Portainer not accessible**:
   - Check firewall settings
   - Verify container IP address
   - Ensure ports 9443/9000 are open

### Diagnostic Tools:
- Use option 6 for complete system diagnosis
- Check container logs with `pct enter CTID`
- Verify GPU access with `nvidia-smi` in container

## 📁 File Structure

```
proxmox-nvidia-lxc/
├── nvidia-lxc-setup.sh          # Traditional installation script
├── nvidia-lxc-one-line.sh       # One-line installation script (v2.0+)
└── README.md                    # This documentation
```

## 🤝 Contributing

Contributions are welcome! Please feel free to submit pull requests or open issues for:

- 🐛 Bug reports
- 💡 Feature requests
- 📖 Documentation improvements
- 🔧 Code optimizations

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🔗 Links

- **📚 Documentation**: [GitHub Repository](https://github.com/rafaelfmuniz/proxmox-nvidia-lxc)
- **🐛 Report Issues**: [Issues Page](https://github.com/rafaelfmuniz/proxmox-nvidia-lxc/issues)
- **💬 Get Support**: [Create Issue](https://github.com/rafaelfmuniz/proxmox-nvidia-lxc/issues/new)

## 🏷 Version History

| Version | Date | Features |
|---------|------|----------|
| **v2.1** | Current | Docker Stack, Portainer, NVIDIA Container Toolkit |
| **v2.0** | Previous | One-line installation fix, improved error handling |
| **v1.0** | Initial | Basic GPU passthrough, container configuration |

---

**⭐ If this project helped you, please consider giving it a star on GitHub!**

---

## 💡 Pro Tips

- 🔄 **Always backup** your container configurations before making changes
- 🧪 **Test in staging** before production deployment
- 📊 **Monitor performance** with nvtop after installation
- 🔒 **Secure your Portainer** instance with strong passwords
- 💾 **Keep drivers updated** for best performance and compatibility

## 🆘 Need Help?

1. Check the troubleshooting section above
2. Review closed issues on GitHub
3. Create a new issue with detailed information about your setup and problem

**Happy GPU Computing!** 🎮🚀
