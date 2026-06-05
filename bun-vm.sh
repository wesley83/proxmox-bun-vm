#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Bun VM Auto-Provisioning Script for Proxmox VE
#
# Original source code:
#   https://github.com/wesley83/proxmox-bun-vm
#
# This script was created by:
#   Wesley Faulkner
#
# Version: v1.3.0
# -----------------------------------------------------------------------------
set -euo pipefail

############################################
# Color + UI helpers
############################################
if [ -t 1 ]; then
  RED="$(printf '\033[31m')"
  GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"
  BLUE="$(printf '\033[34m')"
  CYAN="$(printf '\033[36m')"
  BOLD="$(printf '\033[1m')"
  RESET="$(printf '\033[0m')"
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; RESET=""
fi

INFO()  { echo "${BLUE}[INFO]${RESET}  $*"; }
WARN()  { echo "${YELLOW}[WARN]${RESET}  $*"; }
ERROR() { echo "${RED}[ERROR]${RESET} $*" >&2; }
OK()    { echo "${GREEN}[OK]${RESET}    $*"; }
DEBUG() { [[ "$DEBUG" -eq 1 ]] && echo "${CYAN}[DEBUG]${RESET} $*"; }

############################################
# Banner
############################################
SCRIPT_VERSION="v1.3.0"
REPO_URL="https://github.com/wesley83/proxmox-bun-vm"

printf "${GREEN}${BOLD}"
  cat <<'EOF'
 /$$$$$$$                      /$$    /$$ /$$      /$$      
| $$__  $$                    | $$   | $$| $$$    /$$$      
| $$  \ $$ /$$   /$$ /$$$$$$$ | $$   | $$| $$$$  /$$$$      
| $$$$$$$ | $$  | $$| $$__  $$|  $$ / $$/| $$ $$/$$ $$      
| $$__  $$| $$  | $$| $$  \ $$ \  $$ $$/ | $$  $$$| $$      
| $$  \ $$| $$  | $$| $$  | $$  \  $$$/  | $$\  $ | $$      
| $$$$$$$/|  $$$$$$/| $$  | $$   \  $/   | $$ \/  | $$      
|_______/  \______/ |__/  |__/    \_/    |__/     |__/                                                      
                                                                                                                    
EOF
printf "${RESET}\n"

printf "${CYAN}             Bun VM Installer for Proxmox VE${RESET}\n"
printf "${GREEN}                        ${SCRIPT_VERSION}${RESET}\n"
printf "${CYAN}     ${REPO_URL}${RESET}\n\n"

############################################
# Defaults
############################################
MEMORY_MB=4096
CORES=2
DISK_SIZE="20G"
UBUNTU_CODENAME="noble"   # Fallback if LTS auto-detection fails
VM_USER="developer"
SSH_KEY_PATH="auto"       # auto-detect /root/.ssh/id_ed25519.pub or id_rsa.pub
SNIPPET_STORAGE_ID="auto"
DEBUG=0
_UBUNTU_USER_SET=0        # Set to 1 if --ubuntu is passed on the command line

############################################
# Resolve latest Ubuntu LTS codename
############################################
# Fetches the current latest active LTS codename from Launchpad's API.
# Used as the default UBUNTU_CODENAME when the user doesn't pass --ubuntu.
# Falls back to the hard-coded "noble" (24.04 LTS) if python3, curl, or
# the API is unavailable — keeps the script working in air-gapped/restricted
# environments and avoids a hard dependency on Python.
get_latest_lts() {
  command -v python3 >/dev/null 2>&1 || return 0
  curl -fsSL --max-time 10 \
    'https://api.launchpad.net/1.0/ubuntu/series?active=true' 2>/dev/null | \
  python3 -c '
import json, sys
data = json.load(sys.stdin)
# Ubuntu LTS releases are always the April (.04) releases of even years
# (14.04, 16.04, 18.04, 20.04, 22.04, 24.04, 26.04, ...). Non-LTS are .10.
# Note: the API "version" field is just "24.04" — it does NOT contain "LTS".
#
# Future-proofing: when the next .04 (e.g. 28.04) enters "Active Development"
# ~6 months before release, it will be flagged active=true and match this
# filter - the cloud image will not exist yet and curl will 404. The current
# failure mode is loud (script exits on the curl error) and the user can
# pin with --ubuntu <codename>. If this becomes a recurring annoyance, add
#   and s.get("status") in ("Current Stable Release", "Supported")
# to the filter to exclude in-development series.
lts = [s for s in data.get("entries", [])
       if s.get("active", False) and s.get("version", "").endswith(".04")]
if lts:
    def key(s):
        try:
            return tuple(int(p) for p in s["version"].split("."))
        except (ValueError, IndexError):
            return (0,)
    print(max(lts, key=key)["name"])
' 2>/dev/null
}

############################################
# Help menu
############################################
print_help() {
  cat <<EOF
Usage: bun-vm.sh [options]

Options:
  -m, --memory <MB>       RAM in MB (default 4096, must be >= 1)
  -c, --cores <N>         CPU cores (default 2, must be >= 1)
  -d, --disk <SIZE>       Disk size with suffix (e.g. 20G, 512M; default 20G)
  -u, --ubuntu <codename> Ubuntu cloud image codename (default: latest active LTS,
                          falls back to noble)
  --user <name>           VM username (default: developer; lowercase, must
                          start with letter or _ and be <= 32 chars)
  --ssh-key <path>        SSH public key file (default: auto-detect
                          /root/.ssh/id_ed25519.pub, then id_rsa.pub)
  --debug                 Enable bash debug tracing
  -h, --help              Show help

EOF
}

############################################
# Parse args
############################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--memory)
      [[ "${2:-}" =~ ^[0-9]+$ ]] || { ERROR "--memory must be a positive integer (MB)"; exit 1; }
      (( $2 >= 1 )) || { ERROR "--memory must be >= 1 (got: $2)"; exit 1; }
      MEMORY_MB="$2"; shift 2;;
    -c|--cores)
      [[ "${2:-}" =~ ^[0-9]+$ ]] || { ERROR "--cores must be a positive integer"; exit 1; }
      (( $2 >= 1 )) || { ERROR "--cores must be >= 1 (got: $2)"; exit 1; }
      CORES="$2"; shift 2;;
    -d|--disk)
      [[ "${2:-}" =~ ^[0-9]+[MGK]$ ]] || { ERROR "--disk must have a suffix (e.g. 20G, 512M) — bare numbers default to MB in qm resize"; exit 1; }
      size_num="${2%[MGK]}"
      (( size_num >= 1 )) || { ERROR "--disk must be >= 1 (got: $2)"; exit 1; }
      DISK_SIZE="$2"; shift 2;;
    -u|--ubuntu)
      [[ -n "${2:-}" && "${2:-}" != -* ]] || { ERROR "--ubuntu requires a codename argument"; exit 1; }
      UBUNTU_CODENAME="$2"; _UBUNTU_USER_SET=1; shift 2;;
    --user)
      [[ "${2:-}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { ERROR "--user must be a valid Linux username (lowercase, starts with a-z or _, max 32 chars)"; exit 1; }
      VM_USER="$2"; shift 2;;
    --ssh-key)
      [[ -f "${2:-}" ]] || { ERROR "--ssh-key: file '$2' not found or not a regular file"; exit 1; }
      [[ "$2" == *.pub ]] || {
        ERROR "--ssh-key: file '$2' does not end in .pub"
        ERROR "HINT: extract the public key from a private key with:"
        ERROR "  ssh-keygen -y -f <private-key> > <name>.pub"
        ERROR "Or rename the file if it's already a public key."
        exit 1
      }
      SSH_KEY_PATH="$2"; shift 2;;
    --debug)     DEBUG=1; shift;;
    -h|--help)   print_help; exit 0;;
    *) ERROR "Unknown option: $1"; exit 1;;
  esac
done

# Auto-detect the latest Ubuntu LTS if the user didn't pin one with --ubuntu
if [[ "$_UBUNTU_USER_SET" -eq 0 ]]; then
  LATEST_LTS="$(get_latest_lts 2>/dev/null || true)"
  if [[ -n "$LATEST_LTS" && "$LATEST_LTS" != "$UBUNTU_CODENAME" ]]; then
    INFO "Auto-detected latest Ubuntu LTS: ${LATEST_LTS} (default was: ${UBUNTU_CODENAME})"
    UBUNTU_CODENAME="$LATEST_LTS"
  fi
fi

[[ "$DEBUG" -eq 1 ]] && set -x

############################################
# Environment validation
############################################
if [[ "$(id -u)" -ne 0 ]]; then
  ERROR "This script must be run as root on a Proxmox VE node."
  exit 1
fi

for cmd in qm pvesh pvesm awk curl ip qemu-img; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    ERROR "Required command '$cmd' not found. Are you running this on a Proxmox node?"
    exit 1
  fi
done

############################################
# VM ID and log setup
############################################
if ! VM_ID="$(pvesh get /cluster/nextid 2>/dev/null)"; then
  ERROR "Failed to get next VM ID — cluster/quorum may be degraded."
  exit 1
fi

VM_NAME="bun-dev-${VM_ID}"
LOG_FILE="/var/log/bun-vm-${VM_ID}.log"

# Begin logging
exec > >(tee -a "$LOG_FILE") 2>&1
TEE_PID=$!

INFO "Log file: $LOG_FILE"
INFO "Script version: $SCRIPT_VERSION"
INFO "Repo: $REPO_URL"
INFO "Using VMID: $VM_ID"
INFO "VM Name: $VM_NAME"
INFO "Ubuntu codename: $UBUNTU_CODENAME"
INFO "Resources: ${MEMORY_MB} MB RAM, ${CORES} cores, disk ${DISK_SIZE}"
INFO "Snippet storage mode: ${SNIPPET_STORAGE_ID}"

############################################
# Cleanup handler
############################################
VM_CREATED=0
IMG_FILE=""

cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    ERROR "Script failed with exit code $exit_code."

    if [[ $VM_CREATED -eq 1 ]]; then
      WARN "Cleaning up VM ${VM_ID}..."
      qm stop "${VM_ID}" >/dev/null 2>&1 || true
      qm destroy "${VM_ID}" --purge >/dev/null 2>&1 || true
      OK "Destroyed VM ${VM_ID}."
    fi

    if [[ -n "$IMG_FILE" && -f "$IMG_FILE" ]]; then
      WARN "Removing downloaded image ${IMG_FILE}..."
      rm -f "${IMG_FILE}" || true
    fi

    ERROR "See log file for details: ${LOG_FILE}"
  fi

  # Close stdout to signal EOF to tee (otherwise wait deadlocks — tee blocks
  # on read() of the still-open pipe), then wait for tee to finish flushing.
  exec >/dev/null 2>&1
  wait "${TEE_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

############################################
# Detect VM disk storage
############################################
INFO "Detecting VM disk storage..."

# pvesm status columns: Name(1) Type(2) Status(3) Total(4) Used(5) Available(6) %(7).
# Format has been stable across PVE 6/7/8/9; if it ever changes we'll fall
# through to the empty-string check below and fail with a clear error.
if pvesm status | awk 'NR>1{print $1,$3}' | grep '^local-lvm active' >/dev/null; then
  STORAGE="local-lvm"
else
  STORAGE="$(pvesm status | awk 'NR>1 && $3=="active"{print $1;exit}' || true)"
fi

if [[ -z "${STORAGE}" ]]; then
  ERROR "Could not determine active storage for VM disks."
  exit 1
fi

# Verify the chosen storage can hold VM disks (images or rootdir content)
STORAGE_CONTENT="$(
  awk -v target="${STORAGE}" '
    /^[a-z0-9_-]+:/{split($0,a,"[ :]+"); id=a[2]; inblock=(id==target)}
    inblock && $1=="content"{print; exit}
  ' /etc/pve/storage.cfg
)"
if [[ "$STORAGE_CONTENT" != *images* && "$STORAGE_CONTENT" != *rootdir* ]]; then
  ERROR "Storage '${STORAGE}' does not support VM disks (content: ${STORAGE_CONTENT:-none})."
  ERROR "Enable 'Disk image' / 'Container' content on this storage, or use a storage that already has it."
  exit 1
fi

OK "Using disk storage: ${STORAGE}"

############################################
# Snippet auto-detect (fixed version)
############################################
CFG="/etc/pve/storage.cfg"
INFO "Using storage configuration file: ${CFG}"

if [[ ! -f "${CFG}" ]]; then
  ERROR "Missing storage.cfg — this node may not be healthy."
  exit 1
fi

INFO "Scanning for snippet-capable storages..."
INFO "Debug: snippet-capable storage blocks:"
awk '
  /^[a-z0-9_-]+:/ {hdr=$0; inblock=1; has=0}
  inblock && $1=="content" && /snippets/ {has=1}
  NF==0 && inblock {
    if(has){print "  " hdr "\n    (content includes snippets)"}
    inblock=0
  }
  END { if(inblock && has) print "  " hdr "\n    (content includes snippets)"}
' "$CFG"

if [[ "$SNIPPET_STORAGE_ID" == "auto" || -z "$SNIPPET_STORAGE_ID" ]]; then
  INFO "Auto-selecting first snippet-enabled storage..."

  SNIPPET_STORAGE_ID="$(
    awk '
      BEGIN{printed=0}
      /^[a-z0-9_-]+:/ {
        if(printed) exit
        split($0,a,"[ :]+"); id=a[2]
        inblock=1; has=0
      }
      inblock && $1=="content" && /snippets/ {has=1}
      NF==0 {
        if(inblock && has && !printed){
          print id
          printed=1
          exit
        }
        inblock=0
      }
      END {
        if(!printed && inblock && has){
          print id
        }
      }
    ' "$CFG"
  )"

  # normalize → use only 1st line
  SNIPPET_STORAGE_ID="$(printf '%s\n' "$SNIPPET_STORAGE_ID" | head -n1)"

  if [[ -z "$SNIPPET_STORAGE_ID" ]]; then
    ERROR "No storage with 'snippets' content found."
    exit 1
  fi

  OK "Auto-selected snippet storage: ${SNIPPET_STORAGE_ID}"
else
  INFO "Using user-selected snippet storage: ${SNIPPET_STORAGE_ID}"
fi

############################################
# Verify snippet storage
############################################
INFO "Verifying snippet storage '${SNIPPET_STORAGE_ID}'..."

HAS_SNIP="$(
  awk -v target="${SNIPPET_STORAGE_ID}" '
    /^[a-z0-9_-]+:/{
      split($0,a,"[ :]+"); id=a[2]
      inblock=(id==target); has=0
    }
    inblock && $1=="content" && /snippets/ {has=1}
    NF==0 {
      if(inblock && has) print "yes"
      inblock=0
    }
    END { if(inblock && has) print "yes" }
  ' "$CFG"
)"

if [[ "$HAS_SNIP" != "yes" ]]; then
  ERROR "Storage '${SNIPPET_STORAGE_ID}' does NOT have 'snippets' content."
  exit 1
fi

OK "Storage '${SNIPPET_STORAGE_ID}' supports snippets."

############################################
# Extract snippet storage path
############################################
SNIPPET_BASE_PATH="$(
  awk -v target="${SNIPPET_STORAGE_ID}" '
    /^[a-z0-9_-]+:/{
      split($0,a,"[ :]+"); id=a[2]
      inblock=(id==target)
    }
    inblock && $1=="path"{print $2; exit}
  ' "$CFG"
)"

if [[ -z "$SNIPPET_BASE_PATH" ]]; then
  ERROR "Could not determine snippet storage path."
  exit 1
fi

SNIPPET_DIR="${SNIPPET_BASE_PATH}/snippets"
OK "Snippet directory: ${SNIPPET_DIR}"

############################################
# Detect network bridge
############################################
INFO "Detecting network bridge..."

BRIDGE="$(awk '/^auto vmbr/{print $2;exit}' /etc/network/interfaces 2>/dev/null || true)"

if [[ -z "$BRIDGE" ]]; then
  for f in /etc/network/interfaces.d/*; do
    [[ -f "$f" ]] || continue
    candidate="$(awk '/^auto vmbr/{print $2;exit}' "$f" 2>/dev/null || true)"
    if [[ -n "$candidate" ]]; then
      BRIDGE="$candidate"
      break
    fi
  done
fi

if [[ -z "$BRIDGE" && -n "$(ip -o link show vmbr0 2>/dev/null || true)" ]]; then
  BRIDGE="vmbr0"
fi

if [[ -z "$BRIDGE" ]]; then
  ERROR "Could not find network bridge (vmbr)."
  exit 1
fi

OK "Using bridge: ${BRIDGE}"

############################################
# Detect SSH key
############################################
INFO "Detecting SSH key..."

if [[ "$SSH_KEY_PATH" != "auto" && -n "$SSH_KEY_PATH" ]]; then
  SSH_KEY="$SSH_KEY_PATH"
elif [[ -f /root/.ssh/id_ed25519.pub ]]; then
  SSH_KEY="/root/.ssh/id_ed25519.pub"
elif [[ -f /root/.ssh/id_rsa.pub ]]; then
  SSH_KEY="/root/.ssh/id_rsa.pub"
else
  ERROR "No SSH key found. Pass --ssh-key <path>, or create /root/.ssh/id_ed25519.pub (or id_rsa.pub)."
  exit 1
fi

OK "Using SSH key: $SSH_KEY"

# Read SSH public key file. The file may contain multiple keys (one per line,
# as in authorized_keys), with optional blank lines and # comments. Each valid
# key is embedded into the cloud-init user-data as a separate YAML list item.
# The first whitespace-separated token must be a recognized key-type prefix
# (ssh-, ecdsa-, sk-) — this is forward-compatible with future key types.
#
# Keys are embedded as YAML double-quoted strings. Backslashes and double
# quotes in the key material or comment are escaped (\ → \\, " → \") before
# embedding. $ and ` in the value are safe — YAML double-quoted strings do
# not treat them as special, and bash variable expansion is single-pass (the
# value of ${line} is not re-interpreted).
SSH_KEYS_YAML=""
VALID_KEY_COUNT=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line#"${line%%[![:space:]]*}"}"  # trim leading whitespace
  line="${line%"${line##*[![:space:]]}"}"  # trim trailing whitespace
  [[ -z "$line" || "$line" == \#* ]] && continue
  first_token="${line%% *}"
  if [[ "$first_token" =~ ^(ssh-|ecdsa-|sk-) ]]; then
    line_escaped="${line//\\/\\\\}"
    line_escaped="${line_escaped//\"/\\\"}"
    SSH_KEYS_YAML+="      - \"${line_escaped}\""$'\n'
    VALID_KEY_COUNT=$((VALID_KEY_COUNT + 1))
  else
    WARN "Skipping unrecognized line in ${SSH_KEY}: ${line:0:60}..."
  fi
done < "$SSH_KEY"

if [[ $VALID_KEY_COUNT -eq 0 ]]; then
  ERROR "No valid SSH keys found in ${SSH_KEY}."
  ERROR "Expected lines starting with: ssh-rsa, ssh-ed25519, ecdsa-sha2-..., or sk-*"
  exit 1
fi

OK "Loaded ${VALID_KEY_COUNT} SSH key(s) from ${SSH_KEY}"

# Generate a random initial password for console access. The user must change
# it on first login (chpasswd.expire: True in the user-data).
# Approach: filter /dev/urandom to alphanumerics only, take first 8 chars,
# excluding confusable chars (I, l). 8 chars from 59-char set ≈ 47 bits entropy.
# Note: || true suppresses SIGPIPE exit code (141) from pipefail when head
# closes the pipe after 8 bytes — bash versions differ on whether variable
# assignments fully exempt command substitution from set -e with pipefail.
RANDOM_PASSWORD="$(LC_ALL=C tr -dc 'A-HJ-Za-km-z0-9' </dev/urandom | head -c 8 || true)"

############################################
# Download Ubuntu cloud image
############################################
IMG_URL="https://cloud-images.ubuntu.com/${UBUNTU_CODENAME}/current/${UBUNTU_CODENAME}-server-cloudimg-amd64.img"
# mktemp gives a unique, non-predictable path. Safe even if two instances
# of the script run concurrently or /tmp/ubuntu-<id>.img already exists.
IMG_FILE="$(mktemp /tmp/ubuntu-cloudimg-XXXXXX.img)"

INFO "Downloading cloud image:"
INFO "  $IMG_URL"
curl -fsSL "$IMG_URL" -o "$IMG_FILE" || { ERROR "Download failed: $IMG_URL"; rm -f "$IMG_FILE"; exit 1; }

INFO "Verifying image integrity..."
if ! qemu-img check "$IMG_FILE" >/dev/null 2>&1; then
  ERROR "Downloaded image failed integrity check (corrupt or truncated)."
  rm -f "$IMG_FILE"
  exit 1
fi

OK "Image downloaded and verified."

############################################
# Create VM
############################################
INFO "Creating VM ${VM_ID}..."

qm create "$VM_ID" \
  --name "$VM_NAME" \
  --memory "$MEMORY_MB" \
  --cores "$CORES" \
  --cpu host \
  --machine q35 \
  --agent enabled=1,fstrim_cloned_disks=1 \
  --net0 "virtio,bridge=${BRIDGE}" \
  --scsihw virtio-scsi-single \
  --serial0 socket \
  --ostype l26 \
  --onboot 0

VM_CREATED=1
OK "VM created."

############################################
# Import disk
############################################
INFO "Importing disk into ${STORAGE}..."

qm importdisk "$VM_ID" "$IMG_FILE" "$STORAGE"

DISK_REF="${STORAGE}:vm-${VM_ID}-disk-0"
qm set "$VM_ID" --scsi0 "${DISK_REF},iothread=1" --boot order=scsi0

OK "Disk attached."

INFO "Resizing disk to ${DISK_SIZE}..."
qm resize "$VM_ID" scsi0 "$DISK_SIZE"

############################################
# Cloud-init configuration
############################################
INFO "Configuring cloud-init..."

qm set "$VM_ID" --ide2 "${STORAGE}:cloudinit"
qm set "$VM_ID" --ipconfig0 "ip=dhcp"
# --ciuser and --sshkey intentionally omitted: the --cicustom user=... below
# provides a full user-data file that REPLACES Proxmox's auto-generated one.
# User creation and ssh_authorized_keys are embedded directly in that file.

############################################
# Create user-data for Bun
############################################
mkdir -p "$SNIPPET_DIR"
USERDATA="${SNIPPET_DIR}/bun-${VM_ID}.yaml"

cat > "$USERDATA" <<EOF
#cloud-config
users:
  - name: ${VM_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
${SSH_KEYS_YAML}

chpasswd:
  expire: True
  list:
    - ${VM_USER}:${RANDOM_PASSWORD}

packages:
  - curl
  - unzip
  - qemu-guest-agent

# write_files avoids the brittle runcmd escaping we used to use for the
# /etc/profile.d/bun.sh fragment. The single backslash below is what
# cloud-init writes to disk; cloud-init doesn't do shell interpolation on
# write_files content, so \$PATH reaches the file literally and is expanded
# by the developer's shell at login.
write_files:
  - path: /etc/profile.d/bun.sh
    permissions: '0644'
    owner: root:root
    content: |
      export PATH="/home/${VM_USER}/.bun/bin:\$PATH"

runcmd:
  # Start the QEMU Guest Agent so the host can query the VM's IP via
  # qm guest cmd <vmid> network-get-interfaces. The package is installed
  # above but may not auto-start (static preset in Ubuntu 26.04+).
  - [ systemctl, start, qemu-guest-agent ]
  # Install Bun as the developer user. Writes a status file so the
  # provisioning script can detect success/failure without parsing logs.
  - [ bash, -lc, "sudo -u ${VM_USER} -i bash -c 'set -o pipefail && curl -fsSL -o /tmp/bun-install.sh https://bun.sh/install && bash /tmp/bun-install.sh' 2>/var/log/bun-install-err.log && touch /var/log/bun-install.ok || touch /var/log/bun-install.fail" ]
  # Note: we intentionally do NOT append to ~/.bashrc. The /etc/profile.d/
  # fragment above covers login shells (SSH sessions, console). For
  # interactive non-login bash (e.g., opening a fresh terminal in a desktop
  # session), run 'source /etc/profile.d/bun.sh' or open a login shell.
EOF

qm set "$VM_ID" --cicustom "user=${SNIPPET_STORAGE_ID}:snippets/$(basename "$USERDATA")"

OK "Cloud-init user-data attached."

############################################
# Start the VM
############################################
INFO "Starting VM..."
qm start "$VM_ID"
OK "VM started."

############################################
# Auto-detect VM IP
############################################
INFO "Attempting to detect VM IP..."

TAP="tap${VM_ID}i0"
VM_IP=""

# Resolve the VM's MAC from its config so we can pick the right neighbor
# out of the bridge's table. Without this, head -n1 would race against the
# gateway and any sibling VMs on the same bridge.
VM_MAC="$(
  qm config "$VM_ID" 2>/dev/null | \
    awk '/^net0:/{n=split($0,a,/[=, ]+/); for(i=1;i<=n;i++)if(a[i] ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/){print toupper(a[i]);exit}}'
)"
INFO "VM MAC: ${VM_MAC:-unknown}"

# Try for up to 2 minutes (24 * 5s). The tap interface only appears after
# the VM has begun booting, so the early iterations are expected no-ops.
for _ in {1..24}; do
  if ip link show "$TAP" >/dev/null 2>&1; then
    # Fast path: ARP neighbor table (works within seconds of DHCP lease)
    if [[ -n "$VM_MAC" ]]; then
      VM_IP="$(ip -4 neigh show dev "$TAP" | \
        awk -v mac="$VM_MAC" 'tolower($5) == tolower(mac) {print $1; exit}')" || true
    fi
    if [[ -z "$VM_IP" ]]; then
      VM_IP="$(ip -4 neigh show dev "$TAP" | awk 'NR==1{print $1}' || true)"
    fi
    # ARP fallback: search the full table by MAC (works when the entry
    # hasn't yet been associated with the tap interface).
    if [[ -z "$VM_IP" ]] && [[ -n "$VM_MAC" ]]; then
      VM_IP="$(ip -4 neigh show | awk -v mac="$VM_MAC" 'tolower($0) ~ tolower(mac) {print $1; exit}' || true)"
    fi

    # Diagnostic: log what we found each iteration
    if [[ -z "$VM_IP" ]]; then
      NEIGH_OUTPUT="$(ip -4 neigh show dev "$TAP" 2>&1)"
      INFO "tap $TAP up; no IP yet (neigh: ${NEIGH_OUTPUT:-empty})"
    fi

    # Reliable path: QEMU Guest Agent. Works when ARP is stale or the bridge
    # is busy. Queries the IP directly from inside the VM. Only available
    # once qemu-guest-agent is installed and running (via cloud-init).
    if [[ -z "$VM_IP" ]] && command -v python3 >/dev/null 2>&1; then
      VM_IP="$(
        qm guest cmd "$VM_ID" network-get-interfaces 2>/dev/null | \
          python3 -c '
import json, sys
for iface in json.load(sys.stdin):
    if iface.get("name") in ("lo",):
        continue
    for addr in iface.get("ip-addresses", []):
        if addr.get("ip-address-type") == "ipv4":
            print(addr["ip-address"])
            sys.exit(0)
sys.exit(1)
' 2>/dev/null
      )" || true
      if [[ -n "$VM_IP" ]]; then
        INFO "QGA returned IP: ${VM_IP}"
      fi
    fi

    [[ -n "$VM_IP" ]] && break
  fi
  sleep 5
done

if [[ -n "$VM_IP" ]]; then
  OK "Detected VM IP: ${VM_IP}"

  # Wait for cloud-init + Bun install to finish (max 5 min)
  INFO "Waiting for cloud-init and Bun install to complete..."
  BUN_READY=0
  for _ in {1..60}; do
    # First check if cloud-init has finished its runcmd phase
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes \
       "${VM_USER}@${VM_IP}" 'test -f /var/log/bun-install.ok -o -f /var/log/bun-install.fail' >/dev/null 2>&1; then
      if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes \
         "${VM_USER}@${VM_IP}" 'test -f /var/log/bun-install.ok' >/dev/null 2>&1; then
        OK "Bun is installed and reachable via SSH."
        BUN_READY=1
      else
        WARN "Bun installation failed. Check inside the VM:"
        WARN "  cat /var/log/bun-install.fail"
        WARN "  cat /var/log/bun-install-err.log"
        WARN "  cat /var/log/cloud-init-output.log | tail -n 50"
        BUN_READY=1
      fi
      break
    fi
    sleep 5
  done
  if [[ "$BUN_READY" -ne 1 ]]; then
    WARN "Bun did not become ready within 5 minutes."
    WARN "This means cloud-init's runcmd is still pending or the VM is"
    WARN "still booting. Check inside the VM after cloud-init finishes:"
    WARN "  ssh ${VM_USER}@${VM_IP} 'tail -n 50 /var/log/cloud-init-output.log'"
    WARN "  ssh ${VM_USER}@${VM_IP} 'cat /var/log/bun-install.ok /var/log/bun-install.fail 2>/dev/null || echo no status file found'"
  fi
else
  WARN "Could not determine VM IP automatically (tapped ${TAP} for up to 2 minutes)."
  INFO "Diagnostics:"
  INFO "  tap interface: $(ip link show "$TAP" 2>&1 || echo 'not found')"
  INFO "  neigh table:  $(ip -4 neigh show dev "$TAP" 2>&1 || echo 'not found')"
  INFO "  VM config:    $(qm config "$VM_ID" 2>&1 | grep -o 'net0[^,]*' || echo 'not found')"
  WARN "Find it via the VM console: 'ip a' — or check your router's DHCP leases."
  WARN "Once connected, verify Bun:"
  WARN "  ssh ${VM_USER}@<vm-ip> '~/.bun/bin/bun --version'"
  WARN "If Bun is missing, check cloud-init's log inside the VM:"
  WARN "  sudo tail -50 /var/log/cloud-init-output.log"
fi

############################################
# Cleanup image
############################################
rm -f "$IMG_FILE" || true

############################################
# Success Summary
############################################
# NOTE: do NOT `trap - EXIT` here. The cleanup trap must run on success too,
# because it's responsible for flushing the logging tee before the script
# returns. The cleanup function checks exit_code and only destroys the VM
# on failure.

OK "Bun VM created successfully!"

echo
echo "=============================================="
echo " Bun VM Created"
echo "----------------------------------------------"
echo " VMID        : ${VM_ID}"
echo " Name        : ${VM_NAME}"
echo " Storage     : ${STORAGE}"
echo " Snippets    : ${SNIPPET_STORAGE_ID}"
echo " Bridge      : ${BRIDGE}"
echo " Log file    : ${LOG_FILE}"
[[ -n "${VM_IP}" ]] && echo " VM IP       : ${VM_IP}"
echo " Console login : ${VM_USER} / ${RANDOM_PASSWORD}  (change on first login)"
echo "=============================================="
echo
echo "SSH into your VM, then verify Bun:"
if [[ -n "$VM_IP" ]]; then
  echo "  ssh ${VM_USER}@${VM_IP}"
else
  echo "  ssh ${VM_USER}@<vm-ip>"
fi
echo
echo "Verify Bun:"
echo "  bun --version"
echo
