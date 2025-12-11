#!/bin/bash
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║   STATUS                                                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

echo "=== Containers ==="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" | grep -E "NAME|fact|msieve"
echo ""

echo "=== En cours ==="
docker exec factorn-master cat /opt/factoring/pending_numbers.txt 2>/dev/null || echo "(aucun)"
echo ""

echo "=== Factorisés ==="
if docker exec factorn-master test -f /opt/factoring/results/factorizations.txt 2>/dev/null; then
    echo "Format: N,facteur"
    docker exec factorn-master cat /opt/factoring/results/factorizations.txt | tail -10
    echo ""
    echo "Total: $(docker exec factorn-master wc -l < /opt/factoring/results/factorizations.txt 2>/dev/null || echo 0)"
else
    echo "(aucun)"
fi
echo ""

echo "=== Logs récents ==="
docker logs --tail 25 factorn-master 2>&1 | tail -20
