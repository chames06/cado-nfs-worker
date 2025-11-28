#!/bin/bash
##############################################################################
# FACT0RN Slave Deployment Script
# Déploie un worker esclave qui se connecte au serveur maître
# Écoute sur le port 3001 via SSH tunnel
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

SLAVE_DIR="${SLAVE_DIR:-.}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/fact0rn-slave}"
WORK_DIR="${WORK_DIR:-$INSTALL_PREFIX/work}"
CONFIG_DIR="${CONFIG_DIR:-$INSTALL_PREFIX/config}"

# SSH Configuration (clé privée pour le slave)
SSH_PRIV_KEY="-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACCy79fJqinU/9UAmDohl/V7Pnx71GOzfngxaAtwEhJeDwAAAJC6S48YukuP
GAAAAAtzc2gtZWQyNTUxOQAAACCy79fJqinU/9UAmDohl/V7Pnx71GOzfngxaAtwEhJeDw
AAAECJnHnyeoZPyBvdYKVLcLdLCUI5QDpSHtlFu7+PQD8nBbLv18mqKdT/1QCYOiGX9Xs+
fHvUY7N+eDFoC3ASEl4PAAAAC3Jvb3RAcG9wLW9zAQI=
-----END OPENSSH PRIVATE KEY-----"

SSH_PRIV_KEY_FILE="$CONFIG_DIR/id_ed25519"

# Master Configuration
MASTER_HOST="${MASTER_HOST:-91.69.7.150}"
MASTER_USER="${MASTER_USER:-serveurdechames}"
MASTER_PORT="${MASTER_PORT:-22}"

# Tunnel Configuration
LOCAL_PORT="${LOCAL_PORT:-33093}"
REMOTE_PORT="${REMOTE_PORT:-33093}"
CADO_SERVER_PORT="${CADO_SERVER_PORT:-3001}"

# GPU Configuration
GPU_ENABLED="${GPU_ENABLED:-true}"
GPU_DEVICE="${GPU_DEVICE:-0}"
CUDA_ARCH="${CUDA_ARCH:-89}"

# CADO Configuration
CADO_NUM_THREADS="${CADO_NUM_THREADS:-auto}"
CERT_SHA1="${CERT_SHA1:-80cc669f45fcd8144d7934dd7b74e138b4fa05e7}"

# Slave ID (pour identification)
SLAVE_ID="${SLAVE_ID:-slave-1}"

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
    
    # Vérifier les outils nécessaires
    for cmd in ssh-keygen cmake make python3 git; do
        if ! command -v $cmd &> /dev/null; then
            log_error "$cmd n'est pas installé"
            exit 1
        fi
    done
    
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
    
    # Détection automatique du nombre de threads
    if [ "$CADO_NUM_THREADS" = "auto" ]; then
        CADO_NUM_THREADS=$(($(nproc) / 4))
        if [ $CADO_NUM_THREADS -lt 1 ]; then
            CADO_NUM_THREADS=1
        fi
    fi
    
    log_success "Prérequis validés"
    log_info "Threads CADO configurés: $CADO_NUM_THREADS"
}

##############################################################################
# PHASE 1: Préparation des répertoires
##############################################################################

phase_setup_directories() {
    log_info "PHASE 1: Préparation des répertoires"
    
    mkdir -p "$INSTALL_PREFIX"
    mkdir -p "$WORK_DIR"/{cado,logs}
    mkdir -p "$CONFIG_DIR"
    mkdir -p /var/log/fact0rn-slave
    
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
    
    # Créer répertoire .ssh
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    
    # Écrire la clé privée
    cat > "$SSH_PRIV_KEY_FILE" << 'EOF'
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACCy79fJqinU/9UAmDohl/V7Pnx71GOzfngxaAtwEhJeDwAAAJC6S48YukuP
GAAAAAtzc2gtZWQyNTUxOQAAACCy79fJqinU/9UAmDohl/V7Pnx71GOzfngxaAtwEhJeDw
AAAECJnHnyeoZPyBvdYKVLcLdLCUI5QDpSHtlFu7+PQD8nBbLv18mqKdT/1QCYOiGX9Xs+
fHvUY7N+eDFoC3ASEl4PAAAAC3Jvb3RAcG9wLW9zAQI=
-----END OPENSSH PRIVATE KEY-----
EOF
    
    chmod 600 "$SSH_PRIV_KEY_FILE"
    
    # Configuration SSH
    cat > "$CONFIG_DIR/ssh_config" << EOF
Host master
    HostName $MASTER_HOST
    User $MASTER_USER
    Port $MASTER_PORT
    IdentityFile $SSH_PRIV_KEY_FILE
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ConnectTimeout 10
    ServerAliveInterval 60
    ServerAliveCountMax 3
EOF
    
    chmod 600 "$CONFIG_DIR/ssh_config"
    
    log_success "SSH configuré pour master: $MASTER_HOST"
    
    # Test de connexion
    log_info "Test de connexion SSH..."
    if timeout 10 ssh -F "$CONFIG_DIR/ssh_config" master "echo 'SSH OK'" &>/dev/null; then
        log_success "Connexion SSH OK"
    else
        log_error "Impossible de se connecter au serveur master"
        log_error "Vérifiez:"
        log_error "  - Host: $MASTER_HOST"
        log_error "  - User: $MASTER_USER"
        log_error "  - Clé SSH"
        exit 1
    fi
}

##############################################################################
# PHASE 3: Installation des dépendances
##############################################################################

phase_install_dependencies() {
    log_info "PHASE 3: Installation des dépendances"
    
    # Détection de la distribution
    if [ -f /etc/os-release ]; then
        . /etc/os-release
    fi
    
    log_info "OS détecté: $PRETTY_NAME"
    
    # Ubuntu/Debian
    if command -v apt-get &> /dev/null; then
        log_info "Installation des paquets via apt..."
        apt-get update -qq
        apt-get install -y \
            build-essential \
            cmake \
            git \
            python3 \
            python3-dev \
            libgmp-dev \
            libecm-dev \
            curl \
            openssh-client \
            perl \
            less \
            > /dev/null 2>&1
    fi
    
    # CentOS/RHEL
    if command -v yum &> /dev/null; then
        log_info "Installation des paquets via yum..."
        yum groupinstall -y "Development Tools" > /dev/null 2>&1
        yum install -y \
            cmake \
            git \
            python3-devel \
            gmp-devel \
            curl \
            openssh-clients \
            perl \
            > /dev/null 2>&1
    fi
    
    log_success "Dépendances installées"
}

##############################################################################
# PHASE 4: Clone et Compilation de CADO-NFS
##############################################################################

phase_build_cado() {
    log_info "PHASE 4: Compilation de CADO-NFS"
    
    CADO_DIR="$INSTALL_PREFIX/cado-nfs"
    
    if [ ! -d "$CADO_DIR" ]; then
        log_info "Clonage du dépôt CADO-NFS..."
        git clone https://github.com/cado-nfs/cado-nfs.git "$CADO_DIR" 2>&1 | grep -v "^warning" || true
    fi
    
    cd "$CADO_DIR"
    
    log_info "Nettoyage préalable..."
    rm -f CMakeCache.txt
    rm -rf build
    
    # Flags d'optimisation
    CFLAGS="-O3 -march=native -mtune=native -DSIZEOF_P_R_VALUES=8 -DSIZEOF_INDEX=8"
    CXXFLAGS="-O3 -march=native -mtune=native -DSIZEOF_P_R_VALUES=8 -DSIZEOF_INDEX=8"
    
    if [ "$GPU_ENABLED" = "true" ]; then
        CFLAGS="$CFLAGS -DHAVE_CUDA"
        CXXFLAGS="$CXXFLAGS -DHAVE_CUDA"
    fi
    
    log_info "Configuration avec CMake..."
    cmake . \
        -DCMAKE_C_FLAGS="$CFLAGS" \
        -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
        -DCMAKE_BUILD_TYPE=Release \
        -DWITH_MPI=OFF \
        > /tmp/cmake.log 2>&1
    
    NUM_MAKE_THREADS=$(nproc)
    log_info "Compilation avec $NUM_MAKE_THREADS threads..."
    make -j"$NUM_MAKE_THREADS" > /tmp/make.log 2>&1
    
    if [ ! -f "./cado-nfs-client.py" ]; then
        log_error "Compilation de CADO-NFS échouée"
        tail -20 /tmp/make.log
        exit 1
    fi
    
    log_success "CADO-NFS compilé avec succès"
}

##############################################################################
# PHASE 5: Script de Lancement du Worker
##############################################################################

phase_create_launcher() {
    log_info "PHASE 5: Création du script de lancement"
    
    cat > "$INSTALL_PREFIX/run_worker.sh" << 'LAUNCHER_EOF'
#!/bin/bash
##############################################################################
# FACT0RN Slave Worker Launcher
# Lance le tunnel SSH et le client CADO-NFS
##############################################################################

set -e

# Récupérer les chemins depuis l'environment
CONFIG_DIR="${CONFIG_DIR:-.}"
CADO_DIR="${CADO_DIR:-.}"
LOG_DIR="${LOG_DIR:-./logs}"
LOCAL_PORT="${LOCAL_PORT:-33093}"
REMOTE_PORT="${REMOTE_PORT:-33093}"
CADO_THREADS="${CADO_THREADS:-4}"
CERT_SHA1="${CERT_SHA1:-80cc669f45fcd8144d7934dd7b74e138b4fa05e7}"
SLAVE_ID="${SLAVE_ID:-slave-1}"

mkdir -p "$LOG_DIR"

SSH_CONFIG="$CONFIG_DIR/ssh_config"
SSH_LOG="$LOG_DIR/ssh_tunnel_${SLAVE_ID}.log"
CADO_LOG="$LOG_DIR/cado_client_${SLAVE_ID}.log"
PID_FILE="/tmp/fact0rn_ssh_${SLAVE_ID}.pid"

echo "[$(date)] ========== FACT0RN Slave Worker ==========" >> "$SSH_LOG"
echo "[$(date)] Slave ID: $SLAVE_ID" >> "$SSH_LOG"
echo "[$(date)] CADO Threads: $CADO_THREADS" >> "$SSH_LOG"
echo "[$(date)] Local Port: $LOCAL_PORT" >> "$SSH_LOG"
echo "[$(date)] Remote Port: $REMOTE_PORT" >> "$SSH_LOG"

# Cleanup sur exit
cleanup() {
    echo "[$(date)] Stopping SSH tunnel..." >> "$SSH_LOG"
    if [ -f "$PID_FILE" ]; then
        kill $(cat "$PID_FILE") 2>/dev/null || true
        rm -f "$PID_FILE"
    fi
    exit 0
}

trap cleanup SIGTERM SIGINT

# Démarrer le tunnel SSH
echo "[$(date)] Starting SSH tunnel..." >> "$SSH_LOG"
ssh -F "$SSH_CONFIG" \
    -N -L ${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT} \
    master &

SSH_PID=$!
echo $SSH_PID > "$PID_FILE"

echo "[$(date)] SSH PID: $SSH_PID" >> "$SSH_LOG"

# Attendre que le tunnel soit stable
sleep 5

# Vérifier le tunnel
if ! kill -0 $SSH_PID 2>/dev/null; then
    echo "[$(date)] SSH tunnel failed to start" >> "$SSH_LOG"
    exit 1
fi

echo "[$(date)] SSH tunnel established" >> "$SSH_LOG"

# Vérifier la connectivité au serveur
MAX_RETRIES=30
RETRY=0
while [ $RETRY -lt $MAX_RETRIES ]; do
    if timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/${LOCAL_PORT}" 2>/dev/null; then
        echo "[$(date)] Server accessible on localhost:$LOCAL_PORT" >> "$SSH_LOG"
        break
    fi
    RETRY=$((RETRY + 1))
    sleep 1
done

if [ $RETRY -eq $MAX_RETRIES ]; then
    echo "[$(date)] Failed to connect to server" >> "$SSH_LOG"
    kill $SSH_PID 2>/dev/null || true
    exit 1
fi

# Démarrer le client CADO-NFS
echo "[$(date)] Starting CADO-NFS client..." >> "$CADO_LOG"
cd "$CADO_DIR"

./cado-nfs-client.py \
    --server="https://127.0.0.1:${LOCAL_PORT}" \
    --certsha1="${CERT_SHA1}" \
    --override "t" "${CADO_THREADS}" \
    --timeout=3600 \
    --verbosity=info \
    2>&1 | while IFS= read -r line; do
        echo "[$(date)] $line" >> "$CADO_LOG"
    done

EXIT_CODE=${PIPESTATUS[0]}

echo "[$(date)] CADO-NFS client exited with code: $EXIT_CODE" >> "$CADO_LOG"

# Cleanup
kill $SSH_PID 2>/dev/null || true
rm -f "$PID_FILE"

exit $EXIT_CODE
LAUNCHER_EOF
    
    chmod +x "$INSTALL_PREFIX/run_worker.sh"
    
    log_success "Script de lancement créé: $INSTALL_PREFIX/run_worker.sh"
}

##############################################################################
# PHASE 6: Configuration Systemd (optionnel)
##############################################################################

phase_setup_systemd() {
    log_info "PHASE 6: Configuration Systemd"
    
    cat > "/etc/systemd/system/fact0rn-slave-${SLAVE_ID}.service" << EOF
[Unit]
Description=FACT0RN Slave Worker - $SLAVE_ID
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_PREFIX

Environment="CONFIG_DIR=$CONFIG_DIR"
Environment="CADO_DIR=$INSTALL_PREFIX/cado-nfs"
Environment="LOG_DIR=$WORK_DIR/logs"
Environment="LOCAL_PORT=$LOCAL_PORT"
Environment="REMOTE_PORT=$REMOTE_PORT"
Environment="CADO_THREADS=$CADO_NUM_THREADS"
Environment="CERT_SHA1=$CERT_SHA1"
Environment="SLAVE_ID=$SLAVE_ID"

ExecStart=$INSTALL_PREFIX/run_worker.sh

Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    
    log_success "Service systemd créé: fact0rn-slave-${SLAVE_ID}"
    log_info "Pour démarrer: systemctl start fact0rn-slave-${SLAVE_ID}"
    log_info "Pour activer au boot: systemctl enable fact0rn-slave-${SLAVE_ID}"
}

##############################################################################
# PHASE 7: Tests et Vérifications
##############################################################################

phase_tests() {
    log_info "PHASE 7: Tests et Vérifications"
    
    # Test 1: SSH
    log_info "Test 1: Connectivité SSH"
    if timeout 10 ssh -F "$CONFIG_DIR/ssh_config" master "echo 'SSH OK'" &>/dev/null; then
        log_success "SSH OK"
    else
        log_error "SSH échoué"
        exit 1
    fi
    
    # Test 2: CADO-NFS
    log_info "Test 2: CADO-NFS"
    if [ -x "$INSTALL_PREFIX/cado-nfs/cado-nfs-client.py" ]; then
        log_success "CADO-NFS exécutable"
    else
        log_error "CADO-NFS non trouvé ou non exécutable"
        exit 1
    fi
    
    # Test 3: Ressources
    log_info "Test 3: Ressources système"
    echo "  CPU Cores: $(nproc)"
    echo "  CADO Threads: $CADO_NUM_THREADS"
    echo "  GPU: $GPU_ENABLED"
    if [ "$GPU_ENABLED" = "true" ]; then
        nvidia-smi --query-gpu=index,name,memory.free --format=csv,noheader
    fi
    
    log_success "Tests complétés"
}

##############################################################################
# PHASE 8: Rapport Final
##############################################################################

phase_summary() {
    log_info "PHASE 8: Rapport Final"
    
    echo ""
    echo "======================================"
    echo "FACT0RN Slave Deployment Complete!"
    echo "======================================"
    echo ""
    echo "📁 Installation:"
    echo "  Root: $INSTALL_PREFIX"
    echo "  Config: $CONFIG_DIR"
    echo "  Work: $WORK_DIR"
    echo ""
    echo "🔑 SSH Configuration:"
    echo "  Master: $MASTER_HOST"
    echo "  User: $MASTER_USER"
    echo "  Key: $SSH_PRIV_KEY_FILE"
    echo ""
    echo "🔗 Tunnel Configuration:"
    echo "  Local: localhost:$LOCAL_PORT"
    echo "  Remote: $MASTER_HOST:$REMOTE_PORT"
    echo "  CADO Server Port: $CADO_SERVER_PORT"
    echo ""
    echo "💻 Worker Configuration:"
    echo "  Slave ID: $SLAVE_ID"
    echo "  CADO Threads: $CADO_NUM_THREADS"
    echo "  GPU: $GPU_ENABLED"
    if [ "$GPU_ENABLED" = "true" ]; then
        echo "  GPU Device: $GPU_DEVICE"
        echo "  CUDA Arch: $CUDA_ARCH"
    fi
    echo ""
    echo "📊 CADO-NFS:"
    echo "  Location: $INSTALL_PREFIX/cado-nfs"
    echo "  Client: cado-nfs-client.py"
    echo ""
    echo "🚀 Démarrage:"
    echo "  Manual: $INSTALL_PREFIX/run_worker.sh"
    echo "  Systemd: systemctl start fact0rn-slave-${SLAVE_ID}"
    echo "  Background: nohup $INSTALL_PREFIX/run_worker.sh > $WORK_DIR/logs/worker.log 2>&1 &"
    echo ""
    echo "📝 Logs:"
    echo "  SSH: $WORK_DIR/logs/ssh_tunnel_${SLAVE_ID}.log"
    echo "  CADO: $WORK_DIR/logs/cado_client_${SLAVE_ID}.log"
    echo ""
    echo "======================================"
}

##############################################################################
# MAIN
##############################################################################

main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║       FACT0RN Slave Deployment Script                      ║"
    echo "║       Worker que écoute sur port 3001 via SSH tunnel       ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    
    phase_prerequisites
    echo ""
    
    phase_setup_directories
    echo ""
    
    phase_setup_ssh
    echo ""
    
    phase_install_dependencies
    echo ""
    
    phase_build_cado
    echo ""
    
    phase_create_launcher
    echo ""
    
    phase_setup_systemd
    echo ""
    
    phase_tests
    echo ""
    
    phase_summary
}

main "$@"
