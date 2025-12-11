#!/bin/bash
echo "Test avec un nombre de 40 chiffres..."
N="1234567890123456789012345678901234567891"
mkdir -p /tmp/sieving

# Copier dans le sieving dir local ET dans le master
echo "test" > "/tmp/sieving/${N}_0_test.dat"

# Aussi copier dans le container
docker exec factorn-master mkdir -p /tmp/sieving
docker cp "/tmp/sieving/${N}_0_test.dat" factorn-master:/tmp/sieving/

echo "✓ Fichier créé: ${N}_0_test.dat"
echo ""
echo "Suivez avec: docker logs -f factorn-master"
