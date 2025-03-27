#!/bin/bash

# setup_updates.sh - Sets up automatic security updates
# This script is designed to be run during preseed late_command

set -e

echo "Setting up automatic security updates..."

# Configure unattended-upgrades
echo "Configuring unattended-upgrades..."

# Write auto-upgrades configuration
cat > /etc/apt/apt.conf.d/20auto-upgrades << EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Download-Upgradeable-Packages "1";
EOF

# Check if 50unattended-upgrades exists and modify it
if [ -f /etc/apt/apt.conf.d/50unattended-upgrades ]; then
  # Enable security updates if not already enabled
  sed -i 's|//\s*"origin=Debian,codename=\${distro_codename},label=Debian-Security";|"origin=Debian,codename=${distro_codename},label=Debian-Security";|g' /etc/apt/apt.conf.d/50unattended-upgrades
  
  # Configure automatic reboot (disabled)
  if grep -q "Unattended-Upgrade::Automatic-Reboot" /etc/apt/apt.conf.d/50unattended-upgrades; then
    sed -i 's|Unattended-Upgrade::Automatic-Reboot "true";|Unattended-Upgrade::Automatic-Reboot "false";|g' /etc/apt/apt.conf.d/50unattended-upgrades
  else
    echo 'Unattended-Upgrade::Automatic-Reboot "false";' >> /etc/apt/apt.conf.d/50unattended-upgrades
  fi
else
  # Create full configuration file if it doesn't exist
  echo "Creating full unattended-upgrades configuration..."
  cat > /etc/apt/apt.conf.d/50unattended-upgrades << EOF
Unattended-Upgrade::Allowed-Origins {
    "origin=Debian,codename=\${distro_codename},label=Debian-Security";
};

Unattended-Upgrade::Package-Blacklist {
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
fi

# Enable and restart service
echo "Enabling unattended-upgrades service..."
systemctl enable unattended-upgrades
systemctl restart unattended-upgrades

echo "Automatic updates configuration completed."