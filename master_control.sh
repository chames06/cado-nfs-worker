#!/bin/bash
set -e

# =============================================================================
# Configuration
# =============================================================================
WORK_DIR="/opt/factoring"
CADO_DIR="/opt/cado-nfs"
SIEVING_DIR="/tmp/sieving"
FACTORED_FILE="$WORK_DIR/factored_numbers.txt"
PENDING_FILE="$WORK_DIR/pending_numbers.txt"
RESULTS_FILE="$WORK_DIR/results/factorizations.txt"
LOG_FILE="$WORK_DIR/logs/master.log"

MSIEVE_TIMEOUT="${MSIEVE_TIMEOUT:-120}"
CADO_PORT="${CADO_SERVER_PORT:-3001}"
WORKER_CONTAINER="fact-worker"
MSIEVE_IMAGE="cha256/msieve-cuda"

# Couleurs
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# =============================================================================
# Logging
# =============================================================================
log() { 
    echo -e "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"
}
log_success() { log "${GREEN}✓${NC} $1"; }
log_error() { log "${RED}✗${NC} $1"; }
log_warning() { log "${YELLOW}⚠${NC} $1"; }
log_info() { log "${BLUE}ℹ${NC} $1"; }
log_step() { log "${CYAN}▶${NC} $1"; }

# =============================================================================
# Initialisation
# =============================================================================
init() {
    mkdir -p "$WORK_DIR"/{jobs,results,logs} "$SIEVING_DIR"
    touch "$FACTORED_FILE" "$PENDING_FILE" "$RESULTS_FILE"
    log_info "Répertoires initialisés"
}

# =============================================================================
# Tracking
# =============================================================================
is_factored() { grep -q "^${1}$" "$FACTORED_FILE" 2>/dev/null; }
is_pending() { grep -q "^${1}$" "$PENDING_FILE" 2>/dev/null; }
mark_pending() { is_pending "$1" || echo "$1" >> "$PENDING_FILE"; }
unmark_pending() { sed -i "/^${1}$/d" "$PENDING_FILE" 2>/dev/null || true; }

mark_factored() {
    local N="$1" factor="$2"
    echo "$N" >> "$FACTORED_FILE"
    unmark_pending "$N"
    echo "$N,$factor" >> "$RESULTS_FILE"
    log_success "══════════════════════════════════════════"
    log_success "  RÉSULTAT: N = $N"
    log_success "  Facteur  = $factor"
    log_success "══════════════════════════════════════════"
}

extract_number() {
    basename "$1" | cut -d'_' -f1
}

validate_number() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ ${#1} -ge 10 ]
}

# =============================================================================
# ÉTAPE 1: Démarrer le Worker FACT0RN
# =============================================================================
start_worker() {
    log ""
    log "╔══════════════════════════════════════════════════════════╗"
    log "║  ÉTAPE 1: Démarrage du Worker FACT0RN                    ║"
    log "╚══════════════════════════════════════════════════════════╝"
    log ""
    
    # Vérifier Docker socket
    if [ ! -S /var/run/docker.sock ]; then
        log_error "Socket Docker non monté!"
        return 1
    fi
    log_success "Socket Docker OK"
    
    # Nettoyer ancien worker
    if docker ps -a --format '{{.Names}}' | grep -q "$WORKER_CONTAINER"; then
        log_warning "Ancien worker détecté, suppression..."
        docker stop "$WORKER_CONTAINER" 2>/dev/null || true
        docker rm "$WORKER_CONTAINER" 2>/dev/null || true
        sleep 2
    fi
    
    # Télécharger setup_worker.sh
    log_step "Téléchargement setup_worker.sh..."
    cd /tmp
    rm -f setup_worker.sh start_worker.sh
    
    wget -q -O setup_worker.sh \
        "https://github.com/filthz/fact-worker-public/releases/download/base_files/setup_worker.sh"
    
    if [ ! -f setup_worker.sh ]; then
        log_error "Échec téléchargement"
        return 1
    fi
    log_success "setup_worker.sh téléchargé"
    
    # Exécuter setup_worker.sh
    log_step "Exécution setup_worker.sh..."
    chmod +x setup_worker.sh
    sh setup_worker.sh "${POOL_USERNAME:-gappydesevran}" "${POOL_PASSWORD:-FPV8V5He}" 2>&1 | tee -a "$LOG_FILE"
    
    sleep 3
    
    # Chercher et lancer start_worker.sh
    if [ -f /tmp/start_worker.sh ]; then
        log_step "Lancement start_worker.sh..."
        chmod +x /tmp/start_worker.sh
        sh /tmp/start_worker.sh 2>&1 | tee -a "$LOG_FILE" &
        sleep 10
    else
        log_warning "start_worker.sh non trouvé dans /tmp"
        # Chercher ailleurs
        local found=$(find / -name "start_worker.sh" -type f 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            log_info "Trouvé: $found"
            chmod +x "$found"
            sh "$found" 2>&1 | tee -a "$LOG_FILE" &
            sleep 10
        fi
    fi
    
    # Vérifier
    if docker ps --format '{{.Names}}' | grep -q "$WORKER_CONTAINER"; then
        log_success "Worker '$WORKER_CONTAINER' démarré!"
        docker ps --filter "name=$WORKER_CONTAINER"
    else
        log_warning "Worker pas visible, affichage de tous les containers:"
        docker ps -a
    fi
    
    return 0
}

# =============================================================================
# ÉTAPE 2: Récupérer les fichiers .dat depuis fact-worker
# =============================================================================
fetch_dat_files() {
    # Vérifier que le worker existe
    if ! docker ps --format '{{.Names}}' | grep -q "$WORKER_CONTAINER"; then
        return 1
    fi
    
    # Lister les fichiers .dat dans le worker
    local files=$(docker exec "$WORKER_CONTAINER" ls /tmp/sieving/ 2>/dev/null | grep "\.dat$" || true)
    
    if [ -z "$files" ]; then
        return 1
    fi
    
    # Copier chaque fichier
    for filename in $files; do
        local local_file="$SIEVING_DIR/$filename"
        
        if [ ! -f "$local_file" ]; then
            log_info "Nouveau fichier détecté: $filename"
            docker cp "$WORKER_CONTAINER:/tmp/sieving/$filename" "$local_file" 2>/dev/null
        fi
    done
    
    return 0
}

# =============================================================================
# ÉTAPE 3: Msieve Polynomial Selection (via cha256/msieve-cuda)
# =============================================================================
run_msieve() {
    local N="$1"
    local job_dir="$WORK_DIR/jobs/$N"
    local msieve_container="msieve-$N"
    
    log ""
    log "╔══════════════════════════════════════════════════════════╗"
    log "║  ÉTAPE 3: Msieve-CUDA Polynomial Selection               ║"
    log "╚══════════════════════════════════════════════════════════╝"
    log ""
    log_info "N = $N (${#N} chiffres)"
    log_info "Container: $MSIEVE_IMAGE"
    log_info "Timeout: ${MSIEVE_TIMEOUT}s"
    
    mkdir -p "$job_dir"
    
    # Nettoyer ancien container msieve
    docker stop "$msieve_container" 2>/dev/null || true
    docker rm "$msieve_container" 2>/dev/null || true
    
    # Lancer le container msieve-cuda
    log_step "Lancement $MSIEVE_IMAGE..."
    
    # Essayer avec GPU
    if docker run -d --name "$msieve_container" --gpus all "$MSIEVE_IMAGE" sleep infinity 2>/dev/null; then
        log_success "Container lancé avec GPU"
    else
        log_warning "GPU non disponible, lancement CPU..."
        docker run -d --name "$msieve_container" "$MSIEVE_IMAGE" sleep infinity || {
            log_error "Impossible de lancer le container msieve"
            return 1
        }
    fi
    
    # Installer dépendances dans le container
    log_step "Installation dépendances..."
    docker exec "$msieve_container" bash -c "
        apt-get update -qq > /dev/null 2>&1
        apt-get install -y -qq libecm-dev libgmp-dev > /dev/null 2>&1
    " || log_warning "Installation dépendances échouée (peut-être déjà installées)"
    
    # Créer worktodo.ini
    log_step "Création worktodo.ini avec N..."
    docker exec "$msieve_container" bash -c "echo '$N' > /app/msieve/worktodo.ini"
    
    # Afficher le contenu pour vérification
    docker exec "$msieve_container" cat /app/msieve/worktodo.ini
    
    # Compiler msieve si nécessaire
    log_step "Compilation msieve..."
    docker exec -w /app/msieve "$msieve_container" bash -c "
        make clean > /dev/null 2>&1 || true
        make CUDA=1 ECM=1 -j\$(nproc) 2>&1 || make ECM=1 -j\$(nproc) 2>&1 || make -j\$(nproc) 2>&1
    " | tail -5
    
    # Lancer msieve -np
    log_step "Lancement msieve -np (polynomial selection)..."
    log_info "Durée: ~${MSIEVE_TIMEOUT} secondes"
    
    docker exec -w /app/msieve "$msieve_container" bash -c "
        timeout ${MSIEVE_TIMEOUT} ./msieve -np -v 2>&1 || true
    " 2>&1 | tee "$job_dir/msieve.log" &
    
    local pid=$!
    
    # Afficher progression
    local elapsed=0
    while kill -0 $pid 2>/dev/null && [ $elapsed -lt $MSIEVE_TIMEOUT ]; do
        sleep 15
        elapsed=$((elapsed + 15))
        log_info "Msieve: ${elapsed}s / ${MSIEVE_TIMEOUT}s"
    done
    
    wait $pid 2>/dev/null || true
    log_success "Polynomial selection terminée"
    
    # Récupérer msieve.fb depuis /app/msieve/
    log_step "Récupération msieve.fb depuis /app/msieve/..."
    
    if docker exec "$msieve_container" test -f /app/msieve/msieve.fb; then
        docker cp "$msieve_container:/app/msieve/msieve.fb" "$job_dir/msieve.fb"
        
        if [ -f "$job_dir/msieve.fb" ] && [ -s "$job_dir/msieve.fb" ]; then
            log_success "msieve.fb récupéré ($(wc -c < "$job_dir/msieve.fb") bytes)"
            log_info "Contenu:"
            head -15 "$job_dir/msieve.fb" | while read l; do log "  $l"; done
            
            # Nettoyer
            docker stop "$msieve_container" 2>/dev/null || true
            docker rm "$msieve_container" 2>/dev/null || true
            
            return 0
        else
            log_error "msieve.fb vide ou non copié"
        fi
    else
        log_error "msieve.fb non trouvé dans /app/msieve/"
        log_info "Contenu de /app/msieve/:"
        docker exec "$msieve_container" ls -la /app/msieve/ 2>&1 | head -20
    fi
    
    # Nettoyer en cas d'erreur
    docker stop "$msieve_container" 2>/dev/null || true
    docker rm "$msieve_container" 2>/dev/null || true
    
    return 1
}

# =============================================================================
# ÉTAPE 4: Conversion polynôme
# =============================================================================
convert_poly() {
    local N="$1"
    local job_dir="$WORK_DIR/jobs/$N"
    
    log ""
    log "╔══════════════════════════════════════════════════════════╗"
    log "║  ÉTAPE 4: Conversion Msieve → CADO-NFS                   ║"
    log "╚══════════════════════════════════════════════════════════╝"
    log ""
    
    if [ ! -f "$job_dir/msieve.fb" ]; then
        log_error "msieve.fb manquant"
        return 1
    fi
    
    log_step "Conversion avec convert_poly.py..."
    python3 /usr/local/bin/convert_poly.py "$job_dir/msieve.fb" "$job_dir/factor.poly"
    
    if [ -f "$job_dir/factor.poly" ] && [ -s "$job_dir/factor.poly" ]; then
        log_success "factor.poly créé"
        cat "$job_dir/factor.poly" | while read l; do log "  $l"; done
        return 0
    else
        log_error "Conversion échouée"
        return 1
    fi
}

# =============================================================================
# ÉTAPE 5: CADO-NFS Factorisation
# =============================================================================
run_cado() {
    local N="$1"
    local job_dir="$WORK_DIR/jobs/$N"
    local cado_work="$job_dir/cado_work"
    
    log ""
    log "╔══════════════════════════════════════════════════════════╗"
    log "║  ÉTAPE 5: CADO-NFS Factorisation                         ║"
    log "╚══════════════════════════════════════════════════════════╝"
    log ""
    log_info "N = $N"
    log_info "Port serveur: $CADO_PORT"
    
    mkdir -p "$cado_work"
    cd "$CADO_DIR"
    
    # Construire commande
    local cmd="python3 ./cado-nfs.py $N"
    cmd="$cmd --no-checksum"
    cmd="$cmd server.port=$CADO_PORT"
    cmd="$cmd tasks.workdir=$cado_work"
    
    if [ -f "$job_dir/factor.poly" ] && [ -s "$job_dir/factor.poly" ]; then
        cmd="$cmd tasks.polyselect.import=$job_dir/factor.poly"
        log_info "Polynôme pré-calculé utilisé"
    fi
    
    log_step "Commande:"
    log "  $cmd"
    log ""
    log "═══════════════════════════════════════════════════════════"
    log "  CADO-NFS en cours (peut prendre plusieurs heures)..."
    log "═══════════════════════════════════════════════════════════"
    
    # Exécuter
    eval $cmd 2>&1 | tee "$job_dir/cado.log"
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        log_success "CADO-NFS terminé avec succès"
        
        # Extraire les facteurs
        # Format typique: "N = p * q" ou juste les facteurs sur une ligne
        local factor=""
        
        # Chercher dans différents formats
        factor=$(grep -oP '(?<=^)\d{10,}(?= \d)' "$job_dir/cado.log" 2>/dev/null | head -1)
        
        if [ -z "$factor" ]; then
            # Autre format: chercher les lignes avec des grands nombres
            factor=$(grep -E '^\d{10,}$' "$job_dir/cado.log" 2>/dev/null | sort -n | head -1)
        fi
        
        if [ -z "$factor" ]; then
            # Chercher dans la sortie finale
            factor=$(tail -50 "$job_dir/cado.log" | grep -oP '\d{10,}' | sort -n | head -1)
        fi
        
        if [ -n "$factor" ] && [ "$factor" != "$N" ]; then
            echo "$factor" > "$job_dir/smallest_factor.txt"
            mark_factored "$N" "$factor"
            return 0
        else
            log_warning "Facteurs non extraits, vérifiez le log manuellement"
            log_info "Dernières lignes du log:"
            tail -20 "$job_dir/cado.log"
        fi
    fi
    
    log_error "CADO-NFS échoué ou facteurs non trouvés"
    unmark_pending "$N"
    return 1
}

# =============================================================================
# Pipeline complet
# =============================================================================
process_number() {
    local N="$1"
    local job_dir="$WORK_DIR/jobs/$N"
    
    log ""
    log "╔══════════════════════════════════════════════════════════════════╗"
    log "║  PIPELINE DE FACTORISATION                                       ║"
    log "║  N = $N"
    log "║  (${#N} chiffres)                                                     ║"
    log "╚══════════════════════════════════════════════════════════════════╝"
    log ""
    
    mkdir -p "$job_dir"
    echo "$(date) - Début pipeline" > "$job_dir/status.txt"
    
    # Étape 3: Msieve (via cha256/msieve-cuda)
    if ! run_msieve "$N"; then
        echo "$(date) - ÉCHEC Msieve" >> "$job_dir/status.txt"
        unmark_pending "$N"
        return 1
    fi
    echo "$(date) - Msieve OK" >> "$job_dir/status.txt"
    
    # Étape 4: Conversion
    if ! convert_poly "$N"; then
        echo "$(date) - ÉCHEC conversion" >> "$job_dir/status.txt"
        unmark_pending "$N"
        return 1
    fi
    echo "$(date) - Conversion OK" >> "$job_dir/status.txt"
    
    # Étape 5: CADO-NFS
    if ! run_cado "$N"; then
        echo "$(date) - ÉCHEC CADO-NFS" >> "$job_dir/status.txt"
        unmark_pending "$N"
        return 1
    fi
    echo "$(date) - FACTORISÉ!" >> "$job_dir/status.txt"
    
    log ""
    log "╔══════════════════════════════════════════════════════════╗"
    log "║  ✓✓✓ FACTORISATION RÉUSSIE! ✓✓✓                          ║"
    log "╚══════════════════════════════════════════════════════════╝"
    
    return 0
}

# =============================================================================
# Traiter un fichier .dat
# =============================================================================
process_dat() {
    local filepath="$1"
    local filename=$(basename "$filepath")
    
    log_info "Fichier: $filename"
    
    local N=$(extract_number "$filename")
    
    if ! validate_number "$N"; then
        log_warning "Nombre invalide: '$N'"
        return 1
    fi
    
    log_info "N = $N (${#N} chiffres)"
    
    if is_factored "$N"; then
        log_warning "Déjà factorisé"
        return 0
    fi
    
    if is_pending "$N"; then
        log_warning "Déjà en cours"
        return 0
    fi
    
    mark_pending "$N"
    
    # Lancer en arrière-plan
    process_number "$N" &
    
    return 0
}

# =============================================================================
# Boucle de surveillance
# =============================================================================
watch_loop() {
    log ""
    log "╔══════════════════════════════════════════════════════════╗"
    log "║  SURVEILLANCE DES FICHIERS .dat                          ║"
    log "╚══════════════════════════════════════════════════════════╝"
    log ""
    
    declare -A seen_files
    
    while true; do
        # Récupérer les fichiers depuis fact-worker
        fetch_dat_files 2>/dev/null
        
        # Traiter les nouveaux fichiers
        for f in "$SIEVING_DIR"/*.dat 2>/dev/null; do
            if [ -f "$f" ] && [ -z "${seen_files[$f]}" ]; then
                seen_files[$f]=1
                process_dat "$f"
            fi
        done
        
        # Afficher status
        local factored=$(wc -l < "$FACTORED_FILE" 2>/dev/null || echo 0)
        local pending=$(wc -l < "$PENDING_FILE" 2>/dev/null || echo 0)
        local dats=$(ls -1 "$SIEVING_DIR"/*.dat 2>/dev/null | wc -l || echo 0)
        
        log "─── Status: .dat=$dats | pending=$pending | factorisés=$factored ───"
        
        sleep 30
    done
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    log ""
    log "╔══════════════════════════════════════════════════════════════════╗"
    log "║   MASTER FACT0RN Pipeline v5                                     ║"
    log "║   $(date '+%Y-%m-%d %H:%M:%S')                                             ║"
    log "╚══════════════════════════════════════════════════════════════════╝"
    log ""
    log "Configuration:"
    log "  Pool User: ${POOL_USERNAME:-gappydesevran}"
    log "  CADO Port: $CADO_PORT"
    log "  Msieve Image: $MSIEVE_IMAGE"
    log "  Msieve Timeout: ${MSIEVE_TIMEOUT}s"
    log ""
    
    # Init
    init
    
    # Vérifications
    [ -f "$CADO_DIR/cado-nfs.py" ] && log_success "CADO-NFS OK" || { log_error "CADO-NFS manquant"; exit 1; }
    [ -f "/usr/local/bin/convert_poly.py" ] && log_success "convert_poly.py OK"
    
    # Vérifier que l'image msieve-cuda est disponible
    log_step "Vérification image $MSIEVE_IMAGE..."
    if docker pull "$MSIEVE_IMAGE" 2>&1 | tail -3; then
        log_success "Image $MSIEVE_IMAGE disponible"
    else
        log_warning "Impossible de pull l'image (sera tentée plus tard)"
    fi
    
    # Étape 1: Démarrer le worker
    start_worker || log_warning "Worker non démarré, surveillance locale uniquement"
    
    # Boucle de surveillance
    watch_loop
}

main "$@"
