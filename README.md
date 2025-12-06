# **Proxmox Bun VM Auto-Provisioning Script**

This repository provides a **one-command installer** that automatically creates a fully configured **Bun-ready Linux VM** on Proxmox VE, similar to the community scripts at [community-scripts.github.io/ProxmoxVE](https://community-scripts.github.io/ProxmoxVE/).

Simply run one command on your Proxmox node, and the script will:

---

## ✅ **What This Script Does**

- Auto-detects your **cloud-init template VM**  
- Auto-selects:
  - The next free **VMID**
  - Suitable **storage**
  - Appropriate **network bridge**
  - An SSH public key from `/root/.ssh`  
- Clones a new VM from the template  
- Adds cloud-init user-data to:
  - Create a `developer` user with sudo  
  - Inject your SSH key  
  - Install **curl**  
  - Install **Bun** on first boot  
- Boots the VM and prints instructions on how to connect

No configuration required. No editing variables. No guessing VMIDs or storage names.

---

## 🚀 **Quick Install Command**

Run this **on your Proxmox VE host** as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/wesley83/proxmox-bun-vm/main/bun-vm.sh)"
```

Or the shorter version:

```bash
curl -fsSL https://raw.githubusercontent.com/wesley83/proxmox-bun-vm/main/bun-vm.sh | bash
```

---

## 📦 **Prerequisites**

Before running the script:

### 1. You must have a **cloud-init template VM**

Typical examples:
- Ubuntu 22.04 cloud image  
- Debian cloud image  

Convert a VM into a template:

```bash
qm template <vmid>
```

---

### 2. Enable **Snippets** on storage `local`

In Proxmox:

- **Datacenter → Storage → local → Edit**  
- Check ✅ **Snippets**  
- Save  

---

### 3. Have an SSH key available

The script looks for one of these:

```
/root/.ssh/id_ed25519.pub
/root/.ssh/id_rsa.pub
```

Generate one if needed:

```bash
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519
```

---

## 🧠 How It Works

The script automatically:

### 🔍 Detects a cloud-init template  
Searches for any VM config with `template: 1`.

### 🆕 Gets the next VMID  
Using:

```bash
pvesh get /cluster/nextid
```

### 💾 Detects storage  
Prefers `local-lvm`, falls back to the first active storage.

### 🌐 Detects a network bridge  
Prefers `vmbr0`, falls back to the first available `vmbr*`.

### 🔑 Detects your SSH key  
Uses the first matching public key found in `/root/.ssh`.

### 📝 Generates cloud-init user-data  
Includes the Bun installation commands.

---

## 🧩 Result

After running the installer, you’ll have:

- A fresh Bun-ready VM  
- A `developer` user with sudo  
- Your SSH key authorized  
- Bun installed and ready to run  

SSH in:

```bash
ssh developer@<vm-ip>
```

Verify Bun:

```bash
bun --version
```

---

## 💡 Why This Script Exists

Bun is a fast, modern JavaScript runtime perfect for:

- APIs  
- Microservices  
- Dev environments  
- Prototyping  
- Teaching  

This script makes spinning up a Bun VM effortless.

---

## ⭐ Contributions Welcome

Open an issue or PR if you'd like:

- Flags for CPU/RAM  
- Auto-detected VM IP  
- Additional runtime installers  
- Multi-VM creation  
- Enhanced logging  

---

## 📄 License

MIT — free to use, fork, or extend.
