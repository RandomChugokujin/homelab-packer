# Packer templates for Proxmox VE

Packer templates that build VM templates on a Proxmox VE homelab. Each OS lives in its own
directory with its own README, variables and scripts.

## Templates

| Directory | OS | Notes |
|---|---|---|
| [`win2022/`](win2022/) | Windows Server 2022 Standard | UEFI, VirtIO guest tools, Defender removed, Windows Update blocked, sysprepped |

More will be added as they're built.

## Common requirements

These apply to every template. Each template's README lists what it needs on top of this.

- [Packer](https://developer.hashicorp.com/packer/install). Run `packer init .` in a template
  directory to install its plugins
- A Proxmox VE node with:
  - an API token that can create, configure, power-manage and delete VMs and use the target storage
  - a storage pool for VM disks and ISO storage for installer ISOs
  - a bridge with DHCP. Packer finds the build VM through the QEMU guest agent or its DHCP address
- The workstation running Packer must reach the Proxmox API (port 8006) and the build VM
  (WinRM or SSH, depending on the OS)
- Installer ISOs are not in this repo. Upload them to Proxmox ISO storage and reference them
  by their Proxmox path (`local:iso/...`)

## Using a template

```bash
cd <template-dir>
cp variables.pkrvars.hcl.example variables.pkrvars.hcl   # then fill in
packer init .
packer validate -var-file=variables.pkrvars.hcl .
packer build -on-error=abort -var-file=variables.pkrvars.hcl .
```

`-on-error=abort` keeps a failed build VM running so you can inspect it. Destroy it before
re-running, because the template is built as the VM ID you configured.

Some templates need a preparation step first, such as building a seed ISO. See the
template's README.

## Conventions for new templates

Each template directory contains:

| File | Purpose |
|---|---|
| `README.md` | Prerequisites, configuration, usage, what the build does, troubleshooting |
| `<name>.pkr.hcl` | The Packer template |
| `variables.pkrvars.hcl.example` | Placeholder values only. Copy to `variables.pkrvars.hcl` (git-ignored) |
| `scripts/`, `seed/`, `templates/` | Provisioning scripts, unattended-install files, rendered templates |

Keep these rules so the repo stays safe to publish:

- Real credentials only go in `variables.pkrvars.hcl` or `PKR_VAR_*` environment variables,
  never in tracked files
- Use placeholders in tracked answer files and render real values at build time (like
  `make-seed.sh` does with `ADMIN_PASSWORD`)
- Never commit ISOs, seed images or Packer caches. The root `.gitignore` covers them
- Document anything that behaves unexpectedly. The Windows template's sysprep step, for
  example, is explained in `win2022/README.md`

## Security notes

- These templates are for a trusted homelab network. Build-time settings such as WinRM over
  HTTP with basic auth, skipped TLS verification for the Proxmox API, and a shared admin
  password are convenient for building, not hardened for production
- Seed images contain build-time passwords in plaintext. Delete them after each build
- Rotate any credential that has appeared in logs, chat or screenshots

## License

GPL-3.0. See [LICENSE](LICENSE).
