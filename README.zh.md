# Keenetic Entware Flash

**一条命令为 Keenetic 路由器准备 Entware USB 闪存盘。**

[English](README.md) | [Русский](README.ru.md)

## 快速开始

插入 USB 闪存盘并执行：

```bash
git clone https://github.com/MaxXxaM/keenetic-entware-flash.git
cd keenetic-entware-flash
sudo ./run.sh
```

脚本会显示可用的 USB 设备：

```
============================================
 Select USB device
============================================

  1) /dev/disk4 — USB DISK 2.0 (15.5 GB)
  2) /dev/disk6 — MassStorageClass (64.9 GB)

  0) Cancel

Select device [1-2]:
```

Docker 镜像会自动下载。如果镜像仓库不可用，将在本地构建。

## 系统要求

- [Docker Desktop](https://www.docker.com/products/docker-desktop/)（macOS / Linux）

## 支持的型号

| 架构 | 型号 | `ARCH` |
|---|---|---|
| **MIPSEL**（默认） | Keenetic Ultra, Giga, Viva, Extra, Air, City, Omni, Lite, Start, KN-1010–KN-2310 | `mipsel` |
| **MIPS** | KN-2410, KN-2510, KN-2010, KN-3610 | `mips` |
| **AARCH64** | Keenetic Peak, Titan, Hopper, KN-2710, KN-2810, KN-2910, KN-3510 | `aarch64` |

## 参数

| 变量 | 说明 | 默认值 |
|---|---|---|
| `ARCH` | 架构：`mipsel`、`mips`、`aarch64` | `mipsel` |
| `SWAP_SIZE` | Swap 分区大小（MB） | `1024` |
| `PARTITION_TABLE` | 分区表类型：`mbr` 或 `gpt` | `mbr` |
| `SKIP_ENTWARE` | 跳过 Entware 安装器（`1` 为跳过） | `0` |

## 使用示例

```bash
# 交互式选择 USB 设备
sudo ./run.sh

# 直接指定设备
sudo ./run.sh /dev/disk4          # macOS
sudo ./run.sh /dev/sdb            # Linux

# AArch64（Peak、Titan、Hopper），GPT 分区表，512MB swap
sudo ARCH=aarch64 SWAP_SIZE=512 PARTITION_TABLE=gpt ./run.sh

# 仅分区，不安装 Entware
sudo SKIP_ENTWARE=1 ./run.sh
```

## 直接使用 Docker（Linux）

```bash
docker run --rm -it --privileged \
  -v /dev/sdb:/dev/target \
  ghcr.io/maxxxam/keenetic-entware-flash:main
```

## 工作原理

1. `run.sh` 列出 USB 设备并提示选择
2. 拉取预构建的 Docker 镜像（不可用时自动本地构建）
3. macOS 上创建临时磁盘镜像；Linux 上直接挂载设备
4. 容器创建 MBR/GPT 分区表：
   - **分区 1** — SWAP
   - **分区 2** — EXT4（卷标：OPKG），包含 Entware 安装器
5. macOS 上将镜像写入 USB（跳过空块以加快速度）
6. 完成 — 将闪存盘插入路由器

## 写入后的操作

### 第一步：安装 OPKG

1. 将 USB 闪存盘插入 Keenetic 路由器
2. 打开路由器管理界面（通常为 http://192.168.1.1）
3. 进入 **管理** → **常规设置** → **更新和组件选项**
4. 找到并安装 **OPKG 软件包管理器**：
   > 允许安装 OpenWRT 软件包以扩展路由器功能。
   > 社区支持可在 [forum.keenetic.ru](https://forum.keenetic.ru) 获得。Keenetic 官方技术支持不涵盖此类问题。
5. 路由器将重启，自动检测 USB 闪存盘并安装 Entware

### 第二步：启用 SWAP

Entware 安装完成后，通过 SSH 连接路由器以启用 SWAP：

```bash
ssh admin@192.168.1.1
```

执行以下命令：

```bash
# 检查是否检测到 swap 分区
fdisk -l /dev/sda

# 启用 swap
swapon /dev/sda1

# 验证 swap 是否已激活
free
```

要使 swap 在重启后自动启用，创建启动脚本：

```bash
# 创建启动脚本
cat >> /opt/etc/init.d/S01swap <<'SWAP'
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

### 第三步：验证

```bash
# 检查 Entware 是否正常工作
opkg update
opkg list-installed

# 检查 swap 是否已激活
free
```

更多信息：[help.keenetic.com](https://help.keenetic.com/hc/en/articles/360021888880)

## 本地构建

```bash
# 标准构建
docker build --platform linux/amd64 -t keenetic-entware-flash .

# 在俄罗斯构建（使用可访问的镜像源）
docker build --platform linux/amd64 \
  --build-arg BASE_IMAGE=cr.yandex/mirror/ubuntu:22.04 \
  --build-arg APT_MIRROR=http://mirror.yandex.ru \
  -t keenetic-entware-flash .
```

## 故障排除

**"No external USB devices found"** — 请插入 USB 闪存盘后重试。

**"Permission denied"** — 使用 `sudo` 运行：
```bash
sudo ./run.sh
```

**macOS: "Resource busy"** — 脚本会自动卸载磁盘，如果失败请手动执行：
```bash
diskutil unmountDisk /dev/diskN
```

**Docker Hub / GHCR 不可用** — 脚本会自动使用可访问的镜像源在本地构建。

**Entware 安装器下载失败** — 闪存盘仍然可以使用。安装器已作为备用方案嵌入 Docker 镜像中。如果备用方案也失败，路由器会在启用 OPKG 时自行下载 Entware。

## 许可证

MIT — 详见 [LICENSE](LICENSE)。
