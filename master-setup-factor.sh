#!/bin/bash
# =============================================================================
# MASTER CADO-NFS + FACT0RN Pool Miner - Version Finale Corrigée
# =============================================================================
set -e

# Configuration (sera passée via -e au runtime, pas dans le Dockerfile)
POOL_USERNAME="gappydesevran"
POOL_PASSWORD="FPV8V5He"
SCRIPTPUBKEY="0014e09713d9d962d8b46732fcf9023fad00299d261d"
CADO_SERVER_PORT="3001"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[SETUP]${NC} $1"; }
log_success() { echo -e "${GREEN}[SETUP] ✓${NC} $1"; }
log_error() { echo -e "${RED}[SETUP] ✗${NC} $1"; }

banner() {
    clear
    cat << "EOF"
╔══════════════════════════════════════════════════════════╗
║          MASTER FACT0RN + CADO-NFS Setup                 ║
╚══════════════════════════════════════════════════════════╝
EOF
    echo ""
}

banner
log "Préparation de l'environnement..."

# Nettoyage complet
log "Nettoyage des fichiers existants..."
rm -f Dockerfile.master master_control.sh supervisord.conf start_master.sh
rm -f build.log

# Créer le Dockerfile (SANS variables d'environnement sensibles)
cat > Dockerfile.master << 'DOCKERFILE_END'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Installation dépendances
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    git \
    libgmp-dev \
    libhwloc-dev \
    libecm-dev \
    m4 \
    python3 \
    python3-pip \
    curl \
    wget \
    jq \
    docker.io \
    supervisor \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# Install Python packages
RUN pip3 install --no-cache-dir requests

# Clone CADO-NFS
WORKDIR /opt
RUN git clone --depth 1 https://gitlab.inria.fr/cado-nfs/cado-nfs.git 2>/dev/null || \
    git clone --depth 1 https://github.com/cado-nfs/cado-nfs.git cado-nfs

# Compile CADO-NFS
WORKDIR /opt/cado-nfs
RUN cmake . -DCMAKE_BUILD_TYPE=Release && \
    make -j$(nproc) 2>&1 | tee /tmp/cado_build.log || \
    make 2>&1 | tee /tmp/cado_build_single.log

# Vérifications
RUN test -f /opt/cado-nfs/cado-nfs.py || (echo "ERROR: cado-nfs.py missing" && exit 1)
RUN test -f /opt/cado-nfs/misc/convert_poly || echo "WARNING: convert_poly missing"

# Créer répertoires
RUN mkdir -p /opt/factoring/{jobs,results} && \
    mkdir -p /tmp/sieving && \
    mkdir -p /var/log/supervisor

# Scripts
COPY master_control.sh /usr/local/bin/
COPY supervisord.conf /etc/supervisor/conf.d/
RUN chmod +x /usr/local/bin/master_control.sh

EXPOSE 3001

VOLUME ["/var/run/docker.sock", "/opt/factoring", "/tmp/sieving"]

WORKDIR /opt/factoring

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
DOCKERFILE_END

log_success "Dockerfile créé"

# Créer le script de contrôle
cat > master_control.sh << 'CONTROL_END'
#!/bin/bash
set -e

SIEVING_DIR="/tmp/sieving"
WORK_DIR="/opt/factoring"
CADO_DIR="/opt/cado-nfs"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "=========================================="
log "MASTER CADO-NFS - Démarrage"
log "=========================================="
log ""
log "Configuration:"
log "  Pool User: ${POOL_USERNAME:-non défini}"
log "  CADO Port: ${CADO_SERVER_PORT:-3001}"
log "  Sieving Dir: $SIEVING_DIR"
log ""

# Initialisation
mkdir -p "$WORK_DIR/jobs" "$WORK_DIR/results"
touch "$WORK_DIR/factored_numbers.txt"

# Vérifications
if [ ! -f "$CADO_DIR/cado-nfs.py" ]; then
    log "ERREUR: CADO-NFS introuvable"
    exit 1
fi

log "✓ CADO-NFS détecté: $(ls -lh $CADO_DIR/cado-nfs.py)"

# Boucle de surveillance
log "En attente de fichiers .dat dans $SIEVING_DIR..."
log ""

while true; do
    # Compte les fichiers
    COUNT=$(ls -1 "$SIEVING_DIR"/*.dat 2>/dev/null | wc -l)
    
    if [ "$COUNT" -gt 0 ]; then
        log "✓ Détecté $COUNT fichier(s) .dat:"
        ls -lh "$SIEVING_DIR"/*.dat 2>/dev/null | while read line; do
            log "  - $line"
        done
        log ""
    fi
    
    sleep 30
done
CONTROL_END

chmod +x master_control.sh

log_success "Script master créé"

# Créer supervisord.conf
cat > supervisord.conf << 'SUPERVISOR_END'
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid
loglevel=info

[program:master_control]
command=/usr/local/bin/master_control.sh
autostart=true
autorestart=true
stderr_logfile=/var/log/supervisor/master.err.log
stdout_logfile=/var/log/supervisor/master.out.log
redirect_stderr=true
SUPERVISOR_END

log_success "Supervisor configuré"

# Build l'image
log "Construction de l'image Docker..."
log "Temps estimé: 10-20 minutes"
echo ""

docker build -f Dockerfile.master -t factorn-master:latest . 2>&1 | tee build.log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log_error "Échec du build"
    echo ""
    echo "Dernières lignes de l'erreur:"
    tail -30 build.log
    exit 1
fi

log_success "Image construite avec succès !"

# Créer le script de démarrage
cat > start_master.sh << STARTSCRIPT
#!/bin/bash
set -e

echo "Lancement du Master FACT0RN + CADO-NFS..."

# Arrête si déjà existant
docker stop factorn-master 2>/dev/null || true
docker rm factorn-master 2>/dev/null || true

# Créer les volumes locaux
mkdir -p /opt/factoring /tmp/sieving

# Lance le conteneur
docker run -d \\
    --name factorn-master \\
    --restart unless-stopped \\
    -e POOL_USERNAME="$POOL_USERNAME" \\
    -e POOL_PASSWORD="$POOL_PASSWORD" \\
    -e SCRIPTPUBKEY="$SCRIPTPUBKEY" \\
    -e CADO_SERVER_PORT="$CADO_SERVER_PORT" \\
    -v /var/run/docker.sock:/var/run/docker.sock \\
    -v /opt/factoring:/opt/factoring \\
    -v /tmp/sieving:/tmp/sieving \\
    -p 3001:3001 \\
    --privileged \\
    factorn-master:latest

echo ""
echo "✓ Master démarré"
echo ""
echo "Vérification:"
echo "  docker logs -f factorn-master"
echo ""
echo "Test de détection:"
echo "  echo '12345' > /tmp/sieving/12345_0_test.dat"
echo ""
STARTSCRIPT

chmod +x start_master.sh

log_success "Script start_master.sh créé"

# Créer script de test
cat > test_detection.sh << 'TESTSCRIPT'
#!/bin/bash
echo "Test de détection de fichiers .dat"
echo ""

# Créer un fichier test
TEST_FILE="/tmp/sieving/test_$(date +%s)_0_test.dat"
echo "12345" > "$TEST_FILE"

echo "✓ Fichier créé: $TEST_FILE"
echo ""
echo "Attendez 5 secondes..."
sleep 5
echo ""
echo "Logs du master:"
docker logs --tail 20 factorn-master

echo ""
echo "Pour suivre en temps réel:"
echo "  docker logs -f factorn-master"
TESTSCRIPT

chmod +x test_detection.sh

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              INSTALLATION TERMINÉE ! ✅                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo -e "${GREEN}Fichiers créés:${NC}"
echo "  ✓ Dockerfile.master"
echo "  ✓ master_control.sh"
echo "  ✓ supervisord.conf"
echo "  ✓ start_master.sh"
echo "  ✓ test_detection.sh"
echo ""
echo -e "${GREEN}Prochaines étapes:${NC}"
echo ""
echo "  1. Démarrer le master:"
echo "     ${BLUE}./start_master.sh${NC}"
echo ""
echo "  2. Vérifier les logs:"
echo "     ${BLUE}docker logs -f factorn-master${NC}"
echo ""
echo "  3. Tester la détection:"
echo "     ${BLUE}./test_detection.sh${NC}"
echo ""
echo -e "${YELLOW}Configuration:${NC}"
echo "  Pool: thefactory.solutions"
echo "  User: $POOL_USERNAME"
echo "  Port CADO: $CADO_SERVER_PORT"
echo ""
