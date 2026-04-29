<#
.SYNOPSIS
  Provision a clean Windows 11 VirtualBox VM for testing the YouCoded installer.

.DESCRIPTION
  Creates a Win11 VM from a Microsoft ISO, runs the install fully unattended,
  installs Guest Additions, and takes a "clean" snapshot you can revert to
  between test runs. End state: a fresh Windows 11 with no Node, no Claude,
  no YouCoded — the environment our prerequisite installer must handle.

  See docs/local-dev-vm.md for prerequisites, the manual VBoxManage walkthrough,
  and the test workflow.

.PARAMETER IsoPath
  Path to a Windows 11 ISO downloaded from
  https://www.microsoft.com/en-us/software-download/windows11

.PARAMETER VmName
  Name to register the VM under. Default "YouCoded-Win11-Test".

.EXAMPLE
  pwsh scripts/setup-test-vm.ps1 -IsoPath C:\Users\you\Downloads\Win11.iso

.NOTES
  Idempotency: the script bails if a VM with the target name already exists.
  Delete it first with `VBoxManage unregistervm <name> --delete` if you want
  to rebuild.
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$IsoPath,

  [string]$VmName  = "YouCoded-Win11-Test",
  [int]   $RamMB   = 4096,
  [int]   $Cpus    = 4,
  [int]   $DiskGB  = 64,
  [string]$Username = "tester",

  # Local-only test VM, never internet-facing. Password is documented so future
  # devs can sign in to the snapshot they revert to. Don't change without also
  # updating docs/local-dev-vm.md.
  [string]$Password = "TestVM!2026",

  # Skip-the-snapshot escape hatch for users who want to inspect the install
  # before committing to a baseline.
  [switch]$NoSnapshot
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------

$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
if (-not (Test-Path $VBoxManage)) {
  throw "VBoxManage not found at $VBoxManage. Install VirtualBox first: winget install Oracle.VirtualBox"
}

if (-not (Test-Path $IsoPath)) {
  throw "ISO not found at $IsoPath. Download from https://www.microsoft.com/en-us/software-download/windows11"
}

$IsoPath = (Resolve-Path $IsoPath).Path

# Bail if the VM already exists — refusing to overwrite is the safe default.
$existing = & $VBoxManage list vms 2>$null | Select-String "`"$VmName`""
if ($existing) {
  throw "VM '$VmName' already exists. Delete with: & '$VBoxManage' unregistervm '$VmName' --delete"
}

Write-Host "Creating VM '$VmName'..." -ForegroundColor Cyan

# ----------------------------------------------------------------------------
# 1) Create + configure the VM
# ----------------------------------------------------------------------------

# Win11 needs EFI + TPM 2.0 + Secure Boot or setup refuses to proceed.
& $VBoxManage createvm --name $VmName --ostype "Windows11_64" --register | Out-Null

& $VBoxManage modifyvm $VmName `
    --memory $RamMB `
    --cpus $Cpus `
    --firmware efi `
    --tpm-type 2.0 `
    --graphicscontroller vboxsvga `
    --vram 128 `
    --usbohci on `
    --usbxhci on `
    --audio-driver default `
    --nic1 nat | Out-Null

# Secure Boot is a four-step dance in VBox 7.2+:
#   1) inituefivarstore  — create the NVRAM/UEFI variable store (firmware
#      efi above doesn't auto-create one)
#   2) enrollmssignatures — enroll Microsoft KEK + DB signatures so Win11
#      Setup's bootloader passes Secure Boot validation
#   3) enrollorclpk      — enroll the Oracle Platform Key (any PK works;
#      Oracle's is the convenient one bundled with VBox)
#   4) secureboot --enable — flip Secure Boot on
# This replaces the VBox-7.0 `modifyvm --secure-boot on` + `modifynvram
# initsecureboot`, both of which were removed/renamed in 7.2.
& $VBoxManage modifynvram $VmName inituefivarstore | Out-Null
& $VBoxManage modifynvram $VmName enrollmssignatures | Out-Null
& $VBoxManage modifynvram $VmName enrollorclpk | Out-Null
& $VBoxManage modifynvram $VmName secureboot --enable | Out-Null

# ----------------------------------------------------------------------------
# 2) Storage: disk + DVD
# ----------------------------------------------------------------------------

$VmFolder = (& $VBoxManage showvminfo $VmName --machinereadable | Select-String '^CfgFile=').Line
$VmFolder = $VmFolder -replace '^CfgFile="', '' -replace '"$', ''
$VmFolder = Split-Path $VmFolder -Parent

$DiskPath = Join-Path $VmFolder "$VmName.vdi"

& $VBoxManage createmedium disk --filename $DiskPath --size ($DiskGB * 1024) --variant Standard | Out-Null
& $VBoxManage storagectl $VmName --name "SATA" --add sata --controller IntelAhci --portcount 2 --bootable on | Out-Null
& $VBoxManage storageattach $VmName --storagectl "SATA" --port 0 --device 0 --type hdd --medium $DiskPath | Out-Null
& $VBoxManage storageattach $VmName --storagectl "SATA" --port 1 --device 0 --type dvddrive --medium $IsoPath | Out-Null

# ----------------------------------------------------------------------------
# 3) Unattended install
# ----------------------------------------------------------------------------

# `unattended install` auto-generates an autounattend.xml that matches the
# Windows release on the ISO, partitions the disk, sets the user/password,
# bypasses the Microsoft-account-required OOBE on Win11, and (with
# --install-additions) installs Guest Additions on first boot.
Write-Host "Configuring unattended install..." -ForegroundColor Cyan
& $VBoxManage unattended install $VmName `
    --iso=$IsoPath `
    --user=$Username `
    --user-password=$Password `
    --full-user-name="$Username" `
    --time-zone="Pacific Standard Time" `
    --locale="en_US" `
    --country="US" `
    --hostname="youcoded-test.local" `
    --install-additions `
    --start-vm=gui | Out-Null

Write-Host "VM '$VmName' is booting. Windows install runs hands-free; expect ~25 min." -ForegroundColor Green
Write-Host ""
Write-Host "Sign-in once the desktop appears:" -ForegroundColor Yellow
Write-Host "  user:     $Username"
Write-Host "  password: $Password"
Write-Host ""

# ----------------------------------------------------------------------------
# 4) Wait for Guest Additions, then snapshot
# ----------------------------------------------------------------------------

if ($NoSnapshot) {
  Write-Host "-NoSnapshot supplied; skipping snapshot. Take one manually with:" -ForegroundColor DarkGray
  Write-Host "  & '$VBoxManage' snapshot $VmName take 'clean' --description 'Fresh Win11'"
  return
}

Write-Host "Waiting for Windows install to finish (polling Guest Additions every 30 s, 45-min ceiling)..."
$timeout = [TimeSpan]::FromMinutes(45)
$start   = Get-Date
$ready   = $false

while (((Get-Date) - $start) -lt $timeout) {
  # Guest Additions populates this property only after the GA service is up,
  # which only happens after Windows finishes installing AND first-login OOBE
  # completes. Combined: a reliable "install is done" signal.
  $prop = & $VBoxManage guestproperty get $VmName "/VirtualBox/GuestAdd/Version" 2>$null
  if ($prop -and $prop -notmatch 'No value set') {
    $ready = $true
    break
  }
  Start-Sleep -Seconds 30
}

if (-not $ready) {
  Write-Warning "Windows install did not finish within 45 min. Check the VM window."
  Write-Warning "If it's still installing, wait for it and snapshot manually:"
  Write-Warning "  & '$VBoxManage' snapshot $VmName take 'clean' --description 'Fresh Win11'"
  return
}

# Settle: GA reports up but background services may still be churning.
Start-Sleep -Seconds 30

Write-Host "Taking 'clean' snapshot..." -ForegroundColor Cyan
& $VBoxManage snapshot $VmName take "clean" --description "Fresh Win11 install — no Node, no Claude, no YouCoded" | Out-Null

Write-Host ""
Write-Host "Done. Test workflow:" -ForegroundColor Green
Write-Host "  Revert to clean state: & '$VBoxManage' snapshot $VmName restore clean"
Write-Host "  Boot:                  & '$VBoxManage' startvm $VmName --type gui"
Write-Host "  Power off:             & '$VBoxManage' controlvm $VmName poweroff"
