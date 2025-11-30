#!/bin/bash
# =============================================================================
# SLAVE CADO-NFS Client - Docker Setup avec Auto-Scaling
# =============================================================================
set -e

# ⚠️ CONFIGURATION À MODIFIER SELON VOS BESOINS ⚠️
# Changez cette IP par celle de votre serveur master
MASTER_HOST="82.66.207.144"
MASTER_SSH_USER="Dell"
MASTER_CADO_PORT="3001"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[SLAVE-SETUP]${NC} $1"; }
log_success() { echo -e "${GREEN}[SLAVE-SETUP] ✓${NC} $1"; }
log_error() { echo -e "${RED}[SLAVE-SETUP] ✗${NC} $1"; }
log_warning() { echo -e "${YELLOW}[SLAVE-SETUP] ⚠${NC} $1"; }

banner() {
    clear
    cat << "EOF"
╔══════════════════════════════════════════════════════════╗
║         SLAVE CADO-NFS Client - Auto-Scaling            ║
║           Compilation Locale + SSH Tunnel                ║
╚══════════════════════════════════════════════════════════╝
EOF
    echo ""
}

banner

log "Vérification de la configuration..."
log_warning "Master configuré: $MASTER_HOST:$MASTER_CADO_PORT"
read -p "Cette configuration est-elle correcte ? (y/N): " confirm

if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    log_warning "Modifiez les variables en début de script:"
    log_warning "  MASTER_HOST=\"VOTRE_IP\""
    log_warning "  MASTER_SSH_USER=\"VOTRE_USER\""
    log_warning "  MASTER_CADO_PORT=\"VOTRE_PORT\""
    exit 1
fi

log "Création de l'image Docker Slave..."

# Créer le Dockerfile
cat > Dockerfile.slave << 'DOCKERFILE_END'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV MASTER_HOST=""
ENV MASTER_SSH_USER=""
ENV MASTER_CADO_PORT="3001"

# Installation des dépendances
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
    openssh-client \
    curl \
    netcat \
    htop \
    && rm -rf /var/lib/apt/lists/*

# Clone CADO-NFS (sera compilé au démarrage pour optimisation locale)
WORKDIR /opt
RUN git clone https://gitlab.inria.fr/cado-nfs/cado-nfs.git && \
    cd cado-nfs && \
    git checkout stable

# Script de démarrage
COPY slave_entrypoint.sh /usr/local/bin/slave_entrypoint.sh
RUN chmod +x /usr/local/bin/slave_entrypoint.sh

# Clé SSH (sera injectée au runtime)
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh

WORKDIR /opt/cado-nfs

ENTRYPOINT ["/usr/local/bin/slave_entrypoint.sh"]

HEALTHCHECK --interval=60s --timeout=10s --retries=3 \
    CMD pgrep -f "cado-nfs-client.py" || exit 1
DOCKERFILE_END

log_success "Dockerfile créé"

# Créer le script d'entrypoint
cat > slave_entrypoint.sh << 'ENTRYPOINT_END'
#!/bin/bash
set -e

CADO_DIR="/opt/cado-nfs"

log() { echo "[SLAVE] $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_error() { echo "[SLAVE] $(date '+%Y-%m-%d %H:%M:%S') ✗ $1" >&2; }

log "=========================================="
log "SLAVE CADO-NFS - Démarrage"
log "=========================================="

# Détection ressources
NUM_THREADS=$(nproc)
WORKER_THREADS=$((NUM_THREADS / 4))

if [ $WORKER_THREADS -lt 1 ]; then
    WORKER_THREADS=1
fi

log "Machine: $NUM_THREADS threads disponibles"
log "Configuration: $WORKER_THREADS worker thread(s) (25%)"

# Configuration SSH
log "(1/5) Configuration de la clé SSH..."
mkdir -p /root/.ssh
chmod 700 /root/.ssh

cat <<EOF > /root/.ssh/id_ed25519
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACCy79fJqinU/9UAmDohl/V7Pnx71GOzfngxaAtwEhJeDwAAAJC6S48YukuP
GAAAAAtzc2gtZWQyNTUxOQAAACCy79fJqinU/9UAmDohl/V7Pnx71GOzfngxaAtwEhJeDw
AAAECJnHnyeoZPyBvdYKVLcLdLCUI5QDpSHtlFu7+PQD8nBbLv18mqKdT/1QCYOiGX9Xs+
fHvUY7N+eDFoC3ASEl4PAAAAC3Jvb3RAcG9wLW9zAQI=
-----END OPENSSH PRIVATE KEY-----
EOF

chmod 600 /root/.ssh/id_ed25519
log "✓ Clé SSH configurée"

# Établissement du tunnel SSH
log "(2/5) Établissement du tunnel SSH vers $MASTER_HOST..."

ssh -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes \
    -i /root/.ssh/id_ed25519 \
    -N -L "$MASTER_CADO_PORT:127.0.0.1:$MASTER_CADO_PORT" \
    "$MASTER_SSH_USER@$MASTER_HOST" &

SSH_PID=$!
sleep 5

if ! kill -0 $SSH_PID > /dev/null 2>&1; then
    log_error "ERREUR CRITIQUE: Le tunnel SSH n'a pas pu s'établir"
    log_error "Vérifiez:"
    log_error "  - Clé SSH autorisée sur le master"
    log_error "  - Connectivité réseau vers $MASTER_HOST"
    log_error "  - User SSH: $MASTER_SSH_USER"
    exit 1
fi

log "✓ Tunnel SSH actif (PID: $SSH_PID)"

# Test connexion au serveur CADO
log "(3/5) Test de connexion au serveur CADO-NFS..."

for i in {1..10}; do
    if nc -z 127.0.0.1 "$MASTER_CADO_PORT" 2>/dev/null; then
        log "✓ Serveur CADO-NFS accessible"
        break
    fi
    
    if [ $i -eq 10 ]; then
        log_error "Impossible de joindre le serveur CADO-NFS"
        log_error "Le master est-il démarré ?"
        exit 1
    fi
    
    log "Tentative $i/10..."
    sleep 5
done

# Compilation CADO-NFS avec optimisations natives
log "(4/5) Compilation de CADO-NFS (optimisation CPU locale)..."
log "Cela peut prendre 5-10 minutes..."

cd "$CADO_DIR"

# Nettoyage
rm -f CMakeCache.txt
make clean 2>/dev/null || true

# Configuration avec optimisations natives
cmake . \
    -DCMAKE_C_FLAGS="-DSIZEOF_P_R_VALUES=8 -DSIZEOF_INDEX=8 -march=native -O3" \
    -DCMAKE_CXX_FLAGS="-DSIZEOF_P_R_VALUES=8 -DSIZEOF_INDEX=8 -march=native -O3" \
    > /dev/null 2>&1

# Compilation parallèle
make -j"$NUM_THREADS" > /dev/null 2>&1

log "✓ CADO-NFS compilé avec succès"

# Lancement du client avec auto-reconnexion
log "(5/5) Lancement du client CADO-NFS..."
log "=========================================="
log "Serveur: 127.0.0.1:$MASTER_CADO_PORT"
log "Threads: $WORKER_THREADS"
log "=========================================="

# Gestion de l'arrêt propre
cleanup() {
    log "Arrêt du worker..."
    kill $SSH_PID 2>/dev/null || true
    exit 0
}

trap cleanup SIGTERM SIGINT

# Boucle de reconnexion automatique
while true; do
    log "Connexion au serveur maître..."
    
    ./cado-nfs-client.py \
        --server="http://127.0.0.1:$MASTER_CADO_PORT" \
        --override "t" "$WORKER_THREADS" \
        --workdir="/tmp/cado-work-$$" \
        --niceness=10 || {
        
        log "⚠ Client déconnecté, reconnexion dans 30s..."
        sleep 30
        continue
    }
    
    log "⚠ Le serveur a fermé la connexion"
    sleep 10
done
ENTRYPOINT_END

chmod +x slave_entrypoint.sh

log_success "Script d'entrypoint créé"

# Build l'image
log "Construction de l'image Docker (1-2 minutes)..."
docker build -f Dockerfile.slave -t factorn-slave:latest . || {
    log_error "Échec du build Docker"
    exit 1
}

log_success "Image Docker construite avec succès"

# Créer un script de lancement
cat > start_slave.sh << START_END
#!/bin/bash
set -e

MASTER_HOST="$MASTER_HOST"
MASTER_SSH_USER="$MASTER_SSH_USER"
MASTER_CADO_PORT="$MASTER_CADO_PORT"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║         Lancement du Slave CADO-NFS                     ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Détection du nombre de workers optimaux
NUM_THREADS=\$(nproc)
NUM_WORKERS=\$((NUM_THREADS / 4))

if [ \$NUM_WORKERS -lt 1 ]; then
    NUM_WORKERS=1
fi

echo "Machine: \$NUM_THREADS threads"
echo "Lancement de \$NUM_WORKERS worker(s) CADO-NFS"
echo ""

# Lance les conteneurs (un par worker)
for i in \$(seq 1 \$NUM_WORKERS); do
    CONTAINER_NAME="factorn-slave-\$i"
    
    echo "Démarrage du worker \$i/\$NUM_WORKERS..."
    
    docker run -d \\
        --name "\$CONTAINER_NAME" \\
        --restart unless-stopped \\
        -e MASTER_HOST="\$MASTER_HOST" \\
        -e MASTER_SSH_USER="\$MASTER_SSH_USER" \\
        -e MASTER_CADO_PORT="\$MASTER_CADO_PORT" \\
        --cpus="4" \\
        --memory="8g" \\
        factorn-slave:latest
    
    echo "✓ Worker \$i démarré (conteneur: \$CONTAINER_NAME)"
    
    # Petit délai entre les démarrages
    sleep 2
done

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              TOUS LES WORKERS DÉMARRÉS ! ✅              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Commandes utiles:"
echo "  docker ps | grep factorn-slave        # Liste des workers"
echo "  docker logs -f factorn-slave-1        # Logs du worker 1"
echo "  docker stats | grep factorn-slave     # Ressources utilisées"
echo "  docker stop \\\$(docker ps -q -f name=factorn-slave)  # Arrêt de tous"
echo ""
START_END

chmod +x start_slave.sh

# Créer un script d'arrêt
cat > stop_slave.sh << 'STOP_END'
#!/bin/bash
echo "Arrêt de tous les workers CADO-NFS..."

docker stop $(docker ps -q -f name=factorn-slave) 2>/dev/null || true
docker rm $(docker ps -aq -f name=factorn-slave) 2>/dev/null || true

echo "✓ Tous les workers arrêtés"
STOP_END

chmod +x stop_slave.sh

# Créer un script de scaling
cat > scale_slaves.sh << 'SCALE_END'
#!/bin/bash
set -e

if [ -z "$1" ]; then
    echo "Usage: ./scale_slaves.sh <nombre_de_workers>"
    echo ""
    echo "Exemples:"
    echo "  ./scale_slaves.sh 5    # 5 workers"
    echo "  ./scale_slaves.sh 10   # 10 workers"
    exit 1
fi

TARGET_WORKERS=$1

echo "Scaling à $TARGET_WORKERS worker(s)..."

# Arrête tous les workers existants
docker stop $(docker ps -q -f name=factorn-slave) 2>/dev/null || true
docker rm $(docker ps -aq -f name=factorn-slave) 2>/dev/null || true

# Relance avec le nombre demandé
MASTER_HOST="$MASTER_HOST"
MASTER_SSH_USER="$MASTER_SSH_USER"
MASTER_CADO_PORT="$MASTER_CADO_PORT"

for i in $(seq 1 $TARGET_WORKERS); do
    CONTAINER_NAME="factorn-slave-$i"
    
    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        -e MASTER_HOST="$MASTER_HOST" \
        -e MASTER_SSH_USER="$MASTER_SSH_USER" \
        -e MASTER_CADO_PORT="$MASTER_CADO_PORT" \
        --cpus="4" \
        --memory="8g" \
        factorn-slave:latest > /dev/null
    
    echo "✓ Worker $i/$TARGET_WORKERS démarré"
    sleep 1
done

echo ""
echo "✅ Scaling terminé: $TARGET_WORKERS worker(s) actif(s)"
docker ps -f name=factorn-slave --format "table {{.Names}}\t{{.Status}}"
SCALE_END

chmod +x scale_slaves.sh

log_success "Scripts de gestion créés"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              INSTALLATION TERMINÉE ! ✅                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "${GREEN}Pour démarrer les slaves:${NC}"
echo "  ./start_slave.sh"
echo ""
echo "${BLUE}Configuration:${NC}"
echo "  Master: $MASTER_HOST:$MASTER_CADO_PORT"
echo "  SSH User: $MASTER_SSH_USER"
echo "  Auto-scaling: OUI (1 worker par 4 threads)"
echo ""
echo "${YELLOW}Commandes disponibles:${NC}"
echo "  ./start_slave.sh           # Démarre avec scaling auto"
echo "  ./stop_slave.sh            # Arrête tous les workers"
echo "  ./scale_slaves.sh 10       # Scale à 10 workers"
echo ""
echo "${GREEN}Vérification:${NC}"
echo "  docker ps | grep factorn-slave"
echo "  docker logs -f factorn-slave-1"
echo ""
echo "${RED}⚠️  IMPORTANT:${NC}"
echo "Si les workers ne se connectent pas, vérifiez:"
echo "  1. Le master est démarré: docker logs -f factorn-master"
echo "  2. La clé SSH est autorisée sur le master"
echo "  3. Le port $MASTER_CADO_PORT est ouvert"
echo ""
