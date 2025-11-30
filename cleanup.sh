#!/bin/bash
echo "Nettoyage complet..."

# Arrêt et suppression des conteneurs
docker stop factorn-master 2>/dev/null || true
docker rm factorn-master 2>/dev/null || true

# Suppression de l'image
docker rmi factorn-master:latest 2>/dev/null || true

# Suppression des fichiers
rm -f Dockerfile.master master_control.sh supervisord.conf
rm -f start_master.sh build.log

echo "✓ Nettoyage terminé"
