# 📦 **proxmox-bun-vm**
### _Automatic Bun-Ready Ubuntu VM Installer for Proxmox VE_
Created by **Wesley Faulkner**

---

## 🚀 Overview

`proxmox-bun-vm` is a one-command installer that creates a fully configured **Ubuntu VM** on **Proxmox VE** and automatically installs:

- ⚡ **Bun** (JavaScript runtime)
- 🔐 SSH access for a customizable user (default: `developer`)
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
| Proxmox VE 7/8/9 | Runs directly on a node (not inside a VM) — see [Supported Proxmox VE Versions](#-supported-proxmox-ve-versions) below |
| `local` storage | Must have **Snippets** enabled *(once only)* |
| SSH key | Must exist in `/root/.ssh/id_ed25519.pub` or `id_rsa.pub` (or any `.pub` file with one key per line) |
| `curl`, `qemu-img` | Pre-installed on Proxmox; verified by the script |

### Supported Proxmox VE Versions

| Version | Status | Notes |
|---------|--------|-------|
| **PVE 8.x** | ✅ **Recommended** | Current stable; all `qm` flags used are first-class documented syntax. |
| **PVE 9.x** | ✅ Supported | Forward-compatible. The script uses only currently-documented `qm(1)` flags, with no deprecated syntax in play. |
| **PVE 7.x** | ⚠️ Works (EOL) | Supported by the script, but PVE 7 reached end-of-life in mid-2024. Fine for labs; not recommended for new production deployments. |

The script performs **no runtime `pveversion` check** — it relies solely on the stability of the `qm`, `pvesm`, and `pvesh` CLIs. Any PVE release that ships those CLIs at the documented `qm(1)`/`pvesm(1)`/`pvesh(1)` man-page level should work.

### Enable Snippets on `local` (Required Once)

Proxmox GUI →  
**Datacenter → Storage → local → Edit → Check `Snippets` → Save**

---

## ⚙️ Optional Flags

You can customize the VM with flags:

| Flag | Meaning | Default |
|------|----------|---------|
| `-m`, `--memory <MB>` | VM RAM (positive integer, ≥ 1) | `4096` |
| `-c`, `--cores <N>` | CPU cores (positive integer, ≥ 1) | `2` |
| `-d`, `--disk <SIZE>` | Disk size with suffix (e.g. `20G`, `512M`; numeric part ≥ 1) | `20G` |
| `-u`, `--ubuntu <codename>` | Ubuntu version (`noble`, `jammy`, etc.) | latest active LTS (auto-detected; falls back to `noble`) |
| `--user <name>` | VM username (lowercase, must start with a–z or `_`, ≤ 32 chars) | `developer` |
| `--ssh-key <path>` | SSH public key file to embed in cloud-init (must end in `.pub`; one key per line, multiple keys supported) | `/root/.ssh/id_ed25519.pub` (or `id_rsa.pub`) |
| `--debug` | Enable bash debug tracing (`set -x`) — verbose logs to `/var/log/bun-vm-<VMID>.log` | off |
| `-h`, `--help` | Show help menu and exit | — |

### Example:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/wesley83/proxmox-bun-vm/main/bun-vm.sh)" --   --memory 8192   --cores 4   --disk 40G   --ubuntu jammy
```

---

## 🔐 Default VM Configuration

| Setting | Value |
|---------|--------|
| OS | Ubuntu Cloud Image |
| User | `developer` (customizable via `--user`) |
| Auth | Your root SSH public key (SSH); random initial password printed in script summary (console, must be changed on first login) |
| Network | DHCP via `vmbr0` (or first available bridge) |
| CPU | `host` (see [Known Limitations](#-known-limitations)) |
| Machine | `q35` |
| QEMU Guest Agent | Enabled (with `fstrim_cloned_disks=1` — first backup reclaims cloud-image slack) |
| Bun Install | Performed via cloud-init (`runcmd`) |

SSH in using:

```bash
ssh <username>@<vm-ip>   # Default username is `developer` (use --user to change)
```

Check Bun:

```bash
bun --version
```

---

## ✅ Post-Install Verification

Run these checks **on the Proxmox node** after the script finishes to confirm a clean deployment:

```bash
# 1. VM is running
qm status <VMID>

# 2. Cloud-init has consumed the config (empty pending list = cloud-init has run;
#    a non-empty diff means cloud-init hasn't processed the latest user-data yet)
qm cloudinit pending <VMID> | tail -n +2

# 3. SSH works (replace <vm-ip> with the detected IP, or read it from the VM console)
#    Note: bun lives at ~/.bun/bin/bun. The /etc/profile.d/bun.sh entry only
#    fires in login shells; for non-interactive SSH use the full path.
#    <username> is the value you passed to --user, or `developer` by default.
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 <username>@<vm-ip> 'whoami && ~/.bun/bin/bun --version'
```

Expected output for step 3:

```
<username>     # Or `developer` if you didn't pass --user
1.x.y
```

If `bun --version` is missing from the output, Bun's `runcmd` hasn't run yet — wait ~60s and retry, or check `/var/log/cloud-init-output.log` inside the VM.

---

## 🐞 Troubleshooting

### ❗ "Storage 'local' does not support snippets"
Enable snippets:

> Datacenter → Storage → local → Edit → Check `Snippets`

### ❗ "Could not detect VM IP"
The script polls the bridge neighbor table for **up to 2 minutes** (24 attempts
× 5s) after `qm start`. If the timer expires, either the VM hasn't finished
booting, ARP discovery is blocked, or the bridge is too busy to disambiguate
the VM's MAC. Some networks block ARP discovery. Just open the VM console and run:

```bash
ip a
```

Or check your DHCP leases.

If IP detection succeeds but the **detected IP is wrong** (e.g., you get the
gateway or a sibling VM), the script's MAC filter didn't match. The fallback
takes the first neighbor, which is best-effort. Always sanity-check the IP
before assuming the VM is reachable.

### ❗ "Permission denied (publickey)" on SSH
The VM was created but your key isn't accepted. This means cloud-init either
didn't finish, or the custom `user-data` didn't ship your key. Inside the VM
console (Proxmox GUI → VM → Console) log in as `<username>` (default: `developer`) with the initial
password printed in the script's summary (you'll be forced to change it), then
run:

```bash
cloud-init query userdata | grep -A2 ssh_authorized_keys
sudo cat /var/log/cloud-init-output.log | tail -n 50
```

If `ssh_authorized_keys` is empty or missing, your key wasn't embedded — verify
`/root/.ssh/id_ed25519.pub` (or `id_rsa.pub`) exists on the Proxmox node and
re-run the script with a fresh VMID.

### ❗ "bun: command not found" inside the VM
`/etc/profile.d/bun.sh` is sourced by **login shells** (SSH sessions, console).
For interactive **non-login** shells (e.g., a fresh terminal in a desktop
session), bun isn't on `$PATH` yet. Either run `source /etc/profile.d/bun.sh`
or open a login shell with `bash -l`. For non-interactive commands over SSH,
use the absolute path: `~/.bun/bin/bun`.

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

## ⚠️ Known Limitations

### 🚫 Live migration disabled (`--cpu host`)

The script creates VMs with `--cpu host`, which passes the **full host CPU
feature set** through to the guest. This gives the best performance but
**prevents live migration** to any Proxmox node with a different CPU
(different model, vendor, or even microcode version). Offline migration
(shut-down → move → boot) still works fine.

If you need live migration:

```bash
# After VM creation, switch to a portable CPU type
qm set <VMID> --cpu kvm64
```

Or edit `bun-vm.sh` and remove the `--cpu host` line from the `qm create`
command before re-running.

### 🖥️ amd64 only

The Ubuntu cloud image URL is hard-coded to `amd64`. ARM hosts (e.g.,
`local-zfs` on Apple Silicon clusters, or Ampere Altra) will fail at the
`curl` step. Edit `bun-vm.sh` and change `-server-cloudimg-amd64.img`
to `-server-cloudimg-arm64.img` for ARM.

### 🔄 Latest LTS is auto-detected (with fallback)

By default the script queries Launchpad's API for the current latest active
Ubuntu LTS codename and uses that. If the query fails (no `python3`, no
network, API down), it falls back to the hard-coded `noble` (24.04 LTS).
Pin a specific codename with `--ubuntu` to bypass auto-detection — useful in
air-gapped environments or when you want a non-LTS release.

**In-development LTS risk:** once the next even-year `.04` (e.g. 28.04)
enters *Active Development* — roughly 6 months before its release —
Launchpad flags it as `active=true`, so the auto-detector will pick it.
The corresponding cloud image doesn't exist yet, and the script will
fail with a clear 404 from `curl`. The hard-coded fallback (`noble`)
still works, and you can pin to any specific release with
`--ubuntu jammy`, `--ubuntu noble`, etc. The script ships unfixed on
this point because the failure is loud and the workaround is one flag
away; the filter location is marked with a comment in `bun-vm.sh`.

### 🧹 No automatic VM teardown

The script cleans up after itself on **failure** (auto-destroys the VM) but
not after a **successful** run. To free storage, see the teardown command in
[Useful Commands](#-useful-commands).

### 🔌 VM does not auto-start on host reboot

The script creates VMs with `--onboot 0` (off). After a Proxmox host reboot,
you'll need to start the VM manually. To change this on an existing VM:

```bash
qm set <VMID> --onboot 1
```

This is the safety default — unattended start of a new dev VM after a host
reboot is rarely what you want.

---

## 🛠️ Useful Commands

Run these on the **Proxmox node** to manage the VM after creation:

```bash
# Lifecycle
qm status <VMID>              # Is it running?
qm start <VMID>               # Boot it
qm shutdown <VMID>            # Graceful ACPI shutdown (waits for guest)
qm stop <VMID>                # Hard power-off (last resort)
qm reboot <VMID>              # Reboot

# Access
qm terminal <VMID>            # Serial console — login as <username> with the printed password
                             # (<username> is `developer` by default, or whatever you passed to --user)
                             # Press Ctrl+O to exit the serial terminal
ssh <username>@<vm-ip>         # SSH key auth (no password needed)

# Inspection
qm config <VMID>              # Full VM configuration
qm cloudinit pending <VMID>   # Show pending cloud-init config (empty = already consumed next boot)
cat /var/log/bun-vm-<VMID>.log   # Script log from this run

# Re-trigger cloud-init without recreating the VM
qm cloudinit update <VMID>
qm reboot <VMID>

# Complete teardown (frees storage)
qm stop <VMID>
qm destroy <VMID> --purge
```

Inside the **VM** as `<username>` (default: `developer`):

```bash
bun --version                 # Verify Bun
which bun                     # Should be ~/.bun/bin/bun
ls -la /etc/profile.d/bun.sh  # System-wide PATH entry
passwd                        # Change the initial console password
```

For debugging a failed run, re-run the script with `--debug` to get
`set -x` tracing in the log file:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/wesley83/proxmox-bun-vm/main/bun-vm.sh)" -- --debug
```

---

## 👤 Author

Created by: **Wesley Faulkner**  
GitHub: https://github.com/wesley83  
Project: https://github.com/wesley83/proxmox-bun-vm  

---

## 📄 License

MIT License — feel free to fork, modify, and contribute.

