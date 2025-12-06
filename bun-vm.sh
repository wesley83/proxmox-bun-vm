#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[$(date +'%F %T')] $*"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
  fi
}

require_root

if ! command -v qm >/dev/null 2>&1; then
  echo "ERROR: qm command not found. Run this on a Proxmox VE node." >&2
  exit 1
fi

if ! command -v pvesm >/dev/null 2>&1; then
  echo "ERROR: pvesm command not found. This should exist on Proxmox." >&2
  exit 1
fi

#######################################
# 1) Find a cloud-init template VM    #
#######################################
log "Detecting cloud-init template VM..."

TEMPLATE_ID=""
for cfg in /etc/pve/qemu-server/*.conf; do
  [ -f "$cfg" ] || continue
  if grep -q '^template: 1' "$cfg"; then
    fname=$(basename "$cfg")
    vid="${fname%.conf}"
    TEMPLATE_ID="$vid"
    break
  fi
done

if [ -z "$TEMPLATE_ID" ]; then
  echo "ERROR: No template VM found (no qemu config with 'template: 1')." >&2
  echo "Create a cloud-init template first, then rerun this script." >&2
  exit 1
fi

log "Using template VMID: $TEMPLATE_ID"

#######################################
# 2) Get next free VMID               #
#######################################
log "Requesting next free VMID..."
VM_ID=$(pvesh get /cluster/nextid)
VM_NAME="bun-dev-${VM_ID}"

log "New VM will be:"
log "  VMID : $VM_ID"
log "  Name : $VM_NAME"

#######################################
# 3) Detect storage for VM disks      #
#######################################
log "Detecting storage for VM disks..."

VM_STORAGE=""
if pvesm status | awk 'NR>1 {print $1,$3}' | grep -q '^local-lvm active'; then
  VM_STORAGE="local-lvm"
else
  VM_STORAGE=$(pvesm status | awk 'NR>1 && $3=="active"{print $1; exit}')
fi

if [ -z "$VM_STORAGE" ]; then
  echo "ERROR: No active storage found in 'pvesm status'." >&2
  exit 1
fi

log "Using storage for VM disks: $VM_STORAGE"

#######################################
# 4) Snippet storage (for user-data)  #
#######################################
SNIPPET_STORAGE="local"
SNIPPET_DIR="/var/lib/vz/snippets"

log "Assuming snippet storage: $SNIPPET_STORAGE"
log "Snippet directory: $SNIPPET_DIR"
mkdir -p "$SNIPPET_DIR"

#######################################
# 5) Detect network bridge            #
#######################################
log "Detecting network bridge..."

VM_BRIDGE=""
if grep -q '^auto vmbr0' /etc/network/interfaces 2>/dev/null; then
  VM_BRIDGE="vmbr0"
else
  VM_BRIDGE=$(grep -E '^auto vmbr[0-9]+' /etc/network/interfaces 2>/dev/null | awk '{print $2}' | head -n1 || true)
fi

if [ -z "$VM_BRIDGE" ]; then
  echo "ERROR: No vmbr bridge found in /etc/network/interfaces." >&2
  echo "Please configure a bridge (e.g. vmbr0) before running this script." >&2
  exit 1
fi

log "Using network bridge: $VM_BRIDGE"

#######################################
# 6) Detect SSH public key            #
#######################################
log "Looking for SSH public key to inject..."

SSH_PUBKEY_FILE=""
if [ -f /root/.ssh/id_ed25519.pub ]; then
  SSH_PUBKEY_FILE=/root/.ssh/id_ed25519.pub
elif [ -f /root/.ssh/id_rsa.pub ]; then
  SSH_PUBKEY_FILE=/root/.ssh/id_rsa.pub
fi

if [ -z "$SSH_PUBKEY_FILE" ]; then
  echo "ERROR: No SSH public key found in /root/.ssh (id_ed25519.pub or id_rsa.pub)." >&2
  echo "Generate one with: ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519" >&2
  exit 1
fi

log "Using SSH public key: $SSH_PUBKEY_FILE"

#######################################
# 7) VM sizing & user                 #
#######################################
VM_MEMORY_MB=4096
VM_CORES=2
VM_DISK_SIZE=20G
VM_USER="developer"

log "VM resources:"
log "  RAM : ${VM_MEMORY_MB} MB"
log "  CPU : ${VM_CORES} cores"
log "  Disk: ${VM_DISK_SIZE}"
log "Linux user inside VM: $VM_USER"

#######################################
# 8) Clone template                   #
#######################################
log "Cloning template $TEMPLATE_ID to new VM $VM_ID..."
qm clone "$TEMPLATE_ID" "$VM_ID" --name "$VM_NAME" --full true

log "Resizing disk to $VM_DISK_SIZE..."
qm resize "$VM_ID" scsi0 "$VM_DISK_SIZE"

#######################################
# 9) Basic VM config                  #
#######################################
log "Configuring VM hardware and cloud-init..."

qm set "$VM_ID" \
  --memory "$VM_MEMORY_MB" \
  --cores "$VM_CORES" \
  --net0 "virtio,bridge=$VM_BRIDGE" \
  --scsihw virtio-scsi-pci \
  --ide2 "$VM_STORAGE:cloudinit" \
  --serial0 socket \
  --boot c \
  --bootdisk scsi0

qm set "$VM_ID" \
  --ciuser "$VM_USER" \
  --sshkey "$SSH_PUBKEY_FILE" \
  --ipconfig0 "ip=dhcp"

#######################################
# 10) Cloud-init user-data to install Bun
#######################################
USERDATA_FILE="$SNIPPET_DIR/bun-vm-${VM_ID}-userdata.yaml"

log "Creating cloud-init user-data at: $USERDATA_FILE"

cat > "$USERDATA_FILE" <<EOF
#cloud-config
users:
  - name: $VM_USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash

packages:
  - curl

runcmd:
  - [ bash, -lc, "su - $VM_USER -c 'curl -fsSL https://bun.sh/install | bash'" ]
  - [ bash, -lc, "echo 'export PATH=\"\\$HOME/.bun/bin:\\$PATH\"' >> /home/$VM_USER/.bashrc" ]
EOF

log "Attaching cloud-init user-data snippet to VM..."
qm set "$VM_ID" --cicustom "user=${SNIPPET_STORAGE}:snippets/$(basename "$USERDATA_FILE")"

#######################################
# 11) Start the VM                    #
#######################################
log "Starting VM $VM_ID ($VM_NAME)..."
qm start "$VM_ID"

log "Done."
echo
echo "=============================================="
echo " Bun-ready VM created"
echo "----------------------------------------------"
echo "  Template VMID : $TEMPLATE_ID"
echo "  New VMID      : $VM_ID"
echo "  Name          : $VM_NAME"
echo "  Storage       : $VM_STORAGE"
echo "  Bridge        : $VM_BRIDGE"
echo "  User          : $VM_USER"
echo "  SSH key       : $SSH_PUBKEY_FILE"
echo "=============================================="
echo
echo "On first boot, cloud-init will:"
echo "  - create user '$VM_USER' with sudo"
echo "  - inject your SSH key"
echo "  - install curl"
echo "  - install Bun for '$VM_USER'"
echo
echo "Next steps:"
echo "  1) Wait for the VM to boot and get an IP (check in the Proxmox UI)."
echo "  2) SSH into it using:"
echo "       ssh $VM_USER@<vm-ip>"
echo "  3) Verify Bun:"
echo "       bun --version"
echo
