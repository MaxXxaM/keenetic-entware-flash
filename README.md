# Keenetic Entware Flash

**Prepare a USB flash drive for Entware on Keenetic routers — with a single command.**

[Русский](README.ru.md) | [中文](README.zh.md)

## Quick Start

Insert a USB flash drive and run:

```bash
git clone https://github.com/MaxXxaM/keenetic-entware-flash.git
cd keenetic-entware-flash
sudo ./run.sh
```

The script will show available USB devices:

```
============================================
 Select USB device
============================================

  1) /dev/disk4 — USB DISK 2.0 (15.5 GB)
  2) /dev/disk6 — MassStorageClass (64.9 GB)

  0) Cancel

Select device [1-2]:
```

The Docker image is pulled automatically. If the registry is unavailable, it builds locally.

## Requirements

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (macOS / Linux)

## Supported Models

| Architecture | Models | `ARCH` |
|---|---|---|
| **MIPSEL** (default) | Keenetic Ultra, Giga, Viva, Extra, Air, City, Omni, Lite, Start, KN-1010–KN-2310 | `mipsel` |
| **MIPS** | KN-2410, KN-2510, KN-2010, KN-3610 | `mips` |
| **AARCH64** | Keenetic Peak, Titan, Hopper, KN-2710, KN-2810, KN-2910, KN-3510 | `aarch64` |

## Parameters

| Variable | Description | Default |
|---|---|---|
| `ARCH` | Architecture: `mipsel`, `mips`, `aarch64` | `mipsel` |
| `SWAP_SIZE` | Swap partition size in MB | `1024` |
| `PARTITION_TABLE` | Partition table: `mbr` or `gpt` | `mbr` |
| `SKIP_ENTWARE` | Skip Entware installer (`1` to skip) | `0` |

## Examples

```bash
# Interactive — pick your USB from a list
sudo ./run.sh

# Specify device directly
sudo ./run.sh /dev/disk4          # macOS
sudo ./run.sh /dev/sdb            # Linux

# AArch64 (Peak, Titan, Hopper) with GPT and 512MB swap
sudo ARCH=aarch64 SWAP_SIZE=512 PARTITION_TABLE=gpt ./run.sh

# Partition only, no Entware
sudo SKIP_ENTWARE=1 ./run.sh
```

## Direct Docker Usage (Linux)

```bash
docker run --rm -it --privileged \
  -v /dev/sdb:/dev/target \
  ghcr.io/maxxxam/keenetic-entware-flash:main
```

## How It Works

1. `run.sh` lists USB devices and prompts you to select one
2. Pulls the pre-built Docker image (or builds locally if unavailable)
3. On macOS — creates a temporary disk image; on Linux — passes the device directly
4. The container creates an MBR/GPT partition table:
   - **Partition 1** — SWAP
   - **Partition 2** — EXT4 (label: OPKG) with Entware installer
5. On macOS — writes the image to USB (skipping empty blocks for speed)
6. Done — insert the drive into your router

## After Flashing

### Step 1: Install OPKG

1. Insert the USB drive into the Keenetic router
2. Open the router web UI (usually http://192.168.1.1)
3. Go to **Management** → **General Settings** → **Updates and Component Options**
4. Find and install **OPKG Package Manager**:
   > Allows installing OpenWRT packages to extend the router's functionality.
   > Community support is available at [forum.keenetic.ru](https://forum.keenetic.ru). Keenetic technical support does not cover these topics.
5. The router will reboot and start installing Entware automatically

You can monitor the installation progress in the router log:
**Diagnostics** → **General** → **Log** (`/diagnostics/general/log`)

When finished, you will see:
```
[5/5] Installation of "Entware" package system is complete!
Don't forget to change the password and port number!
```

### Step 2: Change Password and Configure SSH

After installation, Entware provides its own SSH access (Dropbear):
- **Login:** `root`
- **Password:** `keenetic`
- **Port:** `222`

Connect and change the default password immediately:

```bash
ssh root@192.168.1.1 -p 222

passwd root
# Changing password for root
# New password:
# Retype password:
# passwd: password for root changed by root
```

Update the package list and installed packages:

```bash
opkg update
opkg upgrade
```

#### Configure SSH Ports

After installing Entware, you will have two SSH services. It's recommended to move the built-in Keenetic SSH to a different port to avoid conflicts:

**Option A: Via web UI**
1. Open router web UI → **Management** → **General Settings**
2. Find **Command Line** or **Remote Access** section
3. Change SSH port from `22` to `2222`

**Option B: Via Keenetic CLI**
```bash
ssh admin@192.168.1.1 -p 22

(config)> ip ssh
(config-ssh)> port 2222
(config-ssh)> exit
(config)> system configuration save
```

After configuration, you will have two separate SSH connections:

```bash
# Keenetic CLI (router management)
ssh admin@192.168.1.1 -p 2222

# Entware shell (full Linux environment)
ssh root@192.168.1.1 -p 22
```

> Entware SSH port can be changed in `/opt/etc/config/dropbear.conf` if needed.

### Step 3: Enable SWAP (Recommended)

Swap significantly improves stability when running multiple Entware packages. Connect to Entware via SSH and run:

```bash
# Enable swap
swapon /dev/sda1

# Verify swap is active
free
```

To make swap persistent across reboots, create a startup script:

```bash
cat > /opt/etc/init.d/S01swap <<'SWAP'
#!/bin/sh
case "$1" in
  start)
    swapon /dev/sda1
    ;;
  stop)
    swapoff /dev/sda1
    ;;
esac
SWAP
chmod +x /opt/etc/init.d/S01swap
```

### Step 4: Verify

```bash
# Check Entware is working
opkg update
opkg list-installed

# Check swap is active
free
```

More info: [help.keenetic.com](https://help.keenetic.com/hc/en/articles/360021888880)

## Local Build

```bash
# Standard build
docker build --platform linux/amd64 -t keenetic-entware-flash .

# Build in Russia (with accessible mirrors)
docker build --platform linux/amd64 \
  --build-arg BASE_IMAGE=cr.yandex/mirror/ubuntu:22.04 \
  --build-arg APT_MIRROR=http://mirror.yandex.ru \
  -t keenetic-entware-flash .
```

## Troubleshooting

**"No external USB devices found"** — insert a USB flash drive and try again.

**"Permission denied"** — run with `sudo`:
```bash
sudo ./run.sh
```

**macOS: "Resource busy"** — the script unmounts automatically, but if it fails:
```bash
diskutil unmountDisk /dev/diskN
```

**Docker Hub / GHCR unavailable** — the script will automatically build the image locally using accessible mirrors.

**Entware installer failed to download** — the drive is still ready. The installer is embedded in the Docker image as a fallback. If that also fails, the router will download Entware itself when OPKG is enabled.

## License

MIT — see [LICENSE](LICENSE).
