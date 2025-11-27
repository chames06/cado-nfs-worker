#!/usr/bin/env bash

set -e

### ------------------------------------------------------------
### Fonctions
### ------------------------------------------------------------

purge_docker() {
    echo "[*] Purge complète de Docker…"

    # Arrêt et suppression de tous les conteneurs
    if command -v docker >/dev/null 2>&1; then
        docker ps -aq | xargs -r docker rm -f || true
        docker images -aq | xargs -r docker rmi -f || true
        docker volume ls -q | xargs -r docker volume rm || true
        docker network prune -f || true
    fi

    # Suppression des paquets Docker selon l’OS
    if [ -f /etc/debian_version ]; then
        sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras || true
        sudo apt-get autoremove -y
    elif [ -f /etc/redhat-release ]; then
        sudo dnf remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
    fi

    # Suppression des résidus
    sudo rm -rf /var/lib/docker /var/lib/containerd /etc/apt/keyrings/docker.gpg \
                /etc/apt/sources.list.d/docker.list

    echo "[*] Purge terminée."
}

install_docker_debian() {
    echo "[*] Installation Docker (Debian/Ubuntu)…"

    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg lsb-release

    # Création du dossier keyring
    sudo install -m 0755 -d /etc/apt/keyrings

    # Récupération de la clé GPG Docker
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    # Correction : Ubuntu jammy ou dérivé → utiliser "ubuntu"
    DISTRO=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
    CODENAME=$(lsb_release -cs)

    case "$DISTRO" in
        ubuntu|debian)
            ;;
        *)
            echo "[!] Distribution non reconnue → Forçage en 'ubuntu jammy'"
            DISTRO="ubuntu"
            CODENAME="jammy"
            ;;
    esac

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${DISTRO} ${CODENAME} stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    sudo apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    sudo systemctl enable --now docker
    echo "[*] Docker installé."
}

### ------------------------------------------------------------
### Main
### ------------------------------------------------------------

ACTION="$1"

if [ "$ACTION" = "purge" ]; then
    purge_docker
    exit 0
fi

# Installation Docker si absent
if ! command -v docker >/dev/null 2>&1; then
    echo "[*] Docker non détecté. Installation…"

    if [ -f /etc/debian_version ]; then
        install_docker_debian
    elif [ -f /etc/redhat-release ]; then
        echo "[!] Ajout RedHat/CentOS possible, mais non implémenté ici."
        exit 1
    else
        echo "Distribution non supportée automatiquement."
        exit 1
    fi
fi

echo "[*] Docker prêt."

### ------------------------------------------------------------
### Conteneur CADO
### ------------------------------------------------------------

CONTAINER_NAME="cado-worker"
IMAGE="cha256/cado-nfs-worker:latest"

# Suppression si un conteneur existe déjà
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "[*] Conteneur existant détecté : suppression…"
    docker rm -f "${CONTAINER_NAME}"
fi

echo "[*] Lancement du conteneur…"
docker run -d --name "${CONTAINER_NAME}" "${IMAGE}"

echo "[*] Conteneur lancé."
