#!/usr/bin/env bash

set -Eeuo pipefail

# DEBIAN_FRONTEND=noninteractive
# Suppress service restart prompt

sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y


sudo DEBIAN_FRONTEND=noninteractive apt install -y \
    ca-certificates \
    curl \
    gnupg

sudo install -m 0755 -d /etc/apt/keyrings

if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
fi

sudo chmod 644 /etc/apt/keyrings/docker.gpg


ARCH=$(dpkg --print-architecture)
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")

echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  
  
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

echo "Installed versions:"
docker --version
docker compose version
containerd --version || true

sudo systemctl enable --now docker.service
sudo systemctl enable --now containerd.service
