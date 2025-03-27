#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Requesting elevated privileges (enter password when prompted)..."
  sudo -v
  
  (while true; do sudo -v; sleep 50; done) &
  SUDO_KEEP_ALIVE_PID=$!
  
  cleanup() {
    kill $SUDO_KEEP_ALIVE_PID 2>/dev/null
    exit $?
  }
  
  trap cleanup EXIT INT TERM
  
  SUDO="sudo"
else
  SUDO=""
fi

LATEST_ISO=$(curl -s https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/ | grep -oP 'debian-\d+\.\d+\.\d+-amd64-netinst\.iso' | sort -V | tail -n 1)
ISO_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/$LATEST_ISO"
ISO_FILENAME=$LATEST_ISO
WORK_DIR="debian-remaster"
SRC_DIR="src"
CONFIG_DIR="$SRC_DIR/config"
SCRIPTS_DIR="$SRC_DIR/scripts"
SERVICES_DIR="$SRC_DIR/services"
PRESEED_FILE="$CONFIG_DIR/preseed.cfg"
DEB_PRESEED_URL="https://raw.githubusercontent.com/clear-cmos/debian/refs/heads/main/postinst/base.py"
DEB_PRESEED_LOCAL="$SCRIPTS_DIR/base.py"

$SUDO apt-get update
$SUDO apt-get install -y xorriso isolinux grub-efi-amd64-bin wget curl

# Check for and download the latest base.py if needed
echo "Checking for the latest base.py..."
if [ -f "$DEB_PRESEED_LOCAL" ]; then
  # Create a temporary file for the latest version
  TEMP_FILE=$(mktemp)
  if curl -s -o "$TEMP_FILE" "$DEB_PRESEED_URL"; then
    # Compare the local and remote files
    if ! cmp -s "$TEMP_FILE" "$DEB_PRESEED_LOCAL"; then
      echo "Found newer version of base.py, updating..."
      cp "$TEMP_FILE" "$DEB_PRESEED_LOCAL"
      echo "Updated base.py successfully."
    else
      echo "Local base.py is already up to date."
    fi
    rm "$TEMP_FILE"
  else
    echo "Warning: Could not download the latest base.py. Using local version."
    rm "$TEMP_FILE"
  fi
else
  echo "Local base.py not found, downloading..."
  if curl -s -o "$DEB_PRESEED_LOCAL" "$DEB_PRESEED_URL"; then
    echo "Downloaded base.py successfully."
  else
    echo "Error: Failed to download base.py. Check your internet connection."
    exit 1
  fi
fi

$SUDO mkdir -p "$WORK_DIR"/{iso,extracted}

if [ ! -f "$ISO_FILENAME" ]; then
  echo "Downloading Debian ISO..."
  wget "$ISO_URL"
fi

echo "Mounting ISO..."
$SUDO mount -o loop "$ISO_FILENAME" "$WORK_DIR/iso"

echo "Copying files..."
$SUDO cp -rT "$WORK_DIR/iso" "$WORK_DIR/extracted"

$SUDO umount "$WORK_DIR/iso"

if [ ! -f "$PRESEED_FILE" ]; then
  echo "Error: $PRESEED_FILE not found. Create it first."
  exit 1
fi

$SUDO mkdir -p "$WORK_DIR/extracted/$SRC_DIR"/{scripts,services,config}
$SUDO cp "$PRESEED_FILE" "$WORK_DIR/extracted/"
$SUDO cp "$SCRIPTS_DIR/init.sh" "$WORK_DIR/extracted/$SCRIPTS_DIR/"
$SUDO cp "$SCRIPTS_DIR/base.py" "$WORK_DIR/extracted/$SCRIPTS_DIR/"
$SUDO cp "$SERVICES_DIR/first-boot.service" "$WORK_DIR/extracted/$SERVICES_DIR/"

echo "Updating boot configuration..."
$SUDO sed -i 's/timeout 0/timeout 1/' "$WORK_DIR/extracted/isolinux/isolinux.cfg"

MENU_FILE="$WORK_DIR/extracted/isolinux/txt.cfg"
if [ -f "$MENU_FILE" ]; then
  $SUDO cp "$MENU_FILE" "${MENU_FILE}.backup"

  AUTO_ENTRY="label auto\n\tmenu label ^Automated Install\n\tmenu default\n\tkernel /install.amd/vmlinuz\n\tappend initrd=/install.amd/initrd.gz auto=true priority=critical preseed/file=/cdrom/preseed.cfg --"

  $SUDO sed -i 's/^default install/default auto/' "$MENU_FILE"

  if grep -q "^label auto" "$MENU_FILE"; then
    AUTO_PATTERN=$(echo "^label auto" | sed 's/\//\\\//g')
    LABEL_PATTERN=$(echo "^label " | sed 's/\//\\\//g')

    AUTO_LINE=$(grep -n "^label auto" "$MENU_FILE" | cut -d: -f1)

    NEXT_LABEL_LINE=$(tail -n +$((AUTO_LINE+1)) "$MENU_FILE" | grep -n "^label " | head -1 | cut -d: -f1)
    NEXT_LABEL_LINE=$((AUTO_LINE + NEXT_LABEL_LINE))

    $SUDO sed -i "${AUTO_LINE},$(($NEXT_LABEL_LINE-1))d" "$MENU_FILE"

    $SUDO sed -i "${AUTO_LINE}i\\${AUTO_ENTRY}" "$MENU_FILE"
  else
    $SUDO bash -c "echo -e \"${AUTO_ENTRY}\n\" > \"${MENU_FILE}.new\""
    $SUDO bash -c "cat \"${MENU_FILE}\" >> \"${MENU_FILE}.new\""
    $SUDO mv "${MENU_FILE}.new" "${MENU_FILE}"
  fi
fi

GRUB_FILE="$WORK_DIR/extracted/boot/grub/grub.cfg"
if [ -f "$GRUB_FILE" ]; then
  $SUDO cp "$GRUB_FILE" "${GRUB_FILE}.backup"

  $SUDO sed -i 's/set timeout=.*/set timeout=1/' "$GRUB_FILE"

  AUTO_ENTRY="menuentry \"Automated Install\" {\n\tset background_color=black\n\tlinux\t/install.amd/vmlinuz auto=true priority=critical preseed/file=/cdrom/preseed.cfg --\n\tinitrd\t/install.amd/initrd.gz\n}"

  if ! grep -q "Automated Install" "$GRUB_FILE"; then
    INSTALL_LINE=$(grep -n "menuentry \"Install\"" "$GRUB_FILE" | head -1 | cut -d: -f1)
    $SUDO sed -i "${INSTALL_LINE}i\\${AUTO_ENTRY}\n" "$GRUB_FILE"
  fi

  $SUDO sed -i 's/set default=.*/set default="Automated Install"/' "$GRUB_FILE"
fi

echo "Creating new ISO..."
# Extract the Debian version from the downloaded ISO filename
VERSION=$(echo "$ISO_FILENAME" | grep -oP 'debian-\K\d+\.\d+\.\d+(?=-amd64)')
NEW_ISO="debian-${VERSION}-preseed-generic.iso"
$SUDO xorriso -as mkisofs -r -J -joliet-long -l \
  -iso-level 3 \
  -partition_offset 16 \
  -V "DEBIAN AUTOINSTALL" \
  -b isolinux/isolinux.bin \
  -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -output "$NEW_ISO" \
  "$WORK_DIR/extracted"

$SUDO rm -rf "$WORK_DIR"

echo "Done! Your new ISO is: $NEW_ISO"
