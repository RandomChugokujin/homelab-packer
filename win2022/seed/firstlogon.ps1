# Runs once at the build's first logon (from autounattend FirstLogonCommands).
# Order matters: WinRM is enabled first so Packer can connect even if a later step fails.
# Later steps log errors and continue instead of aborting.
$ErrorActionPreference = 'Continue'
# Outside C:\Windows\Temp so cleanup.ps1 can't delete it before the build finishes
$log = 'C:\packer-logs\firstlogon.log'
New-Item -ItemType Directory -Path 'C:\packer-logs' -Force | Out-Null
Start-Transcript -Path $log -Append

function Step($name, [scriptblock]$body) {
    try { & $body; Write-Output "OK: $name" }
    catch { Write-Output "FAILED: $name : $($_.Exception.Message)" }
}

# 1. WinRM for Packer (HTTP + basic auth; isolated build network only)
Step 'enable WinRM' {
    Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
    Enable-PSRemoting -Force -SkipNetworkProfileCheck
    Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true
    Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true
    Set-Service WinRM -StartupType Automatic
    if (-not (Get-NetFirewallRule -Name 'WINRM-HTTP-Packer' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'WINRM-HTTP-Packer' -DisplayName 'WinRM HTTP (Packer)' `
            -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow -Profile Any | Out-Null
    }
}

# 2. VirtIO guest tools (NetKVM + qemu-guest-agent) from the virtio-win CD
Step 'install virtio guest tools' {
    $msi = $null
    foreach ($cd in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5') {
        $candidate = Join-Path ($cd.DeviceID + '\') 'virtio-win-gt-x64.msi'
        if (Test-Path $candidate) { $msi = $candidate; break }
    }
    if (-not $msi) { throw 'virtio-win-gt-x64.msi not found on any CD-ROM drive' }
    Write-Output "Installing from $msi"
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
    # 3010 = reboot required. The NetKVM driver is not fully bound until the guest reboots,
    # so the build restarts the VM before sysprep (see win2022.pkr.hcl) and checks for the NIC.
    Write-Output "virtio-win-gt msiexec exit code: $($p.ExitCode)"
    if ($p.ExitCode -notin 0, 3010) { throw "msiexec exit code $($p.ExitCode)" }
}

# 2b. QEMU guest agent: Packer and Proxmox use it to read the VM's IP. Install it from
# the CD's guest-agent folder if the guest-tools MSI didn't register the service, then start it.
Step 'ensure QEMU guest agent' {
    if (-not (Get-Service QEMU-GA -ErrorAction SilentlyContinue)) {
        $gaMsi = $null
        foreach ($cd in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5') {
            $candidate = Join-Path ($cd.DeviceID + '\') 'guest-agent\qemu-ga-x86_64.msi'
            if (Test-Path $candidate) { $gaMsi = $candidate; break }
        }
        if (-not $gaMsi) { throw 'qemu-ga-x86_64.msi not found on any CD-ROM drive' }
        $p = Start-Process msiexec.exe -ArgumentList "/i `"$gaMsi`" /qn /norestart" -Wait -PassThru
        if ($p.ExitCode -notin 0, 3010) { throw "qemu-ga msiexec exit code $($p.ExitCode)" }
    }
    Set-Service QEMU-GA -StartupType Automatic
    Start-Service QEMU-GA
    $s = (Get-Service QEMU-GA).Status
    if ($s -ne 'Running') { throw "QEMU-GA status is $s" }
}

# 3. Windows Update: block automatic updates (the policy carries into clones)
Step 'disable Windows Update' {
    $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    New-Item -Path $au -Force | Out-Null
    Set-ItemProperty -Path $au -Name NoAutoUpdate -Value 1 -Type DWord
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Set-Service wuauserv -StartupType Disabled
}

# 4. Windows Defender: remove the feature. Takes effect after the restart in the build.
Step 'remove Windows Defender feature' {
    $r = Uninstall-WindowsFeature -Name Windows-Defender
    Write-Output "Restart needed: $($r.RestartNeeded)"
}

# Record NetKVM state at the end, so a missing NIC can be traced later
Write-Output '--- NetKVM driver store entries ---'
pnputil /enum-drivers | Select-String -Pattern 'netkvm' -Context 0,3 | ForEach-Object { Write-Output $_.Line }
Get-NetAdapter -IncludeHidden | Format-Table Name,Status,InterfaceDescription | Out-String | Write-Output
Write-Output 'firstlogon complete'
Stop-Transcript
