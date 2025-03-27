#!/bin/bash
# Enable debugging (set to 1 to enable extra debug output)
DEBUG=1

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Output helper functions ---
print_info() {
  echo -e "${BLUE}[INFO]${NC} $1" >&2
}

print_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

print_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

print_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_debug() {
  if [ "$DEBUG" -eq 1 ]; then
    echo -e "${BLUE}[DEBUG]${NC} $1" >&2
  fi
}

# --- Command-check helper ---
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# --- 1Password authentication check ---
check_1password_auth() {
  print_info "Checking 1Password authentication..."
  if op user get --me &>/dev/null; then
    print_success "Authenticated to 1Password"
    return 0
  else
    print_error "Not authenticated to 1Password"
    print_info "Please run: eval \$(op signin)"
    return 1
  fi
}

# --- Network discovery functions ---
get_local_subnet() {
  local interfaces
  interfaces=$(ip -4 addr show | grep inet | awk '{print $2, $NF}' | grep -v "lo")
  if [ -z "$interfaces" ]; then
    print_error "No network interfaces found"
    return 1
  fi
  local interface
  interface=$(echo "$interfaces" | head -1)
  local cidr
  cidr=$(echo "$interface" | awk '{print $1}')
  local iface
  iface=$(echo "$interface" | awk '{print $2}')
  local ip
  ip=$(echo "$cidr" | cut -d/ -f1)
  local prefix
  prefix=$(echo "$cidr" | cut -d/ -f2)
  local IFS=.
  set -- $ip
  local first=$1
  local second=$2
  local third=$3
  if [ "$prefix" -eq 24 ]; then
    local network="$first.$second.$third.0/24"
  else
    local network="$cidr"
  fi
  print_info "Using network interface $iface ($ip) for scanning subnet $network"
  echo "$network"
}

scan_network() {
  local subnet=$1
  if ! [[ "$subnet" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
    print_error "Invalid subnet format: $subnet"
    return 1
  fi
  print_info "Scanning subnet $subnet for active hosts..."
  if command_exists nmap; then
    print_info "Using nmap for network scanning (this may take a moment)..."
    local nmap_output
    nmap_output=$(nmap -sn "$subnet" 2>/dev/null)
    local hosts
    hosts=$(echo "$nmap_output" | grep "Nmap scan report for")
    local result=""
    while IFS= read -r line; do
      if [[ -n "$line" ]]; then
        line=${line#Nmap scan report for }
        if [[ "$line" =~ (.+)\ \(([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\) ]]; then
          local hostname="${BASH_REMATCH[1]}"
          local ip="${BASH_REMATCH[2]}"
          result+="$hostname:$ip "
        elif [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
          local ip="$line"
          local hostname
          hostname=$(dig +short -x "$ip" 2>/dev/null || echo "$ip")
          if [ "$hostname" == "$ip" ]; then
            result+="$ip:$ip "
          else
            result+="$hostname:$ip "
          fi
        fi
      fi
    done <<< "$hosts"
    echo "$result"
    if [ -z "$result" ]; then
      print_warning "No hosts found on network $subnet"
      return 0
    fi
  else
    print_warning "nmap not found, using basic ping scan (less reliable)"
    local network
    network=$(echo "$subnet" | cut -d/ -f1 | rev | cut -d. -f2- | rev)
    local hosts=""
    print_info "Scanning network $network.0/24 using ping..."
    for i in {1..254}; do
      if ping -c 1 -W 1 "$network.$i" &>/dev/null; then
        local ip="$network.$i"
        local hostname
        hostname=$(dig +short -x "$ip" 2>/dev/null || echo "$ip")
        if [ -n "$hostname" ] && [ "$hostname" != "$ip" ]; then
          hosts+="$hostname:$ip "
        else
          hosts+="$ip:$ip "
        fi
        print_info "Found host: $ip"
      fi
    done
    echo "$hosts"
  fi
}

detect_services() {
  local ip=$1
  local services=""
  if command_exists nc && nc -z -w1 "$ip" 445 2>/dev/null; then
    services+="smb "
  fi
  if command_exists nc && nc -z -w1 "$ip" 2049 2>/dev/null; then
    services+="nfs "
  fi
  for port in 80 443 5000 8080; do
    if command_exists nc && nc -z -w1 "$ip" "$port" 2>/dev/null; then
      services+="nas "
      break
    fi
  done
  echo "$services"
}

list_smb_shares() {
  local host=$1
  local username=$2
  local password=$3
  if ! command_exists smbclient; then
    print_warning "smbclient not installed, cannot list SMB shares"
    return 1
  fi
  print_info "Checking for SMB shares on $host..."
  local shares=""
  if [ -z "$username" ] || [ -z "$password" ]; then
    shares=$(smbclient -N -L "$host" 2>/dev/null | grep Disk | awk '{print $1}')
  else
    shares=$(smbclient -L "$host" -U "$username%$password" 2>/dev/null | grep Disk | awk '{print $1}')
  fi
  if [ -n "$shares" ]; then
    echo "$shares"
    return 0
  else
    return 1
  fi
}

list_nfs_exports() {
  local host=$1
  if ! command_exists showmount; then
    print_warning "showmount not installed, cannot list NFS exports. Install nfs-common package to support NFS."
    return 1
  fi
  print_info "Checking for NFS exports on $host..."
  local exports
  exports=$(showmount -e "$host" 2>/dev/null | tail -n +2 | awk '{print $1}')
  if [ -n "$exports" ]; then
    echo "$exports"
    return 0
  else
    return 1
  fi
}

# --- Menu function ---
select_from_menu() {
  local title=$1
  shift
  local options=("$@")
  local num_options=${#options[@]}
  if [ $num_options -eq 0 ]; then
    print_error "No options provided for menu"
    return 1
  fi
  
  echo -e "\n${BLUE}=== $title ===${NC}" >&2
  for i in $(seq 1 $num_options); do
    echo "$i) ${options[$i-1]}" >&2
  done
  
  print_debug "Presenting menu with $num_options options"
  
  local selection=""
  while true; do
    read -p "Enter selection [1-$num_options]: " selection
    print_debug "User entered: '$selection'"
    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le $num_options ]; then
      print_debug "Selection is valid: $selection"
      echo "$selection"
      return 0
    else
      print_error "Invalid selection. Please enter a number between 1 and $num_options."
    fi
  done
}

# --- 1Password item retrieval helpers ---
# Retrieves the entire item JSON (with --reveal) and prints fields (for debugging)
retrieve_item_fields() {
  local item_identifier=$1
  local vault_name=$2
  print_info "Retrieving fields from item '$item_identifier' in vault '$vault_name' with --reveal..."
  local json
  json=$(op item get "$item_identifier" --vault "$vault_name" --format json --reveal 2>/dev/null)
  if [ -z "$json" ]; then
    print_error "Failed to retrieve item JSON."
    return 1
  fi
  print_debug "Full item JSON: $json"
  if command_exists jq; then
    echo "$json" | jq -r '.fields[] | "\(.label): \(.value) (\(.type))"'
  else
    echo "$json"
  fi
}

# Retrieves an item’s ID by its name from a given vault
get_item_id() {
  local item_name=$1
  local vault_name=$2
  op item get "$item_name" --vault "$vault_name" --format json 2>/dev/null | jq -r '.id'
}

# Retrieves a secret field from an item by trying a list of possible field labels
get_secret_field() {
  local item_id=$1
  shift
  local field
  local value
  # Retrieve the item JSON once
  local json
  json=$(op item get "$item_id" --vault "$VAULT_NAME" --format json --reveal 2>/dev/null)
  if [ -z "$json" ]; then
    return 1
  fi
  for field in "$@"; do
    value=$(echo "$json" | jq -r --arg field "$field" '.fields[] | select(.label==$field) | .value')
    if [ -n "$value" ] && [ "$value" != "null" ]; then
      echo "$value"
      return 0
    fi
  done
  return 1
}

# --- Main function ---
main() {
  if ! command_exists op; then
    print_error "1Password CLI not installed"
    print_info "Please install 1Password CLI from: https://1password.com/downloads/command-line/"
    exit 1
  fi
  if ! check_1password_auth; then
    exit 1
  fi
  
  local VAULT_NAME="Debian Preseed"
  
  echo -e "\n${BLUE}=== 1Password Vault Setup for Debian Installation ===${NC}"
  echo "This script will create or update the 'Debian Preseed' vault and items in 1Password for the Debian automated installation."
  echo "If the vault or items already exist, they will be updated with the new information."
  echo
  echo "You will be prompted to enter values for the following items:"
  echo "  - Debian Preseed: root password, user info, and SSH keys"
  echo "  - SMB Shares: network share configuration"
  echo "  - Network Configuration: network hosts and their details"
  echo
  echo "These values will be used by build-secrets-based.sh to create a customized Debian installation ISO."
  
  local subnet
  subnet=$(get_local_subnet)
  if [ -z "$subnet" ]; then
    print_error "Failed to determine local subnet"
    exit 1
  fi
  
  local host_list
  host_list=$(scan_network "$subnet")
  local scan_exit_code=$?
  
  if [ $scan_exit_code -ne 0 ]; then
    print_error "Network scanning failed"
    exit 1
  elif [ -z "$host_list" ]; then
    print_warning "No hosts found on the network"
    read -p "Would you like to continue with manual configuration instead? (y/n): " continue_manual
    if [[ "$continue_manual" =~ ^[Yy]$ ]]; then
      print_info "Continuing with manual configuration..."
      host_list=""
    else
      print_info "Exiting. Please run the script again when network scanning can complete successfully."
      exit 1
    fi
  else
    print_success "Found hosts on the network"
  fi
  
  # Parse detected hosts
  declare -a hosts=()
  declare -a ips=()
  declare -a services=()
  
  if [ -n "$host_list" ]; then
    for host_data in $host_list; do
      IFS=':' read -r hostname ip <<< "$host_data"
      hosts+=("$hostname")
      ips+=("$ip")
      local service_list
      service_list=$(detect_services "$ip")
      services+=("$service_list")
    done
    print_info "Found ${#hosts[@]} hosts on the network"
  fi
  
  echo
  read -p "How many network hosts do you want to configure? [0]: " num_hosts
  num_hosts=${num_hosts:-0}
  
  declare -a CONFIGURED_HOSTS=()
  declare -a CONFIGURED_IPS=()
  declare -a CONFIGURED_SHARES=()
  declare -a CONFIGURED_USERNAMES=()
  declare -a CONFIGURED_PASSWORDS=()
  
  for i in $(seq 1 $num_hosts); do
    echo -e "\n${BLUE}--- Host #$i Configuration ---${NC}"
    if [ ${#hosts[@]} -gt 0 ]; then
      sorted_list=()
      for j in $(seq 0 $((${#hosts[@]}-1))); do
        sorted_list+=("${ips[$j]}|${hosts[$j]}")
      done
      
      IFS=$'\n' sorted_list=($(sort -t'|' -k1,1 -V <<<"${sorted_list[*]}"))
      unset IFS
      
      host_options=()
      for entry in "${sorted_list[@]}"; do
        ip_val="${entry%%|*}"
        host_val="${entry#*|}"
        host_options+=("${ip_val} (${host_val})")
      done
      
      echo "Available hosts:"
      for idx in "${!host_options[@]}"; do
        echo "  $((idx+1))) ${host_options[$idx]}"
      done
      
      selected_idx=$(select_from_menu "Select host $i" "${host_options[@]}")
      if [[ -z "$selected_idx" ]]; then
        print_error "No selection was returned from menu"
        read -p "Enter hostname for host $i: " selected_host
        read -p "Enter IP address for host $i: " selected_ip
      elif [[ "$selected_idx" =~ ^[0-9]+$ ]] && [[ "$selected_idx" -le "${#sorted_list[@]}" ]]; then
        host_idx=$((selected_idx-1))
        selected_entry="${sorted_list[$host_idx]}"
        selected_ip="${selected_entry%%|*}"
        selected_host="${selected_entry#*|}"
        echo "Selected: $selected_host ($selected_ip)"
      else
        print_error "Invalid selection. Using manual entry instead."
        read -p "Enter hostname for host $i: " selected_host
        read -p "Enter IP address for host $i: " selected_ip
      fi
    else
      read -p "Enter hostname for host $i: " selected_host
      read -p "Enter IP address for host $i: " selected_ip
    fi
    
    if [[ "${services[@]}" == *"smb"* ]]; then
      local share_list
      share_list=$(list_smb_shares "$selected_ip" "" "")
      if [ $? -ne 0 ]; then
        echo "Anonymous SMB share listing failed. Authentication required."
        read -p "Enter username for $selected_host: " smb_username
        read -s -p "Enter password for $selected_host: " smb_password
        echo
        if [ -n "$smb_username" ] && [ -n "$smb_password" ]; then
          share_list=$(list_smb_shares "$selected_ip" "$smb_username" "$smb_password")
        fi
      fi
      if [ -n "$share_list" ]; then
        echo "Found the following SMB shares on $selected_host:"
        share_options=()
        while read -r share; do
          [ -n "$share" ] && share_options+=("$share")
        done <<< "$share_list"
        
        if [ ${#share_options[@]} -gt 0 ]; then
          selected_share=$(select_from_menu "Select share" "${share_options[@]}")
          share_idx=$((selected_share-1))
          selected_share="${share_options[$share_idx]}"
          CONFIGURED_HOSTS+=("$selected_host")
          CONFIGURED_IPS+=("$selected_ip")
          CONFIGURED_SHARES+=("$selected_share")
          CONFIGURED_USERNAMES+=("${smb_username:-$username}")
          CONFIGURED_PASSWORDS+=("${smb_password:-$user_password}")
          print_success "Configured $selected_host/$selected_share"
        else
          print_warning "No valid shares found on $selected_host"
          CONFIGURED_HOSTS+=("$selected_host")
          CONFIGURED_IPS+=("$selected_ip")
          CONFIGURED_SHARES+=("")
          CONFIGURED_USERNAMES+=("${smb_username:-$username}")
          CONFIGURED_PASSWORDS+=("${smb_password:-$user_password}")
        fi
      else
        print_warning "No shares found on $selected_host"
        CONFIGURED_HOSTS+=("$selected_host")
        CONFIGURED_IPS+=("$selected_ip")
        CONFIGURED_SHARES+=("")
        CONFIGURED_USERNAMES+=("${smb_username:-$username}")
        CONFIGURED_PASSWORDS+=("${smb_password:-$user_password}")
      fi
    elif [[ "${services[@]}" == *"nfs"* ]]; then
      local export_list
      export_list=$(list_nfs_exports "$selected_ip")
      if [ -n "$export_list" ]; then
        echo "Found the following NFS exports on $selected_host:"
        export_options=()
        while read -r export_path; do
          [ -n "$export_path" ] && export_options+=("$export_path")
        done <<< "$export_list"
        
        if [ ${#export_options[@]} -gt 0 ]; then
          selected_export=$(select_from_menu "Select NFS export" "${export_options[@]}")
          export_idx=$((selected_export-1))
          selected_export="${export_options[$export_idx]}"
          CONFIGURED_HOSTS+=("$selected_host")
          CONFIGURED_IPS+=("$selected_ip")
          CONFIGURED_SHARES+=("$selected_export")
          CONFIGURED_USERNAMES+=("")
          CONFIGURED_PASSWORDS+=("")
          print_success "Configured $selected_host:$selected_export (NFS)"
        else
          print_warning "No valid NFS exports found on $selected_host"
          CONFIGURED_HOSTS+=("$selected_host")
          CONFIGURED_IPS+=("$selected_ip")
          CONFIGURED_SHARES+=("")
          CONFIGURED_USERNAMES+=("")
          CONFIGURED_PASSWORDS+=("")
        fi
      else
        print_warning "No NFS exports found on $selected_host"
        CONFIGURED_HOSTS+=("$selected_host")
        CONFIGURED_IPS+=("$selected_ip")
        CONFIGURED_SHARES+=("")
        CONFIGURED_USERNAMES+=("")
        CONFIGURED_PASSWORDS+=("")
      fi
    else
      read -p "No file sharing services detected on $selected_host. Would you like to manually configure a share? (y/n): " configure_share
      if [[ "$configure_share" =~ ^[Yy]$ ]]; then
        echo -e "\n${BLUE}--- Manual Share Configuration for $selected_host ---${NC}"
        read -p "Enter share name (e.g., 'share', 'documents'): " share_name
        read -p "Enter username for share access: " share_username
        read -s -p "Enter password for share access: " share_password
        echo
        CONFIGURED_HOSTS+=("$selected_host")
        CONFIGURED_IPS+=("$selected_ip")
        CONFIGURED_SHARES+=("$share_name")
        CONFIGURED_USERNAMES+=("$share_username")
        CONFIGURED_PASSWORDS+=("$share_password")
        print_success "Manually configured share '$share_name' on $selected_host"
      else
        CONFIGURED_HOSTS+=("$selected_host")
        CONFIGURED_IPS+=("$selected_ip")
        CONFIGURED_SHARES+=("")
        CONFIGURED_USERNAMES+=("")
        CONFIGURED_PASSWORDS+=("")
        print_info "Added $selected_host (no file sharing services configured)"
      fi
    fi
  done
  
  # Setup 1Password vault and items
  print_info "Setting up 1Password vault..."
  if op vault get "$VAULT_NAME" >/dev/null 2>&1; then
    print_info "Vault '$VAULT_NAME' already exists. Using existing vault."
  else
    print_info "Creating vault: $VAULT_NAME"
    op vault create "$VAULT_NAME" --description "Debian installation credentials and configuration" >/dev/null
    if [ $? -eq 0 ]; then
      print_success "Created vault: $VAULT_NAME"
    else
      print_error "Failed to create vault: $VAULT_NAME"
    fi
  fi
  
  print_info "Setting up Debian Preseed information..."
  read -s -p "Enter root password: " root_password
  echo
  read -p "Enter user full name: " user_fullname
  read -p "Enter username: " username
  read -s -p "Enter user password: " user_password
  echo
  read -p "Enter SSH authorized key (or leave empty to generate one during installation): " ssh_key
  
  print_info "Retrieving current fields for 'Debian Preseed' item..."
  retrieve_item_fields "Debian Preseed" "$VAULT_NAME"
  
  print_info "Setting up Debian Preseed item..."
  if op item get "Debian Preseed" --vault="$VAULT_NAME" >/dev/null 2>&1; then
    print_info "Debian Preseed item already exists. Updating item..."
    op item edit "Debian Preseed" --vault="$VAULT_NAME" \
      "root_password[password]=$root_password" \
      "user_fullname=$user_fullname" \
      "username=$username" \
      "user_password[password]=$user_password" \
      "ssh_authorized_key=$ssh_key" >/dev/null
    if [ $? -eq 0 ]; then
      print_success "Updated Debian Preseed item"
    else
      print_error "Failed to update Debian Preseed item"
    fi
  else
    print_info "Creating Debian Preseed item..."
    op item create --vault "$VAULT_NAME" --category Login --title "Debian Preseed" \
      "root_password[password]=$root_password" \
      "user_fullname=$user_fullname" \
      "username=$username" \
      "user_password[password]=$user_password" \
      "ssh_authorized_key=$ssh_key" >/dev/null
    if [ $? -eq 0 ]; then
      print_success "Created Debian Preseed item"
    else
      print_error "Failed to create Debian Preseed item"
    fi
  fi
  
  # Retrieve the Debian Preseed item ID for field lookups
  local DEBIAN_PRESEED_ID
  DEBIAN_PRESEED_ID=$(get_item_id "Debian Preseed" "$VAULT_NAME")
  print_debug "Debian Preseed ID: $DEBIAN_PRESEED_ID"
  
  # Retrieve secret fields from the Debian Preseed item
  print_info "Retrieving root password field..."
  local retrieved_root
  retrieved_root=$(get_secret_field "$DEBIAN_PRESEED_ID" "root_password" "password" "rootpassword")
  if [ -z "$retrieved_root" ]; then
    print_error "Failed to retrieve root password."
  else
    print_success "Retrieved root password using alternative field name!"
  fi
  
  print_info "Retrieving user fullname field..."
  local retrieved_fullname
  retrieved_fullname=$(get_secret_field "$DEBIAN_PRESEED_ID" "user_fullname" "fullname" "userfullname")
  if [ -z "$retrieved_fullname" ]; then
    print_error "Failed to retrieve user fullname."
  else
    print_success "Retrieved user fullname: $retrieved_fullname"
  fi
  
  # Setup SMB Shares item
  print_info "Setting up SMB Shares item..."
  local smb_cmd_base="\"num_shares=${#CONFIGURED_HOSTS[@]}\""
  for i in $(seq 0 $((${#CONFIGURED_HOSTS[@]}-1))); do
    local idx=$((i+1))
    smb_cmd_base+=" \"host${idx}=${CONFIGURED_HOSTS[$i]}\""
    smb_cmd_base+=" \"share${idx}=${CONFIGURED_SHARES[$i]}\""
    if [ -n "${CONFIGURED_USERNAMES[$i]}" ]; then
      smb_cmd_base+=" \"username${idx}=${CONFIGURED_USERNAMES[$i]}\""
    else
      smb_cmd_base+=" \"username${idx}=$username\""
    fi
    if [ -n "${CONFIGURED_PASSWORDS[$i]}" ]; then
      smb_cmd_base+=" \"password${idx}[password]=${CONFIGURED_PASSWORDS[$i]}\""
    else
      smb_cmd_base+=" \"password${idx}[password]=$user_password\""
    fi
  done
  
  if op item get "SMB Shares" --vault="$VAULT_NAME" >/dev/null 2>&1; then
    print_info "SMB Shares item already exists. Updating item..."
    local smb_cmd="op item edit \"SMB Shares\" --vault=\"$VAULT_NAME\" $smb_cmd_base"
    eval "$smb_cmd" >/dev/null
    if [ $? -eq 0 ]; then
      print_success "Updated SMB Shares item"
    else
      print_error "Failed to update SMB Shares item"
    fi
  else
    print_info "Creating SMB Shares item..."
    local smb_cmd="op item create --vault \"$VAULT_NAME\" --category Login --title \"SMB Shares\" $smb_cmd_base"
    eval "$smb_cmd" >/dev/null
    if [ $? -eq 0 ]; then
      print_success "Created SMB Shares item"
    else
      print_error "Failed to create SMB Shares item"
    fi
  fi
  
  # Setup Network Configuration item
  print_info "Setting up Network Configuration item..."
  local net_cmd_base="\"num_hosts=${#CONFIGURED_HOSTS[@]}\""
  for i in $(seq 0 $((${#CONFIGURED_HOSTS[@]}-1))); do
    local idx=$((i+1))
    net_cmd_base+=" \"host_${idx}_name=${CONFIGURED_HOSTS[$i]}\""
    net_cmd_base+=" \"host_${idx}_ip=${CONFIGURED_IPS[$i]}\""
    net_cmd_base+=" \"host_${idx}_share=${CONFIGURED_SHARES[$i]}\""
  done
  
  if op item get "Network Configuration" --vault="$VAULT_NAME" >/dev/null 2>&1; then
    print_info "Network Configuration item already exists. Updating item..."
    local net_cmd="op item edit \"Network Configuration\" --vault=\"$VAULT_NAME\" $net_cmd_base"
    eval "$net_cmd" >/dev/null
    if [ $? -eq 0 ]; then
      print_success "Updated Network Configuration item"
    else
      print_error "Failed to update Network Configuration item"
    fi
  else
    print_info "Creating Network Configuration item..."
    local net_cmd="op item create --vault \"$VAULT_NAME\" --category Login --title \"Network Configuration\" $net_cmd_base"
    eval "$net_cmd" >/dev/null
    if [ $? -eq 0 ]; then
      print_success "Created Network Configuration item"
    else
      print_error "Failed to create Network Configuration item"
    fi
  fi
  
  print_success "Setup complete! You can now run ./build-secrets-based.sh to build your customized Debian ISO."
}

main
