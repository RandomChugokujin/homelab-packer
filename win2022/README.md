# Windows Server 2022 template for Proxmox VE (Packer)

Builds a Windows Server 2022 Standard (Desktop Experience) VM on Proxmox VE with the
`proxmox-iso` Packer builder, configures it, runs sysprep, and converts it to a Proxmox
template. Clones of the template boot into a generalized state: random hostname, new SID,
DHCP address.

What the template contains:

- UEFI (OVMF) + Q35, 4 vCPU (host type), 4 GB RAM, 60 GB virtio-scsi disk, Intel e1000 NIC
- VirtIO guest tools and the QEMU guest agent
- Windows Defender feature removed
- Windows Update blocked (`NoAutoUpdate=1`, `wuauserv`/`UsoSvc` disabled)
- Not activated (see [Activation](#activation))

## Layout

| Path | Purpose |
|---|---|
| `win2022.pkr.hcl` | The Packer template: VM definition and provisioning steps |
| `variables.pkrvars.hcl.example` | Copy to `variables.pkrvars.hcl` and fill in. The real file is git-ignored |
| `make-seed.sh` | Builds the seed ISO and uploads it to Proxmox |
| `seed/autounattend.xml` | Windows Setup answer file: disk layout, image, product key, admin password, first logon |
| `seed/firstlogon.ps1` | Runs once at first logon: enables WinRM, installs VirtIO tools, disables Windows Update, removes Defender |
| `templates/sysprep-unattend.xml.pkrtpl` | Answer file used by sysprep, applied to every clone on first boot |
| `scripts/cleanup.ps1` | Shrinks the image before sysprep |

## Prerequisites

### On the machine running Packer

- `packer` (the `proxmox` plugin is installed by `packer init`)
- `xorriso`, `bsdtar` (libarchive), `python3`, `curl`, `scp`. `make-seed.sh` uses all of these
- SSH access to the Proxmox host (key auth recommended). The script copies the seed ISO with `scp`
- Network reachability to the Proxmox API (port 8006) and to the build VM on TCP 5985 (WinRM). The workstation must be on, or routed to, the same network as the VM's bridge

### On Proxmox VE

- A bridge (`vmbr0` in the template) with a **DHCP server**. The build VM and clones use DHCP.
  Optionally add a reservation for the build VM's pinned MAC, `02:00:00:AA:BB:01`
- A storage pool for the VM disk and EFI disk (`storage_pool`, e.g. `pool1`), and ISO storage (`local`)
- A free VM ID (`vm_id`). The template is built as, and ends up as, this VM ID, so it must not already exist
- An **API token** with rights to create, configure, power-manage and delete VMs and to
  allocate on the storage. `root@pam!packer` works. For a least-privilege role, see the
  permission list in the
  [`proxmox-iso` plugin docs](https://developer.hashicorp.com/packer/integrations/hashicorp/proxmox/latest/components/builder/iso)
- Three ISOs in Proxmox ISO storage (`local:iso/` by default):
  1. Windows Server 2022 install ISO
  2. `virtio-win.iso`
  3. `win2022-seed.iso` (built and uploaded by `make-seed.sh`)

### ISO notes

- Use volume-licensed or MSDN/Azure Dev Tools media. The answer file contains the Server 2022
  Standard KMS client key (GVLK), which installs on that media.
- **Evaluation ISOs:** remove the `<ProductKey>` block from `seed/autounattend.xml`, which eval
  media generally rejects. Also check the image name below. Eval clones inherit the 180-day
  timer from when the template was built.
- `autounattend.xml` selects the image `Windows Server 2022 SERVERSTANDARD`. If your ISO names
  it differently, setup stops with "cannot find the image". List names with:
  ```powershell
  Get-WindowsImage -ImagePath D:\sources\install.wim | ft ImageIndex,ImageName
  ```
- `virtio-win.iso` must be on the Proxmox host too. `make-seed.sh` only downloads it locally
  (to get the storage driver). Upload it yourself:
  ```bash
  scp virtio-win.iso root@pve1:/var/lib/vz/template/iso/
  ```

## Configuration

```bash
cp variables.pkrvars.hcl.example variables.pkrvars.hcl
```

Edit `variables.pkrvars.hcl`:

| Variable | Meaning |
|---|---|
| `proxmox_url` | e.g. `https://pve.example.com:8006/api2/json` |
| `proxmox_username` | API token ID, e.g. `root@pam!packer` |
| `proxmox_token` | The token secret |
| `proxmox_node` | Node name where the VM is built |
| `iso_file` | Proxmox path of the Windows ISO, e.g. `local:iso/en-us_windows_server_2022_....iso` |
| `iso_checksum` | `sha256:<hash>` of that ISO |
| `virtio_iso_file` | Defaults to `local:iso/virtio-win.iso` |
| `seed_iso_file` | Defaults to `local:iso/win2022-seed.iso` |
| `storage_pool` | Proxmox storage for disks |
| `vm_id` | VM ID for the build VM and the template |
| `template_name` | Template name |
| `admin_password` | Build-time Administrator password (see below) |

Never commit `variables.pkrvars.hcl`. You can also pass secrets as
`PKR_VAR_proxmox_token` and `PKR_VAR_admin_password` environment variables.

`admin_password` must match the `ADMIN_PASSWORD` you give `make-seed.sh`. It is baked into
the seed ISO's `autounattend.xml`, used by Packer for WinRM, and set again by the sysprep
answer file. **Every clone has this same Administrator password.** Change it after cloning, or
use a per-environment value.

## Usage

### 1. Build and upload the seed ISO

```bash
ADMIN_PASSWORD='the-same-password' ./make-seed.sh root@pve1
# optional: ./make-seed.sh [/path/to/virtio-win.iso] root@pve1 [/var/lib/vz/template/iso]
```

What it does:

1. Uses `./virtio-win.iso`. If missing, downloads it from the Fedora project (about 877 MB;
   override with `VIRTIO_URL`). The download is verified before use.
2. Copies `seed/` into a temp directory and extracts the Server 2022 VirtIO SCSI driver
   (`vioscsi`) into `$WinPEDriver$`, which Windows Setup loads automatically. Without it,
   setup cannot see the virtio disk.
3. Writes `ADMIN_PASSWORD` (XML-escaped) into `autounattend.xml`.
4. Builds `win2022-seed.iso` with `xorriso` and `scp`s it to the Proxmox ISO directory.

Re-run it whenever you change anything in `seed/` or the admin password.

### 2. Build the template

```bash
packer init .
packer validate -var-file=variables.pkrvars.hcl .
packer build -on-error=abort -var-file=variables.pkrvars.hcl .
```

Expect about 20 minutes. `-on-error=abort` leaves a failed VM running so you can inspect it,
for example with `qm guest exec` or the console. Destroy it before re-running.

### 3. After the build

- Delete `win2022-seed.iso` locally and on Proxmox. It contains the admin password in plaintext.
- Clone the template. First boot runs specialize and OOBE, then the VM gets a NIC and a DHCP lease.
- Optionally verify on a clone:
  ```powershell
  Get-WindowsFeature Windows-Defender | ft Name,InstallState   # not Installed
  Get-Service WinDefend -ErrorAction SilentlyContinue          # no service
  Get-Service wuauserv | ft Name,Status,StartType
  (Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU).NoAutoUpdate   # 1
  ```
  Windows can re-enable `wuauserv` on its own after first boot. `NoAutoUpdate=1` still blocks
  automatic updates.

## What the Packer build does

1. **Create and install.** Packer creates the VM with the three ISOs attached and presses a key
   to boot the Windows ISO. `autounattend.xml` partitions the disk (EFI/MSR/NTFS), installs
   Standard, and sets the Administrator password. It auto-logs in once and runs `firstlogon.ps1`.
2. **Connect.** Packer connects over WinRM as soon as `firstlogon.ps1` enables it.
3. **Wait for firstlogon.** A provisioner waits for `firstlogon complete` in
   `C:\packer-logs\firstlogon.log` and fails if any step logged `FAILED:`. Without this, the
   next reboot interrupts the Defender removal.
4. **Upload the sysprep answer file**, then **restart** to finish removing Defender.
5. **`cleanup.ps1`**: clears temp files and the update cache and runs `DISM /ResetBase`.
6. **NIC check**: confirms an adapter has an IPv4 address before sysprep.
7. **Harden and assert**: re-applies the Windows Update policy and disables `wuauserv` and
   `UsoSvc`. The build fails if Update isn't blocked or Defender is still present.
8. **Sysprep**: a scheduled task, run as SYSTEM after a 30-second delay, executes
   `sysprep /generalize /oobe /shutdown`. The delay lets Packer's provisioner return cleanly,
   because generalize deletes the NIC within seconds and kills WinRM.
9. **Wait for power-off.** The workstation polls the Proxmox API until the VM is `stopped`
   (up to 10 minutes). Do not power the VM on during this. A booted, generalized VM can no
   longer be a template.
10. **Convert to template.**

## Activation

The template carries the KMS client key only, so clones are unactivated. They run, with a
watermark, until activated. To activate a clone, use a key from your licensing program:

```powershell
slmgr /ipk <key>
slmgr /ato
```

Do not put that key in the template. Check your program's terms (for example Azure Dev Tools
for Teaching) for allowed use and activation limits.

## Troubleshooting

| Symptom | Cause / action |
|---|---|
| `no route to host` or WinRM drops during the build | Sysprep generalize removed the NIC while a provisioner was still running. The detached sysprep step exists to prevent this |
| The wait-for-power-off step prints `running` forever | The VM was powered on again after sysprep. Destroy it and rebuild |
| `FAILED:` lines from the first provisioner | A step in `firstlogon.ps1` failed. Read `C:\packer-logs\firstlogon.log` on the VM |
| Build stops at hardening checks | Defender or Windows Update is not in the expected state. The check names the failing item |
| Setup cannot find a disk | The VirtIO SCSI driver was not in `$WinPEDriver$`. Re-run `make-seed.sh` and check it finished |
| Setup cannot find the image or rejects the key | See [ISO notes](#iso-notes) |
| Sysprep fails | Read `C:\Windows\System32\Sysprep\Panther\setupact.log` on the VM |
| VM ID already exists | Destroy it, or change `vm_id` |
| Clone has no NIC after a successful build | Not yet seen. Check Device Manager and `pnputil /enum-drivers` for NetKVM/e1000 |

## Security notes

- `variables.pkrvars.hcl`, ISOs, and Packer caches are git-ignored. The seed ISO and the
  uploaded copy contain the admin password in plaintext, so delete them after each build.
- WinRM uses HTTP with basic auth and allows unencrypted traffic. It is intended for a trusted
  build network only. The firewall rule for port 5985 stays in the template, so remove it from
  clones that don't need WinRM.
- The Proxmox API connection skips TLS verification (`insecure_skip_tls_verify = true`).
  Set it to `false` if your Proxmox certificate is trusted.
