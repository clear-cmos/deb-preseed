#!/bin/bash

# setup_wrapper.sh - Main wrapper script for running all setup scripts
# This script is invoked by the preseed late_command

set -e

echo "Starting main system configuration..."

# Execute system setup script
if [ -f /usr/local/sbin/setup_system.sh ]; then
  echo "Running system setup..."
  bash /usr/local/sbin/setup_system.sh
else
  echo "Error: System setup script not found!"
  exit 1
fi

# Execute SSH setup script
if [ -f /usr/local/sbin/setup_ssh.sh ]; then
  echo "Running SSH setup..."
  bash /usr/local/sbin/setup_ssh.sh
else
  echo "Error: SSH setup script not found!"
  exit 1
fi

# Execute SMB setup script
if [ -f /usr/local/sbin/setup_smb.sh ]; then
  echo "Running SMB shares setup..."
  bash /usr/local/sbin/setup_smb.sh
else
  echo "Error: SMB setup script not found!"
  exit 1
fi

# Execute automatic updates setup script
if [ -f /usr/local/sbin/setup_updates.sh ]; then
  echo "Running automatic updates setup..."
  bash /usr/local/sbin/setup_updates.sh
else
  echo "Error: Automatic updates setup script not found!"
  exit 1
fi

# Execute optional packages setup script
# This is handled during first login by setup_optional_packages.sh
# which is managed by the init.sh script

echo "All configuration scripts completed successfully."
echo "System will reboot to complete installation."