# Debian Preseed ISO Builders

A collection of tools for creating customized Debian installation ISOs with automated configuration using preseed files. This repository provides two approaches to building unattended Debian installers:

1. **Generic Preseed Builder**: Simple approach with default credentials and forced password changes on first boot
2. **Secrets-Based Preseed Builder**: Advanced approach using 1Password for secure credential management and network discovery

## Repository Structure

```
.
├── generic/                     # Generic preseed ISO builder
│   ├── build-generic.sh         # Main build script
│   └── src/                     # Source files
│       ├── config/              # Preseed configuration
│       ├── scripts/             # Installation scripts
│       └── services/            # Systemd services
│
└── secrets-based/               # 1Password integrated preseed builder
    ├── build-secrets-based.sh   # Main build script
    ├── secrets-builder.sh       # 1Password vault configuration
    └── src/                     # Source files
        ├── config/              # Preseed configuration
        ├── scripts/             # Installation and setup scripts
        └── services/            # Systemd services
```

## Generic Preseed Builder

The generic approach provides a simple way to create automated Debian installers:

- Downloads the latest Debian netinst ISO
- Embeds preseed configuration for automated installation
- Adds first-boot scripts that force password changes
- Sets up basic system configuration

### Usage

```bash
cd generic
sudo ./build-generic.sh
```

## Secrets-Based Preseed Builder

The secrets-based approach provides enhanced security and customization:

- Stores credentials securely in 1Password
- Discovers and configures network shares
- Sets up SSH with secure defaults
- Configures unattended security updates
- Creates an encrypted ISO for secure distribution

### Usage

```bash
cd secrets-based
./secrets-builder.sh     # Configure 1Password vault
./build-secrets-based.sh # Build the customized ISO
```

## Common Features

Both approaches offer:

- Fully automated Debian installations
- First-boot configuration with systemd services
- Post-installation system setup
- Customizable configurations

## Prerequisites

- Debian-based system with sudo privileges
- Internet connection for downloading packages and ISOs
- Around 1GB free space for ISO creation
- For secrets-based approach: 1Password CLI and additional tools

## Security Considerations

- The generic approach uses default passwords that are changed on first boot
- The secrets-based approach stores credentials in 1Password and encrypts the final ISO
- Both approaches configure SSH and system security settings

## License

This project is licensed under the MIT License.