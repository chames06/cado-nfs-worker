#!/bin/bash
# =============================================================================
# Quick Rebuild - Relance rapide avec les corrections
# =============================================================================
set -e

echo "╔══════════════════════════════════════════════════════════╗"
echo "║          Quick Rebuild - FACT0RN Master                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Nettoyage
echo "[1/3] Nettoyage..."
docker stop factorn-master 2>/dev/null || true
docker rm factorn-master 2>/dev/null || true
docker rmi factorn-master:latest 2>/dev/null || true
rm -f build.log

# Correction du Dockerfile
echo "[2/3] Correction du Dockerfile..."

# Vérifie si python3-flask est dans le Dockerfile
if ! grep -q "python3-flask" Dockerfile.master 2>/dev/null; then
    echo "   ⚠ python3-flask manquant, ajout automatique..."
    
    # Backup
    cp Dockerfile.master Dockerfile.master.bak 2>/dev/null || true
    
    # Correction via sed (ajoute python3-flask et python3-requests après python3-pip)
    sed -i 's/python3-pip \\/python3-pip \\\n    python3-flask \\\n    python3-requests \\/' Dockerfile.master
    
    echo "   ✓ Dockerfile corrigé"
else
    echo "   ✓ Dockerfile déjà corrigé"
fi

# Rebuild
echo "[3/3] Rebuild en cours..."
echo ""

docker build -f Dockerfile.master -t factorn-master:latest . 2>&1 | tee build.log

BUILD_STATUS=${PIPESTATUS[0]}

echo ""
if [ $BUILD_STATUS -eq 0 ]; then
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║              BUILD RÉUSSI ! ✅                           ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo "Démarrage:"
    echo "  ./start_master.sh"
    echo ""
else
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║              BUILD ÉCHOUÉ ✗                              ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo "Dernières lignes de l'erreur:"
    tail -30 build.log
    echo ""
    echo "Log complet: build.log"
    exit 1
fi
