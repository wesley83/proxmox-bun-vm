# 📦 **proxmox-bun-vm**
### _Automatic Bun-Ready Ubuntu VM Installer for Proxmox VE_
Created by **Wesley Faulkner**

---

## 🚀 Overview

`proxmox-bun-vm` is a one-command installer that creates a fully configured **Ubuntu VM** on **Proxmox VE** and automatically installs:

- ⚡ **Bun** (JavaScript runtime)
- 🔐 SSH access for a user (`developer`)
- 📦 Cloud-init provisioning
- 🖧 Network configuration via DHCP
- 📝 Logging and error handling

**No template VM required** — the script downloads the official Ubuntu Cloud Image and builds everything from scratch, just like the official Proxmox community scripts.

---

## 🧩 One-liner Install

Run this directly on any **Proxmox VE node** as **root**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/wesley83/proxmox-bun-vm/main/bun-vm.sh)"
```

That’s it.  
The script will:

- Detect storage, bridge, SSH keys, VMID  
- Download Ubuntu  
- Create and configure a VM  
- Install Bun  
- Attempt to auto-detect VM IP  

---

## ✨ Features

- 🚫 **No prerequisites** — no cloud-init template required  
- 🧠 **Auto-detects storage**, network bridge, available VMID  
- 🔑 **Injects your SSH key** from `/root/.ssh`  
- 📦 **Cloud-init provisioning** (user, packages, Bun install)  
- 🖥️ **Auto IP detection** for quick SSH access  
- 🧹 **Cleanup and rollback** on error  
- 🎨 **Beautiful CLI banner** with version + repo link  
- 📝 Logs everything to: `/var/log/bun-vm-<VMID>.log`  

---

## 🧰 Requirements

| Requirement | Description |
|------------|-------------|
| Proxmox VE 7/8/9 | Runs directly on a node (not inside a VM) |
| `local` storage | Must have **Snippets** enabled *(once only)* |
| SSH key | Must exist in `/root/.ssh/id_ed25519.pub` or `id_rsa.pub` |

### Enable Snippets on `local` (Required Once)

Proxmox GUI →  
**Datacenter → Storage → local → Edit → Check `Snippets` → Save**

---

## ⚙️ Optional Flags

You can customize the VM with flags:

| Flag | Meaning | Default |
|------|----------|----------|
| `--memory <MB>` | VM RAM | `4096` |
| `--cores <N>` | CPU cores | `2` |
| `--disk <SIZE>` | Disk size | `20G` |
| `--ubuntu <codename>` | Ubuntu version (`noble`, `jammy`, etc.) | `noble` |

### Example:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/wesley83/proxmox-bun-vm/main/bun-vm.sh)" --   --memory 8192   --cores 4   --disk 40G   --ubuntu jammy
```

---

## 🔐 Default VM Configuration

| Setting | Value |
|---------|--------|
| OS | Ubuntu Cloud Image |
| User | `developer` |
| Auth | Your root SSH public key |
| Network | DHCP via `vmbr0` (or first available bridge) |
| Bun Install | Performed via cloud-init |

SSH in using:

```bash
ssh developer@<vm-ip>
```

Check Bun:

```bash
bun --version
```

---

## 🐞 Troubleshooting

### ❗ "Storage 'local' does not support snippets"
Enable snippets:

> Datacenter → Storage → local → Edit → Check `Snippets`

### ❗ "Could not detect VM IP"
Some networks block ARP discovery. Just open the VM console and run:

```bash
ip a
```

Or check your DHCP leases.

### ❗ Script aborted, VM auto-deleted
If something goes wrong, the script automatically:

- Stops the VM  
- Removes it  
- Deletes temporary images  

Check the log file:

```
/var/log/bun-vm-<VMID>.log
```

---

## 👤 Author

Created by: **Wesley Faulkner**  
GitHub: https://github.com/wesley83  
Project: https://github.com/wesley83/proxmox-bun-vm  

---

## 📄 License

MIT License — feel free to fork, modify, and contribute.

