#!/bin/bash
echo "Test de détection de fichiers .dat"
echo ""

# Créer un fichier test
TEST_FILE="/tmp/sieving/test_$(date +%s)_0_test.dat"
echo "12345" > "$TEST_FILE"

echo "✓ Fichier créé: $TEST_FILE"
echo ""
echo "Attendez 5 secondes..."
sleep 5
echo ""
echo "Logs du master:"
docker logs --tail 20 factorn-master

echo ""
echo "Pour suivre en temps réel:"
echo "  docker logs -f factorn-master"
