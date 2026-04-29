# Local Test VM (Windows 11)

A clean, snapshot-revertible Windows 11 VM is the highest-fidelity way to validate the YouCoded first-run installer. Real failure modes — `spawn EINVAL`, missing Node, fresh-PATH propagation, blocked execution policy, UAC interactions — only surface on a machine that's never seen Node, npm, or Claude Code. This doc shows you how to spin one up.

The supported host is Windows 11 (Home or Pro). Hyper-V Manager is not required (good — Home doesn't have it).

## Pre-flight: check for hypervisor conflict

**Before you do anything else**, run this and read the result:

```powershell
(Get-CimInstance Win32_ComputerSystem).HypervisorPresent
```

If it returns **`False`** — great, skip ahead to "One-time setup."

If it returns **`True`** — you're hitting the same wall the 2026-04-29 investigation captured. Something on your machine has the Microsoft hypervisor pinned at boot. Almost always **WSL2** (it auto-enables `VirtualMachinePlatform`, which keeps the hypervisor resident even when no Linux is running). Other culprits: Docker Desktop, Windows Sandbox, Android Studio's emulator, the Windows Subsystem for Android.

VirtualBox 7+ in this state falls back to "Hyper-V Platform" mode — a slow shim where every CPU instruction the guest runs goes through Microsoft's APIs instead of native VT-x/AMD-V. **Disk-heavy phases like Win11's install.wim extraction run 5–10x slower.** What should be a 25-minute Windows install becomes 1–3 hours, with the display appearing frozen for many minutes at a time. This is the dominant experience on most modern dev machines.

Two ways to deal with it:

- **(A) Free up the hypervisor for VBox.** Run `bcdedit /set hypervisorlaunchtype off` from an elevated PowerShell, reboot, do your testing, then `bcdedit /set hypervisorlaunchtype auto` and reboot again to get WSL2/Docker back. Two reboots; native-speed VBox in between. Best path if you'll use the VM regularly.
- **(B) Skip the VM, test on a real clean Windows machine.** A friend's, coworker's, or a cloud Win11 instance. Strictly higher signal for installer testing — a clean physical machine is exactly what real users have. Often the right answer for a single fix.

Full context and trade-offs in `docs/superpowers/investigations/2026-04-29-vbox-hyperv-conflict.md`.

## When to use this

- Before merging changes to `desktop/src/main/prerequisite-installer.ts` or `desktop/src/main/first-run.ts`
- Before cutting a release (smoke test the installer end-to-end)
- When debugging a user report that says "first install didn't work"
- Anytime you suspect the dev environment masks a problem the user would hit

The VM is throwaway by design. The "clean" snapshot is your reset button — revert between runs and you get a deterministic clean state in ~10 seconds.

## One-time setup

### 1. Install VirtualBox

```powershell
winget install Oracle.VirtualBox --accept-package-agreements --accept-source-agreements
```

Approve the UAC prompt. Verify with `& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" --version`. You need 7.1+ for working TPM emulation (Win11 setup requires TPM 2.0).

### 2. Download the Windows 11 ISO

Microsoft distributes the Win11 ISO free with no registration. The download links are time-limited per-session signed URLs, so this part can't be scripted without a third-party tool — do it once by hand:

1. Go to https://www.microsoft.com/en-us/software-download/windows11
2. Under **"Download Windows 11 Disk Image (ISO) for x64 devices"** → choose **"Windows 11 (multi-edition ISO)"** → click **Download Now**
3. Pick a language → **English (United States)** → click **Confirm**
4. Click **64-bit Download**
5. Save as `C:\Users\<you>\Downloads\Win11.iso` (~6 GB)

Without activation, Windows runs indefinitely with a small desktop watermark and a few personalization features locked. Fine for a test VM.

### 3. Run the setup script

```powershell
pwsh scripts/setup-test-vm.ps1 -IsoPath C:\Users\you\Downloads\Win11.iso
```

The script:

- Creates a VM named `YouCoded-Win11-Test` (4 GB RAM, 4 vCPUs, 64 GB disk)
- Configures EFI + TPM 2.0 + Secure Boot (Win11 setup hard-requires all three)
- Configures `VBoxManage unattended install` so Windows installs hands-free, including Microsoft-account OOBE bypass
- Boots the VM and waits up to 45 min for the install to complete (polling Guest Additions every 30 s as the "done" signal)
- Takes a snapshot named `clean` once the install is finished

Total wall-clock: ~25 min. The VM window opens immediately so you can watch progress, but no clicks are needed during install.

Default credentials inside the VM (script defaults — change with `-Username` / `-Password` if you re-run):

| Field    | Value         |
|----------|---------------|
| User     | `tester`      |
| Password | `TestVM!2026` |

## Test workflow

Once the `clean` snapshot exists, every test cycle looks like:

```powershell
$vm = "YouCoded-Win11-Test"
$VBox = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"

# 1. Revert to the clean baseline (~10 s)
& $VBox snapshot $vm restore clean

# 2. Boot
& $VBox startvm $vm --type gui

# 3. Inside the VM: download or copy the YouCoded installer, run it, observe.
#    See "Getting the installer into the VM" below.

# 4. When done, power off
& $VBox controlvm $vm poweroff
```

Every revert puts you back at exactly the same OS state — no carryover from prior runs.

## Getting the installer into the VM

Two practical options:

**A. GitHub Release (preferred for CI-built installers).** Open Edge inside the VM, browse to the GitHub release page (or a draft release URL), download `YouCoded Setup x.y.z.exe`, run it. Closest to what a real user does.

**B. VirtualBox shared folder (preferred for locally-built debug builds).** Add a shared folder in the VM settings pointing at e.g. `youcoded\desktop\release\`. In the VM, mount it as a network drive, copy the `.exe` to the desktop, run.

```powershell
& $VBox sharedfolder add $vm --name "release" `
    --hostpath (Resolve-Path .\youcoded\.worktrees\native-installer\desktop\release).Path `
    --automount
```

After the next boot, the share appears at `\\VBOXSVR\release` inside Windows.

## Manual VBoxManage walkthrough (fallback)

Use this if you don't want to run the script — e.g. for ad-hoc tweaks, debugging the script itself, or learning how the pieces fit. The script automates exactly these commands.

```powershell
$VBox = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$vm   = "YouCoded-Win11-Test"
$iso  = "C:\Users\you\Downloads\Win11.iso"

# Create + register the VM
& $VBox createvm --name $vm --ostype "Windows11_64" --register

# Configure system
& $VBox modifyvm $vm `
    --memory 4096 --cpus 4 `
    --firmware efi --tpm-type 2.0 `
    --graphicscontroller vboxsvga --vram 128 `
    --usbohci on --usbxhci on `
    --audio-driver default --nic1 nat

# Secure Boot setup is a four-step dance in VBox 7.2+
& $VBox modifynvram $vm inituefivarstore
& $VBox modifynvram $vm enrollmssignatures
& $VBox modifynvram $vm enrollorclpk
& $VBox modifynvram $vm secureboot --enable

# Storage
$disk = "$env:USERPROFILE\VirtualBox VMs\$vm\$vm.vdi"
& $VBox createmedium disk --filename $disk --size 65536 --variant Standard
& $VBox storagectl     $vm --name "SATA" --add sata --controller IntelAhci --portcount 2 --bootable on
& $VBox storageattach  $vm --storagectl "SATA" --port 0 --device 0 --type hdd --medium $disk
& $VBox storageattach  $vm --storagectl "SATA" --port 1 --device 0 --type dvddrive --medium $iso

# Unattended install + boot
& $VBox unattended install $vm `
    --iso=$iso `
    --user=tester --user-password='TestVM!2026' `
    --full-user-name=tester `
    --locale=en_US --country=US `
    --time-zone="Pacific Standard Time" `
    --hostname="youcoded-test.local" `
    --install-additions `
    --start-vm=gui

# Wait ~25 min, then take the snapshot once Guest Additions is reachable
& $VBox guestproperty get $vm "/VirtualBox/GuestAdd/Version"   # poll until non-empty
& $VBox snapshot $vm take "clean" --description "Fresh Win11 — no Node, no Claude, no YouCoded"
```

## Troubleshooting

**Windows install hangs at "Press any key to boot from CD"** — VirtualBox sometimes shows that prompt despite the unattended install config. Click into the VM window and press a key. The install proceeds normally afterward.

**Win11 setup says "This PC can't run Windows 11"** — TPM or Secure Boot isn't on. Check `& $VBox showvminfo $vm | Select-String -Pattern 'TPM|Secure'`. Should report `TPM Type: 2.0` and `Secure Boot: enabled`. If not, the script's `modifynvram initsecureboot` step likely failed silently. Re-run after `& $VBox unregistervm $vm --delete`.

**`unattended install` errors with "VM is currently running"** — the script's `--start-vm=gui` arg auto-boots after install config. If you also try to start it again manually, you'll get this. Just wait for the install.

**Guest Additions never reports a version** — happens if Win11 setup failed silently (sometimes when Secure Boot is misconfigured). Open the VM window — if Windows isn't running, you'll see the BSOD or the setup error. Tear down and rebuild.

**VirtualBox runs slowly / VM appears frozen mid-install** — see "Pre-flight: check for hypervisor conflict" at the top of this doc. Almost certainly the Hyper-V Platform fallback. Empirically: 5–10x slowdown, mid-install screens appear frozen for many minutes at a time, mouse capture stops responding. Not a true crash; just unusably slow. Use option (A) bcdedit toggle or (B) test on a real clean machine.

**Test cycle leaves crud behind** — that's the point of `restore clean`. Revert before every run and you're back to a deterministic state. Don't take additional snapshots on top unless you intentionally want to keep state between runs.

## What's installed inside the snapshot

By design, the `clean` snapshot has only:

- Windows 11 (multi-edition; activates as "unactivated" — fine for testing)
- VirtualBox Guest Additions (drivers + clipboard sync)
- The `tester` user account

It does NOT have Node, npm, Git, Claude Code, or YouCoded. That's intentional — the whole point is to exercise YouCoded's first-run installer against the same blank slate a real user has.

## See also

- `scripts/setup-test-vm.ps1` — the script that produces the snapshot
- `docs/superpowers/investigations/2026-04-28-friend-install-einval.md` — the original investigation that motivated having a test VM (if/when written)
- `youcoded/desktop/src/main/prerequisite-installer.ts` — the code under test
