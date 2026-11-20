# Shrink and tidy the image before sysprep.
$ErrorActionPreference = 'Continue'

Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Windows\SoftwareDistribution\Download\*' -Recurse -Force -ErrorAction SilentlyContinue
# Leave wuauserv stopped and disabled: updates are off by policy in firstlogon.ps1.

# Keep Packer's own files in C:\Windows\Temp (packer-ps-env-vars-*, packer-ps-*, winrmcp-*);
# deleting them breaks the next provisioner and the build.
Get-ChildItem 'C:\Windows\Temp' -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike 'packer-*' -and $_.Name -notlike 'winrmcp-*' } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem 'C:\Users' -Directory | ForEach-Object {
    Remove-Item (Join-Path $_.FullName 'AppData\Local\Temp\*') -Recurse -Force -ErrorAction SilentlyContinue
}


# Remove superseded component store versions after updates (slow, but cuts image size)
Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase | Out-Null

Write-Output 'cleanup complete'
