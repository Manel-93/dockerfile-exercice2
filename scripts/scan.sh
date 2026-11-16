#!/bin/sh
# Analyse de sécurité d'une image avec Trivy, SANS exposer le socket Docker à Trivy.
#   L'image est exportée en archive (docker save), puis Trivy l'analyse hors ligne
#   avec --input. Le conteneur Trivy n'a donc aucun accès au démon Docker.
#
# Usage : ./scripts/scan.sh <image> [dossier_de_sortie]
# Code de retour 1 s'il reste des vulnérabilités HIGH/CRITICAL corrigeables
# (utilisable en CI ou dans une tâche planifiée pour un contrôle régulier).
set -eu

IMAGE="${1:?usage: $0 <image> [dossier_de_sortie]}"
OUT="${2:-audit/scan}"
TRIVY="aquasec/trivy:0.67.2"
CACHE="${HOME}/.cache/trivy"
NAME=$(echo "$IMAGE" | tr '/:' '__')

mkdir -p "$OUT" "$CACHE"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "[1/4] Export de $IMAGE"
docker save -o "$TMP/image.tar" "$IMAGE"
chmod 644 "$TMP/image.tar"

run_trivy() {
  docker run --rm --user "$(id -u):$(id -g)" \
    -e HOME=/cache -v "$CACHE:/cache/.cache/trivy" \
    -v "$TMP:/in:ro" -v "$(pwd)/$OUT:/out" "$TRIVY" "$@"
}

echo "[2/4] Vulnérabilités, rapport JSON complet"
run_trivy image --quiet --input /in/image.tar --format json -o "/out/trivy-$NAME.json"

echo "[3/4] Vulnérabilités, rapport texte"
run_trivy image --quiet --input /in/image.tar --format table -o "/out/trivy-$NAME.txt"

echo "[4/4] Mauvaises configurations du Dockerfile"
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/cache -v "$CACHE:/cache/.cache/trivy" \
  -v "$(pwd):/src:ro" -v "$(pwd)/$OUT:/out" "$TRIVY" \
  config --quiet -o "/out/trivy-$NAME-dockerfile.txt" /src/Dockerfile

echo "Rapports écrits dans $OUT/"
echo "Contrôle bloquant : HIGH/CRITICAL corrigeables"
run_trivy image --quiet --input /in/image.tar --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 --format table
