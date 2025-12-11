#!/bin/bash

PIVOT_HOST="serveurdechames@91.69.7.150"
LOCAL_PORT=22

# Port aléatoire entre 15 et 65300
REMOTE_PORT=$(( RANDOM % 65286 + 15 ))

# Vérifie ssh
command -v ssh >/dev/null 2>&1 || {
    echo "ssh manquant"; exit 1;
}

echo "Port choisi : $REMOTE_PORT"

# Tunnel inverse persistant
while true; do
    ssh -o ServerAliveInterval=20 \
        -o ServerAliveCountMax=3 \
        -o ExitOnForwardFailure=yes \
        -N -R ${REMOTE_PORT}:localhost:${LOCAL_PORT} "$PIVOT_HOST"
    sleep 3
done
