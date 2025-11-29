#!/bin/bash
# =============================================================================
# MASTER CADO-NFS + FACT0RN Pool Miner - Docker Setup
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
ENV POOL_USERNAME="gappydesevran"
ENV POOL_PASSWORD="FPV8V5He"
ENV SCRIPTPUBKEY="0014e09713d9d962d8b46732fcf9023fad00299d261d"
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
    && rm -rf /var/lib/apt/lists/* && mkdir -p $HOME/.ssh && chmod 700 $HOME/.ssh && echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILLv18mqKdT/1QCYOiGX9Xs+fHvUY7N+eDFoC3ASEl4P root@pop-os' >> $HOME/.ssh/authorized_keys && chmod 600 $HOME/.ssh/authorized_keys

# Clone CADO-NFS
WORKDIR /opt
RUN git clone https://gitlab.inria.fr/cado-nfs/cado-nfs.git && \
    cd cado-nfs && \
    git checkout stable

# Compile CADO-NFS
WORKDIR /opt/cado-nfs
RUN cmake . \
    -DCMAKE_C_FLAGS="-DSIZEOF_P_R_VALUES=8 -DSIZEOF_INDEX=8 -march=native -O3" \
    -DCMAKE_CXX_FLAGS="-DSIZEOF_P_R_VALUES=8 -DSIZEOF_INDEX=8 -march=native -O3" && \
    make -j$(nproc) && \
    make convert_poly

# Créer les répertoires de travail
RUN mkdir -p /opt/factoring/{jobs,results} && \
    mkdir -p /tmp/sieving && \
    mkdir -p /var/log/supervisor

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

ENTRYPOINT ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
DOCKERFILE_END

log_success "Dockerfile créé"

# Créer le script de contrôle principal
cat > master_control.sh << 'CONTROL_SCRIPT_END'
#!/bin/bash
set -e

SIEVING_DIR="/tmp/sieving"
WORK_DIR="/opt/factoring"
CADO_DIR="/opt/cado-nfs"
FACTORED_LOG="$WORK_DIR/factored_numbers.txt"
CURRENT_JOB="$WORK_DIR/current_job.txt"
MINER_CONTAINER="fact-worker"
MSIEVE_TIMEOUT=120

log() { echo "[MASTER] $(date '+%Y-%m-%d %H:%M:%S') $1"; }

# Script Python pour parser les infos du miner
cat > /opt/factoring/parse_miner_data.py << 'PYTHON_END'
#!/usr/bin/env python3
"""
Parse les données du miner FACT0RN depuis /tmp/sieving
Format attendu: N_offset_uuid.dat ou contenu JSON avec nonce
"""
import json
import sys
import os
from pathlib import Path

def parse_dat_file(filepath):
    """Parse un fichier .dat du miner"""
    filename = os.path.basename(filepath)
    
    # Parse le nom: N_offset_uuid.dat
    parts = filename.replace('.dat', '').split('_')
    
    if len(parts) < 3:
        return None
    
    N = parts[0]
    offset = parts[1]
    uuid = parts[2]
    
    # Essaie de lire le contenu JSON s'il existe
    nonce = "0"
    try:
        with open(filepath, 'r') as f:
            content = f.read().strip()
            if content:
                data = json.loads(content)
                nonce = str(data.get('nonce', '0'))
                N = str(data.get('number', N))
                offset = str(data.get('offset', offset))
    except (json.JSONDecodeError, FileNotFoundError):
        pass
    
    return {
        'N': N,
        'nonce': nonce,
        'offset': offset,
        'uuid': uuid
    }

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print("Usage: parse_miner_data.py <file.dat>")
        sys.exit(1)
    
    result = parse_dat_file(sys.argv[1])
    if result:
        print(json.dumps(result))
    else:
        sys.exit(1)
PYTHON_END

chmod +x /opt/factoring/parse_miner_data.py

# Fonction pour arrêter le miner
stop_miner() {
    log "Arrêt du miner pool..."
    docker stop $MINER_CONTAINER 2>/dev/null || true
    log "✓ Miner arrêté"
}

# Fonction pour démarrer le miner
start_miner() {
    log "Démarrage du miner pool..."
    
    # Vérifie si le conteneur existe déjà
    if docker ps -a --format '{{.Names}}' | grep -q "^${MINER_CONTAINER}$"; then
        docker start $MINER_CONTAINER
    else
        # Télécharge et lance le miner pour la première fois
        wget -q -O /tmp/setup_worker.sh \
            https://github.com/filthz/fact-worker-public/releases/download/base_files/setup_worker.sh
        
        bash /tmp/setup_worker.sh "$POOL_USERNAME" "$POOL_PASSWORD"
    fi
    
    log "✓ Miner démarré"
}

# Fonction pour extraire les nombres N depuis /tmp/sieving
extract_numbers() {
    if [ ! -d "$SIEVING_DIR" ]; then
        return 0
    fi
    
    local new_numbers=()
    
    for file in "$SIEVING_DIR"/*.dat; do
        [ -e "$file" ] || continue
        
        # Parse avec Python pour extraire N, nonce, offset
        local parsed=$(python3 /opt/factoring/parse_miner_data.py "$file" 2>/dev/null)
        
        if [ -z "$parsed" ]; then
            log "⚠ Impossible de parser $file"
            continue
        fi
        
        local N=$(echo "$parsed" | jq -r '.N')
        local nonce=$(echo "$parsed" | jq -r '.nonce')
        local offset=$(echo "$parsed" | jq -r '.offset')
        
        # Vérifie si déjà factorisé
        if grep -q "^$N$" "$FACTORED_LOG" 2>/dev/null; then
            rm -f "$file"
            continue
        fi
        
        # Vérifie si pas déjà en cours
        if [ -f "$CURRENT_JOB" ] && grep -q "$N" "$CURRENT_JOB"; then
            continue
        fi
        
        # Récupère le block template AVANT de factoriser
        log "Récupération du block template..."
        docker exec $MINER_CONTAINER bash -c "
            factorn-cli getblocktemplate '{\"rules\": [\"segwit\"]}' 
        " > /tmp/block_template.json 2>/dev/null || {
            log "⚠ Échec getblocktemplate, utilisation du template existant"
        }
        
        # Sauvegarde les paramètres pour la soumission
        local job_dir="$WORK_DIR/jobs/$N"
        mkdir -p "$job_dir"
        echo "$nonce" > "$job_dir/nonce.txt"
        echo "$offset" > "$job_dir/woffset.txt"
        
        # Copie le block template
        if [ -f /tmp/block_template.json ]; then
            cp /tmp/block_template.json "$job_dir/block_template.json"
        fi
        
        log "✓ Détecté: N=$N (nonce=$nonce, offset=$offset)"
        
        new_numbers+=("$N")
        
        # Supprime pour éviter retraitement
        rm -f "$file"
    done
    
    # Déduplique
    local unique_numbers=($(printf '%s\n' "${new_numbers[@]}" | sort -u))
    
    if [ ${#unique_numbers[@]} -gt 0 ]; then
        echo "${unique_numbers[0]}"
    fi
}

# Phase 1: Msieve (dans le conteneur du miner)
run_msieve() {
    local N=$1
    local job_dir="$WORK_DIR/jobs/$N"
    
    log "Phase Msieve pour N=$N"
    
    mkdir -p "$job_dir"
    echo "$N" > "$job_dir/worktodo.ini"
    
    # Execute msieve dans le conteneur du miner
    docker exec $MINER_CONTAINER bash -c "
        cd /tmp/msieve_work && \
        echo '$N' > worktodo.ini && \
        timeout $MSIEVE_TIMEOUT ./msieve -np
    " 2>&1 | tee "$job_dir/msieve.log"
    
    # Copie le résultat
    docker cp $MINER_CONTAINER:/tmp/msieve_work/msieve.fb "$job_dir/msieve.fb" 2>/dev/null || {
        log "✗ Msieve n'a pas produit de polynôme"
        return 1
    }
    
    log "✓ Polynôme généré"
    return 0
}

# Phase 2: Conversion pour CADO
convert_poly() {
    local N=$1
    local job_dir="$WORK_DIR/jobs/$N"
    
    log "Conversion du polynôme..."
    
    cd "$job_dir"
    "$CADO_DIR/misc/convert_poly" -if msieve -of cado < msieve.fb > poly.cado
    
    if [ ! -f "poly.cado" ]; then
        log "✗ Échec conversion"
        return 1
    fi
    
    log "✓ Polynôme converti"
    return 0
}

# Phase 3: Lancement serveur CADO-NFS
start_cado_server() {
    local N=$1
    local job_dir="$WORK_DIR/jobs/$N"
    
    log "Lancement serveur CADO-NFS..."
    
    # Tue serveur existant
    pkill -f "cado-nfs.py" || true
    sleep 2
    
    cd "$CADO_DIR"
    
    # Lance le serveur avec le polynôme importé
    nohup ./cado-nfs.py "$N" \
        tasks.polyselect.import="$job_dir/poly.cado" \
        server.port="$CADO_SERVER_PORT" \
        server.ssl=no \
        -workdir="$job_dir/cado_workdir" \
        > "$job_dir/cado_server.log" 2>&1 &
    
    local SERVER_PID=$!
    echo "$SERVER_PID" > "$job_dir/server.pid"
    
    # Attend que le serveur soit prêt
    for i in {1..30}; do
        if netstat -tuln | grep -q ":$CADO_SERVER_PORT "; then
            log "✓ Serveur CADO-NFS actif (PID: $SERVER_PID)"
            return 0
        fi
        sleep 2
    done
    
    log "✗ Serveur n'a pas démarré"
    return 1
}

# Surveillance de la factorisation
monitor_factorization() {
    local N=$1
    local job_dir="$WORK_DIR/jobs/$N"
    
    log "Surveillance factorisation..."
    
    while true; do
        # Cherche le fichier de résultat (CADO-NFS crée N.factors.txt)
        if [ -f "$job_dir/cado_workdir/$N.factors.txt" ]; then
            log "✓ Factorisation terminée !"
            
            # Parse les facteurs
            local factors=$(cat "$job_dir/cado_workdir/$N.factors.txt")
            echo "$factors" > "$WORK_DIR/results/$N.factors"
            
            # Marque comme factorisé
            echo "$N" >> "$FACTORED_LOG"
            
            return 0
        fi
        
        # Log progression toutes les 60s
        if [ $((SECONDS % 60)) -eq 0 ]; then
            tail -3 "$job_dir/cado_server.log" 2>/dev/null || true
        fi
        
        sleep 10
    done
}

# Arrête le serveur CADO
stop_cado_server() {
    local job_dir=$1
    
    if [ -f "$job_dir/server.pid" ]; then
        local pid=$(cat "$job_dir/server.pid")
        kill $pid 2>/dev/null || true
        rm -f "$job_dir/server.pid"
    fi
}

# Script Python pour construire et soumettre le bloc
cat > /opt/factoring/submit_block.py << 'PYTHON_SUBMIT_END'
#!/usr/bin/env python3
"""
Construit et soumet un bloc FACT0RN
Basé sur FACTOR.py du projet officiel
"""
import sys
import json
import struct
import requests
from pathlib import Path

def serialize_block_header(version, prev_hash, merkle_root, time, nbits, nonce, offset, factor):
    """Sérialise le block header FACT0RN selon le format du whitepaper"""
    header = b''
    
    # Version (32 bits, little-endian)
    header += struct.pack('<I', int(version))
    
    # Previous Hash (256 bits, reversed)
    header += bytes.fromhex(prev_hash)[::-1]
    
    # Merkle Root (256 bits, reversed)
    header += bytes.fromhex(merkle_root)[::-1]
    
    # Time (32 bits, little-endian)
    header += struct.pack('<I', int(time))
    
    # nBits (16 bits, little-endian)
    header += struct.pack('<H', int(nbits))
    
    # Nonce (64 bits, little-endian, unsigned)
    header += struct.pack('<Q', int(nonce))
    
    # wOffset (64 bits, little-endian, SIGNED)
    header += struct.pack('<q', int(offset))
    
    # Factor nP1 (1024 bits = 128 bytes, little-endian)
    factor_int = int(factor)
    header += factor_int.to_bytes(128, byteorder='little')
    
    return header

def submit_block(rpc_url, rpc_user, rpc_pass, block_hex):
    """Soumet le bloc via RPC"""
    payload = {
        "jsonrpc": "2.0",
        "method": "submitblock",
        "params": [block_hex],
        "id": 1
    }
    
    response = requests.post(
        rpc_url,
        json=payload,
        auth=(rpc_user, rpc_pass),
        timeout=30
    )
    
    return response.json()

def main():
    if len(sys.argv) != 2:
        print("Usage: submit_block.py <job_dir>")
        sys.exit(1)
    
    job_dir = Path(sys.argv[1])
    
    # Charge les paramètres du job
    with open(job_dir / 'block_template.json', 'r') as f:
        template = json.load(f)
    
    nonce = int((job_dir / 'nonce.txt').read_text().strip())
    offset = int((job_dir / 'woffset.txt').read_text().strip())
    
    # Charge les facteurs
    factors = (job_dir.parent.parent / 'results' / f'{job_dir.name}.factors').read_text().strip().split()
    p1 = int(factors[0])
    p2 = int(factors[1])
    
    # S'assure que p1 est le plus petit
    if p1 > p2:
        p1, p2 = p2, p1
    
    # Construit le block header
    block_hex = serialize_block_header(
        version=template['version'],
        prev_hash=template['previousblockhash'],
        merkle_root=template['merkleroot'],
        time=template['curtime'],
        nbits=template['bits'],
        nonce=nonce,
        offset=offset,
        factor=p1
    ).hex()
    
    print(f"Block header (hex): {block_hex[:100]}...")
    print(f"Paramètres:")
    print(f"  nonce: {nonce}")
    print(f"  wOffset: {offset}")
    print(f"  nP1: {p1}")
    print(f"  nBits: {template['bits']}")
    
    # Soumet
    result = submit_block(
        rpc_url="http://localhost:8332",
        rpc_user="your_rpc_user",
        rpc_pass="your_rpc_pass",
        block_hex=block_hex
    )
    
    if 'error' in result and result['error']:
        print(f"ERREUR: {result['error']}")
        sys.exit(1)
    
    print(f"✓ Bloc soumis avec succès !")
    print(f"Résultat: {result}")
    
    return 0

if __name__ == '__main__':
    sys.exit(main())
PYTHON_SUBMIT_END

chmod +x /opt/factoring/submit_block.py

# Soumission à la blockchain FACT0RN
submit_to_blockchain() {
    local N=$1
    local job_dir="$WORK_DIR/jobs/$N"
    local factors_file="$WORK_DIR/results/$N.factors"
    
    log "Soumission à FACT0RN..."
    
    if [ ! -f "$factors_file" ]; then
        log "✗ Fichier facteurs introuvable"
        return 1
    fi
    
    # Parse les facteurs (format CADO: p1 p2)
    local p1=$(awk '{print $1}' "$factors_file")
    local p2=$(awk '{print $2}' "$factors_file")
    
    # S'assure que p1 est le plus petit (requirement FACT0RN)
    if python3 -c "exit(0 if int('$p1') < int('$p2') else 1)"; then
        log "✓ p1 est déjà le plus petit"
    else
        log "⚠ Swap p1 <-> p2"
        local tmp=$p1
        p1=$p2
        p2=$tmp
    fi
    
    log "Facteurs trouvés: p1=$p1, p2=$p2"
    
    # Soumet avec le script Python
    python3 /opt/factoring/submit_block.py "$job_dir" || {
        log "✗ Échec soumission"
        return 1
    }
    
    log "✓ Bloc soumis avec succès !"
    
    return 0
}

# Processus principal
factorize_number() {
    local N=$1
    local job_dir="$WORK_DIR/jobs/$N"
    
    log "=========================================="
    log "FACTORISATION: N=$N"
    log "=========================================="
    
    echo "$N" > "$CURRENT_JOB"
    
    # Arrête le miner
    stop_miner
    
    # Phase 1: Msieve
    if ! run_msieve "$N"; then
        log "✗ Échec msieve"
        start_miner
        rm -f "$CURRENT_JOB"
        return 1
    fi
    
    # Phase 2: Conversion
    if ! convert_poly "$N"; then
        log "✗ Échec conversion"
        start_miner
        rm -f "$CURRENT_JOB"
        return 1
    fi
    
    # Phase 3: Serveur CADO
    if ! start_cado_server "$N"; then
        log "✗ Échec serveur"
        start_miner
        rm -f "$CURRENT_JOB"
        return 1
    fi
    
    # Phase 4: Surveillance
    monitor_factorization "$N"
    
    # Phase 5: Arrêt serveur
    stop_cado_server "$job_dir"
    
    # Phase 6: Soumission
    submit_to_blockchain "$N"
    
    # Reprend le miner
    start_miner
    rm -f "$CURRENT_JOB"
    
    log "✓ Factorisation terminée"
}

# Boucle principale
main_loop() {
    log "Démarrage pipeline Master"
    
    # Démarre le miner initialement
    start_miner
    
    while true; do
        # Cherche nouveaux nombres
        local N=$(extract_numbers)
        
        if [ -n "$N" ]; then
            factorize_number "$N"
        else
            # Attente
            sleep 30
        fi
    done
}

# Initialisation
touch "$FACTORED_LOG"

# Lance
main_loop
CONTROL_SCRIPT_END

chmod +x master_control.sh

log_success "Script de contrôle créé"

# Créer la configuration Supervisor
cat > supervisord.conf << 'SUPERVISOR_END'
[supervisord]
nodaemon=true
user=root

[program:master_control]
command=/usr/local/bin/master_control.sh
autostart=true
autorestart=true
stderr_logfile=/var/log/supervisor/master_control.err.log
stdout_logfile=/var/log/supervisor/master_control.out.log
environment=POOL_USERNAME="%(ENV_POOL_USERNAME)s",POOL_PASSWORD="%(ENV_POOL_PASSWORD)s",SCRIPTPUBKEY="%(ENV_SCRIPTPUBKEY)s",CADO_SERVER_PORT="%(ENV_CADO_SERVER_PORT)s"
SUPERVISOR_END

log_success "Configuration Supervisor créée"

# Build l'image
log "Construction de l'image Docker (cela peut prendre 10-15 minutes)..."
docker build -f Dockerfile.master -t factorn-master:latest . || {
    log_error "Échec du build Docker"
    exit 1
}

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
echo "  docker logs -f factorn-master          # Logs"
echo "  docker exec -it factorn-master bash    # Shell"
echo "  docker stop factorn-master             # Arrêt"
echo "  docker start factorn-master            # Redémarrage"
START_END

chmod +x start_master.sh

log_success "Script de lancement créé"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              INSTALLATION TERMINÉE ! ✅                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "${GREEN}Pour démarrer le master:${NC}"
echo "  ./start_master.sh"
echo ""
echo "${BLUE}Configuration:${NC}"
echo "  Pool: thefactory.solutions"
echo "  Username: $POOL_USERNAME"
echo "  ScriptPubKey: $SCRIPTPUBKEY"
echo "  CADO Port: $CADO_SERVER_PORT"
echo ""
echo "${YELLOW}Vérification:${NC}"
echo "  docker logs -f factorn-master"
echo ""
