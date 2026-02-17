# Keenetic Entware Flash

**Подготовка USB-флешки для Entware на Keenetic роутерах — одной командой.**

[English](README.md) | [中文](README.zh.md)

## Быстрый старт

Вставьте USB-флешку и выполните:

```bash
git clone https://github.com/MaxXxaM/keenetic-entware-flash.git
cd keenetic-entware-flash
sudo ./run.sh
```

Скрипт покажет доступные USB-устройства:

```
============================================
 Select USB device
============================================

  1) /dev/disk4 — USB DISK 2.0 (15.5 GB)
  2) /dev/disk6 — MassStorageClass (64.9 GB)

  0) Cancel

Select device [1-2]:
```

Docker-образ скачивается автоматически. Если реестр недоступен — собирается локально.

## Требования

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (macOS / Linux)

## Поддерживаемые модели

| Архитектура | Модели | `ARCH` |
|---|---|---|
| **MIPSEL** (по умолчанию) | Keenetic Ultra, Giga, Viva, Extra, Air, City, Omni, Lite, Start, KN-1010–KN-2310 | `mipsel` |
| **MIPS** | KN-2410, KN-2510, KN-2010, KN-3610 | `mips` |
| **AARCH64** | Keenetic Peak, Titan, Hopper, KN-2710, KN-2810, KN-2910, KN-3510 | `aarch64` |

## Параметры

| Переменная | Описание | По умолчанию |
|---|---|---|
| `ARCH` | Архитектура: `mipsel`, `mips`, `aarch64` | `mipsel` |
| `SWAP_SIZE` | Размер swap-раздела в МБ | `1024` |
| `PARTITION_TABLE` | Таблица разделов: `mbr` или `gpt` | `mbr` |
| `SKIP_ENTWARE` | Пропустить установщик Entware (`1` — пропустить) | `0` |

## Примеры

```bash
# Интерактивный выбор флешки
sudo ./run.sh

# Указать устройство напрямую
sudo ./run.sh /dev/disk4          # macOS
sudo ./run.sh /dev/sdb            # Linux

# AArch64 (Peak, Titan, Hopper) с GPT и 512MB swap
sudo ARCH=aarch64 SWAP_SIZE=512 PARTITION_TABLE=gpt ./run.sh

# Только разметка, без Entware
sudo SKIP_ENTWARE=1 ./run.sh
```

## Прямой запуск через Docker (Linux)

```bash
docker run --rm -it --privileged \
  -v /dev/sdb:/dev/target \
  ghcr.io/maxxxam/keenetic-entware-flash:main
```

## macOS: Ручная подготовка (без Docker)

Если вы не хотите устанавливать Docker, можно подготовить флешку напрямую в macOS.

### Требования

```bash
brew install e2fsprogs
```

### Шаги

1. Вставьте USB-флешку и найдите её идентификатор:

```bash
diskutil list external physical
```

Найдите вашу флешку (например, `/dev/disk4`). **Перепроверьте номер диска** — выбор неправильного диска уничтожит данные.

2. Создайте таблицу разделов MBR с двумя разделами (замените `disk4` на ваш диск):

```bash
sudo diskutil partitionDisk /dev/disk4 MBRFormat \
  "MS-DOS FAT32" "SWAP" 1024M \
  "MS-DOS FAT32" "OPKG" R
```

Это создаст:
- **Раздел 1** — 1 ГБ для SWAP
- **Раздел 2** — оставшееся место для данных Entware

3. Переформатируйте раздел 2 в ext4:

```bash
diskutil unmountDisk /dev/disk4
sudo $(brew --prefix e2fsprogs)/sbin/mkfs.ext4 -O ^metadata_csum -L OPKG -F /dev/disk4s2
```

4. Извлеките флешку:

```bash
diskutil eject /dev/disk4
```

5. Вставьте флешку в Keenetic роутер и следуйте шагам из раздела [После записи](#после-записи).

> **Примечание:** SWAP-раздел будет автоматически инициализирован init-скриптом на роутере (`mkswap` + `swapon`). Роутер сам скачает Entware при включении компонента OPKG — требуется подключение к интернету.

### Настройки

- **Размер swap**: замените `1024M` на нужный размер (например, `512M`, `2048M`)
- **GPT вместо MBR**: замените `MBRFormat` на `GPTFormat`

## Как это работает

1. `run.sh` показывает список USB-устройств и предлагает выбрать
2. Скачивает готовый Docker-образ (или собирает локально при недоступности)
3. На macOS создаёт временный образ диска, на Linux пробрасывает устройство напрямую
4. Контейнер создаёт таблицу разделов MBR/GPT:
   - **Раздел 1** — SWAP
   - **Раздел 2** — EXT4 (метка: OPKG) с установщиком Entware
5. На macOS записывает образ на флешку (пропуская пустые блоки для скорости)
6. Готово — вставляйте флешку в роутер

## После записи

### Шаг 1: Установка OPKG

1. Вставьте USB-флешку в Keenetic роутер
2. Откройте веб-интерфейс роутера (обычно http://192.168.1.1)
3. Перейдите в **Управление** → **Общие настройки** → **Обновления и компоненты**
4. Найдите и установите **Менеджер пакетов OPKG**:
   > Позволяет устанавливать пакеты OpenWRT для расширения возможностей интернет-центра.
   > Обсуждение работы интернет-центра с открытыми пакетами ведется на форуме [forum.keenetic.ru](https://forum.keenetic.ru). Техническая поддержка Keenetic такие вопросы не рассматривает.
5. Роутер перезагрузится и начнёт установку Entware автоматически

Процесс установки можно наблюдать в журнале роутера:
**Диагностика** → **Общие** → **Журнал** (`/diagnostics/general/log`)

По завершении вы увидите:
```
[5/5] Установка системы пакетов "Entware" завершена!
Не забудьте сменить пароль и номер порта!
```

### Шаг 2: Смена пароля и настройка SSH

После установки Entware предоставляет собственный SSH-доступ (Dropbear):
- **Логин:** `root`
- **Пароль:** `keenetic`
- **Порт:** `222`

Подключитесь и сразу смените пароль по умолчанию:

```bash
ssh root@192.168.1.1 -p 222

passwd root
# Changing password for root
# New password:
# Retype password:
# passwd: password for root changed by root
```

Обновите список пакетов и установленные пакеты:

```bash
opkg update
opkg upgrade
```

#### Настройка SSH-портов

После установки Entware у вас будет два SSH-сервиса. Рекомендуется перенести встроенный SSH Keenetic на другой порт, чтобы избежать конфликтов:

**Вариант А: Через веб-интерфейс**
1. Откройте веб-интерфейс роутера → **Управление** → **Общие настройки**
2. Найдите раздел **Командная строка** или **Удалённый доступ**
3. Измените порт SSH с `22` на `2222`

**Вариант Б: Через CLI Keenetic**
```bash
ssh admin@192.168.1.1 -p 22

(config)> ip ssh
(config-ssh)> port 2222
(config-ssh)> exit
(config)> system configuration save
```

После настройки у вас будет два раздельных SSH-подключения:

```bash
# CLI Keenetic (управление роутером)
ssh admin@192.168.1.1 -p 2222

# Entware shell (полноценная Linux-среда)
ssh root@192.168.1.1 -p 22
```

> Порт SSH Entware можно изменить в `/opt/etc/config/dropbear.conf` при необходимости.

### Шаг 3: Включение SWAP (рекомендуется)

Swap значительно повышает стабильность при работе нескольких пакетов Entware. SWAP **не активируется автоматически** без init-скрипта — после каждой перезагрузки роутера `free -m` покажет `Swap: 0`.

Скрипт автозапуска уже записан на флешку при прошивке. Он сам определяет SWAP раздел (по метке OPKG на соседнем разделе) и выполняет `mkswap` + `swapon`.

Подключитесь к Entware по SSH и выполните:

Скопируйте скрипт в автозагрузку:

```bash
cp /opt/scripts/S01swap /opt/etc/init.d/S01swap && chmod +x /opt/etc/init.d/S01swap
```

Запустите — скрипт сам найдёт раздел, инициализирует и активирует SWAP:

```bash
/opt/etc/init.d/S01swap start
```

Проверьте:

```bash
/opt/etc/init.d/S01swap status
```

```bash
free -m
```

В строке `Swap` должны быть значения (например, `Swap: 1023 MB`).

---

<details>
<summary>Если скрипта нет в /opt/scripts/ — создайте вручную</summary>

Скопируйте и вставьте эту команду целиком (она создаст файл скрипта):

```bash
cat > /opt/etc/init.d/S01swap <<'SWAP'
#!/bin/sh
find_swap() {
    if command -v blkid >/dev/null 2>&1; then
        OPKG=$(blkid -L OPKG 2>/dev/null)
        [ -n "$OPKG" ] && DEV=$(echo "$OPKG" | sed 's/2$/1/') && [ -b "$DEV" ] && echo "$DEV" && return
    fi
    for d in /dev/sda1 /dev/sdb1 /dev/sdc1; do [ -b "$d" ] && echo "$d" && return; done
    return 1
}
case "$1" in
  start)
    DEV=$(find_swap) || { echo "SWAP not found"; exit 1; }
    swapon "$DEV" 2>/dev/null || { mkswap -L SWAP "$DEV" >/dev/null 2>&1; swapon "$DEV"; }
    echo "SWAP started on $DEV"
    ;;
  stop) swapoff -a 2>/dev/null ;;
  restart) "$0" stop; sleep 1; "$0" start ;;
  status) cat /proc/swaps; free -m | grep -i swap ;;
  *) echo "Usage: $0 {start|stop|restart|status}" ;;
esac
SWAP
```

Сделайте скрипт исполняемым:

```bash
chmod +x /opt/etc/init.d/S01swap
```

</details>

---

После перезагрузки роутера SWAP включится автоматически. Проверка:

```bash
free -m
```

```bash
cat /proc/swaps
```

### Шаг 4: Проверка

```bash
# Проверить работу Entware
opkg update
opkg list-installed

# Проверить, что swap активен
free -m
```

Подробнее: [help.keenetic.com](https://help.keenetic.com/hc/ru/articles/360021888880)

## Локальная сборка

```bash
# Стандартная сборка
docker build --platform linux/amd64 -t keenetic-entware-flash .

# Сборка в России (с доступными зеркалами)
docker build --platform linux/amd64 \
  --build-arg BASE_IMAGE=cr.yandex/mirror/ubuntu:22.04 \
  --build-arg APT_MIRROR=http://mirror.yandex.ru \
  -t keenetic-entware-flash .
```

## Клонирование USB (Backup / Restore)

Флешки в роутерах работают 24/7 и могут выходить из строя. Используйте `clone.sh` для создания полного побайтового слепка флешки и восстановления на новый накопитель — без Docker.

### Backup (USB → файл)

```bash
# Интерактивный выбор флешки
sudo ./clone.sh backup

# Указать устройство напрямую
sudo ./clone.sh backup /dev/disk4          # macOS
sudo ./clone.sh backup /dev/sdb            # Linux

# Указать путь к файлу
sudo ./clone.sh backup /dev/disk4 ~/backup.img

# Сжатый backup (gzip)
sudo ./clone.sh backup --compress
sudo ./clone.sh backup /dev/disk4 --compress
```

По умолчанию сохраняет в `~/keenetic-backup-YYYY-MM-DD.img`

### Restore (файл → USB)

```bash
# Интерактивный выбор флешки
sudo ./clone.sh restore backup.img

# Указать устройство напрямую
sudo ./clone.sh restore backup.img /dev/disk4
```

- Сжатые образы (`.img.gz`) определяются автоматически
- При восстановлении пустые блоки пропускаются — запись быстрее на 60-80%
- Скрипт проверяет, что образ помещается на целевой диск
- Перед записью требуется подтверждение

## Решение проблем

**"No external USB devices found"** — вставьте USB-флешку и попробуйте снова.

**"Permission denied"** — запускайте с `sudo`:
```bash
sudo ./run.sh
```

**macOS: "Resource busy"** — скрипт размонтирует диск автоматически, но если не получилось:
```bash
diskutil unmountDisk /dev/diskN
```

**Docker Hub / GHCR недоступен** — скрипт автоматически соберёт образ локально через доступные зеркала.

**Установщик Entware не скачался** — флешка всё равно готова. Установщик зашит в Docker-образ как fallback. Если и он не сработал — роутер скачает Entware сам при включении OPKG.

## Лицензия

MIT — см. [LICENSE](LICENSE).
