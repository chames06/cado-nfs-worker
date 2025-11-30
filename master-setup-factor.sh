#!/bin/bash
# =============================================================================
# MASTER CADO-NFS + FACT0RN Pool Miner - Docker Setup (VERSION CORRIGÉE)
# =============================================================================
set -e

# Configuration
POOL_USERNAME="gappydesevran"
POOL_PASSWORD="FPV8V5He"
SCRIPTPUBKEY="0014e09713d9d962d8b46732fcf9023fad00299d261d"
CADO_SERVER_PORT="3001"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[MASTER-SETUP]${NC} $1"; }
log_success() { echo -e "${GREEN}[MASTER-SETUP] ✓${NC} $1"; }
log_error() { echo -e "${RED}[MASTER-SETUP] ✗${NC} $1"; }

banner() {
    clear
    cat << "EOF"
╔══════════════════════════════════════════════════════════╗
║     MASTER CADO-NFS + FACT0RN Pool Miner Setup          ║
║              Docker-in-Docker Architecture               ║
╚══════════════════════════════════════════════════════════╝
EOF
    echo ""
}

banner

log "Création de l'image Docker Master..."

# Créer le Dockerfile
cat > Dockerfile.master << 'DOCKERFILE_END'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV POOL_USERNAME=""
ENV POOL_PASSWORD=""
ENV SCRIPTPUBKEY=""
ENV CADO_SERVER_PORT="3001"

# Installation des dépendances système
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
    netcat \
    && rm -rf /var/lib/apt/lists/*

# Install Python packages
RUN pip3 install requests

# Clone CADO-NFS depuis GitLab INRIA (source officielle)
WORKDIR /opt
RUN git clone --depth 1 https://gitlab.inria.fr/cado-nfs/cado-nfs.git || \
    (echo "GitLab INRIA inaccessible, clone depuis le mirror..." && \
     git clone --depth 1 https://github.com/cado-nfs/cado-nfs.git cado-nfs)

# Compile CADO-NFS (compilation générique pour éviter les erreurs)
WORKDIR /opt/cado-nfs
RUN cmake . \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="-O3" \
    -DCMAKE_CXX_FLAGS="-O3" && \
    make -j$(nproc) || (echo "Erreur compilation, tentative avec 1 thread..." && make) && \
    echo "CADO-NFS compilé avec succès"

# Vérifier que convert_poly existe
RUN test -f /opt/cado-nfs/misc/convert_poly || \
    (echo "ERREUR: convert_poly introuvable" && exit 1)

# Créer les répertoires de travail
RUN mkdir -p /opt/factoring/{jobs,results} && \
    mkdir -p /tmp/sieving && \
    mkdir -p /var/log/supervisor

# Créer les scripts
WORKDIR /opt/factoring

# Script principal de gestion
COPY master_control.sh /usr/local/bin/master_control.sh
RUN chmod +x /usr/local/bin/master_control.sh

# Configuration Supervisor
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Expose le port CADO-NFS
EXPOSE 3001

# Volume pour Docker socket (Docker-in-Docker)
VOLUME /var/run/docker.sock

WORKDIR /opt/factoring

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
DOCKERFILE_END

log_success "Dockerfile créé"

# Créer le script de contrôle principal (VERSION SIMPLIFIÉE)
cat > master_control.sh << 'CONTROL_SCRIPT_END'
#!/bin/bash
set -e

SIEVING_DIR="/tmp/sieving"
WORK_DIR="/opt/factoring"
CADO_DIR="/opt/cado-nfs"
FACTORED_LOG="$WORK_DIR/factored_numbers.txt"
CURRENT_JOB="$WORK_DIR/current_job.txt"
MINER_CONTAINER="fact-worker"

log() { echo "[MASTER] $(date '+%Y-%m-%d %H:%M:%S') $1"; }

# Initialisation
touch "$FACTORED_LOG"
mkdir -p "$WORK_DIR/jobs" "$WORK_DIR/results"

log "=========================================="
log "MASTER CADO-NFS - Démarrage"
log "=========================================="
log "En attente de fichiers dans $SIEVING_DIR..."
log ""
log "Pour tester, créez un fichier:"
log "  echo '12345' > /tmp/sieving/12345_0_test.dat"
log ""

# Fonction stub pour test
test_detection() {
    while true; do
        if [ -f "$SIEVING_DIR"/*.dat ]; then
            log "✓ Fichier .dat détecté !"
            ls -la "$SIEVING_DIR"/*.dat
        fi
        sleep 30
    done
}

# Boucle principale (VERSION SIMPLIFIÉE POUR TEST)
log "Mode détection activé (version simplifiée)"
test_detection
CONTROL_SCRIPT_END

chmod +x master_control.sh

log_success "Script de contrôle créé"

# Créer la configuration Supervisor
cat > supervisord.conf << 'SUPERVISOR_END'
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
loglevel=info

[program:master_control]
command=/usr/local/bin/master_control.sh
autostart=true
autorestart=true
stderr_logfile=/var/log/supervisor/master_control.err.log
stdout_logfile=/var/log/supervisor/master_control.out.log
environment=POOL_USERNAME="%(ENV_POOL_USERNAME)s",POOL_PASSWORD="%(ENV_POOL_PASSWORD)s",SCRIPTPUBKEY="%(ENV_SCRIPTPUBKEY)s",CADO_SERVER_PORT="%(ENV_CADO_SERVER_PORT)s"
SUPERVISOR_END

log_success "Configuration Supervisor créée"

# Vérifier que Docker est disponible
if ! command -v docker &> /dev/null; then
    log_error "Docker n'est pas installé !"
    echo ""
    echo "Installez Docker avec:"
    echo "  curl -fsSL https://get.docker.com | sh"
    exit 1
fi

# Build l'image
log "Construction de l'image Docker..."
log "Cela peut prendre 10-20 minutes (compilation CADO-NFS)..."
echo ""

docker build -f Dockerfile.master -t factorn-master:latest . 2>&1 | tee build.log

if [ $? -ne 0 ]; then
    log_error "Échec du build Docker"
    echo ""
    echo "Consultez build.log pour plus de détails"
    exit 1
fi

log_success "Image Docker construite avec succès"

# Créer un script de lancement
cat > start_master.sh << 'START_END'
#!/bin/bash
set -e

POOL_USERNAME="gappydesevran"
POOL_PASSWORD="FPV8V5He"
SCRIPTPUBKEY="0014e09713d9d962d8b46732fcf9023fad00299d261d"
CADO_SERVER_PORT="3001"

echo "Lancement du Master FACT0RN + CADO-NFS..."

# Arrête le conteneur existant s'il existe
docker stop factorn-master 2>/dev/null || true
docker rm factorn-master 2>/dev/null || true

docker run -d \
    --name factorn-master \
    --restart unless-stopped \
    -e POOL_USERNAME="$POOL_USERNAME" \
    -e POOL_PASSWORD="$POOL_PASSWORD" \
    -e SCRIPTPUBKEY="$SCRIPTPUBKEY" \
    -e CADO_SERVER_PORT="$CADO_SERVER_PORT" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /opt/factoring:/opt/factoring \
    -v /tmp/sieving:/tmp/sieving \
    -p 3001:3001 \
    --privileged \
    factorn-master:latest

echo "✓ Master démarré"
echo ""
echo "Commandes utiles:"
echo "  docker logs -f factorn-master          # Logs en temps réel"
echo "  docker exec -it factorn-master bash    # Shell interactif"
echo ""
echo "Test de détection:"
echo "  echo '12345' > /tmp/sieving/12345_0_test.dat"
echo "  docker logs -f factorn-master"
START_END

chmod +x start_master.sh

# Créer un script de test
cat > test_master.sh << 'TEST_END'
#!/bin/bash
echo "Test de l'environnement master..."
echo ""

# Vérifie que le conteneur tourne
if ! docker ps | grep -q factorn-master; then
    echo "✗ Le conteneur factorn-master ne tourne pas"
    echo "Lancez-le avec: ./start_master.sh"
    exit 1
fi

echo "✓ Conteneur actif"

# Test CADO-NFS
echo "Test CADO-NFS..."
docker exec factorn-master bash -c "cd /opt/cado-nfs && ls -la cado-nfs.py"

if [ $? -eq 0 ]; then
    echo "✓ CADO-NFS présent"
else
    echo "✗ CADO-NFS manquant"
    exit 1
fi

# Test convert_poly
echo "Test convert_poly..."
docker exec factorn-master bash -c "ls -la /opt/cado-nfs/misc/convert_poly"

if [ $? -eq 0 ]; then
    echo "✓ convert_poly présent"
else
    echo "✗ convert_poly manquant"
    exit 1
fi

# Test des répertoires
echo "Test des répertoires..."
docker exec factorn-master bash -c "ls -la /tmp/sieving /opt/factoring"

echo ""
echo "✓ Tous les tests passés !"
echo ""
echo "Pour tester la détection:"
echo "  echo '12345' > /tmp/sieving/12345_0_test.dat"
echo "  docker logs -f factorn-master"
TEST_END

chmod +x test_master.sh

log_success "Script de test créé"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              INSTALLATION TERMINÉE ! ✅                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "${GREEN}Pour démarrer le master:${NC}"
echo "  ./start_master.sh"
echo ""
echo "${GREEN}Pour tester:${NC}"
echo "  ./test_master.sh"
echo ""
echo "${BLUE}Configuration:${NC}"
echo "  Pool: thefactory.solutions"
echo "  Username: $POOL_USERNAME"
echo "  CADO Port: $CADO_SERVER_PORT"
echo ""
echo "${YELLOW}Logs:${NC}"
echo "  docker logs -f factorn-master"
echo ""
echo "${YELLOW}Note:${NC} Cette version est simplifiée pour le test."
echo "Le workflow complet sera activé après validation."
echo ""
