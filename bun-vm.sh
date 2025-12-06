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
# Version: v1.1.1 (hardened + snippet autodetect fix)
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

############################################
# Banner
############################################
SCRIPT_VERSION="v1.1.1"
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
UBUNTU_CODENAME="noble"
VM_USER="developer"
SNIPPET_STORAGE_ID="auto"
DEBUG=0

############################################
# Help menu
############################################
print_help() {
  cat <<EOF
Usage: bun-vm.sh [options]

Options:
  -m, --memory <MB>       RAM (default 4096)
  -c, --cores <N>         CPU cores (default 2)
  -d, --disk <SIZE>       Disk size (default 20G)
  -u, --ubuntu <codename> Ubuntu cloud image codename (default noble)
  --debug                 Enable bash debug tracing
  -h, --help              Show help

EOF
}

############################################
# Parse args
############################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--memory) MEMORY_MB="$2"; shift 2;;
    -c|--cores)  CORES="$2"; shift 2;;
    -d|--disk)   DISK_SIZE="$2"; shift 2;;
    -u|--ubuntu) UBUNTU_CODENAME="$2"; shift 2;;
    --debug)     DEBUG=1; shift;;
    -h|--help)   print_help; exit 0;;
    *) ERROR "Unknown option: $1"; exit 1;;
  esac
done

[[ "$DEBUG" -eq 1 ]] && set -x

############################################
# Environment validation
############################################
if [[ "$(id -u)" -ne 0 ]]; then
  ERROR "This script must be run as root on a Proxmox VE node."
  exit 1
fi

for cmd in qm pvesh pvesm awk curl ip; do
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
}
trap cleanup EXIT

############################################
# Detect VM disk storage
############################################
INFO "Detecting VM disk storage..."

if pvesm status | awk 'NR>1{print $1,$3}' | grep -q '^local-lvm active'; then
  STORAGE="local-lvm"
else
  STORAGE="$(pvesm status | awk 'NR>1 && $3=="active"{print $1;exit}')"
fi

if [[ -z "${STORAGE}" ]]; then
  ERROR "Could not determine active storage for VM disks."
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

BRIDGE="$(awk '/^auto vmbr/{print $2;exit}' /etc/network/interfaces || true)"

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

if [[ -f /root/.ssh/id_ed25519.pub ]]; then
  SSH_KEY="/root/.ssh/id_ed25519.pub"
elif [[ -f /root/.ssh/id_rsa.pub ]]; then
  SSH_KEY="/root/.ssh/id_rsa.pub"
else
  ERROR "No SSH key found (/root/.ssh/id_ed25519.pub or id_rsa.pub)."
  exit 1
fi

OK "Using SSH key: $SSH_KEY"

############################################
# Download Ubuntu cloud image
############################################
IMG_URL="https://cloud-images.ubuntu.com/${UBUNTU_CODENAME}/current/${UBUNTU_CODENAME}-server-cloudimg-amd64.img"
IMG_FILE="/tmp/ubuntu-${VM_ID}.img"

INFO "Downloading cloud image:"
INFO "  $IMG_URL"
curl -fsSL "$IMG_URL" -o "$IMG_FILE"

OK "Image downloaded."

############################################
# Create VM
############################################
INFO "Creating VM ${VM_ID}..."

qm create "$VM_ID" \
  --name "$VM_NAME" \
  --memory "$MEMORY_MB" \
  --cores "$CORES" \
  --net0 "virtio,bridge=${BRIDGE}" \
  --scsihw virtio-scsi-pci \
  --serial0 socket \
  --boot c \
  --ostype l26

VM_CREATED=1
OK "VM created."

############################################
# Import disk
############################################
INFO "Importing disk into ${STORAGE}..."

qm importdisk "$VM_ID" "$IMG_FILE" "$STORAGE" --format qcow2

DISK_REF="${STORAGE}:vm-${VM_ID}-disk-0"
qm set "$VM_ID" --scsi0 "$DISK_REF" --bootdisk scsi0

OK "Disk attached."

INFO "Resizing disk to ${DISK_SIZE}..."
qm resize "$VM_ID" scsi0 "$DISK_SIZE"

############################################
# Cloud-init configuration
############################################
INFO "Configuring cloud-init..."

qm set "$VM_ID" --ide2 "${STORAGE}:cloudinit"
qm set "$VM_ID" --ciuser "$VM_USER"
qm set "$VM_ID" --sshkey "$SSH_KEY"
qm set "$VM_ID" --ipconfig0 "ip=dhcp"

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

packages:
  - curl

runcmd:
  - [ bash, -lc, "su - ${VM_USER} -c 'curl -fsSL https://bun.sh/install | bash'" ]
  - [ bash, -lc, "echo 'export PATH=\\\"\\\$HOME/.bun/bin:\\\$PATH\\\"' >> /home/${VM_USER}/.bashrc" ]
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

for _ in {1..24}; do
  if ip link show "$TAP" >/dev/null 2>&1; then
    VM_IP="$(ip -4 neigh show dev "$TAP" | awk '{print $1}' | head -n1 || true)"
    [[ -n "$VM_IP" ]] && break
  fi
  sleep 5
done

if [[ -n "$VM_IP" ]]; then
  OK "Detected VM IP: ${VM_IP}"
else
  WARN "Could not determine VM IP automatically."
fi

############################################
# Cleanup image
############################################
rm -f "$IMG_FILE" || true

############################################
# Success Summary
############################################
trap - EXIT

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
echo "=============================================="
echo
echo "SSH into your VM:"
if [[ -n "$VM_IP" ]]; then
  echo "  ssh ${VM_USER}@${VM_IP}"
else
  echo "  ssh ${VM_USER}@<vm-ip>"
fi
echo
echo "Verify Bun:"
echo "  bun --version"
echo
