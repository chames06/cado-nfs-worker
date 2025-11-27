#!/usr/bin/env bash

set -e

# Vérification Docker
if ! command -f docker >/dev/null 2>&1; then
    echo "[*] Docker non détecté. Installation…"

    # Détection distribution
    if [ -f /etc/debian_version ]; then
        sudo apt-get update
        sudo apt-get install -y ca-certificates curl gnupg
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
          $(lsb_release -cs) stable" | \
          sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    elif [ -f /etc/redhat-release ]; then
        sudo dnf -y install dnf-plugins-core
        sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
        echo "Distribution non supportée automatiquement."
        exit 1
    fi

    sudo systemctl enable --now docker
fi

echo "[*] Docker prêt."

# Lancement du conteneur
CONTAINER_NAME="cado-worker"
IMAGE="cha256/cado-nfs-worker:latest"

# Stop et remove si déjà existant
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "[*] Conteneur déjà présent : suppression préalable."
    docker rm -f "${CONTAINER_NAME}"
fi

echo "[*] Lancement du conteneur…"
docker run -d --name "${CONTAINER_NAME}" "${IMAGE}"

echo "[*] Conteneur lancé."

