#!/bin/bash
##############################################################################
# FACT0RN Master Deployment Script
# Déploie l'orchestration complète sur la machine maître
# Inclut: GPU, pool listener, N detector, orchestrator, résultats
##############################################################################

set -e

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

##############################################################################
# CONFIGURATION
##############################################################################

DEPLOY_DIR="${DEPLOY_DIR:-.}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/fact0rn}"
WORK_DIR="${WORK_DIR:-$INSTALL_PREFIX/work}"
CONFIG_DIR="${CONFIG_DIR:-$INSTALL_PREFIX/config}"

# SSH Configuration
SSH_PUB_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILLv18mqKdT/1QCYOiGX9Xs+fHvUY7N+eDFoC3ASEl4P root@pop-os"
SSH_PRIV_KEY_FILE="$CONFIG_DIR/id_ed25519"

# RPC Configuration (pour le nœud FACT0RN local)
RPC_USER="${RPC_USER:-factorn}"
RPC_PASS="${RPC_PASS:-$(openssl rand -base64 24)}"
RPC_HOST="127.0.0.1"
RPC_PORT="${RPC_PORT:-8332}"

# Pool Configuration
POOL_HOST="${POOL_HOST:-91.69.7.150}"
POOL_PORT="${POOL_PORT:-33093}"

# GPU Configuration
GPU_ENABLED="${GPU_ENABLED:-true}"
GPU_DEVICE="${GPU_DEVICE:-0}"
CUDA_ARCH="${CUDA_ARCH:-89}"  # Ada (H100)

# CADO Configuration
CADO_SERVER_PORT=3001

##############################################################################
# PHASE 0: Vérifications préalables
##############################################################################

phase_prerequisites() {
    log_info "PHASE 0: Vérification des prérequis"
    
    # Vérifier les permissions
    if [ "$EUID" -ne 0 ]; then
        log_error "Ce script doit être exécuté en tant que root"
        exit 1
    fi
    
    # Vérifier Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker n'est pas installé"
        exit 1
    fi
    
    # Vérifier docker-compose
    if ! command -v docker-compose &> /dev/null; then
        log_error "docker-compose n'est pas installé"
        exit 1
    fi
    
    # Vérifier GPU (optionnel)
    if [ "$GPU_ENABLED" = "true" ]; then
        if command -v nvidia-smi &> /dev/null; then
            log_success "GPU NVIDIA détecté"
            nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader
        else
            log_warn "GPU NVIDIA requis mais non détecté, déploiement CPU uniquement"
            GPU_ENABLED="false"
        fi
    fi
    
    log_success "Prérequis validés"
}

##############################################################################
# PHASE 1: Préparation des répertoires
##############################################################################

phase_setup_directories() {
    log_info "PHASE 1: Préparation des répertoires"
    
    mkdir -p "$INSTALL_PREFIX"/{detector,master,slave,submitter}
    mkdir -p "$WORK_DIR"/{sessions,logs}
    mkdir -p "$CONFIG_DIR"
    mkdir -p /var/log/fact0rn
    
    # Permissions
    chmod 755 "$INSTALL_PREFIX"
    chmod 700 "$CONFIG_DIR"
    chmod 777 "$WORK_DIR"
    
    log_success "Répertoires créés: $INSTALL_PREFIX"
}

##############################################################################
# PHASE 2: Configuration SSH
##############################################################################

phase_setup_ssh() {
    log_info "PHASE 2: Configuration SSH"
    
    # Créer répertoire .ssh si nécessaire
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    
    # Ajouter la clé publique à authorized_keys
    if ! grep -q "root@pop-os" /root/.ssh/authorized_keys 2>/dev/null; then
        echo "$SSH_PUB_KEY" >> /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        log_success "Clé publique ajoutée à authorized_keys"
    else
        log_info "Clé publique déjà présente"
    fi
    
    # SSH config pour la pool
    cat > "$CONFIG_DIR/ssh_config" << 'EOF'
Host poolserver
    HostName 91.69.7.150
    User serveurdechames
    IdentityFile /config/id_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ConnectTimeout 10
EOF
    
    chmod 600 "$CONFIG_DIR/ssh_config"
    log_success "Configuration SSH préparée"
}

##############################################################################
# PHASE 3: Configuration RPC et Portefeuille
##############################################################################

phase_setup_rpc() {
    log_info "PHASE 3: Configuration RPC et Portefeuille"
    
    # Créer répertoire FACT0RN
    mkdir -p /root/.factorn
    chmod 700 /root/.factorn
    
    # Configuration factorn.conf
    cat > /root/.factorn/factorn.conf << EOF
# Network
server=1
rpcuser=$RPC_USER
rpcpassword=$RPC_PASS
rpcallowip=127.0.0.1
rpcport=$RPC_PORT

# Node settings
daemon=1
pid=/tmp/factornd.pid
logips=1
maxconnections=256

# Wallet
wallet=default
keypool=100

# Logging
debug=1
debugexclude=libevent
loglevel=info

# Performance
dbcache=4000
maxmempool=300
EOF
    
    chmod 600 /root/.factorn/factorn.conf
    
    log_success "Configuration RPC: $RPC_USER:$RPC_PASS"
    log_info "Port RPC: $RPC_PORT"
}

##############################################################################
# PHASE 4: Création du .env docker-compose
##############################################################################

phase_create_env() {
    log_info "PHASE 4: Création du fichier .env"
    
    # Encoder la clé privée en base64 (sera utilisée par les workers)
    SSH_KEY_B64=$(cat "$SSH_PRIV_KEY_FILE" 2>/dev/null | base64 -w0 || echo "")
    
    cat > "$INSTALL_PREFIX/.env" << EOF
# ========== SSH Configuration ==========
SSH_HOST=$POOL_HOST
SSH_USER=serveurdechames
SSH_PORT=22
SSH_KEY_B64=$SSH_KEY_B64

# ========== CADO-NFS Configuration ==========
CADO_SERVER_PORT=$CADO_SERVER_PORT
CADO_TIMEOUT=86400
CADO_IMAGE=cado-nfs:latest

# ========== RPC Configuration ==========
RPC_HOST=$RPC_HOST
RPC_PORT=$RPC_PORT
RPC_USER=$RPC_USER
RPC_PASS=$RPC_PASS

# ========== Network Configuration ==========
TESTNET=false
CERT_SHA1=80cc669f45fcd8144d7934dd7b74e138b4fa05e7

# ========== GPU Configuration ==========
GPU_ENABLED=$GPU_ENABLED
GPU_DEVICE=$GPU_DEVICE
CUDA_ARCH=$CUDA_ARCH

# ========== Paths ==========
WORK_DIR=$WORK_DIR
CONFIG_DIR=$CONFIG_DIR

# ========== Logging ==========
LOG_LEVEL=INFO
PYTHONUNBUFFERED=1
EOF
    
    chmod 600 "$INSTALL_PREFIX/.env"
    log_success "Fichier .env créé"
}

##############################################################################
# PHASE 5: Téléchargement des scripts
##############################################################################

phase_download_scripts() {
    log_info "PHASE 5: Téléchargement des scripts"
    
    # Créer un script proxy pour les téléchargements
    # (en production, vous utiliseriez git clone ou curl vers vos repos)
    
    log_info "Scripts source:"
    log_info "  - orchestrator.py"
    log_info "  - n_detector.py"
    log_info "  - result_submitter.py"
    log_info "  - entrypoint.sh"
    log_info ""
    log_warn "À faire manuellement ou via git:"
    log_warn "  cp orchestrator.py $INSTALL_PREFIX/master/"
    log_warn "  cp n_detector.py $INSTALL_PREFIX/detector/"
    log_warn "  cp result_submitter.py $INSTALL_PREFIX/submitter/"
    log_warn "  cp entrypoint.sh $INSTALL_PREFIX/slave/"
    log_warn "  cp Dockerfiles $INSTALL_PREFIX/"
    log_warn "  cp docker-compose.yml $INSTALL_PREFIX/"
}

##############################################################################
# PHASE 6: Build des images Docker
##############################################################################

phase_build_docker() {
    log_info "PHASE 6: Build des images Docker"
    
    cd "$INSTALL_PREFIX"
    
    # Vérifier que les Dockerfiles existent
    if [ ! -f "docker-compose.yml" ]; then
        log_error "docker-compose.yml non trouvé dans $INSTALL_PREFIX"
        log_error "Veuillez copier docker-compose.yml"
        exit 1
    fi
    
    log_info "Building Docker images..."
    docker-compose build --no-cache
    
    log_success "Images Docker compilées"
}

##############################################################################
# PHASE 7: Démarrage des services
##############################################################################

phase_start_services() {
    log_info "PHASE 7: Démarrage des services"
    
    cd "$INSTALL_PREFIX"
    
    # Créer les volumes de travail
    mkdir -p "$WORK_DIR"/{detector,orchestrator,submitter}
    mkdir -p "$WORK_DIR"/slave-{1,2,3,4}
    
    # Démarrer docker-compose
    log_info "Démarrage de docker-compose..."
    docker-compose up -d
    
    # Attendre l'initialisation
    sleep 10
    
    # Vérifier les services
    log_info "État des services:"
    docker-compose ps
    
    log_success "Services démarrés"
}

##############################################################################
# PHASE 8: Configuration du Faux Miner (Pool Listener)
##############################################################################

phase_setup_pool_listener() {
    log_info "PHASE 8: Configuration du Pool Listener"
    
    # Créer un script de test pour vérifier la connexion à la pool
    mkdir -p "$CONFIG_DIR/pool_utils"
    
    cat > "$CONFIG_DIR/pool_utils/test_pool.sh" << 'EOF'
#!/bin/bash
POOL_HOST="91.69.7.150"
POOL_PORT="33093"

echo "Test de connexion à la pool..."
echo "Host: $POOL_HOST"
echo "Port: $POOL_PORT"

# Test de port ouvert
if timeout 5 bash -c "echo >/dev/tcp/$POOL_HOST/$POOL_PORT" 2>/dev/null; then
    echo "✓ Pool accessible"
else
    echo "✗ Impossible de se connecter à la pool"
fi

# Voir les fichiers N
echo ""
echo "Fichiers N dans /tmp/cado_work:"
ls -lh /tmp/cado_work/*_*.dat 2>/dev/null | tail -5 || echo "Aucun fichier N trouvé"
EOF
    
    chmod +x "$CONFIG_DIR/pool_utils/test_pool.sh"
    
    log_success "Pool listener configuré"
    log_info "Pour tester: $CONFIG_DIR/pool_utils/test_pool.sh"
}

##############################################################################
# PHASE 9: Configuration du Monitoring
##############################################################################

phase_setup_monitoring() {
    log_info "PHASE 9: Configuration du Monitoring"
    
    # Créer un script de monitoring
    cat > "$CONFIG_DIR/monitor.sh" << 'EOF'
#!/bin/bash

while true; do
    clear
    echo "====== FACT0RN Pipeline Status ======"
    echo ""
    
    echo "Docker Containers:"
    docker ps --format "table {{.Names}}\t{{.Status}}"
    
    echo ""
    echo "Sessions Complétées:"
    find /factorization_work/session_*/factors.json 2>/dev/null | wc -l
    
    echo ""
    echo "Derniers résultats:"
    find /factorization_work/session_*/factors.json 2>/dev/null -exec ls -lt {} + | head -3
    
    echo ""
    echo "Fichiers N reçus:"
    ls -lt /tmp/cado_work/*_*.dat 2>/dev/null | wc -l
    
    echo ""
    sleep 5
done
EOF
    
    chmod +x "$CONFIG_DIR/monitor.sh"
    
    log_success "Monitoring script créé"
    log_info "Pour utiliser: $CONFIG_DIR/monitor.sh"
}

##############################################################################
# PHASE 10: Tests et Vérifications
##############################################################################

phase_tests() {
    log_info "PHASE 10: Tests et Vérifications"
    
    cd "$INSTALL_PREFIX"
    
    # Test 1: Docker-compose
    log_info "Test 1: docker-compose status"
    docker-compose ps
    
    # Test 2: Logs
    log_info "Test 2: Vérification des logs"
    echo "Logs du n-detector:"
    docker-compose logs --tail=5 n-detector 2>/dev/null || echo "Service non disponible"
    
    echo ""
    echo "Logs de l'orchestrator:"
    docker-compose logs --tail=5 orchestrator 2>/dev/null || echo "Service non disponible"
    
    # Test 3: Connectivité
    log_info "Test 3: Connectivité"
    echo "RPC Node:"
    curl -s --user "$RPC_USER:$RPC_PASS" \
        --data-binary '{"jsonrpc": "1.0", "id":"test", "method": "getblockcount", "params": []}' \
        -H 'content-type: text/plain;' \
        http://127.0.0.1:$RPC_PORT/ || echo "RPC indisponible"
    
    log_success "Tests complétés"
}

##############################################################################
# PHASE 11: Rapport Final
##############################################################################

phase_summary() {
    log_info "PHASE 11: Rapport Final"
    
    echo ""
    echo "======================================"
    echo "FACT0RN Master Deployment Complete!"
    echo "======================================"
    echo ""
    echo "📁 Installation:"
    echo "  Root: $INSTALL_PREFIX"
    echo "  Work: $WORK_DIR"
    echo "  Config: $CONFIG_DIR"
    echo ""
    echo "🔑 SSH Public Key Added:"
    echo "  root@pop-os"
    echo ""
    echo "💻 Services:"
    echo "  - n-detector: Détecte les N de la pool"
    echo "  - orchestrator: Orchestre la factorisation"
    echo "  - slave-1/2/3/4: Workers CADO-NFS"
    echo "  - result-submitter: Valide et soumet les résultats"
    echo ""
    echo "🌐 RPC Configuration:"
    echo "  Host: $RPC_HOST"
    echo "  Port: $RPC_PORT"
    echo "  User: $RPC_USER"
    echo "  Pass: $RPC_PASS"
    echo ""
    echo "📊 GPU:"
    echo "  Enabled: $GPU_ENABLED"
    if [ "$GPU_ENABLED" = "true" ]; then
        echo "  Device: $GPU_DEVICE"
        echo "  CUDA Arch: $CUDA_ARCH"
    fi
    echo ""
    echo "🔗 Pool:"
    echo "  Host: $POOL_HOST"
    echo "  Port: $POOL_PORT"
    echo ""
    echo "📝 Logs:"
    echo "  docker-compose logs -f n-detector"
    echo "  docker-compose logs -f orchestrator"
    echo "  docker-compose logs -f slave-1"
    echo "  docker-compose logs -f result-submitter"
    echo ""
    echo "🚀 Next Steps:"
    echo "  1. Placer les scripts Python et Dockerfiles"
    echo "  2. Vérifier: cd $INSTALL_PREFIX && docker-compose ps"
    echo "  3. Lancer: cd $INSTALL_PREFIX && docker-compose up -d"
    echo "  4. Monitorer: $CONFIG_DIR/monitor.sh"
    echo ""
    echo "======================================"
}

##############################################################################
# MAIN
##############################################################################

main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║       FACT0RN Master Deployment Script                     ║"
    echo "║       Full Pipeline with GPU, Pool Listener & N Detector   ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    
    phase_prerequisites
    echo ""
    
    phase_setup_directories
    echo ""
    
    phase_setup_ssh
    echo ""
    
    phase_setup_rpc
    echo ""
    
    phase_create_env
    echo ""
    
    phase_setup_pool_listener
    echo ""
    
    phase_setup_monitoring
    echo ""
    
    # Les phases suivantes nécessitent les fichiers sources
    log_warn "Les phases suivantes nécessitent les fichiers sources:"
    log_warn "  - Docker images"
    log_warn "  - Scripts Python"
    log_warn "  - Dockerfiles"
    echo ""
    
    phase_summary
}

main "$@"
