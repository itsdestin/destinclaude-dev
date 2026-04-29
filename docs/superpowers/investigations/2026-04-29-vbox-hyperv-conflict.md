# VirtualBox + Hyper-V conflict on Windows 11 Home (test VM provisioning)

**Date:** 2026-04-29
**Context:** We needed a clean Windows 11 VM to validate the YouCoded installer's native-installer migration (`fix/native-installer` branch) before shipping. The plan was: VirtualBox + Microsoft's free Win11 ISO + unattended install, snapshot when done, revert between test runs.
**Outcome:** VM provisioning works mechanically but is unusably slow on this machine. Documented findings, fixed the script's silent failures, captured a path-forward decision.

## What we built

- `scripts/setup-test-vm.ps1` — single-command provisioner. Takes `-IsoPath`, creates the VM with TPM 2.0 + Secure Boot + EFI, runs `unattended install` so Windows installs hands-free, polls Guest Additions to detect "install done," takes a `clean` snapshot. Idempotent (refuses to overwrite an existing VM).
- `docs/local-dev-vm.md` — full setup doc: prerequisites, ISO download, running the script, manual `VBoxManage` walkthrough, test workflow, troubleshooting.

Both shipped.

## What we hit

### 1. Microsoft discontinued the pre-built dev VM (resolved)

Original plan was the free Win11 dev VM image Microsoft used to publish at `developer.microsoft.com/.../virtual-machines/`. That URL now 301-redirects to a generic dev-tools overview — they killed it. Replacement: download the multi-edition Win11 ISO from `microsoft.com/software-download/windows11` and use VBox's unattended install. Adds ~25 min vs. the OVA import path but is free, legal, and unactivated-runs-forever.

### 2. ISO download form is gated behind session-bound URLs (worked around)

Microsoft's ISO download is a JS form that hands out a 24h-signed URL — can't curl a static link. We used **Fido v1.70** (open-source PowerShell script bundled with Rufus) to hit the same Microsoft API the website uses. Got a real `software.download.prss.microsoft.com` URL, BITS-transferred to disk. Worked, but: Microsoft rate-limits Fido — the second call within a short window returns "anonymous/location hiding tech not allowed." Save the URL from the first call and use it directly within ~24h.

### 3. VirtualBox 7.2 changed flag syntax (resolved)

Two flags from older docs no longer work in VBox 7.2.8:

- **Removed:** `modifyvm --secure-boot on` (silently ignored — exit 0, no flag persisted)
- **Renamed:** `modifynvram <vm> initsecureboot` → must be a four-step sequence:
  ```
  modifynvram <vm> inituefivarstore
  modifynvram <vm> enrollmssignatures
  modifynvram <vm> enrollorclpk
  modifynvram <vm> secureboot --enable
  ```
- **Renamed:** `unattended install --password=` → `--user-password=`. Old form fails with `VERR_UNRESOLVED_ERROR`.

Caught these the hard way — script printed success, VM aborted at first boot. **Lesson:** native-command exit codes don't trip PowerShell's `$ErrorActionPreference = 'Stop'`. Add `if ($LASTEXITCODE -ne 0) { throw }` after every `VBoxManage` call if you want fail-fast. The current script swallows errors via `Out-Null`; that's a debt to repay if the script is ever rerun headless.

### 4. Hyper-V/VBox conflict on Windows 11 Home (UNRESOLVED — root issue)

The actual blocker. Symptoms:

- Windows install screen reaches "Installing Windows 11 — 10% complete," then appears frozen
- Mouse cursor doesn't move when captured into the VM
- Pixel-identical screenshots ten seconds apart
- VBox process at ~3300 CPU-seconds, 4 GB RAM, "Responding"

Looks like a hard hang. Actually a **5–10x slowdown** under VBox's "Hyper-V Platform" fallback mode.

**Root cause:** `Get-CimInstance Win32_ComputerSystem | Select HypervisorPresent` returns `True`. On Win11 Home this is almost certainly **WSL2** (WSL2 enables `VirtualMachinePlatform`, which keeps Hyper-V resident at boot whether or not any WSL distro is running). VBox 7+ detects the resident hypervisor and falls back from native VT-x/AMD-V to Microsoft's Hyper-V Platform APIs. Disk-heavy phases (Windows install's `install.wim` extraction) are particularly punishing — what should be a 25-min install runs 1–3 hours, with the display appearing frozen for many minutes at a time.

**This is the dominant experience for anyone with WSL2 / Docker Desktop / Windows Sandbox enabled.** Not an edge case.

## Three paths forward

| Option | Cost | When it makes sense |
|--------|------|---------------------|
| **A. Wait it out** | 1–3 hr per install instead of 25 min, then snapshot/revert works (slow but functional) | Never — too painful for any iteration loop |
| **B. Disable hypervisor + reboot** (`bcdedit /set hypervisorlaunchtype off`, reboot, do testing, `auto`, reboot) | Two reboots; loses WSL2 / Docker / Sandbox / Android emulator until restored | Long-term test rig you'll use weekly+ |
| **C. Skip VM, use a real clean machine** (e.g. friend's, or coworker's) | One round-trip per test; depends on availability | Validating against the *actual* failure mode we're fixing — strictly higher signal than a generic VM |

For the EINVAL fix specifically, **(C) is the highest-signal test** — your friend's machine is the literal repro case. The VM was always a generic stand-in. We took (C) for the immediate fix.

## Decisions

1. **Keep the VM tooling we built.** Script and doc ship as-is. Future devs may want it; we don't rip it out because *we* couldn't use it today.
2. **Update `docs/local-dev-vm.md` to lead with the Hyper-V warning.** It was a footnote; it should be a prerequisite check.
3. **Don't ship a pre-built VM image.** Considered. Killed: Microsoft EULA disallows redistributing Windows in third-party projects, GitHub LFS bandwidth would be untenable, monthly Windows updates would force re-uploads of 6+ GB.
4. **Future:** if (B) becomes worth it (we're shipping this kind of fix often enough that "test on clean Win11" is a recurring need), add a `scripts/disable-hypervisor-for-vbox.ps1` helper that runs the bcdedit toggle and prompts for the reboot.

## Open follow-ups

- Add `if ($LASTEXITCODE -ne 0) { throw }` after each VBoxManage call in `setup-test-vm.ps1` so silent failures surface immediately
- Pre-flight check in the script: detect `HypervisorPresent` and warn before a 1+ hour install attempt
- Document the Fido double-call rate-limit in `docs/local-dev-vm.md` (currently buried in this investigation only)
