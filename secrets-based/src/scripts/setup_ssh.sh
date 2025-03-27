#!/bin/bash

# setup_ssh.sh - Sets up SSH server and keys
# This script is designed to be run during preseed late_command

set -e

# Source network configuration if available
if [ -f /usr/local/etc/network_config.sh ]; then
  source /usr/local/etc/network_config.sh
else
  echo "Error: network_config.sh not found. Cannot configure SSH properly."
  exit 1
fi

# Get username or use default
USERNAME="${username:-user}"
echo "Using username: $USERNAME for SSH setup"

# SSH authorized key should be in network_config.sh
SSH_AUTHORIZED_KEY="${ssh_authorized_key:-# No SSH key was provided. Add your public key here.}"

echo "Configuring SSH server..."

# Configure SSH server with secure settings
cat > /etc/ssh/sshd_config << EOF
Include /etc/ssh/sshd_config.d/*.conf
Port 22
Protocol 2
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers $USERNAME
EOF

echo "Setting up SSH keys..."

# Create user's SSH directory
mkdir -p /home/$USERNAME/.ssh
chmod 700 /home/$USERNAME/.ssh

# Generate SSH key for user
ssh-keygen -t rsa -N "" -f /home/$USERNAME/.ssh/id_rsa

# Generate SSH key for root
mkdir -p /root/.ssh
ssh-keygen -t rsa -N "" -f /root/.ssh/id_rsa
chmod 700 /root/.ssh

# Add authorized SSH key to user account
echo "$SSH_AUTHORIZED_KEY" > /home/$USERNAME/.ssh/authorized_keys
chmod 600 /home/$USERNAME/.ssh/authorized_keys
chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh

echo "SSH configuration completed."