#!/usr/bin/env python3
"""
Debian Optional Packages Setup

This script allows users to install optional packages.
"""

import os
import sys
import re
import subprocess
import datetime
import logging
from typing import List, Dict, Tuple, Union

# Setup logging
LOG_FILE = "optional-packages.log"

# Custom formatter that doesn't show timestamp and level for console output
class CustomFormatter(logging.Formatter):
    def format(self, record):
        if isinstance(record.args, dict) and record.args.get('color', False):
            # For messages marked with color=True, keep the ANSI color codes
            return record.getMessage()
        return record.getMessage()

# Standard formatter for file logs (with timestamps)
file_formatter = logging.Formatter("%(asctime)s - %(levelname)s - %(message)s")
console_formatter = CustomFormatter()

# Set up handlers
file_handler = logging.FileHandler(LOG_FILE)
file_handler.setFormatter(file_formatter)

console_handler = logging.StreamHandler(sys.stdout)
console_handler.setFormatter(console_formatter)

# Configure logger
logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)
file_handler.setLevel(logging.DEBUG)
console_handler.setLevel(logging.INFO)
logger.addHandler(file_handler)
logger.addHandler(console_handler)

# Color formatting helpers
def blue(text):
    return f"\033[1;34m{text}\033[0m"

def green(text):
    return f"\033[1;32m{text}\033[0m"

def red(text):
    return f"\033[1;31m{text}\033[0m"

def yellow(text):
    return f"\033[1;33m{text}\033[0m"

def cyan(text):
    return f"\033[1;36m{text}\033[0m"

def magenta(text):
    return f"\033[1;35m{text}\033[0m"

class DebianSetup:
    def __init__(self):
        self.error_flag = False

    def run(self):
        """Main execution function"""
        try:
            logger.info(f"Starting optional packages setup at {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
            logger.info(f"{blue('Starting optional packages setup...')}", {'color': True})

            # Install selected packages
            self.install_packages()

            # Finish up
            self.finalize_script()

        except Exception as e:
            self.error_flag = True
            logger.error(f"Error in main execution: {str(e)}", exc_info=True)
            sys.exit(1)

    def run_command(self, command: Union[str, List[str]],
                   shell: bool = False,
                   check: bool = True) -> Tuple[int, str, str]:
        """Run a command and return return code, stdout, and stderr"""
        cmd_str = command if isinstance(command, str) else " ".join(command)
        logger.debug(f"Executing command: '{cmd_str}', shell={shell}, check={check}")

        if isinstance(command, str) and not shell:
            command = command.split()
            logger.debug(f"Split command into: {command}")

        try:
            start_time = datetime.datetime.now()
            logger.debug(f"Command execution started at {start_time.strftime('%Y-%m-%d %H:%M:%S.%f')}")

            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                shell=shell
            )
            stdout, stderr = process.communicate()
            returncode = process.returncode

            end_time = datetime.datetime.now()
            execution_time = (end_time - start_time).total_seconds()
            logger.debug(f"Command execution completed in {execution_time:.4f} seconds with return code {returncode}")

            # Log stdout/stderr at debug level (truncated if too long)
            if stdout:
                log_stdout = (stdout[:500] + '... [truncated]') if len(stdout) > 500 else stdout
                logger.debug(f"Command stdout: {log_stdout}")
            if stderr:
                log_stderr = (stderr[:500] + '... [truncated]') if len(stderr) > 500 else stderr
                logger.debug(f"Command stderr: {log_stderr}")

            if check and returncode != 0:
                logger.error(f"Command failed: {cmd_str}")
                logger.error(f"Error: {stderr.strip()}")
                logger.debug(f"Failed command details - return code: {returncode}, execution time: {execution_time:.4f}s")

            return returncode, stdout.strip(), stderr.strip()
        except Exception as e:
            logger.error(f"Exception running command {cmd_str}: {str(e)}")
            logger.debug(f"Command exception details: {type(e).__name__}, {str(e)}")
            logger.debug(f"Exception traceback:", exc_info=True)
            return 1, "", str(e)

    def is_installed(self, package: str) -> bool:
        """Check if a package is installed using dpkg"""
        returncode, stdout, _ = self.run_command(f"dpkg -l {package}", shell=True, check=False)
        # Check if package exists in dpkg database AND has "ii" status (properly installed)
        return returncode == 0 and any(line.strip().startswith("ii") for line in stdout.split("\n"))

    def setup_docker_repository(self):
        """Set up Docker repository"""
        logger.info("Setting up Docker repository...")

        # Setup keyrings directory
        self.run_command("install -m 0755 -d /etc/apt/keyrings", shell=True)

        # Add Docker's GPG key
        if not os.path.exists("/etc/apt/keyrings/docker.gpg"):
            logger.info("Adding Docker's official GPG key...")
            curl_cmd = f"curl -fsSL https://download.docker.com/linux/debian/gpg"
            gpg_cmd = f"gpg --dearmor -o /etc/apt/keyrings/docker.gpg"

            self.run_command(
                f"{curl_cmd} | {gpg_cmd}",
                shell=True
            )
            self.run_command("chmod a+r /etc/apt/keyrings/docker.gpg", shell=True)

        # Add Docker repository
        logger.info("Adding Docker repository to apt sources...")
        codename_cmd = ". /etc/os-release && echo \"$VERSION_CODENAME\""
        _, codename, _ = self.run_command(codename_cmd, shell=True)

        arch_cmd = "dpkg --print-architecture"
        _, arch, _ = self.run_command(arch_cmd, shell=True)

        docker_repo = f"deb [arch={arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian {codename} stable"

        with open("/etc/apt/sources.list.d/docker.list", "w") as f:
            f.write(docker_repo + "\n")

        # Update apt
        self.run_command("apt update", shell=True)

    def display_package_menu(self, packages, docker_pkgs):
        """Display a simple command-line menu for package selection"""
        print("\nPackage Selection Menu")
        print("----------------------")
        print("Available packages:")

        for i, pkg in enumerate(packages, 1):
            print(f"{i}) {pkg}")

        print("\nEnter package numbers to install (comma-separated, e.g., '1,3,5')")
        print("Type 'all' to select all packages or 'none' to select none")

        selection = input("Your selection: ").strip().lower()

        selected_indices = set()
        if selection == 'all':
            selected_indices = set(range(len(packages)))
        elif selection != 'none':
            try:
                for num in selection.split(','):
                    idx = int(num.strip()) - 1
                    if 0 <= idx < len(packages):
                        selected_indices.add(idx)
            except ValueError:
                print("Invalid selection format. Please use numbers separated by commas.")
                return self.display_package_menu(packages, docker_pkgs)

        # Process selections into package dict
        result = {}
        docker_item_index = packages.index("docker") if "docker" in packages and self.docker_available else None
        docker_selected = docker_item_index is not None and docker_item_index in selected_indices

        for i, pkg in enumerate(packages):
            if i in selected_indices:
                if pkg == "docker":
                    # Mark all docker packages as selected
                    for docker_pkg in docker_pkgs:
                        result[docker_pkg] = True
                else:
                    result[pkg] = True

        # Show selected packages for confirmation
        print("\nSelected packages:")
        selected_pkgs = [pkg for pkg, selected in result.items() if selected]
        if selected_pkgs:
            for pkg in selected_pkgs:
                print(f"- {pkg}")
        else:
            print("- None")

        # Proceed immediately without requiring confirmation
        return result

    def install_packages(self):
        """Install selected packages"""
        # Base packages list (excluding critical packages and curl which should already be installed)
        pkgs = [
            "1password-cli",
            "bitwarden-cli",
            "certbot",
            "cmake",
            "cockpit",
            "fail2ban",
            "fdupes",
            "ffmpeg",
            "nginx",
            "nodejs",
            "npm",
            "nvm",
            "pandoc",
            "rclone",
            "timeshift",
        ]

        # Check if Docker is available and add Docker packages
        self.docker_available = False
        docker_pkgs = []
        _, apt_cache_output, _ = self.run_command("apt-cache policy docker-ce", shell=True, check=False)

        if "Candidate:" in apt_cache_output:
            self.docker_available = True
            docker_pkgs = [
                "containerd.io",
                "docker-buildx-plugin",
                "docker-ce",
                "docker-ce-cli",
                "docker-compose-plugin",
            ]
            # If Docker is available, add "docker" to the package list rather than individual packages
            pkgs.append("docker")

        # Add Plex as an option regardless of whether it's in repositories
        pkgs.append("plex")

        # Setup Docker repository
        self.setup_docker_repository()

        # Sort packages alphabetically
        pkgs.sort()

        # Display interactive menu for package selection
        logger.info("Displaying package selection menu...")
        selected_packages_dict = self.display_package_menu(pkgs, docker_pkgs)

        # Process selection
        if selected_packages_dict is None:
            logger.info("Package selection was cancelled.")
            selected_pkgs = []
        else:
            selected_pkgs = [pkg for pkg, selected in selected_packages_dict.items() if selected]
            logger.info(f"Selected {len(selected_pkgs)} packages for installation.")

        # Install selected packages
        for pkg in selected_pkgs:
            if pkg == "plex":
                # Handle Plex Media Server installation
                if not self.is_installed("plexmediaserver"):
                    logger.info("Installing Plex Media Server...")

                    # Add Plex repository (with minimal output)
                    logger.info("Adding Plex repository...")
                    self.run_command("curl -fsSL https://downloads.plex.tv/plex-keys/PlexSign.key | gpg --dearmor | tee /usr/share/keyrings/plex.gpg > /dev/null", shell=True, check=False)
                    self.run_command("echo \"deb [signed-by=/usr/share/keyrings/plex.gpg] https://downloads.plex.tv/repo/deb public main\" | tee /etc/apt/sources.list.d/plexmediaserver.list > /dev/null", shell=True, check=False)

                    # Update package list and install Plex
                    self.run_command("apt update > /dev/null", shell=True, check=False)
                    self.run_command("apt install -y plexmediaserver", shell=True, check=False)

                    # Enable and start Plex Media Server
                    self.run_command("systemctl enable plexmediaserver", shell=True, check=False)
                    self.run_command("systemctl start plexmediaserver", shell=True, check=False)
                else:
                    logger.info("Plex Media Server is already installed, skipping.")
            elif pkg == "bitwarden-cli":
                # Handle Bitwarden CLI installation
                logger.info("Installing Bitwarden CLI...")
                # First install build-essential package
                if not self.is_installed("build-essential"):
                    logger.info("Installing build-essential package for Bitwarden CLI...")
                    self.run_command("apt install -y build-essential", shell=True, check=False)

                # Make sure npm is installed
                if not self.is_installed("npm"):
                    logger.info("Installing npm for Bitwarden CLI...")
                    self.run_command("apt install -y npm", shell=True, check=False)

                # Install Bitwarden CLI using npm
                logger.info("Installing Bitwarden CLI using npm...")
                self.run_command("npm install -g @bitwarden/cli", shell=True, check=False)
                logger.info("Bitwarden CLI installation completed.")
            elif pkg == "1password-cli":
                # Handle 1Password CLI installation
                logger.info("Installing 1Password CLI...")

                # Update system packages
                self.run_command("apt update", shell=True, check=False)

                # Install required dependencies
                self.run_command("apt install -y gnupg2 apt-transport-https ca-certificates software-properties-common", shell=True, check=False)

                # Add the GPG key for the 1Password APT repository (with minimal output)
                self.run_command("curl -fsSL https://downloads.1password.com/linux/keys/1password.asc | gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg", shell=True, check=False)

                # Add the 1Password APT repository (with minimal output)
                self.run_command("echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/amd64 stable main\" | tee /etc/apt/sources.list.d/1password.list > /dev/null", shell=True, check=False)

                # Add the debsig-verify policy for verifying package signatures (with minimal output)
                self.run_command("mkdir -p /etc/debsig/policies/AC2D62742012EA22/", shell=True, check=False)
                self.run_command("curl -fsSL https://downloads.1password.com/linux/debian/debsig/1password.pol | tee /etc/debsig/policies/AC2D62742012EA22/1password.pol > /dev/null", shell=True, check=False)
                self.run_command("mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22/", shell=True, check=False)
                self.run_command("curl -fsSL https://downloads.1password.com/linux/keys/1password.asc | gpg --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg", shell=True, check=False)

                # Update package list and install 1Password CLI
                self.run_command("apt update > /dev/null && apt install -y 1password-cli", shell=True, check=False)
                logger.info("1Password CLI installation completed.")
            elif pkg == "nvm":
                # Handle NVM installation via apt
                logger.info("Installing NVM (Node Version Manager)...")
                self.run_command("apt install -y nvm", shell=True, check=False)
                logger.info("NVM installation completed.")
            elif not self.is_installed(pkg):
                logger.info(f"Installing {pkg}...")
                self.run_command(f"apt install -y {pkg}", shell=True, check=False)
            else:
                logger.info(f"{pkg} is already installed, skipping.")

    def finalize_script(self):
        """Final steps and summary"""
        logger.info("-" * 40)
        logger.info(f"Script completed at {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

        if self.error_flag:
            logger.error(f"{red('ERROR: There were errors during script execution.')}", {'color': True})
            logger.error(f"Please check the log file at {LOG_FILE} for details.")
            sys.exit(1)
        else:
            logger.info(f"{green('SUCCESS: Optional packages configured successfully.')}", {'color': True})
            logger.info(f"Log file is available at {LOG_FILE}")
            sys.exit(0)

if __name__ == "__main__":
    setup = DebianSetup()
    setup.run()