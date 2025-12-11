#!/bin/bash
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║   RÉSULTATS DE FACTORISATION                              ║"
echo "║   Format: N,plus_petit_facteur                            ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

if docker exec factorn-master test -f /opt/factoring/results/factorizations.txt 2>/dev/null; then
    docker exec factorn-master cat /opt/factoring/results/factorizations.txt
else
    echo "(aucun résultat)"
fi
