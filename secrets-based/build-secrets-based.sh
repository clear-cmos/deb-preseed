#!/bin/bash

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

print_debug() {
  echo -e "${BLUE}[DEBUG]${NC} $1"
}

# Function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Function to check if signed in to 1Password and exit if not signed in
check_1password_auth() {
  # More reliable way to check 1Password authentication status
  if ! op user get --me &>/dev/null; then
    print_error "You are not signed in to 1Password."
    print_info "Please sign in first with: eval \$(op signin)"
    print_info "Then run this script again."
    exit 1
  fi
  print_success "Successfully authenticated with 1Password."
  return 0
}

# Function to retrieve secrets from 1Password with improved error handling
get_1password_secret() {
  local item_id="$1"
  local field_name="$2"
  
  # Debug: Show what field we're trying to retrieve
  print_info "Attempting to retrieve field '$field_name' from item '$item_id'"
  
  # Try to get the secret and capture both stdout and stderr
  local secret
  local error_output
  
  # Use a temporary file for error output
  local error_file=$(mktemp)
  
  # Check if item_id is a UUID or a name
  if [[ "$item_id" =~ ^[a-z0-9]{26}$ ]]; then
    # It's an ID - verify it exists
    if ! op item get "$item_id" &>/dev/null; then
      print_error "Item with ID '$item_id' does not exist in the vault"
      print_info "Available items in the vault:"
      op item list --vault "$VAULT_NAME" | head -10
      rm -f "$error_file"
      return 1
    fi
  else
    # It's a name - get its ID first
    local item_json=$(op item list --vault "$VAULT_NAME" --format json 2>/dev/null | jq -r --arg title "$item_id" '.[] | select(.title==$title)')
    if [ -z "$item_json" ]; then
      print_error "Item with name '$item_id' does not exist in the vault"
      print_info "Available items in the vault:"
      op item list --vault "$VAULT_NAME" | head -10
      rm -f "$error_file"
      return 1
    fi
    # Extract the ID and use that for subsequent operations
    item_id=$(echo "$item_json" | jq -r '.id')
    print_info "Resolved item name to ID: $item_id"
  fi
  
  # First try direct field access (works for top-level fields)
  print_info "Trying direct field access..."
  secret=$(op item get "$item_id" --field "$field_name" --reveal 2>"$error_file")
  local op_status=$?
  
  # Read error output if any
  if [ -s "$error_file" ]; then
    error_output=$(cat "$error_file")
    print_warning "1Password CLI error output: $error_output"
  fi
  
  # If direct access failed, try using JSON parsing
  if [ $op_status -ne 0 ] || [ -z "$secret" ]; then
    print_warning "Direct field access failed, trying JSON parsing approach..."
    
    # Get the full item JSON
    local fields_json=$(op item get "$item_id" --format json --reveal 2>/dev/null)
    if [ -n "$fields_json" ]; then
      # Check if jq is available
      if command_exists jq; then
        # First try searching fields by label, including those in sections
        print_info "Searching for field with label '$field_name' in all fields including sections..."
        secret=$(echo "$fields_json" | jq -r --arg label "$field_name" '.fields[] | select(.label==$label) | .value' 2>/dev/null)
        
        # If that fails, try alternative field names
        if [ -z "$secret" ] || [ "$secret" = "null" ]; then
          print_info "Checking fields with similar names..."
          # List available fields for troubleshooting
          echo "$fields_json" | jq -r '.fields[] | "\(.id): \(.label) (\(.type))"' 2>/dev/null
          
          # Try standardized field names if the target is password-related
          if [[ "$field_name" == *"password"* ]]; then
            # Try common password field variants
            for pwfield in "password" "Password" "root_password" "rootpassword" "user_password" "userpassword"; do
              print_info "Trying alternative field name: $pwfield"
              secret=$(echo "$fields_json" | jq -r --arg label "$pwfield" '.fields[] | select(.label==$label) | .value' 2>/dev/null)
              if [ -n "$secret" ] && [ "$secret" != "null" ]; then
                print_success "Found value using alternative field name: $pwfield"
                break
              fi
            done
          fi
        else
          print_success "Retrieved field using label matching in JSON."
        fi
      else
        print_warning "jq not available, cannot parse JSON response."
      fi
    fi
  fi
  
  rm -f "$error_file"
  
  if [ -z "$secret" ] || [ "$secret" = "null" ]; then
    print_error "Could not retrieve field '$field_name' from item '$item_id'"
    
    # List available fields for debugging
    print_info "Available fields in item '$item_id':"
    op item get "$item_id" --format json 2>/dev/null | jq -r '.fields[] | "\(.id): \(.label) (\(.type))"' 2>/dev/null || 
      print_warning "Unable to list fields using jq"
    
    return 1
  fi
  
  if [ -z "$secret" ]; then
    print_warning "Field '$field_name' was found but is empty"
  else
    print_success "Successfully retrieved field '$field_name'"
  fi
  
  echo "$secret"
}

# Clean up output of get_1password_secret to extract just the value
clean_secret() {
  echo "$1" | grep -v "\[INFO\]" | grep -v "\[SUCCESS\]" | grep -v "\[WARNING\]" | tail -1
}

# Ensure we have sudo powers
if [ "$EUID" -ne 0 ]; then
  print_info "Requesting elevated privileges (enter password when prompted)..."
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

# Check for 1Password CLI
if ! command_exists op; then
  print_error "1Password CLI not installed. Please install it first."
  exit 1
fi

# Check 1Password CLI version for troubleshooting
print_info "1Password CLI version:"
OP_VERSION=$(op --version)
echo "$OP_VERSION"

# Verify the CLI version is in expected format
if [[ ! "$OP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  print_warning "1Password CLI version format is unexpected. This may cause issues."
else
  print_info "1Password CLI version format is as expected."
fi

# Check authentication status
print_info "Checking authentication status for 1Password..."
if ! check_1password_auth; then
  exit 1
fi

# Check for secrets-builder.sh and recommend running it first if needed
if [ -f "secrets-builder.sh" ] && [ ! -x "secrets-builder.sh" ]; then
  chmod +x "secrets-builder.sh"
fi

if [ -x "secrets-builder.sh" ]; then
  print_info "Note: If you encounter issues with missing secrets, you can run ./secrets-builder.sh first to set them up correctly."
fi

# Vault name and item IDs in the vault
VAULT_NAME="Debian Preseed"
print_info "Using 1Password vault: $VAULT_NAME"
print_info "Checking for required items in the vault..."

# List items in the vault to get their IDs
print_info "Listing items in vault '$VAULT_NAME'..."
items=$(op item list --vault "$VAULT_NAME")
if [ $? -ne 0 ]; then
  print_error "Failed to list items in vault '$VAULT_NAME'. Check that the vault exists."
  
  # Check if vault exists
  print_info "Checking for vault existence..."
  vault_exists=$(op vault list | grep -q "$VAULT_NAME"; echo $?)
  if [ $vault_exists -eq 0 ]; then
    print_info "Vault '$VAULT_NAME' exists but item listing failed. This might be a permission issue."
  else
    print_error "Vault '$VAULT_NAME' does not exist. Please run ./secrets-builder.sh first to create it."
    print_info "Available vaults:"
    op vault list
  fi
  
  exit 1
fi

# Use JSON format to parse item IDs reliably
print_info "Parsing item IDs from vault output using JSON format..."
items_json=$(op item list --vault "$VAULT_NAME" --format json 2>/dev/null)

if [ -z "$items_json" ]; then
  print_error "Failed to get items in JSON format. Check vault access."
  exit 1
fi

# Extract item IDs using jq for reliable parsing
SECRETS_ID=$(echo "$items_json" | jq -r '.[] | select(.title=="Debian Preseed") | .id')
NETWORK_ID=$(echo "$items_json" | jq -r '.[] | select(.title=="Network Configuration") | .id')
SMB_SHARES_ID=$(echo "$items_json" | jq -r '.[] | select(.title=="SMB Shares") | .id')

# Verify each ID is properly extracted
if [ -z "$SECRETS_ID" ]; then
  print_error "Failed to extract Debian Preseed item ID."
  print_info "Available items in vault:"
  echo "$items_json" | jq -r '.[] | .title'
  exit 1
fi

print_info "Extracted item IDs:"
print_info "Debian Preseed ID: $SECRETS_ID"
print_info "Network Configuration ID: $NETWORK_ID"
print_info "SMB Shares ID: $SMB_SHARES_ID"

# Verify we can access each item
print_info "Verifying item access..."
if ! op item get "$SECRETS_ID" --format json > /dev/null 2>&1; then
  print_error "Cannot access Debian Preseed item with ID: $SECRETS_ID"
  exit 1
else
  print_success "Successfully accessed Debian Preseed item"
fi

# Verify we have a valid SECRETS_ID before proceeding
if [ -z "$SECRETS_ID" ]; then
  print_error "Could not find 'Debian Preseed' item in vault '$VAULT_NAME'."
  print_info "Please ensure an item called 'Debian Preseed' exists in the vault."
  exit 1
fi

print_info "Debugging vault item access:"
print_info "Checking Debian Preseed item details..."
if [ -n "$SECRETS_ID" ]; then
  # Verify we can access the item to ensure the ID is correct
  op item get "$SECRETS_ID" --format json | jq -r '.title, .fields | length' 2>/dev/null || print_warning "Unable to get detailed item info for '$SECRETS_ID'"
else
  print_warning "SECRETS_ID is empty, cannot check item details"
fi

if [ -z "$NETWORK_ID" ]; then
  print_warning "Could not find 'Network Configuration' item in vault '$VAULT_NAME'."
else
  print_info "Found Network Configuration item: $NETWORK_ID"
fi

if [ -z "$SMB_SHARES_ID" ]; then
  print_warning "Could not find 'SMB Shares' item in vault '$VAULT_NAME'."
else
  print_info "Found SMB Shares item: $SMB_SHARES_ID"
fi

print_info "Retrieving secrets from 1Password vault..."

# Debug fields available in the Debian Preseed item
print_info "Listing available fields in Debian Preseed item..."
if [ -n "$SECRETS_ID" ]; then
  # Use --format json to get structured output that's easier to parse
  print_info "Executing: op item get \"$SECRETS_ID\" --format json"
  FIELDS_JSON=$(op item get "$SECRETS_ID" --format json 2> /tmp/op_error.log)
  OP_EXIT_CODE=$?
  
  if [ $OP_EXIT_CODE -eq 0 ]; then
    print_success "Retrieved item JSON successfully"
    echo "$FIELDS_JSON" | jq -r '.fields[] | "\(.id): \(.label) (\(.type))"' 2>/dev/null || print_warning "Unable to parse fields JSON"
  else
    print_warning "Failed to get item details in JSON format (exit code: $OP_EXIT_CODE)"
    if [ -s /tmp/op_error.log ]; then
      print_error "Error output: $(cat /tmp/op_error.log)"
    fi
    
    # Test with different quotes or format
    print_info "Trying alternative formats to retrieve item..."
    if op item get $SECRETS_ID --format json > /dev/null 2>&1; then
      print_success "Retrieval works with unquoted ID"
      FIELDS_JSON=$(op item get $SECRETS_ID --format json 2>/dev/null)
      echo "$FIELDS_JSON" | jq -r '.fields[] | "\(.id): \(.label) (\(.type))"' 2>/dev/null || print_warning "Unable to parse fields JSON"
    else
      print_error "Alternative formats also failed"
    fi
  fi
  rm -f /tmp/op_error.log
else
  print_warning "SECRETS_ID is empty, cannot list fields"
fi

# Try to list password fields specifically
print_info "Looking for password fields in the item:"
if [ -n "$SECRETS_ID" ]; then
  FIELDS_JSON=$(op item get "$SECRETS_ID" --format json 2>/dev/null)
  if [ $? -eq 0 ]; then
    echo "$FIELDS_JSON" | jq -r '.fields[] | select(.purpose=="PASSWORD") | .label' 2>/dev/null || print_warning "No password fields found or unable to parse JSON"
  else
    print_warning "Failed to get item details in JSON format"
  fi
else
  print_warning "SECRETS_ID is empty, cannot list password fields"
fi

# Retrieve authentication secrets
print_info "Retrieving root_password field..."

# First try using the item title instead of ID for more reliable retrieval
print_info "Trying to retrieve root_password directly using item title..."
ROOT_PASSWORD=$(op item get "Debian Preseed" --vault="$VAULT_NAME" --field "root_password" --reveal 2>/dev/null)

if [ -z "$ROOT_PASSWORD" ]; then
  print_info "Direct access by title failed, trying by ID with our enhanced function..."
  
  # Verify SECRETS_ID is valid
  if [ -z "$SECRETS_ID" ]; then
    print_error "SECRETS_ID is empty, cannot retrieve root_password"
    exit 1
  fi
  
  # Show the item fields for debugging
  print_info "Listing fields in Debian Preseed item:"
  op item get "$SECRETS_ID" --format json 2>/dev/null | jq -r '.fields[] | "\(.label): \(.type)"' 2>/dev/null
  
  # Try our enhanced function that handles sections and alternative field names
  ROOT_PASSWORD=$(get_1password_secret "$SECRETS_ID" "root_password")
  
  if [ -z "$ROOT_PASSWORD" ]; then
    print_error "Failed to retrieve root password using all methods."
    print_info "As a last resort, trying to extract JSON manually..."
    
    # Get the full JSON and directly extract the field with jq
    local preseed_json=$(op item get "$SECRETS_ID" --format json --reveal 2>/dev/null)
    if [ -n "$preseed_json" ]; then
      # Try to find any field with label containing "root" and "password"
      ROOT_PASSWORD=$(echo "$preseed_json" | jq -r '.fields[] | select(.label | test("root.*password|password.*root"; "i")) | .value' 2>/dev/null)
      
      if [ -n "$ROOT_PASSWORD" ]; then
        print_success "Extracted root password using direct JSON parsing!"
      else
        # Last attempt - just try to get any password field
        ROOT_PASSWORD=$(echo "$preseed_json" | jq -r '.fields[] | select(.purpose=="PASSWORD") | .value' 2>/dev/null)
        if [ -n "$ROOT_PASSWORD" ]; then
          print_success "Found a password field as fallback!"
        else
          print_error "Could not find any usable password field in the item."
          print_info "Please ensure the 'Debian Preseed' item has a field called 'root_password' or similar."
          exit 1
        fi
      fi
    else
      print_error "Could not retrieve item JSON for manual extraction."
      exit 1
    fi
  else
    print_success "Successfully retrieved root_password using our enhanced function!"
  fi
else
  print_success "Successfully retrieved root_password directly by item name!"
fi

# Use the JSON approach to get all fields at once, which is more efficient
print_info "Retrieving all user fields using JSON approach..."
PRESEED_JSON=$(op item get "Debian Preseed" --vault="$VAULT_NAME" --format json --reveal 2>/dev/null)

if [ -n "$PRESEED_JSON" ]; then
  print_success "Retrieved full Debian Preseed item JSON"
  
  # Extract user fullname
  print_info "Extracting user_fullname..."
  USER_FULLNAME=$(echo "$PRESEED_JSON" | jq -r '.fields[] | select(.label=="user_fullname") | .value' 2>/dev/null)
  if [ -z "$USER_FULLNAME" ] || [ "$USER_FULLNAME" = "null" ]; then
    print_info "Trying alternative field names for user fullname..."
    for field in "fullname" "userfullname" "user fullname" "full_name" "full name"; do
      USER_FULLNAME=$(echo "$PRESEED_JSON" | jq -r --arg label "$field" '.fields[] | select(.label==$label) | .value' 2>/dev/null)
      if [ -n "$USER_FULLNAME" ] && [ "$USER_FULLNAME" != "null" ]; then
        print_success "Found user fullname using field: $field"
        break
      fi
    done
  fi
  
  if [ -z "$USER_FULLNAME" ] || [ "$USER_FULLNAME" = "null" ]; then
    print_warning "Could not find user fullname in any field"
    USER_FULLNAME="Debian User" # Default fallback
  fi
  
  # Extract username
  print_info "Extracting username..."
  USERNAME=$(echo "$PRESEED_JSON" | jq -r '.fields[] | select(.purpose=="USERNAME") | .value' 2>/dev/null)
  if [ -z "$USERNAME" ] || [ "$USERNAME" = "null" ]; then
    USERNAME=$(echo "$PRESEED_JSON" | jq -r '.fields[] | select(.label=="username") | .value' 2>/dev/null)
    if [ -z "$USERNAME" ] || [ "$USERNAME" = "null" ]; then
      print_info "Trying alternative field names for username..."
      for field in "user" "loginname" "login" "user name"; do
        USERNAME=$(echo "$PRESEED_JSON" | jq -r --arg label "$field" '.fields[] | select(.label==$label) | .value' 2>/dev/null)
        if [ -n "$USERNAME" ] && [ "$USERNAME" != "null" ]; then
          print_success "Found username using field: $field"
          break
        fi
      done
    fi
  fi
  
  if [ -z "$USERNAME" ] || [ "$USERNAME" = "null" ]; then
    print_error "Failed to retrieve username from any field, this is required"
    echo "$PRESEED_JSON" | jq -r '.fields[] | "\(.label): \(.type) (\(.purpose // "none"))"' 2>/dev/null
    exit 1
  else
    print_success "Found username: $USERNAME"
  fi
  
  # Extract user password
  print_info "Extracting user_password..."
  USER_PASSWORD=$(echo "$PRESEED_JSON" | jq -r '.fields[] | select(.label=="user_password") | .value' 2>/dev/null)
  if [ -z "$USER_PASSWORD" ] || [ "$USER_PASSWORD" = "null" ]; then
    print_info "Trying alternative field names for user password..."
    for field in "userpassword" "user password" "password"; do
      USER_PASSWORD=$(echo "$PRESEED_JSON" | jq -r --arg label "$field" '.fields[] | select(.label==$label) | .value' 2>/dev/null)
      if [ -n "$USER_PASSWORD" ] && [ "$USER_PASSWORD" != "null" ]; then
        print_success "Found user password using field: $field"
        break
      fi
    done
    
    # If still not found, try looking for PASSWORD purpose fields
    if [ -z "$USER_PASSWORD" ] || [ "$USER_PASSWORD" = "null" ]; then
      USER_PASSWORD=$(echo "$PRESEED_JSON" | jq -r '.fields[] | select(.purpose=="PASSWORD") | .value' 2>/dev/null)
      if [ -n "$USER_PASSWORD" ] && [ "$USER_PASSWORD" != "null" ]; then
        print_success "Found user password from PASSWORD purpose field"
      fi
    fi
  fi
  
  if [ -z "$USER_PASSWORD" ] || [ "$USER_PASSWORD" = "null" ]; then
    print_error "Failed to retrieve user password from any field, this is required"
    exit 1
  else
    print_success "Found user password, value is hidden"
  fi
  
  # Extract SSH authorized key
  print_info "Extracting SSH authorized key..."
  SSH_AUTHORIZED_KEY=$(echo "$PRESEED_JSON" | jq -r '.fields[] | select(.label=="ssh_authorized_key") | .value' 2>/dev/null)
else
  print_error "Failed to retrieve Debian Preseed item JSON - falling back to individual field retrieval"
  
  # Fallback to our enhanced get_1password_secret function if JSON approach fails
  USER_FULLNAME=$(get_1password_secret "$SECRETS_ID" "user_fullname")
  if [ $? -ne 0 ]; then
    print_warning "Failed to retrieve user fullname."
    USER_FULLNAME="Debian User" # Default fallback
  fi
  
  USERNAME=$(get_1password_secret "$SECRETS_ID" "username")
  if [ $? -ne 0 ]; then
    print_error "Failed to retrieve username, this is required."
    exit 1
  fi
  
  USER_PASSWORD=$(get_1password_secret "$SECRETS_ID" "user_password")
  if [ $? -ne 0 ]; then
    print_error "Failed to retrieve user password, this is required."
    exit 1
  fi
fi

# Check if SSH key was already extracted from JSON
if [ -z "$SSH_AUTHORIZED_KEY" ] || [ "$SSH_AUTHORIZED_KEY" = "null" ]; then
  print_info "SSH key not found in JSON extract, trying alternative methods..."
  
  # First try direct access by item title
  SSH_AUTHORIZED_KEY=$(op item get "Debian Preseed" --vault="$VAULT_NAME" --field "ssh_authorized_key" --reveal 2>/dev/null)
  
  # If that fails, try our enhanced function
  if [ -z "$SSH_AUTHORIZED_KEY" ] || [ "$SSH_AUTHORIZED_KEY" = "null" ]; then
    SSH_AUTHORIZED_KEY=$(get_1password_secret "$SECRETS_ID" "ssh_authorized_key" 2>/dev/null)
    
    # If still empty, try to extract from JSON with alternative field names
    if [ -z "$SSH_AUTHORIZED_KEY" ] || [ "$SSH_AUTHORIZED_KEY" = "null" ]; then
      if [ -n "$PRESEED_JSON" ]; then
        print_info "Trying alternative field names for SSH key..."
        for field in "sshkey" "ssh key" "ssh_key" "public key" "authorized_key"; do
          SSH_AUTHORIZED_KEY=$(echo "$PRESEED_JSON" | jq -r --arg label "$field" '.fields[] | select(.label==$label) | .value' 2>/dev/null)
          if [ -n "$SSH_AUTHORIZED_KEY" ] && [ "$SSH_AUTHORIZED_KEY" != "null" ]; then
            print_success "Found SSH key using field: $field"
            break
          fi
        done
      fi
    fi
  fi
  
  # If still not found, prompt the user
  if [ -z "$SSH_AUTHORIZED_KEY" ] || [ "$SSH_AUTHORIZED_KEY" = "null" ]; then
    print_warning "No SSH authorized key found in vault. You will need to provide one."
    echo "Please enter an SSH public key to be used for authentication (paste your public key):"
    read -r SSH_AUTHORIZED_KEY
    
    if [ -z "$SSH_AUTHORIZED_KEY" ]; then
      print_info "No SSH key provided. A key will be generated during installation."
      # Create a default message for the authorized_keys so it's not empty
      SSH_AUTHORIZED_KEY="# No SSH key was provided during installation. Add your public key here."
    fi
  else
    print_success "Found SSH authorized key"
  fi
else
  print_success "Found SSH authorized key from JSON extract"
fi

# Extract the actual values without the log output
ROOT_PASSWORD=$(clean_secret "$ROOT_PASSWORD")
USER_FULLNAME=$(clean_secret "$USER_FULLNAME")
USERNAME=$(clean_secret "$USERNAME")
USER_PASSWORD=$(clean_secret "$USER_PASSWORD")
SSH_AUTHORIZED_KEY=$(clean_secret "$SSH_AUTHORIZED_KEY")

# Debug output to verify values were set correctly
print_info "Verification of retrieved values:"
print_info "Root password: [REDACTED]"
print_info "User fullname: $USER_FULLNAME"
print_info "Username: $USERNAME"
print_info "User password: [REDACTED]"
print_info "SSH key: $(if [ -n "$SSH_AUTHORIZED_KEY" ]; then echo "[PROVIDED]"; else echo "[NOT PROVIDED]"; fi)"

# Validate credential values before proceeding
if [[ "$ROOT_PASSWORD" == *"CONCEALED"* ]]; then
  print_error "Invalid root password extracted from 1Password: $ROOT_PASSWORD"
  print_error "Password appears to contain the raw placeholder instead of the actual password"
  exit 1
fi

if [[ "$USERNAME" == *"CONCEALED"* ]]; then
  print_error "Invalid username extracted from 1Password: $USERNAME"
  print_error "Username appears to contain the raw placeholder instead of the actual username"
  exit 1
fi

if [[ "$USER_PASSWORD" == *"CONCEALED"* ]]; then
  print_error "Invalid user password extracted from 1Password: $USER_PASSWORD"
  print_error "Password appears to contain the raw placeholder instead of the actual password" 
  exit 1
fi

# Retrieve Network Configuration
print_info "Retrieving network configuration from 1Password vault..."
NUM_HOSTS=0
declare -a NETWORK_HOSTS=()
declare -a NETWORK_HOST_IPS=()
declare -a NETWORK_SHARES=()

if [ -n "$NETWORK_ID" ]; then
  # Get number of hosts from vault
  RAW_NUM_HOSTS=$(get_1password_secret "$NETWORK_ID" "num_hosts" 2>/dev/null)
  # Clean the output to get just the numeric value
  NUM_HOSTS=$(clean_secret "$RAW_NUM_HOSTS")
  # If NUM_HOSTS is not a number, set it to 0
  if ! [[ "$NUM_HOSTS" =~ ^[0-9]+$ ]]; then
    NUM_HOSTS=0
  fi
  
  print_info "Found configuration for $NUM_HOSTS hosts"
  
  # Get host information for each host
  if [ "$NUM_HOSTS" -gt 0 ]; then
    for i in $(seq 1 "$NUM_HOSTS"); do
      RAW_HOST_NAME=$(get_1password_secret "$NETWORK_ID" "host_${i}_name" 2>/dev/null)
      RAW_HOST_IP=$(get_1password_secret "$NETWORK_ID" "host_${i}_ip" 2>/dev/null)
      RAW_HOST_SHARE=$(get_1password_secret "$NETWORK_ID" "host_${i}_share" 2>/dev/null)
      
      HOST_NAME=$(clean_secret "$RAW_HOST_NAME")
      HOST_IP=$(clean_secret "$RAW_HOST_IP")
      HOST_SHARE=$(clean_secret "$RAW_HOST_SHARE")
      
      if [ -n "$HOST_NAME" ] && [ -n "$HOST_IP" ]; then
        NETWORK_HOSTS+=("$HOST_NAME")
        NETWORK_HOST_IPS+=("$HOST_IP")
        NETWORK_SHARES+=("$HOST_SHARE")
        print_info "Found host $i: $HOST_NAME ($HOST_IP)"
      fi
    done
  fi
fi

# Retrieve SMB share information
print_info "Retrieving SMB share configuration from 1Password vault..."
NUM_SHARES=0
declare -a SMB_HOSTS=()
declare -a SMB_SHARES=()
declare -a SMB_USERNAMES=()
declare -a SMB_PASSWORDS=()

if [ -n "$SMB_SHARES_ID" ]; then
  # Get the entire SMB Shares item content in JSON format for better section handling
  print_info "Retrieving SMB Shares item in JSON format..."
  SMB_SHARES_JSON=$(op item get "$SMB_SHARES_ID" --format json --reveal 2>/dev/null)
  
  if [ -n "$SMB_SHARES_JSON" ]; then
    # First try to get num_shares directly from JSON, regardless of section
    print_info "Extracting SMB shares count from JSON..."
    NUM_SHARES=$(echo "$SMB_SHARES_JSON" | jq -r '.fields[] | select(.label=="num_shares") | .value' 2>/dev/null)
    
    # If NUM_SHARES is not a number, set it to 0
    if ! [[ "$NUM_SHARES" =~ ^[0-9]+$ ]]; then
      print_warning "Invalid or missing num_shares value, defaulting to 0"
      NUM_SHARES=0
    fi
    
    print_info "Found configuration for $NUM_SHARES SMB shares"
    
    # Get share information for each share directly from JSON
    if [ "$NUM_SHARES" -gt 0 ]; then
      for i in $(seq 1 "$NUM_SHARES"); do
        # Extract values directly from JSON, regardless of section structure
        # Try both with and without underscore format (host1 and host_1)
        SMB_HOST=$(echo "$SMB_SHARES_JSON" | jq -r --arg label "host${i}" '.fields[] | select(.label==$label) | .value' 2>/dev/null)
        if [ -z "$SMB_HOST" ]; then
            SMB_HOST=$(echo "$SMB_SHARES_JSON" | jq -r --arg label "host_${i}" '.fields[] | select(.label==$label) | .value' 2>/dev/null)
        fi
        
        SMB_SHARE=$(echo "$SMB_SHARES_JSON" | jq -r --arg label "share${i}" '.fields[] | select(.label==$label) | .value' 2>/dev/null)
        if [ -z "$SMB_SHARE" ]; then
            SMB_SHARE=$(echo "$SMB_SHARES_JSON" | jq -r --arg label "share_${i}" '.fields[] | select(.label==$label) | .value' 2>/dev/null)
        fi
        
        SMB_USER=$(echo "$SMB_SHARES_JSON" | jq -r --arg label "username${i}" '.fields[] | select(.label==$label) | .value' 2>/dev/null)
        if [ -z "$SMB_USER" ]; then
            SMB_USER=$(echo "$SMB_SHARES_JSON" | jq -r --arg label "username_${i}" '.fields[] | select(.label==$label) | .value' 2>/dev/null)
        fi
        
        SMB_PASS=$(echo "$SMB_SHARES_JSON" | jq -r --arg label "password${i}" '.fields[] | select(.label==$label) | .value' 2>/dev/null)
        if [ -z "$SMB_PASS" ]; then
            SMB_PASS=$(echo "$SMB_SHARES_JSON" | jq -r --arg label "password_${i}" '.fields[] | select(.label==$label) | .value' 2>/dev/null)
        fi
        
        # If still not found, directly output all fields to help with debugging
        if [ -z "$SMB_HOST" ] || [ -z "$SMB_SHARE" ]; then
            print_info "Available fields for debugging:"
            echo "$SMB_SHARES_JSON" | jq -r '.fields[] | "\(.id): \(.label) (\(.type))"' 2>/dev/null
            
            # Based on your 1Password JSON, try using the exact field names we saw (with "section.")
            if [ -z "$SMB_HOST" ]; then
                # Try all possible patterns for the host field
                for pattern in "host$i" "host_$i" "smb_host_$i" "smb_host$i"; do
                    SMB_HOST=$(echo "$SMB_SHARES_JSON" | jq -r --arg label "$pattern" '.fields[] | select(.label==$label) | .value' 2>/dev/null)
                    if [ -n "$SMB_HOST" ]; then
                        print_success "Found host using pattern: $pattern"
                        break
                    fi
                done
                
                # Special lookup for the section format in your 1Password export
                if [ -z "$SMB_HOST" ]; then
                    SMB_HOST=$(echo "$SMB_SHARES_JSON" | jq -r '.fields[] | select(.section != null and .label=="host'"$i"'") | .value' 2>/dev/null)
                    
                    # Direct query as seen in your JSON output sample
                    if [ -z "$SMB_HOST" ]; then
                        print_info "Trying direct section query for 'host$i'..."
                        SMB_HOST=$(echo "$SMB_SHARES_JSON" | jq -r '.fields[] | select(.section.id != null and .label=="host'"$i"'") | .value' 2>/dev/null)
                        if [ -n "$SMB_HOST" ]; then
                            print_success "Found host using exact section query!"
                        fi
                    fi
                fi
            fi
            
            if [ -z "$SMB_SHARE" ]; then
                # Try all possible patterns for the share field
                for pattern in "share$i" "share_$i" "smb_share_$i" "smb_share$i"; do
                    SMB_SHARE=$(echo "$SMB_SHARES_JSON" | jq -r --arg label "$pattern" '.fields[] | select(.label==$label) | .value' 2>/dev/null)
                    if [ -n "$SMB_SHARE" ]; then
                        print_success "Found share using pattern: $pattern"
                        break
                    fi
                done
                
                # Special lookup for the section format in your 1Password export
                if [ -z "$SMB_SHARE" ]; then
                    SMB_SHARE=$(echo "$SMB_SHARES_JSON" | jq -r '.fields[] | select(.section != null and .label=="share'"$i"'") | .value' 2>/dev/null)
                    
                    # Direct query as seen in your JSON output sample
                    if [ -z "$SMB_SHARE" ]; then
                        print_info "Trying direct section query for 'share$i'..."
                        SMB_SHARE=$(echo "$SMB_SHARES_JSON" | jq -r '.fields[] | select(.section.id != null and .label=="share'"$i"'") | .value' 2>/dev/null)
                        if [ -n "$SMB_SHARE" ]; then
                            print_success "Found share using exact section query!"
                        fi
                    fi
                fi
            fi
            
            if [ -z "$SMB_USER" ]; then
                # Try all possible patterns for the username field
                for pattern in "username$i" "username_$i" "smb_username_$i" "smb_username$i" "user$i" "user_$i"; do
                    SMB_USER=$(echo "$SMB_SHARES_JSON" | jq -r --arg label "$pattern" '.fields[] | select(.label==$label) | .value' 2>/dev/null)
                    if [ -n "$SMB_USER" ]; then
                        print_success "Found username using pattern: $pattern"
                        break
                    fi
                done
                
                # Special lookup for the section format in your 1Password export
                if [ -z "$SMB_USER" ]; then
                    SMB_USER=$(echo "$SMB_SHARES_JSON" | jq -r '.fields[] | select(.section != null and .label=="username'"$i"'") | .value' 2>/dev/null)
                    
                    # Direct query as seen in your JSON output sample
                    if [ -z "$SMB_USER" ]; then
                        print_info "Trying direct section query for 'username$i'..."
                        SMB_USER=$(echo "$SMB_SHARES_JSON" | jq -r '.fields[] | select(.section.id != null and .label=="username'"$i"'") | .value' 2>/dev/null)
                        if [ -n "$SMB_USER" ]; then
                            print_success "Found username using exact section query!"
                        fi
                    fi
                fi
            fi
            
            if [ -z "$SMB_PASS" ]; then
                # Try all possible patterns for the password field
                for pattern in "password$i" "password_$i" "smb_password_$i" "smb_password$i" "pass$i" "pass_$i"; do
                    SMB_PASS=$(echo "$SMB_SHARES_JSON" | jq -r --arg label "$pattern" '.fields[] | select(.label==$label) | .value' 2>/dev/null)
                    if [ -n "$SMB_PASS" ]; then
                        print_success "Found password using pattern: $pattern"
                        break
                    fi
                done
                
                # Special lookup for the section format in your 1Password export
                if [ -z "$SMB_PASS" ]; then
                    SMB_PASS=$(echo "$SMB_SHARES_JSON" | jq -r '.fields[] | select(.section != null and .label=="password'"$i"'") | .value' 2>/dev/null)
                    
                    # Direct query as seen in your JSON output sample
                    if [ -z "$SMB_PASS" ]; then
                        print_info "Trying direct section query for 'password$i'..."
                        SMB_PASS=$(echo "$SMB_SHARES_JSON" | jq -r '.fields[] | select(.section.id != null and .label=="password'"$i"'") | .value' 2>/dev/null)
                        if [ -n "$SMB_PASS" ]; then
                            print_success "Found password using exact section query!"
                        fi
                    fi
                fi
            fi
        fi
        
        # Debug output to help diagnose issues
        print_debug "Host${i} value from JSON: '$SMB_HOST'"
        print_debug "Share${i} value from JSON: '$SMB_SHARE'"
        print_debug "Username${i} value from JSON: '$SMB_USER'"
        print_debug "Password${i} value from JSON: '[REDACTED]'"
        
        if [ -n "$SMB_HOST" ] && [ -n "$SMB_SHARE" ]; then
          SMB_HOSTS+=("$SMB_HOST")
          SMB_SHARES+=("$SMB_SHARE")
          SMB_USERNAMES+=("${SMB_USER:-$USERNAME}")
          SMB_PASSWORDS+=("${SMB_PASS:-$USER_PASSWORD}")
          print_info "Found SMB share $i: $SMB_HOST/$SMB_SHARE"
        else
          print_warning "Missing host or share information for SMB share $i"
        fi
      done
    fi
  else
    print_error "Failed to retrieve SMB Shares item JSON"
  fi
fi

print_success "Secrets retrieved successfully!"

# ISO build variables
LATEST_ISO=$(curl -s https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/ | grep -oP 'debian-\d+\.\d+\.\d+-amd64-netinst\.iso' | sort -V | tail -n 1)
ISO_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/$LATEST_ISO"
ISO_FILENAME=$LATEST_ISO
WORK_DIR="debian-remaster"
SRC_DIR="src"
CONFIG_DIR="$SRC_DIR/config"
SCRIPTS_DIR="$SRC_DIR/scripts"
SERVICES_DIR="$SRC_DIR/services"
PRESEED_FILE="$CONFIG_DIR/preseed.cfg"

# Install required packages
print_info "Installing required packages..."
$SUDO apt-get update
$SUDO apt-get install -y xorriso isolinux grub-efi-amd64-bin wget curl

# Check for existing preseed.cfg
if [ ! -f "$PRESEED_FILE" ]; then
  print_error "Preseed file not found at $PRESEED_FILE"
  print_info "Please create the preseed file before running this script."
  exit 1
fi

print_info "Using existing preseed file from $PRESEED_FILE"

# Create a temporary preseed file with variables substituted
print_info "Substituting secrets in preseed file..."
print_info "Values to be substituted:"
print_info "USERNAME: $USERNAME"
print_info "USER_FULLNAME: $USER_FULLNAME"
print_info "ROOT_PASSWORD: [REDACTED]"
print_info "USER_PASSWORD: [REDACTED]"
print_info "NUM_SHARES: $NUM_SHARES"
print_info "NUM_HOSTS: $NUM_HOSTS"

# Validate all required variables before substitution
if [ -z "$USERNAME" ] || [ -z "$USER_FULLNAME" ] || [ -z "$ROOT_PASSWORD" ] || [ -z "$USER_PASSWORD" ]; then
  print_error "One or more required variables are empty:"
  print_error "USERNAME: $(if [ -z "$USERNAME" ]; then echo "EMPTY"; else echo "SET"; fi)"
  print_error "USER_FULLNAME: $(if [ -z "$USER_FULLNAME" ]; then echo "EMPTY"; else echo "SET"; fi)"
  print_error "ROOT_PASSWORD: $(if [ -z "$ROOT_PASSWORD" ]; then echo "EMPTY"; else echo "SET"; fi)"
  print_error "USER_PASSWORD: $(if [ -z "$USER_PASSWORD" ]; then echo "EMPTY"; else echo "SET"; fi)"
  exit 1
fi

TMP_PRESEED=$(mktemp)

# Function to properly escape variables for sed
escape_for_sed() {
  echo "$1" | sed -e 's/[\/&]/\\&/g'
}

# Make the base substitutions first (authentication)
ROOT_PASSWORD_ESC=$(escape_for_sed "$ROOT_PASSWORD")
USER_FULLNAME_ESC=$(escape_for_sed "$USER_FULLNAME")
USERNAME_ESC=$(escape_for_sed "$USERNAME")
USER_PASSWORD_ESC=$(escape_for_sed "$USER_PASSWORD")
SSH_AUTHORIZED_KEY_ESC=$(escape_for_sed "$SSH_AUTHORIZED_KEY")

sed \
  -e "s/\${rootpassword}/$ROOT_PASSWORD_ESC/g" \
  -e "s/\${userfullname}/$USER_FULLNAME_ESC/g" \
  -e "s/\${username}/$USERNAME_ESC/g" \
  -e "s/\${userpassword}/$USER_PASSWORD_ESC/g" \
  -e "s|\${ssh_authorized_key}|$SSH_AUTHORIZED_KEY_ESC|g" \
  -e "s/\${num_smb_shares}/$NUM_SHARES/g" \
  "$PRESEED_FILE" > "$TMP_PRESEED"

# Substitute SMB share variables
if [ "$NUM_SHARES" -gt 0 ]; then
  for i in $(seq 1 "$NUM_SHARES"); do
    idx=$((i-1))
    if [ $idx -lt ${#SMB_HOSTS[@]} ]; then
      host=$(escape_for_sed "${SMB_HOSTS[$idx]}")
      share=$(escape_for_sed "${SMB_SHARES[$idx]}")
      user=$(escape_for_sed "${SMB_USERNAMES[$idx]}")
      pass=$(escape_for_sed "${SMB_PASSWORDS[$idx]}")
      
      sed -i \
        -e "s/\${smb_host$i}/$host/g" \
        -e "s/\${smb_share$i}/$share/g" \
        -e "s/\${smb_username$i}/$user/g" \
        -e "s/\${smb_password$i}/$pass/g" \
        "$TMP_PRESEED"
    fi
  done
fi

# Substitute network host variables
sed -i "s/\${num_network_hosts}/$NUM_HOSTS/g" "$TMP_PRESEED"

if [ "$NUM_HOSTS" -gt 0 ]; then
  for i in $(seq 1 "$NUM_HOSTS"); do
    idx=$((i-1))
    if [ $idx -lt ${#NETWORK_HOSTS[@]} ]; then
      host=$(escape_for_sed "${NETWORK_HOSTS[$idx]}")
      ip=$(escape_for_sed "${NETWORK_HOST_IPS[$idx]}")
      share=$(escape_for_sed "${NETWORK_SHARES[$idx]}")
      
      sed -i \
        -e "s/\${smb_host_${i}_name}/$host/g" \
        -e "s/\${smb_host_${i}_ip}/$ip/g" \
        -e "s/\${smb_host_${i}_share}/$share/g" \
        "$TMP_PRESEED"
    fi
  done
fi

# Create a network configuration file directly in the ISO structure
print_info "Creating network configuration file in ISO structure..."
mkdir -p "$WORK_DIR/extracted/$SCRIPTS_DIR"

# Create network_config.sh directly in the ISO structure
NETWORK_CONFIG_FILE="$WORK_DIR/extracted/$SCRIPTS_DIR/network_config.sh"
$SUDO cat > "$NETWORK_CONFIG_FILE" << EOF
#!/bin/bash
# Network configuration file generated by build-secrets-based.sh
# This file contains network and share information for the system

# Number of network hosts
export NUM_NETWORK_HOSTS=$NUM_HOSTS

EOF

# Add host configuration
if [ "$NUM_HOSTS" -gt 0 ]; then
  $SUDO bash -c "cat >> \"$NETWORK_CONFIG_FILE\"" << EOF
# Network hosts
EOF
  
  for i in $(seq 1 "$NUM_HOSTS"); do
    idx=$((i-1))
    if [ $idx -lt ${#NETWORK_HOSTS[@]} ]; then
      $SUDO bash -c "cat >> \"$NETWORK_CONFIG_FILE\"" << EOF
export SMB_HOST_${i}_NAME="${NETWORK_HOSTS[$idx]}"
export SMB_HOST_${i}_IP="${NETWORK_HOST_IPS[$idx]}"
export SMB_HOST_${i}_SHARE="${NETWORK_SHARES[$idx]}"

EOF
    fi
  done
fi

# Add username to the configuration file - validate that it's a proper value first
if [[ "$USERNAME" == *"CONCEALED"* || -z "$USERNAME" ]]; then
  print_error "Cannot add invalid username to network config. Value: '$USERNAME'"
  exit 1
fi

$SUDO bash -c "cat >> \"$NETWORK_CONFIG_FILE\"" << EOF
# User information
export username="$USERNAME"

# SSH authorized key
export ssh_authorized_key="$SSH_AUTHORIZED_KEY"

# SMB Shares for auto-mounting
export NUM_SMB_SHARES=$NUM_SHARES

EOF

# Add SMB share information
if [ "$NUM_SHARES" -gt 0 ]; then
  for i in $(seq 1 "$NUM_SHARES"); do
    idx=$((i-1))
    if [ $idx -lt ${#SMB_HOSTS[@]} ]; then
      $SUDO bash -c "cat >> \"$NETWORK_CONFIG_FILE\"" << EOF
# SMB Share $i
export SMB_HOST_$i="${SMB_HOSTS[$idx]}"
export SMB_SHARE_$i="${SMB_SHARES[$idx]}"
export SMB_USERNAME_$i="${SMB_USERNAMES[$idx]}"
export SMB_PASSWORD_$i="${SMB_PASSWORDS[$idx]}"

EOF
    fi
  done
fi

# Make the network configuration file executable
$SUDO chmod +x "$NETWORK_CONFIG_FILE"

# Create necessary scripts directory
print_info "Checking for necessary script directories..."
mkdir -p "$SCRIPTS_DIR"


# Ensure our new setup_optional_packages.sh exists
if [ ! -f "$SCRIPTS_DIR/setup_optional_packages.sh" ]; then
  print_error "setup_optional_packages.sh not found in $SCRIPTS_DIR"
  print_info "This script is required for the installation. Please make sure it exists."
  exit 1
else
  print_success "Found setup_optional_packages.sh script"
fi

# Ensure init.sh is present in scripts dir
if [ ! -f "$SCRIPTS_DIR/init.sh" ]; then
  print_info "Creating basic init.sh script..."
  cat > "$SCRIPTS_DIR/init.sh" << 'EOF'
#!/bin/bash
echo "First boot initialization starting..."

# Source network configuration if available
if [ -f /usr/local/etc/network_config.sh ]; then
  echo "Loading network configuration..."
  source /usr/local/etc/network_config.sh
  
  # Display network configuration (optional)
  echo "Network hosts configuration loaded:"
  echo "Number of network hosts: $NUM_NETWORK_HOSTS"
  
  for i in $(seq 1 $NUM_NETWORK_HOSTS); do
    if [ -n "$(eval echo \$SMB_HOST_${i}_NAME)" ]; then
      HOST_NAME="$(eval echo \$SMB_HOST_${i}_NAME)"
      HOST_IP="$(eval echo \$SMB_HOST_${i}_IP)"
      HOST_SHARE="$(eval echo \$SMB_HOST_${i}_SHARE)"
      echo "Host $i: $HOST_NAME ($HOST_IP)"
      if [ -n "$HOST_SHARE" ]; then
        echo "  Share: $HOST_SHARE"
      fi
    fi
  done
  
  echo "SMB Shares configuration loaded:"
  echo "Number of SMB shares: $NUM_SMB_SHARES"
  for i in $(seq 1 $NUM_SMB_SHARES); do
    if [ -n "$(eval echo \$SMB_HOST_$i)" ]; then
      SHARE_HOST="$(eval echo \$SMB_HOST_$i)"
      SHARE_NAME="$(eval echo \$SMB_SHARE_$i)"
      echo "Share $i: $SHARE_HOST/$SHARE_NAME"
    fi
  done
fi

# Add your post-installation commands here
echo "First boot initialization complete."
EOF
  chmod +x "$SCRIPTS_DIR/init.sh"
fi

# Ensure first-boot.service is present in services dir
mkdir -p "$SERVICES_DIR"
if [ ! -f "$SERVICES_DIR/first-boot.service" ]; then
  print_info "Creating first-boot.service unit file..."
  cat > "$SERVICES_DIR/first-boot.service" << 'EOF'
[Unit]
Description=First Boot Setup Service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/init.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
fi

# Set up ISO build environment
print_info "Setting up ISO build environment..."
$SUDO mkdir -p "$WORK_DIR"/{iso,extracted}

# Download ISO if needed
if [ ! -f "$ISO_FILENAME" ]; then
  print_info "Downloading Debian ISO from $ISO_URL..."
  wget "$ISO_URL"
fi

# Mount and extract ISO
print_info "Mounting ISO..."
$SUDO mount -o loop "$ISO_FILENAME" "$WORK_DIR/iso"

print_info "Copying files..."
$SUDO cp -rT "$WORK_DIR/iso" "$WORK_DIR/extracted"

$SUDO umount "$WORK_DIR/iso"

# Create necessary directories in the ISO
$SUDO mkdir -p "$WORK_DIR/extracted/$SRC_DIR"/{scripts,services,config}
$SUDO mkdir -p "$WORK_DIR/extracted/usr/local/etc"

# Copy files to the ISO
print_info "Copying configuration files to ISO..."
$SUDO cp "$TMP_PRESEED" "$WORK_DIR/extracted/preseed.cfg"
$SUDO cp "$SCRIPTS_DIR/init.sh" "$WORK_DIR/extracted/$SCRIPTS_DIR/init.sh"

# Copy the new setup scripts to the ISO
$SUDO cp "$SCRIPTS_DIR/setup_system.sh" "$WORK_DIR/extracted/$SCRIPTS_DIR/"
$SUDO cp "$SCRIPTS_DIR/setup_ssh.sh" "$WORK_DIR/extracted/$SCRIPTS_DIR/"
$SUDO cp "$SCRIPTS_DIR/setup_smb.sh" "$WORK_DIR/extracted/$SCRIPTS_DIR/"
$SUDO cp "$SCRIPTS_DIR/setup_updates.sh" "$WORK_DIR/extracted/$SCRIPTS_DIR/"
$SUDO cp "$SCRIPTS_DIR/setup_wrapper.sh" "$WORK_DIR/extracted/$SCRIPTS_DIR/"
$SUDO cp "$SCRIPTS_DIR/setup_optional_packages.sh" "$WORK_DIR/extracted/$SCRIPTS_DIR/"
$SUDO chmod +x "$WORK_DIR/extracted/$SCRIPTS_DIR/setup_*.sh"

$SUDO cp "$SERVICES_DIR/first-boot.service" "$WORK_DIR/extracted/$SERVICES_DIR/"

# Clean up temporary files
rm "$TMP_PRESEED"

# Update boot configuration
print_info "Updating boot configuration..."
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

# Directly substitute network and share variables in preseed.cfg
print_info "Directly substituting network and share variables in preseed.cfg..."
for i in $(seq 1 "$NUM_HOSTS"); do
  idx=$((i-1))
  if [ $idx -lt ${#NETWORK_HOSTS[@]} ]; then
    host="${NETWORK_HOSTS[$idx]}"
    ip="${NETWORK_HOST_IPS[$idx]}"
    share="${NETWORK_SHARES[$idx]}"
    
    # Replace the variables in preseed.cfg with their actual values
    $SUDO sed -i "s/\${smb_host_${i}_name}/$host/g" "$WORK_DIR/extracted/preseed.cfg"
    $SUDO sed -i "s/\${smb_host_${i}_ip}/$ip/g" "$WORK_DIR/extracted/preseed.cfg"
    $SUDO sed -i "s/\${smb_host_${i}_share}/$share/g" "$WORK_DIR/extracted/preseed.cfg"
  fi
done

# Directly substitute SMB share variables in preseed.cfg
for i in $(seq 1 "$NUM_SHARES"); do
  idx=$((i-1))
  if [ $idx -lt ${#SMB_HOSTS[@]} ]; then
    host="${SMB_HOSTS[$idx]}"
    share="${SMB_SHARES[$idx]}"
    user="${SMB_USERNAMES[$idx]}"
    pass="${SMB_PASSWORDS[$idx]}"
    
    # Replace the variables in preseed.cfg with their actual values
    $SUDO sed -i "s/\${smb_host$i}/$host/g" "$WORK_DIR/extracted/preseed.cfg"
    $SUDO sed -i "s/\${smb_share$i}/$share/g" "$WORK_DIR/extracted/preseed.cfg"
    $SUDO sed -i "s/\${smb_username$i}/$user/g" "$WORK_DIR/extracted/preseed.cfg"
    $SUDO sed -i "s/\${smb_password$i}/$pass/g" "$WORK_DIR/extracted/preseed.cfg"
  fi
done

# We no longer need to inject SMB variables directly into the preseed command
# since they're now passed through network_config.sh
print_info "Using network_config.sh for SMB share variable definitions..."

print_info "Creating new ISO..."
# Extract the Debian version from the downloaded ISO filename
VERSION=$(echo "$ISO_FILENAME" | grep -oP 'debian-\K\d+\.\d+\.\d+(?=-amd64)')
NEW_ISO="debian-${VERSION}-preseed-secrets-based.iso"
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

# Change ownership of the ISO file to the current user
CURRENT_USER=$(whoami)
print_info "Changing ownership of $NEW_ISO to $CURRENT_USER..."
$SUDO chown "$CURRENT_USER": "$NEW_ISO"

# Clean up
$SUDO rm -rf "$WORK_DIR"

# Unset sensitive variables
unset rootpassword userfullname username userpassword ROOT_PASSWORD USER_FULLNAME USERNAME USER_PASSWORD
unset ssh_authorized_key SSH_AUTHORIZED_KEY
unset NETWORK_HOSTS NETWORK_HOST_IPS NETWORK_SHARES
unset NUM_HOSTS
unset SMB_HOSTS SMB_SHARES SMB_USERNAMES SMB_PASSWORDS
unset NUM_SHARES 

openssl enc -aes-256-cbc -salt -in $NEW_ISO -out $NEW_ISO.enc -pbkdf2

$SUDO rm $NEW_ISO

ITEM_NAME="Encrypted ISO Location"

# Function to check if an item exists in 1Password
item_exists() {
    local item="$1"
    op item get "$item" >/dev/null 2>&1
    return $?
}

# Set the destination path
DESTINATION_PATH="/mnt/syno/software/os"

# Check if the item exists
if item_exists "$ITEM_NAME"; then
    echo "Item '$ITEM_NAME' found in 1Password. Moving file..."
    sudo mv "$NEW_ISO.enc" "$DESTINATION_PATH"
    FINAL_PATH="$DESTINATION_PATH/$(basename "$NEW_ISO.enc")"
else
    echo "Item '$ITEM_NAME' not found in 1Password. Skipping move."
    FINAL_PATH="$NEW_ISO.enc"
fi

# Create a version of the path without the .enc extension
DECRYPTED_PATH="${FINAL_PATH%.enc}"

# Print cleaner output
print_success "Done! Encrypted ISO: $FINAL_PATH"
print_info "Decrypt command: openssl enc -aes-256-cbc -d -in $FINAL_PATH -out $DECRYPTED_PATH -pbkdf2"