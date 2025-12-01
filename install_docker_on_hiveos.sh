#!/bin/bash
set -e

echo "[INFO] Installation de Docker sur HiveOS"

# -----------------------------------------------------------------------
# Vérification : éviter d'exécuter un fichier HTML à la place du script
# -----------------------------------------------------------------------
file_head=$(head -n 1 "$0")
if echo "$file_head" | grep -qi "<!DOCTYPE html>"; then
    echo "[ERREUR] Ce fichier n’est pas un script shell mais une page HTML."
    echo "[ERREUR] Utilise l’URL RAW GitHub pour télécharger ce script :"
    echo "  wget https://raw.githubusercontent.com/chames06/cado-nfs-worker/main/install_docker_on_hiveos.sh -O install_docker_on_hiveos.sh"
    exit 1
fi

# -----------------------------------------------------------------------
# Vérification des privilèges root
# -----------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "[ERREUR] Ce script doit être exécuté en root."
    exit 1
fi

# -----------------------------------------------------------------------
# Mise à jour du système
# -----------------------------------------------------------------------
echo "[INFO] Mise à jour des paquets..."
apt-get update -y

# -----------------------------------------------------------------------
# Suppression d'éventuels restes Docker
# -----------------------------------------------------------------------
echo "[INFO] Nettoyage éventuels anciens Docker..."
apt-get remove -y docker docker-engine docker.io containerd runc || true

# -----------------------------------------------------------------------
# Installation des dépendances
# -----------------------------------------------------------------------
echo "[INFO] Installation des dépendances..."
apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# -----------------------------------------------------------------------
# Ajout du dépôt Docker officiel
# -----------------------------------------------------------------------
echo "[INFO] Ajout du dépôt Docker officiel..."

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor \
    | tee /etc/apt/keyrings/docker.gpg > /dev/null

chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

# -----------------------------------------------------------------------
# Installation de Docker
# -----------------------------------------------------------------------
echo "[INFO] Installation de Docker Engine..."
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# -----------------------------------------------------------------------
# Activation du service
# -----------------------------------------------------------------------
echo "[INFO] Activation de Docker..."
systemctl enable docker
systemctl start docker

# -----------------------------------------------------------------------
# Vérification
# -----------------------------------------------------------------------
echo "[INFO] Vérification de l’installation..."
if ! docker --version >/dev/null 2>&1; then
    echo "[ERREUR] Docker ne semble pas installé correctement."
    exit 1
fi

echo "[SUCCÈS] Docker est installé et opérationnel."
docker --version
