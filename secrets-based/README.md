# Secrets-Based Debian Preseed ISO Builder

This directory contains scripts and configuration files for creating a customized Debian installation ISO with automated configuration based on secrets stored in a password manager (1Password).

## Overview

The secrets-based approach addresses several key challenges in managing automated Debian installations:

1. **Secure Credential Management**: Stores sensitive information like passwords and SSH keys in 1Password.
2. **Network Discovery**: Automatically discovers and configures network shares during installation.
3. **Customized Setup**: Creates a tailored Debian installation with predefined packages and configurations.
4. **Encryption**: Encrypts the final ISO for secure storage.

## Prerequisites

- A Linux system (Debian-based preferred) with sudo privileges
- 1Password CLI (`op`) installed and configured
- Required packages: `xorriso`, `isolinux`, `grub-efi-amd64-bin`, `curl`, `jq`

For network discovery:
- `nmap`
- `smbclient` (for SMB share detection)
- `nfs-common` (for NFS share detection) - note: no testing done with NFS shares yet

## Setup Process

### 1. Configure the 1Password Vault

Run the `secrets-builder.sh` script to set up the 1Password vault with required credentials:

```bash
./secrets-builder.sh
```

This script will:
- Create a "Debian Preseed" vault in 1Password (if it doesn't exist)
- Scan your local network for available hosts and shares
- Guide you through configuring:
  - Root password
  - User account details
  - SSH authorized keys
  - Network shares for auto-mounting

### 2. Build the Custom ISO

After setting up the 1Password vault, build the custom Debian ISO:

```bash
./build-secrets-based.sh
```

This script will:
- Authenticate with 1Password and retrieve credentials
- Download the latest Debian netinst ISO (if not already present)
- Customize the ISO with preseed configuration
- Inject scripts for post-installation setup
- Create an encrypted ISO file

## Script Details

### secrets-builder.sh

- Scans the local network for hosts and services
- Detects SMB and NFS shares
- Creates/updates the following items in 1Password:
  - "Debian Preseed" - contains root/user credentials and SSH keys
  - "SMB Shares" - contains network share configuration
  - "Network Configuration" - contains discovered hosts and their details

### build-secrets-based.sh

- Retrieves secrets from 1Password
- Customizes the preseed.cfg file with the retrieved secrets
- Injects custom scripts for post-installation setup
- Creates an encrypted ISO for secure distribution

## Installation Components

### Preseed Configuration

The `src/config/preseed.cfg` file contains the Debian installer automated configuration.

### Setup Scripts

- **setup_system.sh**: Configures basic system settings and sudo access
- **setup_ssh.sh**: Sets up SSH server with secure defaults and authorized keys
- **setup_smb.sh**: Configures automatic mounting of network shares
- **setup_updates.sh**: Sets up unattended security updates
- **setup_optional_packages.sh**: Interactive menu for installing additional packages
- **setup_wrapper.sh**: Main script that calls all other setup scripts
- **init.sh**: Runs on first boot to complete post-installation tasks

### First Boot Service

The `src/services/first-boot.service` systemd unit file executes `init.sh` on the first boot after installation.

## ISO Output

The build process creates an encrypted ISO file with a name like:
`debian-12.10.0-preseed-secrets-based.iso.enc`

To decrypt and use:
```bash
openssl enc -aes-256-cbc -d -in debian-12.10.0-preseed-secrets-based.iso.enc -out debian-12.10.0-preseed-secrets-based.iso -pbkdf2
```

## Security Features

- Credentials fetched from 1Password
- Encryption of the final ISO for secure storage
- Secure SSH configuration with disabled root login
- Automatic security updates enabled by default
- Optional SSH key authentication

## Notes

- Requires the target system to have network access during installation
- The `setup_optional_packages.sh` script provides an interactive menu for additional packages on first login

## License

This project is licensed under the MIT License.
