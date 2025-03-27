# Debian Generic Preseed ISO Builder

This tool automates the creation of a customized Debian installation ISO with preseed configuration, making Debian installations unattended and automated.

## Overview

The generic preseed ISO builder creates a Debian installation disc that:

1. Downloads the latest official Debian netinst ISO
2. Modifies it to include a preseed configuration 
3. Adds first-boot scripts that force password changes
4. Creates a bootable installation medium with automated setup

## Prerequisites

- Debian
- Root access or sudo privileges
- Internet connection to download packages and ISO
- Around 1GB free space for ISO creation

## Directory Structure

```
.
├── build-generic.sh                # Main build script
└── src/
    ├── config/
    │   └── preseed.cfg             # Debian automated installation config
    ├── scripts/
    │   ├── base.py                 # System customization script
    │   └── init.sh                 # First boot initialization script
    └── services/
        └── first-boot.service      # Systemd service for first boot
```

## Usage

1. Clone the repository:
   ```
   git clone https://github.com/clear-cmos/debian.git
   cd debian/preseed/generic
   ```

2. Run the build script:
   ```
   sudo ./build-generic.sh
   ```

3. The script will:
   - Install required dependencies
   - Download the latest Debian netinst ISO
   - Create a customized ISO with preseed configuration
   - Generate the output as `debian-[version]-preseed-generic.iso`

## Preseed Configuration

The `preseed.cfg` file includes default settings for:

- Locale and keyboard setup (US English)
- Network configuration via DHCP
- Disk partitioning (automatic, entire disk)
- User creation with default credentials (user/1234, root/1234)
- Package selection (SSH server and essential utilities)
- Post-installation setup that installs first-boot files

> **Important**: The default users have insecure passwords which will be forcibly changed on first boot.

## First Boot Experience

When booting from the created ISO, the installer will:

1. Run through the Debian installation automatically
2. Reboot after installation completes
3. Force password changes for root and user accounts
4. Run the base.py script to configure system settings

## Customization

To customize the preseed ISO:

- Modify `src/config/preseed.cfg` to change installation parameters
- Edit `src/scripts/init.sh` to adjust first-boot behavior
- Update `src/scripts/base.py` to modify post-installation setup

## Security Notes

- Default passwords are insecure and are only meant for initial setup
- The system will force password changes on first boot
- SSH is configured with password authentication enabled initially

## License

This project is licensed under the MIT License.
