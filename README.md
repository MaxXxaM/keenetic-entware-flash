# Keenetic Entware Flash

**Подготовка USB-флешки для Entware на Keenetic роутерах — одной командой.**

Prepare a USB flash drive for Entware on Keenetic routers — with a single command.

## Quick Start

Вставьте USB-флешку и выполните:

```bash
git clone https://github.com/MaxXxaM/keenetic-entware-flash.git
cd keenetic-entware-flash
sudo ./run.sh
```

Скрипт сам предложит выбрать USB-устройство:

```
============================================
 Select USB device
============================================

  1) /dev/disk4 — USB DISK 2.0 (15.5 GB)
  2) /dev/disk6 — MassStorageClass (64.9 GB)

  0) Cancel

Select device [1-2]:
```

Docker-образ скачается автоматически. Если pull недоступен — соберётся локально.

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
# Interactive — выберите флешку из списка
sudo ./run.sh

# Указать устройство напрямую
sudo ./run.sh /dev/disk4          # macOS
sudo ./run.sh /dev/sdb            # Linux

# AArch64 (Peak, Titan, Hopper) с GPT и 512MB swap
sudo ARCH=aarch64 SWAP_SIZE=512 PARTITION_TABLE=gpt ./run.sh

# Только разметка, без Entware
sudo SKIP_ENTWARE=1 ./run.sh
```

## Direct Docker Usage (Linux)

```bash
docker run --rm -it --privileged \
  -v /dev/sdb:/dev/target \
  ghcr.io/maxxxam/keenetic-entware-flash:main
```

## How It Works

1. `run.sh` показывает список USB-устройств и предлагает выбрать
2. Скачивает готовый Docker-образ (или собирает локально при недоступности)
3. На macOS создаёт временный образ диска, на Linux пробрасывает устройство напрямую
4. Контейнер создаёт MBR/GPT таблицу разделов:
   - **Partition 1** — SWAP
   - **Partition 2** — EXT4 (label: OPKG) с Entware installer
5. На macOS записывает образ на флешку (пропуская пустые блоки для скорости)
6. Готово — вставляйте флешку в роутер

## After Flashing

1. Вставьте USB в Keenetic роутер
2. Откройте веб-интерфейс роутера → **Управление** → **Общие настройки**
3. Установите пакет **Среда OPKG**
4. Роутер обнаружит флешку и настроит Entware автоматически

Подробнее: [help.keenetic.com](https://help.keenetic.com/hc/ru/articles/360021888880)

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

**"No external USB devices found"** — вставьте USB-флешку и попробуйте снова.

**"Permission denied"** — запускайте с `sudo`:
```bash
sudo ./run.sh
```

**macOS: "Resource busy"** — скрипт размонтирует автоматически, но если не получилось:
```bash
diskutil unmountDisk /dev/diskN
```

**Docker Hub / GHCR недоступен** — скрипт автоматически соберёт образ локально через доступные зеркала.

**Entware installer не скачался** — флешка всё равно готова к использованию. Инсталлер зашит в Docker-образ как fallback. Если и fallback не сработал — роутер скачает Entware сам при включении OPKG.

## License

MIT — see [LICENSE](LICENSE).
