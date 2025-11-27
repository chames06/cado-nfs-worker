#!/bin/bash
set -e

# Récupération du nombre de threads disponibles
NUM_THREADS=$(nproc)
WORKER_THREADS=$((NUM_THREADS / 4))

if [ $WORKER_THREADS -lt 1 ]; then
    WORKER_THREADS=1
fi

echo ">>> Machine détectée : $NUM_THREADS threads disponibles"
echo ">>> Worker configuré pour : $WORKER_THREADS thread(s)"

echo ">>> (1/4) Configuration de la clé SSH..."

# Emplacements HiveOS
SSH_DIR_ROOT="/root/.ssh"
SSH_DIR_USER="/home/user/.ssh"

mkdir -p "$SSH_DIR_ROOT" "$SSH_DIR_USER"
chmod 700 "$SSH_DIR_ROOT" "$SSH_DIR_USER"

# On utilise une zone temporaire pour garantir le format exact
cat << 'EOF' > /tmp/id_ed25519_hive
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACCy79fJqinU/9UAmDohl/V7Pnx71GOzfngxaAtwEhJeDwAAAJC6S48YukuP
GAAAAAtzc2gtZWQyNTUxOQAAACCy79fJqinU/9UAmDohl/V7Pnx71GOzfngxaAtwEhJeDw
AAAECJnHnyeoZPyBvdYKVLcLdLCUI5QDpSHtlFu7+PQD8nBbLv18mqKdT/1QCYOiGX9Xs+
fHvUY7N+eDFoC3ASEl4PAAAAC3Jvb3RAcG9wLW9zAQI=
-----END OPENSSH PRIVATE KEY-----
EOF

# Suppression des retours Windows (problème courant sur HiveOS)
tr -d '\r' < /tmp/id_ed25519_hive > /tmp/id_fixed
mv /tmp/id_fixed /tmp/id_ed25519_hive

# Copie dans root et user HiveOS
install -m 600 /tmp/id_ed25519_hive "$SSH_DIR_ROOT/id_ed25519"
install -m 600 /tmp/id_ed25519_hive "$SSH_DIR_USER/id_ed25519"

rm -f /tmp/id_ed25519_hive

echo ">>> Clé SSH installée dans :"
echo "    - $SSH_DIR_ROOT/id_ed25519"
echo "    - $SSH_DIR_USER/id_ed25519"

echo ">>> (2/4) Établissement du tunnel SSH..."

SSH_KEY="/root/.ssh/id_ed25519"
SSH_USER="serveurdechames"
SSH_HOST="91.69.7.150"

ssh \
  -o StrictHostKeyChecking=no \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  -i "$SSH_KEY" \
  -N -L 33093:127.0.0.1:33093 "$SSH_USER@$SSH_HOST" &

SSH_PID=$!
sleep 4

if ! kill -0 $SSH_PID 2>/dev/null; then
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "ERREUR CRITIQUE : Le tunnel SSH n'a pas pu s'établir."
    echo "CAUSES PROBABLES :"
    echo "  1) La clé publique correspondant à ta clé privée n'est pas dans ~/.ssh/authorized_keys"
    echo "  2) Mauvais utilisateur SSH (actuel : $SSH_USER)"
    echo "  3) Serveur inaccessible"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    exit 1
fi

echo ">>> Tunnel SSH actif (PID $SSH_PID)."

echo ">>> (3/4) Compilation de Cado-NFS (Optimisation HOST)..."
cd /cado-nfs || cd /home/user/cado-nfs

rm -f CMakeCache.txt

cmake . \
    -DCMAKE_C_FLAGS="-DSIZEOF_P_R_VALUES=8 -DSIZEOF_INDEX=8 -march=native" \
    -DCMAKE_CXX_FLAGS="-DSIZEOF_P_R_VALUES=8 -DSIZEOF_INDEX=8 -march=native"

make -j"$NUM_THREADS"

echo ">>> (4/4) Lancement du client..."
./cado-nfs-client.py --server=https://127.0.0.1:33093 \
    --certsha1=80cc669f45fcd8144d7934dd7b74e138b4fa05e7 \
    --override "t" "$WORKER_THREADS"
