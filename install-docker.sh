#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Docker installation helper for Keenetic Entware Flash
# ============================================================================

echo "============================================"
echo " Docker Installation Helper"
echo "============================================"
echo ""

detect_os() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        *) echo "unknown" ;;
    esac
}

install_macos() {
    echo "Detected: macOS"
    echo ""

    if command -v docker &>/dev/null; then
        echo "Docker is already installed:"
        docker --version
        echo ""
        echo "Make sure Docker Desktop is running."
        return 0
    fi

    if ! command -v brew &>/dev/null; then
        echo "Homebrew not found. Installing Homebrew first..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi

    echo "Installing Docker Desktop via Homebrew..."
    brew install --cask docker

    echo ""
    echo "Docker Desktop installed!"
    echo "Please launch Docker Desktop from Applications and wait for it to start."
    echo "Then run your keenatic-flash command."
}

install_linux() {
    echo "Detected: Linux"
    echo ""

    if command -v docker &>/dev/null; then
        echo "Docker is already installed:"
        docker --version
        return 0
    fi

    echo "Installing Docker via get.docker.com..."
    curl -fsSL https://get.docker.com | sh

    echo ""
    echo "Adding current user to docker group..."
    sudo usermod -aG docker "$USER" || true

    echo ""
    echo "Docker installed!"
    echo "You may need to log out and log back in for group changes to take effect."
    echo "Or run: newgrp docker"
}

install_wsl() {
    echo "Detected: Windows (WSL)"
    echo ""

    if command -v docker &>/dev/null; then
        echo "Docker is already available in WSL:"
        docker --version
        return 0
    fi

    echo "For WSL, install Docker Desktop for Windows:"
    echo ""
    echo "  1. Download Docker Desktop from https://www.docker.com/products/docker-desktop/"
    echo "  2. Install and enable 'Use the WSL 2 based engine'"
    echo "  3. In Settings → Resources → WSL Integration, enable your distro"
    echo "  4. Restart your WSL terminal"
    echo ""
    echo "After installation, 'docker' will be available inside WSL."
}

OS=$(detect_os)

case "$OS" in
    macos) install_macos ;;
    linux) install_linux ;;
    wsl)   install_wsl ;;
    *)
        echo "Unsupported OS: $(uname -s)"
        echo "Please install Docker manually: https://docs.docker.com/get-docker/"
        exit 1
        ;;
esac
