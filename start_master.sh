#!/bin/bash
set -e

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║   Lancement Master FACT0RN Pipeline v5                           ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Arrêter l'ancien
docker stop factorn-master 2>/dev/null || true
docker rm factorn-master 2>/dev/null || true

# Créer volumes
mkdir -p /opt/factoring

# Lancer
docker run -d \
    --name factorn-master \
    --restart unless-stopped \
    --privileged \
    -e POOL_USERNAME="gappydesevran" \
    -e POOL_PASSWORD="FPV8V5He" \
    -e SCRIPTPUBKEY="0014e09713d9d962d8b46732fcf9023fad00299d261d" \
    -e CADO_SERVER_PORT="3001" \
    -e MSIEVE_TIMEOUT="120" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /opt/factoring:/opt/factoring \
    -p 3001:3001 \
    factorn-master:latest

echo ""
echo "✓ Master démarré!"
echo ""
echo "Pipeline automatique:"
echo "  1. Lance fact-worker (connexion pool)"
echo "  2. Surveille les fichiers N_xxx.dat"
echo "  3. Lance cha256/msieve-cuda pour chaque N"
echo "     → Récupère msieve.fb depuis /app/msieve/"
echo "  4. Convertit le polynôme pour CADO-NFS"
echo "  5. Factorise avec CADO-NFS"
echo "  6. Sauvegarde: N,facteur"
echo ""
echo "Commandes:"
echo "  docker logs -f factorn-master"
echo "  ./status.sh"
echo "  ./results.sh"
echo ""
