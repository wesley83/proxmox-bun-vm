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
# You are free to use, modify, and distribute this script. Contributions welcome.
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
# Banner (with ASCII art, colors, fallback)
############################################
SCRIPT_VERSION="v1.0.0"
REPO_URL="https://github.com/wesley83/proxmox-bun-vm"

# Dedicated colors for banner
if [ -t 1 ]; then
  C_BLUE="\033[34m"
  C_CYAN="\033[36m"
  C_GREEN="\033[32m"
  C_BOLD="\033[1m"
  C_RESET="\033[0m"
else
  C_BLUE=""; C_CYAN=""; C_GREEN=""; C_BOLD=""; C_RESET=""
fi

# Try fancy ASCII banner (fallback if environment is weird)
if printf "█" | grep -q "█" >/dev/null 2>&1; then
  printf "${C_GREEN}${C_BOLD}"
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
  printf "${C_RESET}\n"
else
  printf "${C_BOLD}Bun VM Installer for Proxmox VE${C_RESET}\n"
fi

printf "${C_BLUE}${C_BOLD}        Bun VM Installer for Proxmox VE${C_RESET}\n"
printf "${C_CYAN}              Created by Wesley Faulkner${C_RESET}\n"
printf "${C_GREEN}                   ${SCRIPT_VERSION}${C_RESET}\n"
printf "${C_CYAN}      ${REPO_URL}${C_RESET}\n"
echo

############################################
# Defaults / CLI flags
############################################
MEMORY_MB=4096
CORES=2
DISK_SIZE="20G"
UBUNTU_CODENAME="noble"   # 24.04 LTS; can also use "jammy"
VM_USER="developer"
SHOW_HELP=0

print_help() {
  cat <<EOF
${BOLD}Bun VM Installer for Proxmox VE${RESET}

This script:
  - Creates a new Ubuntu cloud VM (no template required)
  - Installs Bun for user "${VM_USER}"
  - Injects your SSH key from /root/.ssh
  - Auto-detects storage, bridge, and VMID
  - Attempts to auto-detect the VM's IP

${BOLD}Usage:${RESET}
  bun-vm.sh [options]

${BOLD}Options:${RESET}
  -m, --memory <MB>       RAM in megabytes (default: ${MEMORY_MB})
  -c, --cores  <N>        vCPU cores (default: ${CORES})
  -d, --disk   <SIZE>     Disk size (default: ${DISK_SIZE})
  -u, --ubuntu <codename> Ubuntu codename (noble, jammy, etc.; default: ${UBUNTU_CODENAME})
  -h, --help              Show this help message and exit

${BOLD}Examples:${RESET}
  bun-vm.sh
  bun-vm.sh --memory 8192 --cores 4 --disk 40G
  bun-vm.sh --ubuntu jammy
EOF
}

############################################
# Parse arguments
############################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--memory)
      MEMORY_MB="$2"; shift 2;;
    -c|--cores)
      CORES="$2"; shift 2;;
    -d|--disk)
      DISK_SIZE="$2"; shift 2;;
    -u|--ubuntu)
      UBUNTU_CODENAME="$2"; shift 2;;
    -h|--help)
      SHOW_HELP=1; shift;;
    *)
      ERROR "Unknown option: $1"
      SHOW_HELP=1
      break;;
  esac
done

if [ "$SHOW_HELP" -eq 1 ]; then
  print_help
  exit 0
fi

############################################
# Environment checks
############################################
if [ "$(id -u)" -ne 0 ]; then
  ERROR "Must run as root on a Proxmox VE node."
  exit 1
fi

if ! command -v qm >/dev/null 2>&1; then
  ERROR "qm command not found. Are you on a Proxmox VE node?"
  exit 1
fi

if ! command -v pvesm >/dev/null 2>&1; then
  ERROR "pvesm command not found. This should exist on Proxmox."
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  ERROR "curl is required. Install with: apt-get update && apt-get install -y curl"
  exit 1
fi

############################################
# VM ID, name, log file
############################################
VM_ID=$(pvesh get /cluster/nextid)
VM_NAME="bun-dev-${VM_ID}"

LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/bun-vm-${VM_ID}.log"
mkdir -p "$LOG_DIR"

# Log everything (stdout+stderr) to log file as well
exec > >(tee -a "$LOG_FILE") 2>&1

INFO "Log file: ${LOG_FILE}"
INFO "Using VMID: ${VM_ID}"
INFO "VM Name: ${VM_NAME}"
INFO "Ubuntu codename: ${UBUNTU_CODENAME}"
INFO "Resources: ${MEMORY_MB} MB RAM, ${CORES} cores, disk ${DISK_SIZE}"

############################################
# Cleanup on error
############################################
VM_CREATED=0
IMG_FILE=""
cleanup() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    ERROR "Script failed with exit code ${exit_code}."
    if [ "$VM_CREATED" -eq 1 ]; then
      WARN "Cleaning up VM ${VM_ID}..."
      qm stop "$VM_ID" >/dev/null 2>&1 || true
      qm destroy "$VM_ID" --purge >/dev/null 2>&1 || true
      OK "Destroyed VM ${VM_ID} due to failure."
    fi
    if [ -n "${IMG_FILE}" ] && [ -f "${IMG_FILE}" ]; then
      WARN "Removing downloaded image ${IMG_FILE}..."
      rm -f "${IMG_FILE}" || true
    fi
    ERROR "See log file for details: ${LOG_FILE}"
  fi
}
trap cleanup EXIT

############################################
# Storage detection
############################################
INFO "Detecting storage..."

if pvesm status | awk 'NR>1{print $1,$3}' | grep -q '^local-lvm active'; then
  STORAGE="local-lvm"
else
  STORAGE=$(pvesm status | awk 'NR>1 && $3=="active"{print $1; exit}')
fi

if [ -z "${STORAGE:-}" ]; then
  ERROR "No active storage found via 'pvesm status'."
  exit 1
fi

OK "Using storage: ${STORAGE}"

############################################
# Verify 'local' supports snippets
############################################
INFO "Checking that storage 'local' supports snippets..."

if ! pvesm status --verbose 2>/dev/null | awk '
  $1=="local" && $0 ~ /snippets/ {found=1}
  END {exit !found}
'; then
  ERROR "Storage 'local' does not support snippets."
  ERROR "Enable 'Snippets' content for 'local' in Datacenter -> Storage -> local -> Edit."
  exit 1
fi

OK "Storage 'local' has snippets enabled."

############################################
# Bridge detection
############################################
INFO "Detecting network bridge..."

if grep -q '^auto vmbr0' /etc/network/interfaces 2>/dev/null; then
  BRIDGE="vmbr0"
else
  BRIDGE=$(grep -E '^auto vmbr[0-9]+' /etc/network/interfaces 2>/dev/null | awk '{print $2}' | head -n1 || true)
fi

if [ -z "${BRIDGE:-}" ]; then
  ERROR "No vmbr bridge found in /etc/network/interfaces."
  exit 1
fi

OK "Using bridge: ${BRIDGE}"

############################################
# SSH public key detection
############################################
INFO "Detecting SSH public key in /root/.ssh..."

if [ -f /root/.ssh/id_ed25519.pub ]; then
  SSH_KEY="/root/.ssh/id_ed25519.pub"
elif [ -f /root/.ssh/id_rsa.pub ]; then
  SSH_KEY="/root/.ssh/id_rsa.pub"
else
  ERROR "No SSH public key found (id_ed25519.pub or id_rsa.pub)."
  echo "Generate one with: ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519"
  exit 1
fi

OK "Using SSH key: ${SSH_KEY}"

############################################
# Download Ubuntu cloud image
############################################
IMG_URL="https://cloud-images.ubuntu.com/${UBUNTU_CODENAME}/current/${UBUNTU_CODENAME}-server-cloudimg-amd64.img"
IMG_FILE="/tmp/ubuntu-cloudimg-${UBUNTU_CODENAME}-${VM_ID}.img"
IMG_FILE="$IMG_FILE" # keep shellcheck happy for trap

INFO "Downloading Ubuntu cloud image from:"
INFO "  ${IMG_URL}"

curl -fsSL "${IMG_URL}" -o "${IMG_FILE}"
OK "Downloaded image to ${IMG_FILE}"

############################################
# Create VM
############################################
INFO "Creating VM ${VM_ID}..."

qm create "${VM_ID}" \
  --name "${VM_NAME}" \
  --memory "${MEMORY_MB}" \
  --cores "${CORES}" \
  --net0 "virtio,bridge=${BRIDGE}" \
  --scsihw virtio-scsi-pci \
  --bios seabios \
  --serial0 socket \
  --boot c \
  --ostype l26

VM_CREATED=1
OK "Created VM config."

############################################
# Import disk and attach (simplified)
############################################
INFO "Importing disk into storage ${STORAGE}..."

qm importdisk "${VM_ID}" "${IMG_FILE}" "${STORAGE}" --format qcow2

# Proxmox consistently names imported disk as vm-<VMID>-disk-0
DISK_REF="${STORAGE}:vm-${VM_ID}-disk-0"

qm set "${VM_ID}" --scsi0 "${DISK_REF}" --bootdisk scsi0
OK "Attached disk ${DISK_REF} to VM ${VM_ID}."

INFO "Resizing disk to ${DISK_SIZE}..."
qm resize "${VM_ID}" scsi0 "${DISK_SIZE}"
OK "Resized disk."

############################################
# Cloud-init drive & basic config
############################################
INFO "Configuring cloud-init..."

qm set "${VM_ID}" --ide2 "${STORAGE}:cloudinit"
qm set "${VM_ID}" --ciuser "${VM_USER}"
qm set "${VM_ID}" --sshkey "${SSH_KEY}"
qm set "${VM_ID}" --ipconfig0 "ip=dhcp"

############################################
# Cloud-init user-data: install Bun
############################################
SNIPPET_DIR="/var/lib/vz/snippets"
mkdir -p "${SNIPPET_DIR}"
USERDATA_FILE="${SNIPPET_DIR}/bun-${VM_ID}-userdata.yaml"

INFO "Writing cloud-init user-data to ${USERDATA_FILE}..."

cat > "${USERDATA_FILE}" <<EOF
#cloud-config
users:
  - name: ${VM_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash

packages:
  - curl

runcmd:
  - [ bash, -lc, "su - ${VM_USER} -c 'curl -fsSL https://bun.sh/install | bash'" ]
  - [ bash, -lc, "echo 'export PATH=\\\"\\\\\$HOME/.bun/bin:\\\\\$PATH\\\"' >> /home/${VM_USER}/.bashrc" ]
EOF

qm set "${VM_ID}" --cicustom "user=local:snippets/$(basename "${USERDATA_FILE}")"
OK "Cloud-init user-data attached."

############################################
# Start VM
############################################
INFO "Starting VM ${VM_ID}..."
qm start "${VM_ID}"
OK "VM started."

############################################
# Try to auto-detect VM IP
############################################
INFO "Attempting to detect VM IP (this may take up to ~2 minutes)..."

VM_IP=""
TAP_IFACE="tap${VM_ID}i0"

for i in {1..24}; do
  if ip link show "${TAP_IFACE}" >/dev/null 2>&1; then
    VM_IP=$(ip -4 neigh show dev "${TAP_IFACE}" | awk '{print $1}' | head -n1 || true)
    if [ -n "${VM_IP}" ]; then
      break
    fi
  fi
  sleep 5
done

if [ -n "${VM_IP}" ]; then
  OK "Detected VM IP: ${VM_IP}"
else
  WARN "Could not automatically detect VM IP."
  WARN "Check the VM console or your DHCP server for the assigned IP."
fi

############################################
# Success summary
############################################
# Disable cleanup trap on success
trap - EXIT

if [ -n "${IMG_FILE}" ] && [ -f "${IMG_FILE}" ]; then
  INFO "Removing downloaded image ${IMG_FILE}..."
  rm -f "${IMG_FILE}" || true
fi

OK "Bun-ready VM created successfully!"

echo
echo "=============================================="
echo "   Bun-ready VM deployed"
echo "----------------------------------------------"
echo " VMID       : ${VM_ID}"
echo " Name       : ${VM_NAME}"
echo " User       : ${VM_USER}"
echo " Storage    : ${STORAGE}"
echo " Bridge     : ${BRIDGE}"
echo " Log file   : ${LOG_FILE}"
if [ -n "${VM_IP}" ]; then
  echo " VM IP      : ${VM_IP}"
fi
echo "=============================================="
echo
echo "Next steps:"
if [ -n "${VM_IP}" ]; then
  echo "  ssh ${VM_USER}@${VM_IP}"
else
  echo "  Find the VM's IP in the Proxmox UI or DHCP server, then:"
  echo "    ssh ${VM_USER}@<vm-ip>"
fi
echo "Then verify Bun with:"
echo "  bun --version"
echo