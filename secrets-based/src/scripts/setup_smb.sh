#!/bin/bash

# setup_smb.sh - Sets up SMB shares configuration
# This script is designed to be run during preseed late_command

set -e

# Source network configuration if available
if [ -f /usr/local/etc/network_config.sh ]; then
  source /usr/local/etc/network_config.sh
else
  echo "Error: network_config.sh not found. Cannot configure SMB shares."
  exit 1
fi

echo "Setting up CIFS share mounts..."

# Get username or use default
USERNAME="${username:-user}"
echo "Using username: $USERNAME for SMB mounts"

# Iterate through all defined SMB shares
for i in $(seq 1 $NUM_SMB_SHARES); do
  # Get share details from environment variables
  SMB_HOST="$(eval echo \$SMB_HOST_$i)"
  SMB_SHARE="$(eval echo \$SMB_SHARE_$i)"
  SMB_USER="$(eval echo \$SMB_USERNAME_$i)"
  SMB_PASS="$(eval echo \$SMB_PASSWORD_$i)"
  
  echo "Setting up SMB share $i: $SMB_HOST/$SMB_SHARE"
  
  # Create mount point directory
  mkdir -p /mnt/$SMB_SHARE
  chmod 755 /mnt/$SMB_SHARE
  chown $USERNAME:$USERNAME /mnt/$SMB_SHARE
  
  # Create credentials file
  echo "username=$SMB_USER" > /etc/.$SMB_HOST
  echo "password=$SMB_PASS" >> /etc/.$SMB_HOST
  chmod 600 /etc/.$SMB_HOST
  chown root:root /etc/.$SMB_HOST
  
  # Add to fstab
  echo "//$SMB_HOST/$SMB_SHARE /mnt/$SMB_SHARE cifs credentials=/etc/.$SMB_HOST,rw,file_mode=0777,dir_mode=0777,x-gvfs-show,uid=$USERNAME,gid=$USERNAME 0 0" >> /etc/fstab
done

echo "SMB share configuration completed."