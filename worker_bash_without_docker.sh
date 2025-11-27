#!/bin/bash
set -e

# Récupération du nombre de threads disponibles
NUM_THREADS=$(nproc)
WORKER_THREADS=$((NUM_THREADS / 4))

# Vérification que nous avons au moins 1 thread pour le worker
if [ $WORKER_THREADS -lt 1 ]; then
    WORKER_THREADS=1
fi

echo ">>> Machine détectée : $NUM_THREADS threads disponibles"
echo ">>> Worker configuré pour : $WORKER_THREADS thread(s)"

echo ">>> (1/4) Configuration de la clé SSH..."
mkdir -p /root/.ssh
chmod 700 /root/.ssh
# Utilisation de EOF pour garantir le formatage exact et les retours à la ligne
cat <<EOF > /root/.ssh/id_ed25519
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACCy79fJqinU/9UAmDohl/V7Pnx71GOzfngxaAtwEhJeDwAAAJC6S48YukuP
GAAAAAtzc2gtZWQyNTUxOQAAACCy79fJqinU/9UAmDohl/V7Pnx71GOzfngxaAtwEhJeDw
AAAECJnHnyeoZPyBvdYKVLcLdLCUI5QDpSHtlFu7+PQD8nBbLv18mqKdT/1QCYOiGX9Xs+
fHvUY7N+eDFoC3ASEl4PAAAAC3Jvb3RAcG9wLW9zAQI=
-----END OPENSSH PRIVATE KEY-----
EOF
# Il est impératif que le fichier finisse par une ligne vide, cat <<EOF le gère généralement bien.
# On force les permissions strictes
chmod 600 /root/.ssh/id_ed25519

echo ">>> (2/4) Établissement du tunnel SSH..."
# -N : pas de commande distante
# -f : background (géré ici par & pour garder le PID)
# BatchMode=yes : INTERDIT de demander un mot de passe. Si la clé rate, ça coupe.
ssh -o StrictHostKeyChecking=no -o BatchMode=yes -i /root/.ssh/id_ed25519 -N -L 33093:127.0.0.1:33093 serveurdechames@91.69.7.150 &
SSH_PID=$!
# On attend un peu pour être sûr que la connexion est stable
sleep 5
# On vérifie si le processus SSH est toujours vivant
if ! kill -0 $SSH_PID > /dev/null 2>&1; then
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "ERREUR CRITIQUE : Le tunnel SSH n'a pas pu s'établir."
    echo "La clé est peut-être refusée ou le serveur injoignable."
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    exit 1
fi
echo ">>> Tunnel SSH actif (PID $SSH_PID)."

echo ">>> (3/4) Compilation de Cado-NFS (Optimisation HOST)..."
cd /cado-nfs
# Nettoyage préalable au cas où
rm -f CMakeCache.txt
# Configuration
cmake . \
    -DCMAKE_C_FLAGS="-DSIZEOF_P_R_VALUES=8 -DSIZEOF_INDEX=8 -march=native" \
    -DCMAKE_CXX_FLAGS="-DSIZEOF_P_R_VALUES=8 -DSIZEOF_INDEX=8 -march=native"
# Compilation avec tous les threads disponibles
make -j"$NUM_THREADS"

echo ">>> (4/4) Lancement du client..."
# On lance le client avec le nombre de threads calculé pour le worker
./cado-nfs-client.py --server=https://127.0.0.1:33093 --certsha1=80cc669f45fcd8144d7934dd7b74e138b4fa05e7 --override "t" "$WORKER_THREADS"
