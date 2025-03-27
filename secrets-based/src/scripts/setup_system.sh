#!/bin/bash

# setup_system.sh - Sets up basic system configuration
# This script is designed to be run during preseed late_command

set -e

# Source network configuration if available
if [ -f /usr/local/etc/network_config.sh ]; then
  source /usr/local/etc/network_config.sh
else
  echo "Error: network_config.sh not found. Using fallback configuration."
  username="user"
fi

# Get username or use default
USERNAME="${username:-user}"
echo "Using username: $USERNAME for system setup"

# Set up sudo access
echo "$USERNAME ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USERNAME
chmod 440 /etc/sudoers.d/$USERNAME

# Create user's home directory structure if needed
mkdir -p /home/$USERNAME
chown -R $USERNAME:$USERNAME /home/$USERNAME

# Set up bash_profile for the user
echo 'if [ -f /etc/systemd/system/getty@tty1.service.d/autologin.conf ]; then sudo rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf; sudo systemctl daemon-reload; fi' >> /home/$USERNAME/.bash_profile
chown $USERNAME:$USERNAME /home/$USERNAME/.bash_profile

# Run system updates
apt-get update || true
apt-get upgrade -y || true

echo "Basic system configuration completed."