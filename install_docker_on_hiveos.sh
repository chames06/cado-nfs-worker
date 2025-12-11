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
# Vérification root
# -----------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "[ERREUR] Ce script doit être exécuté en root."
    exit 1
fi

apt-get update -y

# -----------------------------------------------------------------------
# Vérifier si Docker est déjà installé
# -----------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    echo "[INFO] Docker non détecté. Installation via apt…"

    # Tentative 1 : docker.io
    if apt-get install -y docker.io; then
        echo "[INFO] docker.io installé avec succès."
    else
        echo "[WARN] docker.io n’a pas pu être installé. Tentative avec podman-docker…"

        # Tentative 2 : podman-docker (fallback)
        if apt-get install -y podman-docker; then
            echo "[INFO] podman-docker installé. 'docker' sera émulé par Podman."
        else
            echo "[ERREUR] Impossible d’installer docker.io ou podman-docker."
            exit 1
        fi
    fi
else
    echo "[INFO] Docker déjà installé."
fi

# -----------------------------------------------------------------------
# Vérification finale
# -----------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    echo "[ERREUR] Docker n’est pas disponible même après installation."
    exit 1
fi

echo "[SUCCÈS] Docker opérationnel : $(docker --version 2>/dev/null || echo 'via podman-docker')"
