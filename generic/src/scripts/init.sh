#!/bin/bash

PERSISTENT_FLAG="/var/lib/password-changed"

if [ -f "$PERSISTENT_FLAG" ]; then
  echo "Passwords have already been changed. Exiting."

  systemctl disable first-boot.service
  rm -f /etc/systemd/system/first-boot.service

  systemctl restart getty@tty1.service

  exit 0
fi

chvt 1
clear
echo "=== Forcing password changes ==="

while true; do
  echo
  echo "Please set a new root password."
  passwd root && break
  echo "Password change for root failed, please try again."
done

while true; do
  echo
  echo "Please set a new password for 'user'."
  passwd user && break
  echo "Password change for user failed, please try again."
done

echo
echo "Passwords updated successfully."

mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin user --noclear %I \$TERM
EOF

cat > /usr/local/bin/disable-autologin.sh << 'EOF'
rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
systemctl daemon-reload
rm -f /etc/sudoers.d/disable-autologin
rm -f /usr/local/bin/disable-autologin.sh
EOF

chmod +x /usr/local/bin/disable-autologin.sh

echo 'user ALL=(ALL) NOPASSWD: /usr/local/bin/disable-autologin.sh' > /etc/sudoers.d/disable-autologin
chmod 440 /etc/sudoers.d/disable-autologin

if [ ! -d /home/user ]; then
  mkdir -p /home/user
fi

cat > /home/user/.bash_profile << 'EOF'
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
if [ -f ~/base.py ]; then
  echo "$(date): Running Python script" >> ~/debug.log
  python3 ~/base.py 2>> ~/debug.log
  echo "$(date): Python exit code: $?" >> ~/debug.log
  
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
  echo "$(date): Python script not found" >> ~/debug.log
  # Check if script exists in other locations as fallback
  if [ -f /usr/local/bin/base.py ]; then
    echo "$(date): Found script in /usr/local/bin, copying to home directory" >> ~/debug.log
    cp /usr/local/bin/base.py ~/
    chmod 755 ~/base.py
    echo "$(date): Running Python script from copied location" >> ~/debug.log
    python3 ~/base.py 2>> ~/debug.log
    echo "$(date): Python exit code: $?" >> ~/debug.log
    
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
    echo "$(date): Script not found in fallback locations" >> ~/debug.log
  fi
fi
EOF

chmod +x /home/user/.bash_profile
chown user:user /home/user/.bash_profile
chown -R user:user /home/user

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

touch "$PERSISTENT_FLAG"

systemctl daemon-reload

systemctl unmask getty@tty1.service

systemctl restart getty@tty1.service

systemctl disable first-boot.service

rm -f /etc/systemd/system/first-boot.service

exit 0