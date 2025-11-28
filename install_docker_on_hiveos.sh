#!/usr/bin/env bash
set -e

echo "=== [1] Vérification des droits root ==="
if [ "$EUID" -ne 0 ]; then
  echo "Merci de lancer ce script en root (sudo su ou sudo bash)."
  exit 1
fi

echo "=== [2] Arrêt des services Docker / containerd ==="
systemctl stop docker 2>/dev/null  true
systemctl stop containerd 2>/dev/null  true

echo "=== [3] Suppression des anciens paquets Docker / containerd ==="
apt-get remove -y docker docker-engine docker.io \
  docker-ce docker-ce-cli containerd containerd.io runc 2>/dev/null  true
apt-get purge -y docker* containerd* runc 2>/dev/null  true
apt-get autoremove -y

echo "=== [4] Nettoyage des données Docker / containerd ==="
rm -rf /var/lib/docker /var/lib/containerd /etc/docker

echo "=== [5] Nettoyage des dépôts APT liés à Docker / jammy ==="
rm -f /etc/apt/sources.list.d/docker.list  true
rm -f /etc/apt/sources.list.d/jammy.list  true
on enlève toute ligne Docker / jammy qui aurait pu être ajoutée dans le sources.list principal
sed -i '/download.docker.com/d' /etc/apt/sources.list  true
sed -i '/jammy.*docker.com/d' /etc/apt/sources.list  true

echo "=== [6] Préparation des keyrings APT ==="
mkdir -p /etc/apt/keyrings
rm -f /etc/apt/keyrings/docker.gpg || true

echo "=== [7] Mise à jour APT + installation des outils nécessaires ==="
apt-get update
apt-get install -y ca-certificates curl gnupg
echo "=== [8] Installation de la clé GPG Docker ==="
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "=== [9] Création d'un dépôt Docker PROPRE pour Ubuntu 20.04 (focal) ==="
cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu focal stable
EOF
echo "=== [10] Passage d'iptables en mode legacy (plus compatible avec Docker sur HiveOS) ==="
apt-get update
apt-get install -y iptables iptables-legacy arptables ebtables
update-alternatives --set iptables /usr/sbin/iptables-legacy
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
update-alternatives --set arptables /usr/sbin/arptables-legacy
update-alternatives --set ebtables /usr/sbin/ebtables-legacy

echo "=== [11] Installation de Docker CE tout neuf ==="
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

echo "=== [12] Activation et démarrage des services ==="
systemctl enable containerd docker
systemctl restart containerd
systemctl restart docker

echo "=== [13] Vérifications rapides ==="
docker --version  echo "docker --version a échoué"
systemctl status docker --no-pager -l | head -n 20

echo "=== [14] Test avec l'image hello-world (si Internet OK) ==="
docker run --rm hello-world  echo "Le test hello-world a échoué (souvent problème de réseau/DNS, pas d'installation)."

echo "=== FIN : Docker propre installé sur HiveOS ==="
