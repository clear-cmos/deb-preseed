#!/bin/bash

# setup_optional_packages.sh - Install optional packages with interactive selection
# Using whiptail for package selection

# Setup logging
LOG_FILE="/var/log/optional-packages.log"

# Check if already completed
FLAG_FILE="$HOME/.optional_packages_completed"
if [ -f "$FLAG_FILE" ]; then
    echo "Optional packages setup already completed." | tee -a "$LOG_FILE"
    exit 0
fi

# Check sudo privileges
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo." | tee -a "$LOG_FILE"
    exit 1
fi

# Color formatting helpers
blue() { echo -e "\033[1;34m$1\033[0m"; }
green() { echo -e "\033[1;32m$1\033[0m"; }
red() { echo -e "\033[1;31m$1\033[0m"; }
yellow() { echo -e "\033[1;33m$1\033[0m"; }
cyan() { echo -e "\033[1;36m$1\033[0m"; }
magenta() { echo -e "\033[1;35m$1\033[0m"; }

# Color reset
reset="\033[0m"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    echo "$1"
}

# Initialize script
log "Starting optional packages setup"

# Function to run a command and handle errors
run_command() {
    local cmd="$1"
    log "Running command: $cmd"
    
    output=$(eval "$cmd" 2>&1)
    local status=$?
    
    if [ $status -ne 0 ]; then
        log "$(red "Error executing command: $cmd")"
        log "Exit code: $status"
        log "Output: $output"
        return 1
    fi
    
    log "Command executed successfully"
    return 0
}

# Check if a package is installed
is_installed() {
    local package="$1"
    dpkg -l "$package" 2>/dev/null | grep -q "^ii"
    return $?
}

# Install 1Password CLI
install_1password_cli() {
    log "Installing 1Password CLI..."
    
    # Install dependencies
    run_command "apt install -y gnupg2 apt-transport-https ca-certificates software-properties-common"
    
    # Add GPG key
    run_command "curl -fsSL https://downloads.1password.com/linux/keys/1password.asc | gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg"
    
    # Add repository
    run_command "echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/amd64 stable main\" | tee /etc/apt/sources.list.d/1password.list > /dev/null"
    
    # Add debsig-verify policy
    run_command "mkdir -p /etc/debsig/policies/AC2D62742012EA22/"
    run_command "curl -fsSL https://downloads.1password.com/linux/debian/debsig/1password.pol | tee /etc/debsig/policies/AC2D62742012EA22/1password.pol > /dev/null"
    run_command "mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22/"
    run_command "curl -fsSL https://downloads.1password.com/linux/keys/1password.asc | gpg --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg"
    
    # Install 1Password CLI
    run_command "apt update"
    run_command "apt install -y 1password-cli"
}

# Install Bitwarden CLI
install_bitwarden_cli() {
    log "Installing Bitwarden CLI..."
    
    # Install dependencies
    if ! is_installed "build-essential"; then
        log "Installing build-essential package for Bitwarden CLI..."
        run_command "apt install -y build-essential"
    fi
    
    # Make sure npm is installed
    if ! is_installed "npm"; then
        log "Installing npm for Bitwarden CLI..."
        run_command "apt install -y npm"
    fi
    
    # Install Bitwarden CLI using npm
    run_command "npm install -g @bitwarden/cli"
}

# Install NVM (Node Version Manager)
install_nvm() {
    log "Installing NVM (Node Version Manager)..."
    
    # Get the latest NVM version
    local NVM_VERSION
    NVM_VERSION=$(curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [ -z "$NVM_VERSION" ]; then
        log "$(red "Failed to get latest NVM version. Using default v0.39.7")"
        NVM_VERSION="v0.39.7"
    fi
    
    # Install NVM
    run_command "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh | bash"
    
    # Setup for current user
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    
    # Setup NVM for the current non-root user
    USER_HOME=$(getent passwd ${SUDO_USER:-$USER} | cut -d: -f6)
    if [ -n "$USER_HOME" ] && [ "$USER_HOME" != "/root" ]; then
        log "Setting up NVM for user $(cyan "${SUDO_USER:-$USER}")"
        
        # Make sure .nvm directory exists and has correct permissions
        if [ ! -d "$USER_HOME/.nvm" ]; then
            mkdir -p "$USER_HOME/.nvm"
            chown -R ${SUDO_USER:-$USER}:${SUDO_USER:-$USER} "$USER_HOME/.nvm"
        fi
        
        # Add NVM setup to user's .bashrc if not already there
        if ! grep -q 'export NVM_DIR=' "$USER_HOME/.bashrc"; then
            cat >> "$USER_HOME/.bashrc" << 'EOF'

# NVM Setup
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
EOF
            chown ${SUDO_USER:-$USER}:${SUDO_USER:-$USER} "$USER_HOME/.bashrc"
        fi
    fi
    
    # Setup NVM for root user as well
    if [ ! -d "/root/.nvm" ]; then
        mkdir -p "/root/.nvm"
    fi
    
    # Add NVM setup to root's .bashrc if not already there
    if ! grep -q 'export NVM_DIR=' "/root/.bashrc"; then
        cat >> "/root/.bashrc" << 'EOF'

# NVM Setup
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
EOF
    fi
    
    log "NVM installation completed"
}

# Setup Docker repository
setup_docker_repository() {
    log "Setting up Docker repository..."

    # Setup keyrings directory
    run_command "install -m 0755 -d /etc/apt/keyrings"

    # Add Docker's GPG key
    if [ ! -f "/etc/apt/keyrings/docker.gpg" ]; then
        log "Adding Docker's official GPG key..."
        run_command "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
        run_command "chmod a+r /etc/apt/keyrings/docker.gpg"
    fi

    # Add Docker repository
    log "Adding Docker repository to apt sources..."
    codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    arch=$(dpkg --print-architecture)
    docker_repo="deb [arch=$arch signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $codename stable"

    echo "$docker_repo" > /etc/apt/sources.list.d/docker.list

    # Update apt
    run_command "apt update"
}

# Install Docker
install_docker() {
    log "Installing Docker..."
    
    # Install Docker packages
    run_command "apt install -y containerd.io docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin"
    
    # Enable and start Docker service
    run_command "systemctl enable docker"
    run_command "systemctl start docker"
    
    # Add current user to docker group if not root and if SUDO_USER is defined
    if [ "$EUID" -eq 0 ] && [ -n "$SUDO_USER" ]; then
        log "Adding user $(cyan "$SUDO_USER") to the docker group"
        run_command "usermod -aG docker $SUDO_USER"
        log "$(yellow "Please log out and back in for docker group changes to take effect")"
    fi
}

# Install selected packages
install_packages() {
    # Check if Docker is available and prepare Docker-related variables
    docker_available=false
    apt-cache policy docker-ce >/dev/null 2>&1
    if grep -q "Candidate:" <<< "$(apt-cache policy docker-ce 2>/dev/null)"; then
        docker_available=true
    fi
    
    # Setup Docker repository regardless (to enable docker selection)
    setup_docker_repository
    
    # Define the list of optional packages
    local optional_packages=(
        "1password-cli"
        "bitwarden-cli"
        "certbot"
        "cmake"
        "cockpit"
        "docker"
        "fail2ban"
        "fdupes"
        "ffmpeg"
        "nginx"
        "nodejs"
        "npm"
        "nvm"
        "pandoc"
        "rclone"
        "timeshift"
    )
    
    # Sort optional packages alphabetically
    IFS=$'\n' optional_packages=($(sort <<<"${optional_packages[*]}"))
    unset IFS
    
    # Show package selection menu
    log "Displaying package selection menu..."
    
    # Create a simple number-based menu
    echo -e "\n${blue}Package Selection Menu${reset}"
    echo "----------------------"
    echo -e "${cyan}Available packages:${reset}"
    
    # Display numbered list of packages with descriptions
    local i=1
    local pkg_descriptions=()
    
    for pkg in "${optional_packages[@]}"; do
        local description=""
        case "$pkg" in
            "1password-cli") description="1Password command-line password manager" ;;
            "bitwarden-cli") description="Bitwarden command-line password manager" ;;
            "certbot") description="Let's Encrypt certificate automation tool" ;;
            "cmake") description="Cross-platform, open-source build system" ;;
            "cockpit") description="Web-based server management interface" ;;
            "docker") description="Docker container platform" ;;
            "fail2ban") description="Ban hosts that cause multiple authentication errors" ;;
            "fdupes") description="Finds duplicate files within given directories" ;;
            "ffmpeg") description="Tools for transcoding multimedia files" ;;
            "nginx") description="High-performance HTTP server" ;;
            "nodejs") description="JavaScript runtime built on Chrome's V8 engine" ;;
            "npm") description="Package manager for Node.js" ;;
            "nvm") description="Node Version Manager" ;;
            "pandoc") description="Universal markup converter" ;;
            "rclone") description="Rsync for cloud storage" ;;
            "timeshift") description="System restore utility" ;;
            *) description="$pkg" ;;
        esac
        
        echo -e "${green}$i)${reset} ${yellow}$pkg${reset} - $description"
        pkg_descriptions+=("$description")
        ((i++))
    done
    
    echo -e "\n${cyan}Enter package numbers to install (space-separated, e.g., '1 3 5')${reset}"
    echo -e "${cyan}Type 'all' to select all packages or 'none' to select none${reset}"
    
    # Get user selection
    echo -ne "${yellow}Your selection: ${reset}"
    read -r selection

    selected_packages=""
    
    # Process selection
    if [[ "$selection" == "all" ]]; then
        # Select all packages
        for pkg in "${optional_packages[@]}"; do
            selected_packages+="$pkg "
        done
    elif [[ "$selection" != "none" ]]; then
        # Process space-separated list of numbers
        for num in $selection; do
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#optional_packages[@]}" ]; then
                # Convert number to package name (array is 0-indexed, so subtract 1)
                index=$((num - 1))
                selected_packages+="${optional_packages[$index]} "
            else
                log "Invalid selection: $num - ignoring"
            fi
        done
    fi
    
    # Trim trailing space
    selected_packages=$(echo "$selected_packages" | xargs)
    
    # If no packages were selected
    if [ -z "$selected_packages" ]; then
        echo -e "\n${yellow}No packages selected. Installation complete.${reset}"
        return 0
    fi
    
    # Show selected packages for confirmation
    echo -e "\n${cyan}Selected packages:${reset}"
    for pkg in $selected_packages; do
        echo -e "- ${yellow}$pkg${reset}"
    done
    
    # Process selected packages
    log "User selected the following packages:"
    local install_list=()
    
    # Parse the selected packages
    for pkg in $selected_packages; do
        log "Selected: $pkg"
        install_list+=("$pkg")
    done
    
    # Show confirmation with all packages to be installed
    echo -e "\n${cyan}About to install the following packages:${reset}"
    printf "%s\n" "${install_list[@]}" | sed 's/^/- /'
    echo -e "\n${yellow}Proceed with installation? (y/n)${reset}"
    read -r proceed
    
    if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
        log "User cancelled installation"
        echo -e "${yellow}Installation cancelled.${reset}"
        return 0
    fi
    
    # Install selected packages
    log "Installing packages..."
    
    # Update the package database
    if ! run_command "apt update"; then
        log "$(red "Failed to update package database")"
        return 1
    fi
    
    # Process each package separately for better error handling
    for pkg in "${install_list[@]}"; do
        case "$pkg" in
            "1password-cli")
                install_1password_cli
                ;;
                
            "bitwarden-cli")
                install_bitwarden_cli
                ;;
                
            "docker")
                install_docker
                ;;
                
            "nvm")
                install_nvm
                ;;
                
            *)
                # Regular package installation
                if ! is_installed "$pkg"; then
                    log "Installing $pkg..."
                    if ! run_command "apt install -y $pkg"; then
                        log "$(yellow "Warning: Failed to install $pkg, continuing with other packages")"
                    fi
                else
                    log "$pkg is already installed, skipping."
                fi
                ;;
        esac
    done
    
    return 0
}

# Main function
main() {
    # Install packages
    if install_packages; then
        log "$(green "SUCCESS: Optional packages installed successfully.")"
        # Create completion flag
        touch "$FLAG_FILE"
        echo -e "\n${green}SUCCESS: Optional packages installation completed successfully!${reset}"
    else
        log "$(red "ERROR: There were errors during package installation.")"
        echo -e "\n${red}ERROR: There were errors during package installation.${reset}"
        echo -e "${yellow}Please check the log at $LOG_FILE for details.${reset}"
        exit 1
    fi
}

# Run the main function
main
exit 0