# syntax=docker/dockerfile:1
#
# Image sécurisée de l'application Quiz Docker (site statique généré par Vite).
#   - Build multi-étapes : Node ne sert qu'à compiler, il n'est pas dans l'image finale.
#   - Images de base minimales, en version précise et épinglées par digest.
#   - Exécution en utilisateur non-root (nginx, UID 101), sur un port non privilégié (8080).
#   - COPY uniquement (pas de ADD), fichiers copiés un par un, avec un .dockerignore.


FROM node:24.22.3-alpine3.24@sha256:116b800c3754b440ee0aa3ed2f20f5bf3d99a554bfd9adeea09ea8017f6e85f5 AS build

WORKDIR /app

# Le build tourne lui aussi en utilisateur non-root (fourni par l'image node)
RUN chown node:node /app
USER node

# Dépendances d'abord (cache de couches), installées strictement selon le lockfile
COPY --chown=node:node package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

# Uniquement les fichiers nécessaires au build
COPY --chown=node:node vite.config.js index.html main.js style.css questions_defaut.js ./
COPY --chown=node:node public ./public

RUN npm run build


FROM nginxinc/nginx-unprivileged:1.30.6-alpine3.24-slim@sha256:5d8bb9437d74a600ec5dbf90c035451c724dc33eac8d3a71078f6f8612c345f6

# Correctifs de sécurité Alpine publiés après la création de l'image de base
# (musl, zlib...). Root est nécessaire uniquement pour cette étape.
USER root
RUN apk upgrade --no-cache

# Configuration nginx durcie (en-têtes de sécurité, version masquée)
COPY nginx/default.conf /etc/nginx/conf.d/default.conf

# Seul le résultat du build est copié. Les fichiers appartiennent à root et sont en
# lecture seule pour l'utilisateur nginx, qui ne peut donc pas modifier le site.
COPY --from=build /app/dist /usr/share/nginx/html

# Utilisateur non-root explicite (UID numérique, vérifiable par les orchestrateurs)
USER 101:101

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q --spider http://127.0.0.1:8080/healthz || exit 1

# Hérité de l'image de base, rappelé ici pour être explicite
CMD ["nginx", "-g", "daemon off;"]
