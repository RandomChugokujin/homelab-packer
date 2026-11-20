packer {
  required_plugins {
    proxmox = {
      source  = "github.com/hashicorp/proxmox"
      version = ">= 1.2.0"
    }
  }
}

variable "proxmox_url" {
  type = string
}

variable "proxmox_username" {
  type = string
}

variable "proxmox_token" {
  type      = string
  sensitive = true
}

variable "proxmox_node" {
  type = string
}

variable "iso_file" {
  type    = string
  default = "local:iso/SERVER_2022_EVAL_x64FRE_en-us.iso"
}

variable "iso_checksum" {
  type = string
}

variable "virtio_iso_file" {
  type    = string
  default = "local:iso/virtio-win.iso"
}

# Built and uploaded by make-seed.sh (autounattend.xml, firstlogon.ps1, VirtIO SCSI driver)
variable "seed_iso_file" {
  type    = string
  default = "local:iso/win2022-seed.iso"
}

variable "storage_pool" {
  type    = string
  default = "local-lvm"
}

variable "vm_id" {
  type    = number
  default = 9100
}

variable "template_name" {
  type    = string
  default = "win2022-tpl"
}

# Build-time Administrator password (WinRM login). Must match the value make-seed.sh
# rendered into autounattend.xml. Clones are prompted to change it on first boot unless
# overridden.
variable "admin_password" {
  type      = string
  sensitive = true
}

locals {
  sysprep_unattend = templatefile("${path.root}/templates/sysprep-unattend.xml.pkrtpl", {
    admin_password = var.admin_password
  })
}

source "proxmox-iso" "win2022" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  node                     = var.proxmox_node
  insecure_skip_tls_verify = true

  task_timeout         = "10m"
  vm_id                = var.vm_id
  vm_name              = var.template_name
  template_name        = var.template_name
  template_description = "Windows Server 2022, DHCP, unactivated. Built by Packer."

  os              = "win11"   # Proxmox OS type used for modern Windows, including Server 2022
  bios            = "ovmf"
  machine         = "q35"
  cpu_type        = "host"
  cores           = 4
  memory          = 4096
  qemu_agent      = true
  scsi_controller = "virtio-scsi-single"

  # Windows Server ISO (installer)
  boot_iso {
    type         = "sata"
    index        = 0
    iso_file     = var.iso_file
    iso_checksum = var.iso_checksum
    unmount      = true
  }

  # Seed CD: autounattend.xml + firstlogon.ps1 + $WinPEDriver$ (VirtIO SCSI)
  additional_iso_files {
    type     = "sata"
    index    = 1
    iso_file = var.seed_iso_file
    unmount  = true
  }

  # VirtIO guest tools. Stays attached until firstlogon installs them, then unmounted.
  additional_iso_files {
    type     = "sata"
    index    = 2
    iso_file = var.virtio_iso_file
    unmount  = true
  }

  efi_config {
    efi_storage_pool  = var.storage_pool
    efi_type          = "4m"
    pre_enrolled_keys = true
  }

  disks {
    type         = "scsi"
    disk_size    = "60G"
    storage_pool = var.storage_pool
    discard      = true
  }

  network_adapters {
    model       = "e1000"
    bridge      = "vmbr0"
    # Fixed MAC so a pfSense DHCP reservation can give the build VM a stable address.
    mac_address = "02:00:00:AA:BB:01"
  }

  boot_wait = "3s"
  # Windows shows "Press any key to boot from CD or DVD" for about 5s.
  # Extra spaces at later Setup screens are harmless.
  boot_command = ["<spacebar><wait2s><spacebar><wait2s><spacebar>"]

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.admin_password
  winrm_port     = 5985
  winrm_use_ssl  = false
  winrm_timeout  = "2h"
}

build {
  sources = ["source.proxmox-iso.win2022"]

  # Packer connects as soon as firstlogon.ps1 enables WinRM, while the script is still
  # installing drivers and removing Defender. Rebooting now would kill it mid-run.
  # Wait for its completion marker, and fail the build if any step logged FAILED.
  provisioner "powershell" {
    inline = [
      "$log = 'C:\\packer-logs\\firstlogon.log'",
      "$deadline = (Get-Date).AddMinutes(30)",
      "while (-not ((Test-Path $log) -and (Select-String -Path $log -Pattern 'firstlogon complete' -Quiet))) { if ((Get-Date) -gt $deadline) { throw 'timed out waiting for firstlogon.ps1 to finish' }; Start-Sleep -Seconds 10 }",
      "$failed = Select-String -Path $log -Pattern '^FAILED:'",
      "if ($failed) { $failed | ForEach-Object { Write-Output $_.Line }; throw 'firstlogon.ps1 had failed steps' }",
      "Write-Output 'firstlogon.ps1 finished cleanly'"
    ]
  }

  provisioner "file" {
    content     = local.sysprep_unattend
    destination = "C:/Windows/System32/Sysprep/unattend.xml"
  }

  # Windows Update is disabled by seed/firstlogon.ps1, so no update step runs here.
  # The restart completes the Defender feature removal before cleanup and sysprep.
  provisioner "windows-restart" {}

  provisioner "powershell" {
    scripts = ["scripts/cleanup.ps1"]
  }

  # Fail fast if no network adapter is up. Packer needs the NIC to reach the VM, and
  # sysprep on a machine with no NIC produces a template that can't get a DHCP address.
  provisioner "powershell" {
    inline = [
      "$deadline = (Get-Date).AddMinutes(3)",
      "do { $up = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } | Where-Object { Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254.*' } }; if ($up) { break }; Start-Sleep -Seconds 5 } while ((Get-Date) -lt $deadline)",
      "if (-not $up) { Get-NetAdapter -IncludeHidden | Format-Table Name,Status,InterfaceDescription | Out-String | Write-Output; throw 'no physical network adapter is up with an IPv4 address' }",
      "Write-Output \"NIC up with IPv4: $($up.Name)\"; Get-NetIPAddress -AddressFamily IPv4 | Format-Table InterfaceAlias,IPAddress | Out-String | Write-Output"
    ]
  }


  # Runs after the restart, so Defender removal is complete. Windows can re-enable
  # wuauserv on its own, so set it again right before sysprep, then assert the final state.
  provisioner "powershell" {
    inline = [
      "$au = 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU'",
      "New-Item -Path $au -Force | Out-Null",
      "Set-ItemProperty -Path $au -Name NoAutoUpdate -Value 1 -Type DWord",
      "foreach ($n in 'wuauserv','UsoSvc') { Stop-Service $n -Force -ErrorAction SilentlyContinue; Set-Service $n -StartupType Disabled -ErrorAction SilentlyContinue; Set-ItemProperty \"HKLM:\\SYSTEM\\CurrentControlSet\\Services\\$n\" -Name Start -Value 4 -ErrorAction SilentlyContinue }",
      "$errs = @()",
      "if ((Get-ItemProperty $au).NoAutoUpdate -ne 1) { $errs += 'NoAutoUpdate policy not set' }",
      "if ((Get-Service wuauserv).StartType -ne 'Disabled') { $errs += 'wuauserv is not Disabled' }",
      "if ((Get-WindowsFeature Windows-Defender).InstallState -eq 'Installed') { $errs += 'Windows-Defender feature is still installed' }",
      "if (Get-Service WinDefend -ErrorAction SilentlyContinue) { $errs += 'WinDefend service still exists' }",
      "if ($errs) { $errs | ForEach-Object { Write-Output \"CHECK FAILED: $_\" }; throw 'template hardening check failed' }",
      "Write-Output 'Defender removed, Windows Update disabled'"
    ]
  }

  # Sysprep /generalize deletes every PnP device node, NIC included, so the WinRM session
  # dies seconds after it starts. If that happens while a provisioner is still running, the
  # provisioner hangs. So: drop a script on the guest, schedule it as SYSTEM, and return.
  # The script waits 30s, so this provisioner exits cleanly before the NIC goes away.
  # /shutdown makes sysprep power the VM off itself when done.
  provisioner "file" {
    destination = "C:/Windows/Temp/run-sysprep.ps1"
    content     = <<-EOT
      Start-Sleep -Seconds 30
      & 'C:\Windows\System32\Sysprep\sysprep.exe' /generalize /oobe /shutdown /unattend:C:\Windows\System32\Sysprep\unattend.xml
    EOT
  }

  provisioner "powershell" {
    inline = [
      "schtasks.exe /Create /F /TN SysprepTpl /SC ONCE /ST 00:00 /RU SYSTEM /RL HIGHEST /TR 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\run-sysprep.ps1'",
      "if ($LASTEXITCODE -ne 0) { throw 'schtasks create failed' }",
      "schtasks.exe /Run /TN SysprepTpl",
      "if ($LASTEXITCODE -ne 0) { throw 'schtasks run failed' }",
      "Write-Output 'sysprep scheduled'"
    ]
  }

  # Wait for sysprep to finish and power the VM off before the template-conversion step
  # sends its own ACPI shutdown mid-generalize.
  provisioner "shell-local" {
    environment_vars = [
      "PVE_URL=${var.proxmox_url}",
      "PVE_AUTH=PVEAPIToken=${var.proxmox_username}=${var.proxmox_token}",
      "PVE_NODE=${var.proxmox_node}",
      "PVE_VMID=${var.vm_id}",
    ]
    inline = [
      "for i in $(seq 1 120); do s=$(curl -sk -H \"Authorization: $PVE_AUTH\" \"$PVE_URL/nodes/$PVE_NODE/qemu/$PVE_VMID/status/current\" | grep -o '\"status\":\"[a-z]*\"'); echo \"$s\"; case \"$s\" in *stopped*) exit 0;; esac; sleep 5; done; echo 'VM did not power off after sysprep' >&2; exit 1"
    ]
  }
}
