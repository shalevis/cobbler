# Offline Cobbler (Ubuntu) — PXE provisioning with usbguard + FreeIPA + users

A self-contained kit to run **Cobbler on an offline Ubuntu server** and PXE-deploy
**Ubuntu 22.04.1** and **Noble (24.04)** with a full hardening/onboarding post-install:

- **usbguard** installed with rules that allow **only keyboards + mice** (HID) and hubs
- machine **enrolled into FreeIPA** (domain join, per-host one-time password)
- an **`ansible` user** with SSH-key login + passwordless sudo (for playbooks)
- a **local admin user** with root/sudo as a **break-glass** login (works with no network);
  its password is **prompted during the offline install** and stored only as a hash

> Heads-up (important): Cobbler is **not packaged for Ubuntu** at all. This kit
> installs it from a **pip wheelhouse + apt dependency .debs**, which works but is
> more involved than the RHEL path. Ubuntu + subiquity + PXE + air-gap has sharp
> edges — see "Known risks" below.

## Layout
```
cobbler/
├─ config/cobbler.env              # EDIT FIRST: IP, releases, IPA, users
├─ 1-download-offline-bundle.sh    # connected Ubuntu: gather everything -> bundle
├─ 2-install-offline.sh            # offline: install Cobbler, prompt admin pw, gen ansible key
├─ 3-configure-cobbler.sh          # offline: import ISOs, render autoinstall, wire profiles
├─ scripts/new-host.sh             # per-machine: IPA OTP + per-host autoinstall (+ MAC bind)
├─ autoinstall/
│  ├─ ubuntu.user-data.tmpl        # the post-install (usbguard/IPA/ansible/local-admin)
│  └─ meta-data.tmpl               # NoCloud meta-data
└─ verify-bundle.sh                # sanity-check the bundle before transfer
```

## Prerequisites
- **Connected machine:** Ubuntu 22.04/24.04 with `sudo`, `debootstrap`, `dpkg-dev`,
  `python3-pip`, `curl`/`wget`. Reaches `archive.ubuntu.com` + `releases.ubuntu.com`.
- **Offline server:** Ubuntu 22.04/24.04. Needs nothing pre-installed except what the
  bundle brings (Cobbler deps are included).

## Flow

### 1. Configure
Edit [config/cobbler.env](config/cobbler.env): `COBBLER_SERVER_IP`, the two ISO URLs
(verify the Noble point-release filename), FreeIPA domain/realm/server, user names.

### 2. Download everything (connected machine)
```bash
cd cobbler
chmod +x *.sh scripts/*.sh
sudo ./1-download-offline-bundle.sh     # debootstrap needs sudo
./verify-bundle.sh                       # confirm counts look right
# -> cobbler-offline-bundle.tar.gz
```

### 3. Transfer + install (offline server)
```bash
mkdir cobbler && tar -xzf cobbler-offline-bundle.tar.gz -C cobbler
cd cobbler
sudo ./2-install-offline.sh              # prompts for the LOCAL ADMIN password
```

### 4. Configure (offline server)
```bash
sudo ./3-configure-cobbler.sh            # imports ISOs, renders autoinstall, syncs
```

### 5. Point your existing DHCP at Cobbler
Your network already has DHCP/DNS, so Cobbler does **not** manage them. Add to your DHCP:
```
next-server <COBBLER_SERVER_IP>
filename "pxelinux.0"        # BIOS
filename "grub/grubx64.efi"  # UEFI
```

### 6. Deploy a machine
```bash
kinit admin
./scripts/new-host.sh web01.example.com ubuntu2404 aa:bb:cc:dd:ee:ff
# -> creates the IPA OTP, a per-host autoinstall, and binds it to the MAC.
# PXE-boot the machine: it installs Ubuntu, locks USB to kbd/mouse, joins FreeIPA,
# and creates the ansible + local-admin users.
```

## How the post-install runs
Ubuntu uses **subiquity autoinstall** (not preseed/kickstart). The logic lives in
[autoinstall/ubuntu.user-data.tmpl](autoinstall/ubuntu.user-data.tmpl):
- `late-commands` run **during install** (target mounted at `/target`).
- usbguard, FreeIPA client, and the users are all configured there, pulling packages
  from the **local .deb repo** served by Cobbler (`file:/opt/localdebs`) — fully offline.

## Controlling distro & versions
Everything is driven by [config/cobbler.env](config/cobbler.env): change the ISO URLs
and codenames to add/replace releases, and `TARGET_CODENAMES` so the matching
post-install packages get gathered per release. Re-run step 2 to rebuild the bundle.

## Known risks (Ubuntu + Cobbler + offline)
1. **Cobbler pip install** on Ubuntu can need manual Apache/gunicorn/systemd wiring;
   `2-install-offline.sh` does the common steps but review `cobbler check` output.
2. **PXE-booting the live-server** relies on `url=<iso> autoinstall ds=nocloud-net`
   kernel args; confirm the profile picked up the kernel/initrd from the ISO import.
3. **Per-release packages** are gathered with `debootstrap`, so the connected machine
   must reach `archive.ubuntu.com` for both `jammy` and `noble`.
4. **usbguard** blocks USB storage/NICs by design — make sure the console keyboard is
   a normal HID device (it is allowed by the rules).

If any step fails offline, capture the failing command's output and iterate on that
single script — the autoinstall content itself is reusable regardless of orchestrator.
