# Keenetic Entware Flash

**Docker-утилита для подготовки USB-флешек под Entware на Keenetic роутерах.**

Docker utility for preparing USB flash drives for Entware on Keenetic routers.

---

## Проблема / Problem

Владельцы Keenetic роутеров вынуждены вручную форматировать USB-флешки (swap + ext4), скачивать правильный Entware installer — а на macOS нет нативной поддержки ext4. Эта утилита решает всё одной командой через Docker.

Keenetic router owners need to manually format USB drives (swap + ext4) and download the correct Entware installer — and macOS has no native ext4 support. This utility solves everything with a single Docker command.

## Quick Start

### 1. Find your USB drive

**macOS:**
```bash
diskutil list
# Find your USB drive (e.g. /dev/disk4)
diskutil unmountDisk /dev/disk4
```

**Linux:**
```bash
lsblk
# Find your USB drive (e.g. /dev/sdb)
sudo umount /dev/sdb*
```

### 2. Run

```bash
docker run --rm -it --privileged \
  -v /dev/disk4:/dev/target \
  ghcr.io/maxxxam/keenetic-entware-flash
```

That's it! The flash drive is ready for your Keenetic router.

## Supported Models / Поддерживаемые модели

| Architecture | Models | Env value |
|---|---|---|
| **MIPSEL** | Keenetic Ultra, Giga, Viva, Extra, Air, City, Omni, Lite, Start, KN-1010, KN-1110, KN-1210, KN-1310, KN-1410, KN-1510, KN-1610, KN-1710, KN-1810, KN-1910, KN-2110, KN-2310 | `ARCH=mipsel` (default) |
| **MIPS** | KN-2410, KN-2510, KN-2010, KN-3610 | `ARCH=mips` |
| **AARCH64** | Keenetic Peak, Titan, Hopper, KN-2710, KN-2810, KN-2910, KN-3510 | `ARCH=aarch64` |

## Parameters / Параметры

| Variable | Description | Default |
|---|---|---|
| `ARCH` | Entware architecture: `mipsel`, `mips`, `aarch64` | `mipsel` |
| `SWAP_SIZE` | Swap partition size in MB | `1024` |
| `PARTITION_TABLE` | Partition table type: `mbr` or `gpt` | `mbr` |
| `SKIP_ENTWARE` | Skip Entware download (`1` to skip) | `0` |
| `FORCE` | Skip confirmation prompt (`1` to skip) | `0` |

## Examples / Примеры

```bash
# Default: MIPSEL, 1GB swap, MBR
docker run --rm -it --privileged \
  -v /dev/sdb:/dev/target \
  ghcr.io/maxxxam/keenetic-entware-flash

# AArch64 (Peak, Titan, Hopper) with GPT and 512MB swap
docker run --rm -it --privileged \
  -e ARCH=aarch64 \
  -e SWAP_SIZE=512 \
  -e PARTITION_TABLE=gpt \
  -v /dev/sdb:/dev/target \
  ghcr.io/maxxxam/keenetic-entware-flash

# Format only (no Entware download)
docker run --rm -it --privileged \
  -e SKIP_ENTWARE=1 \
  -v /dev/sdb:/dev/target \
  ghcr.io/maxxxam/keenetic-entware-flash

# Non-interactive (CI/scripts)
docker run --rm --privileged \
  -e FORCE=1 \
  -v /dev/sdb:/dev/target \
  ghcr.io/maxxxam/keenetic-entware-flash
```

## Building locally / Локальная сборка

```bash
docker build -t keenetic-entware-flash .
docker run --rm -it --privileged \
  -v /dev/diskN:/dev/target \
  keenetic-entware-flash
```

## Installing Docker / Установка Docker

If you don't have Docker installed:

```bash
bash install-docker.sh
```

The script auto-detects your OS (macOS, Linux, WSL) and installs Docker.

## How it works / Как это работает

1. Validates that `/dev/target` is a block device
2. Shows disk info and asks for confirmation
3. Creates partition table (MBR or GPT)
4. Creates swap partition (1 GB by default)
5. Creates ext4 partition (remaining space, without `metadata_csum` for KeeneticOS compatibility)
6. Downloads Entware installer to `/install/` on the ext4 partition
7. Done — insert the drive into your router

## Troubleshooting

### "Device /dev/target not found"
Make sure you're passing the correct device with `-v`:
```bash
# macOS
diskutil list            # find your disk
diskutil unmountDisk /dev/diskN
docker run ... -v /dev/diskN:/dev/target ...

# Linux
lsblk                   # find your disk
docker run ... -v /dev/sdX:/dev/target ...
```

### "Permission denied" or partitioning fails
The `--privileged` flag is required for direct disk access:
```bash
docker run --rm -it --privileged -v /dev/sdX:/dev/target keenatic-flash
```

### macOS: "Resource busy"
Unmount the disk first:
```bash
diskutil unmountDisk /dev/diskN
```

### Entware download fails
If the download fails due to network issues, the drive is still properly formatted. You can manually download the installer from [bin.entware.net](https://bin.entware.net/) and place it in the `install/` directory on the ext4 partition.

## License

MIT — see [LICENSE](LICENSE).
