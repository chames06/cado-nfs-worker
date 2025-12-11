#!/bin/bash
# Test avec un nombre de 40 chiffres (faisable rapidement)
N="1234567890123456789012345678901234567891"
echo "Test avec N = $N (${#N} chiffres)"
echo "test" > "/tmp/sieving/${N}_0_test.dat"
echo "✓ Fichier créé"
echo ""
echo "Suivez avec: docker logs -f factorn-master"
