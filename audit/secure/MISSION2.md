# Mission 2 : sécuriser l'image et le conteneur Docker

Image finale : `quiz-docker:secure`. L'image de départ `quiz-docker:initial` est décrite dans [../initial/RAPPORT.md](../initial/RAPPORT.md).

Fichiers concernés :

| Fichier | Rôle |
|---|---|
| [Dockerfile](../../Dockerfile) | Nouveau Dockerfile sécurisé, multi-étapes |
| [Dockerfile.initial](../../Dockerfile.initial) | Dockerfile d'origine, conservé pour la comparaison |
| [.dockerignore](../../.dockerignore) | Liste blanche du contexte de build |
| [nginx/default.conf](../../nginx/default.conf) | Configuration nginx durcie |
| [docker-compose.yml](../../docker-compose.yml) | Lancement avec limites de privilèges et de ressources |
| [scripts/scan.sh](../../scripts/scan.sh) | Analyse Trivy reproductible, sans socket Docker |

```bash
docker compose up -d --build                   # build et lancement durci → http://localhost:8090
./scripts/scan.sh quiz-docker:secure audit/secure
```

---

## 1. Utiliser des images de base minimales

| | Initial | Sécurisé |
|---|---|---|
| Image d'exécution | `node:18-alpine` (Node, npm, yarn, corepack) | `nginxinc/nginx-unprivileged:1.30.6-alpine3.24-slim` |
| Rôle | Runtime JavaScript complet pour servir des fichiers statiques | Serveur HTTP statique seulement |

L'application est un site statique. Un serveur nginx suffit, et la variante **`-slim`** retire les modules facultatifs (njs, image-filter, xslt…). Node reste utilisé, mais uniquement dans l'étape de build (voir §7).

## 2. Ne pas exécuter le conteneur en root

- L'image `nginx-unprivileged` est conçue pour fonctionner sans root : elle écoute sur **8080** (port > 1024, donc aucune capability nécessaire) et place son PID et ses fichiers temporaires dans `/tmp`.
- `USER 101:101` est déclaré explicitement à la fin du Dockerfile, avec un UID numérique vérifiable par Kubernetes (`runAsNonRoot`).
- L'étape de build tourne elle aussi en non-root (`USER node`).
- `docker-compose.yml` impose aussi `user: "101:101"`.
- Les fichiers du site appartiennent à **root**, en lecture seule pour l'utilisateur `nginx`. Un processus compromis ne peut donc pas modifier le site.

Preuve :
```
$ docker exec quiz-secure id
uid=101(nginx) gid=101(nginx) groups=101(nginx)
$ docker exec quiz-secure ps -o user,args
nginx  nginx: master process nginx -g daemon off;
nginx  nginx: worker process  (...)
```

> `USER root` apparaît brièvement dans l'étape finale pour `apk upgrade`. Il est suivi de `USER 101:101` avant le `CMD`. Le processus applicatif ne tourne jamais en root.

## 3. Utiliser un `.dockerignore`

Le fichier fonctionne en **liste blanche** : tout est exclu (`*`), puis seuls les fichiers nécessaires au build sont réautorisés. `.git`, `node_modules`, `dist`, `.env*`, `*.pem` et `*.key` sont exclus dans tous les cas.

Résultat : un fichier ajouté plus tard dans le dépôt (un secret, une clé…) n'entrera **jamais** dans le contexte de build par accident. Dans l'image initiale, `.git/` (historique et e-mails des auteurs) était copié dans `/app`.

En complément, le Dockerfile copie les fichiers **un par un** (`COPY vite.config.js index.html main.js …`) au lieu de `COPY . .`. Il y a donc deux protections indépendantes.

## 4. Utiliser des tags d'images précis

| | Initial | Sécurisé |
|---|---|---|
| Build | `node:18-alpine` (tag flottant, version en fin de vie) | `node:24.22.3-alpine3.24@sha256:116b80…` |
| Exécution | idem | `nginxinc/nginx-unprivileged:1.30.6-alpine3.24-slim@sha256:5d8bb9…` |
| Outil d'analyse | n/a | `aquasec/trivy:0.67.2` |

- **Version complète** (majeure.mineure.correctif, plus la version d'Alpine) : on sait exactement ce qui est déployé.
- **Digest `sha256`** : l'image est immuable. Même si le tag est republié, éventuellement de façon malveillante, le build utilise exactement la même image.
- **Node 24** est la version LTS active, maintenue. **nginx 1.30** est la branche stable (numéro mineur pair).

Ce choix a une contrepartie : un digest épinglé ne reçoit plus les correctifs automatiquement. Il faut le mettre à jour régulièrement, à la main ou avec un outil comme Dependabot ou Renovate (voir §9).

## 5. Préférer `COPY` à `ADD`

Le Dockerfile sécurisé ne contient **aucune instruction `ADD`**. `ADD` peut télécharger une URL distante, sans vérification d'intégrité, et décompresse automatiquement les archives. Cela crée un risque de contenu imprévu, voire de *zip slip*. `COPY` se contente de copier des fichiers locaux, ce qui est explicite et prévisible.

> Le `ADD alpine-minirootfs…` visible dans `docker history` appartient à l'image de base officielle, pas à notre Dockerfile.

## 6. Limiter les ressources et les privilèges du conteneur

Ces limites sont définies dans [docker-compose.yml](../../docker-compose.yml). Commande `docker run` équivalente :

```bash
docker run -d --name quiz-secure -p 8090:8080 \
  --user 101:101 \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --memory 64m --memory-swap 64m --cpus 0.5 --pids-limit 50 \
  --restart unless-stopped \
  quiz-docker:secure
```

| Option | Effet | Vérification |
|---|---|---|
| `read_only: true` | Système de fichiers racine en lecture seule | `touch /etc/x` → *Read-only file system* |
| `tmpfs /tmp` (`noexec,nosuid,nodev`, 16 MB) | Seul dossier inscriptible, mais aucun binaire n'y est exécutable | `/tmp/t` → *Permission denied* |
| `cap_drop: ALL` | Aucune capability Linux | `CapEff: 0000000000000000` dans `/proc/1/status` |
| `no-new-privileges` | Aucune élévation de privilèges via un binaire setuid | `SecurityOpt=[no-new-privileges:true]` |
| `mem_limit` / `memswap_limit` 64 MB | Protège l'hôte contre une fuite mémoire ou un déni de service | Utilisation réelle : environ 8,5 MiB sur 64 MiB |
| `cpus: 0.5` | Au plus un demi-cœur | `NanoCpus=500000000` |
| `pids_limit: 50` | Protège contre une *fork bomb* | `PidsLimit=50` |

Durcissements applicatifs supplémentaires dans nginx : `server_tokens off` (version masquée), en-têtes `Content-Security-Policy`, `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy` et `Permissions-Policy`, méthodes limitées à `GET`/`HEAD` (`POST` → 405), et fichiers cachés (`/.git`, `/.env`) jamais servis.

## 7. Utiliser un build multi-étapes

```
┌─────────────── étape "build" ───────────────┐     ┌──────────── image finale ────────────┐
│ node:24.22.3-alpine3.24                     │     │ nginx-unprivileged 1.30.6 slim       │
│ npm ci  →  vite build  →  /app/dist         │ ──► │ /usr/share/nginx/html  (57 kB)       │
│ (Node, npm, node_modules, sources)          │     │ + default.conf                       │
│   → jetée après le build                    │     │ USER 101, HEALTHCHECK                │
└─────────────────────────────────────────────┘     └──────────────────────────────────────┘
```

Seul `COPY --from=build /app/dist` passe dans l'image finale. **Node, npm, `node_modules`, les sources et le cache npm n'y sont pas**. Le build utilise aussi `npm ci` à la place de `npm install`, ce qui respecte strictement le `package-lock.json` et rend le build reproductible.

Vérification : `which node npm serve` dans le conteneur ne renvoie rien.

## 8. Ne pas exposer le socket Docker

- `docker-compose.yml` ne monte **aucun volume**, en particulier pas `/var/run/docker.sock` (`ls /var/run/docker.sock` → *No such file or directory*). Un accès au socket équivaut à être root sur l'hôte : on peut lancer un conteneur `--privileged` qui monte `/`.
- **Le premier scan (état initial) montait le socket dans le conteneur Trivy**, comme le fait la commande de la documentation. [scripts/scan.sh](../../scripts/scan.sh) corrige ce point : l'image est exportée avec `docker save`, puis Trivy l'analyse **hors ligne** avec `--input`. Le conteneur Trivy n'a alors aucun accès au démon Docker et tourne avec l'UID de l'utilisateur, pas en root.

## 9. Vérifier régulièrement la sécurité

`scripts/scan.sh <image>` produit à chaque exécution :
- `trivy-<image>.json` / `.txt` : les vulnérabilités de l'image ;
- `trivy-<image>-dockerfile.txt` : les mauvaises configurations du Dockerfile ;
- un **contrôle bloquant** : code retour `1` s'il reste des vulnérabilités HIGH ou CRITICAL corrigeables.

Ce contrôle a été utile pendant le TP : le premier scan de l'image sécurisée a relevé **3 HIGH** (musl CVE-2026-107891, zlib CVE-2026-85091). Les correctifs étaient publiés dans Alpine, mais l'image nginx n'avait pas encore été reconstruite avec. D'où l'ajout de `RUN apk upgrade --no-cache` dans l'étape finale. Après reconstruction, le résultat est 0 vulnérabilité.

Pour un contrôle **régulier** :
- en CI, lancer `scripts/scan.sh` à chaque push, le code retour bloquant le déploiement ;
- en tâche planifiée, par exemple chaque semaine avec cron (`0 6 * * 1 cd /chemin && ./scripts/scan.sh quiz-docker:secure`). De nouvelles CVE sont publiées en permanence : une image saine aujourd'hui ne le sera plus dans un mois ;
- utiliser Dependabot ou Renovate pour proposer la mise à jour des tags et des digests épinglés ;
- vérifier le conteneur en cours d'exécution : `docker inspect` (user, capabilities, limites) et l'état `healthy` du `HEALTHCHECK`.

---

## Résultats : avant / après

| Critère | `quiz-docker:initial` | `quiz-docker:secure` |
|---|---|---|
| Image de base | `node:18-alpine` (Node en fin de vie, Alpine 3.21.3) | `nginx-unprivileged:1.30.6-alpine3.24-slim` (Alpine 3.24.2) |
| Tag | Flottant | Version précise et digest `sha256` |
| **Taille** | **221 MB** | **33,4 MB** (−85 %) |
| **Vulnérabilités (Trivy)** | **139** (3 CRITICAL, 43 HIGH, 55 MEDIUM, 38 LOW) | **0** |
| Mauvaises configurations Dockerfile | 2 (DS-0002 root, DS-0026 healthcheck) | **0** |
| Utilisateur | root (UID 0) | nginx (UID 101) |
| Capabilities | Celles par défaut de Docker | Aucune |
| Système de fichiers | Lecture/écriture | Lecture seule (+ `/tmp` noexec) |
| Limites de ressources | Aucune | 64 MB RAM, 0,5 CPU, 50 PID |
| Outils dans l'image | Node, npm, yarn, corepack, `serve` | Aucun outil de build |
| `.git/` et sources dans l'image | Oui | Non |
| Build | `npm install`, multi-étapes : non | `npm ci`, multi-étapes : oui |
| `ADD` dans notre Dockerfile | Non | Non |
| Socket Docker | Non monté (mais monté pour le scan) | Jamais monté, scan via `docker save` |
| `HEALTHCHECK` | Non | Oui (`/healthz`), état `healthy` |
| Serveur | `serve` (outil de développement) | nginx durci (en-têtes de sécurité, méthodes limitées) |

## Limites et points d'attention

- **Le shell et `wget` restent présents** dans l'image nginx (ils servent au `HEALTHCHECK` et aux scripts d'entrée). Pour aller plus loin, une image *distroless* ou `scratch` avec un serveur statique compilé en binaire unique supprimerait aussi le shell.
- **0 CVE est un constat daté** (16/11/2026). Il faut relancer le scan régulièrement (§9).
- **`apk upgrade` réduit un peu la reproductibilité** : deux builds à des dates différentes peuvent installer des versions de paquets différentes. C'est un compromis assumé en faveur des correctifs de sécurité. L'alternative est de mettre à jour le digest de l'image de base dès qu'elle est reconstruite.
- **Le port hôte est 8090**, parce que 8080 est déjà utilisé sur la machine. Il est modifiable avec `QUIZ_PORT=xxxx docker compose up -d`.
- `Dockerfile.initial` ne se construit plus à l'identique, parce que le `.dockerignore` filtre désormais le contexte. Ce n'est pas un problème : l'image `quiz-docker:initial` et ses rapports sont conservés.
