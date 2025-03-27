#!/bin/bash

# Get the username from the username environment variable
# If not defined, try to source the network_config.sh which may have been copied by preseed
echo "Starting init.sh - checking for network_config.sh..."

if [ -f /usr/local/etc/network_config.sh ]; then
  echo "Found network_config.sh, sourcing it..."
  cat /usr/local/etc/network_config.sh >> /var/log/init-debug.log
  source /usr/local/etc/network_config.sh
  echo "After sourcing: username=$username" >> /var/log/init-debug.log
else
  echo "Warning: /usr/local/etc/network_config.sh not found" >> /var/log/init-debug.log
  # Check if there's a copy in other locations
  if [ -f /cdrom/src/scripts/network_config.sh ]; then
    echo "Found copy in /cdrom/src/scripts/, copying and sourcing..." >> /var/log/init-debug.log
    cp /cdrom/src/scripts/network_config.sh /usr/local/etc/
    chmod 755 /usr/local/etc/network_config.sh
    source /usr/local/etc/network_config.sh
  else
    echo "No network_config.sh found in alternate locations" >> /var/log/init-debug.log
  fi
fi

# Fall back to default if still not defined
echo "Username before fallback: ${username}" >> /var/log/init-debug.log
USERNAME="${username:-user}"
echo "Using username: $USERNAME" >> /var/log/init-debug.log

PERSISTENT_FLAG="/var/lib/setup-completed"

if [ -f "$PERSISTENT_FLAG" ]; then
  echo "Setup has already been completed. Exiting."

  systemctl disable first-boot.service
  rm -f /etc/systemd/system/first-boot.service

  systemctl restart getty@tty1.service

  exit 0
fi

# Configure autologin for user
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${USERNAME} --noclear %I \$TERM
EOF

# Create disable-autologin script
cat > /usr/local/bin/disable-autologin.sh << 'EOF'
rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
systemctl daemon-reload
rm -f /etc/sudoers.d/disable-autologin
rm -f /usr/local/bin/disable-autologin.sh
EOF

chmod +x /usr/local/bin/disable-autologin.sh

echo "${USERNAME} ALL=(ALL) NOPASSWD: /usr/local/bin/disable-autologin.sh" > /etc/sudoers.d/disable-autologin
chmod 440 /etc/sudoers.d/disable-autologin

# Create user home directory if needed
if [ ! -d "/home/${USERNAME}" ]; then
  mkdir -p "/home/${USERNAME}"
fi

# Set up user's bash_profile
cat > "/home/${USERNAME}/.bash_profile" << 'EOF'
echo "$(date): Starting bash_profile" > ~/debug.log

# Source .bashrc to ensure proper environment setup for NVM and other tools
if [ -f ~/.bashrc ]; then
  echo "$(date): Sourcing .bashrc" >> ~/debug.log
  . ~/.bashrc
fi

if [ -f /usr/local/bin/disable-autologin.sh ]; then
  sudo /usr/local/bin/disable-autologin.sh
else
  echo "$(date): disable-autologin.sh script not found, already removed" >> ~/debug.log
fi

cd ~/
echo "$(date): Current directory: $(pwd)" >> ~/debug.log
echo "$(date): Files in directory:" >> ~/debug.log
ls -la >> ~/debug.log

# Run the setup script, which will self-remove from .bash_profile when done
if [ -f /usr/local/bin/setup_optional_packages.sh ]; then
  echo "$(date): Running setup_optional_packages.sh script" >> ~/debug.log
  sudo /usr/local/bin/setup_optional_packages.sh 2>> ~/debug.log
  echo "$(date): setup_optional_packages.sh exit code: $?" >> ~/debug.log
  
  # Self-modify .bash_profile to remove the script execution section and add a re-sourcing of .bashrc
  echo "$(date): Removing script execution from .bash_profile and adding re-sourcing of .bashrc" >> ~/debug.log
  sed -i '/# Run the setup script/,/^fi$/d' ~/.bash_profile
  
  # Add command to source .bashrc again after script execution
  echo -e "\n# Re-source .bashrc to apply any environment changes made by the script\nif [ -f ~/.bashrc ]; then\n  . ~/.bashrc\nfi" >> ~/.bash_profile
  
  # Source .bashrc immediately to apply changes in current session
  if [ -f ~/.bashrc ]; then
    echo "$(date): Re-sourcing .bashrc after script execution" >> ~/debug.log
    . ~/.bashrc
  fi
  
  echo "$(date): .bash_profile updated to prevent future runs and re-source .bashrc" >> ~/debug.log
else
  echo "$(date): setup_optional_packages.sh script not found" >> ~/debug.log
  # Check if old script exists as fallback (for backward compatibility)
  if [ -f ~/base.py ]; then
    echo "$(date): Found legacy base.py script" >> ~/debug.log
    echo "$(date): Please update to use setup_optional_packages.sh" >> ~/debug.log
  else
    echo "$(date): No setup scripts found in expected locations" >> ~/debug.log
  fi
fi
EOF

chmod +x "/home/${USERNAME}/.bash_profile"
chown ${USERNAME}:${USERNAME} "/home/${USERNAME}/.bash_profile"
chown -R ${USERNAME}:${USERNAME} "/home/${USERNAME}"

# Set up root's bash_profile to source .bashrc
if [ ! -f /root/.bash_profile ]; then
  cat > /root/.bash_profile << 'EOF'
# Source .bashrc to ensure proper environment setup for NVM and other tools
if [ -f ~/.bashrc ]; then
  . ~/.bashrc
fi
EOF
  chmod +x /root/.bash_profile
fi

# Ensure root's .bashrc has NVM configuration
if [ -f /root/.bashrc ]; then
  if ! grep -q "NVM setup" /root/.bashrc; then
    cat >> /root/.bashrc << 'EOF'

# NVM setup
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
EOF
  fi
fi

# Ensure root's .profile sources .bashrc
if [ -f /root/.profile ]; then
  if ! grep -q "bashrc" /root/.profile; then
    cat >> /root/.profile << 'EOF'

# if running bash
if [ -n "$BASH_VERSION" ]; then
    # include .bashrc if it exists
    if [ -f "$HOME/.bashrc" ]; then
        . "$HOME/.bashrc"
    fi
fi
EOF
  fi
fi

# Mark setup as completed
touch "$PERSISTENT_FLAG"

systemctl daemon-reload
systemctl unmask getty@tty1.service
systemctl restart getty@tty1.service
systemctl disable first-boot.service
rm -f /etc/systemd/system/first-boot.service

exit 0