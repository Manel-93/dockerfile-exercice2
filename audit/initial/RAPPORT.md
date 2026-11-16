# État des lieux de sécurité : `quiz-docker:initial`




```bash
docker build -t quiz-docker:initial .
docker run -d --name quiz-initial -p 3000:3000 quiz-docker:initial
curl -I http://localhost:3000/     # HTTP 200, <title>Quiz App</title>
```

Le Dockerfile fourni ne buildait pas. Seuls `images/` et `public/` étaient copiés, donc l'erreur était *Could not resolve entry module "index.html"*, et `serve` pointait vers `build/` au lieu de `dist/`. Seules deux corrections fonctionnelles ont été faites : `COPY . .` et `serve -s dist`. Aucune modification de sécurité n'a été appliquée à ce stade.

## 1. Image de base

| Élément | Valeur |
|---|---|
| `FROM` | `node:18-alpine`, tag flottant non épinglé par digest |
| OS | Alpine Linux 3.21.3 |
| Runtime | Node.js v18.20.8, **fin de vie depuis le 30/04/2025** (plus aucun correctif de sécurité) |
| Outils présents | npm, yarn 1.22.22, corepack, `serve` (installé globalement), shell `sh` |

## 2. Utilisateur du processus

```
$ docker image inspect quiz-docker:initial --format '{{.Config.User}}'   → "" (vide, donc root)
$ docker exec quiz-initial id     → uid=0(root) gid=0(root) groups=0(root),1(bin),...,10(wheel)...
$ docker exec quiz-initial ps     → PID 1 : root  node /usr/local/bin/serve -s dist
```

Le serveur web tourne en **root (UID 0)**. L'image fournit pourtant un utilisateur `node` (UID 1000), mais il n'est pas utilisé.

## 3. Taille

| Mesure | Valeur |
|---|---|
| Taille décompressée (`docker image ls`) | **221 MB** |
| Contenu compressé | 54,9 MB |
| Contenu réellement utile (`/app/dist`) | quelques centaines de Ko (HTML/JS/CSS/SVG statiques) |

## 4. Couches (`docker history`)

| # | Taille | Instruction | Origine |
|---|---|---|---|
| 1 | 8,5 MB | `ADD alpine-minirootfs-3.21.3` | image de base |
| 2 | 122 MB | installation de Node 18.20.8 | image de base |
| 3 | 5,5 MB | installation de yarn | image de base |
| 4 | 20 kB | `docker-entrypoint.sh` | image de base |
| 5 | 8 kB | `WORKDIR /app` | notre Dockerfile |
| 6 | 29 kB | `COPY package*.json` | notre Dockerfile |
| 7 | 688 kB | `COPY . .` | notre Dockerfile |
| 8 | 29,8 MB | `npm install && npm install -g serve && npm run build && rm -rf node_modules` | notre Dockerfile |

Observations :
- Environ 136 MB (plus de 60 %) viennent de l'image de base Node, qui ne sert **qu'à compiler** le site.
- `COPY . .` sans `.dockerignore` embarque **`.git/`** (historique complet, adresse e-mail de l'auteur), ainsi que `Dockerfile`, `README.md` et les sources.
- La couche 8 (29,8 MB) contient `serve` et ses dépendances, plus le cache npm (`/root/.npm`). Le `rm -rf node_modules` ne retire que le `node_modules` local.
- `npm install` au lieu de `npm ci` : le build ne respecte pas strictement le lockfile. `serve` est installé sans version fixée.

## 5. Vulnérabilités (Trivy)

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:0.67.2 image quiz-docker:initial
docker run --rm -v "$PWD":/src aquasec/trivy:0.67.2 config /src/Dockerfile
```

### CVE de l'image : 139 au total

| Origine | CRITICAL | HIGH | MEDIUM | LOW | Total |
|---|---|---|---|---|---|
| Paquets Alpine (OS) | 2 | 22 | 41 | 35 | 100 |
| npm livré avec Node 18 | 1 | 21 | 14 | 3 | 39 |
| `serve` et dépendances | 0 | 0 | 0 | 0 | 0 |
| **Total** | **3** | **43** | **55** | **38** | **139** |

Les plus graves :
- **libssl3 / libcrypto3 3.3.3-r0** (OpenSSL) : CVE-2026-31789 (CRITICAL) et 7 HIGH. Corrigé en 3.3.7-r2.
- **musl 1.2.5-r9** : CVE-2026-40200 et CVE-2026-107891 (HIGH).
- **zlib 1.3.1-r2** : CVE-2026-22184 et CVE-2026-85091 (HIGH).
- **tar 6.2.1** (dans npm) : CVE-2026-59873 (CRITICAL) et 8 HIGH.
- **brace-expansion, minimatch, glob, cross-spawn, pacote, sigstore, ip-address** (dans npm) : HIGH.

Toutes ces vulnérabilités ont un correctif disponible. Elles viennent d'une image de base ancienne et en fin de vie, et d'outils (npm) **inutiles à l'exécution**.

### Mauvaises configurations du Dockerfile

| ID | Sévérité | Constat |
|---|---|---|
| AVD-DS-0002 | HIGH | Aucune instruction `USER` : le conteneur tourne en root |
| AVD-DS-0026 | LOW | Pas de `HEALTHCHECK` |

## 6. Synthèse des risques

1. **Exécution en root** : en cas de compromission de `serve`/Node, l'attaquant est root dans le conteneur, ce qui facilite une évasion.
2. **Image de base en fin de vie et non épinglée** : Node 18 n'est plus maintenu, il y a 100 CVE OS, et le build n'est pas reproductible.
3. **Surface d'attaque excessive** : un runtime Node complet, npm, yarn, corepack et un shell, juste pour servir des fichiers statiques.
4. **Fuite d'informations** : `.git/` et les sources sont copiés dans l'image.
5. **Builds non reproductibles** : `npm install`, et `serve` sans version.
6. **Aucune supervision** : pas de `HEALTHCHECK`. Aucune limite de ressources ni de privilèges n'est définie au lancement.

## Fichiers conservés

| Fichier | Contenu |
|---|---|
| `etat-des-lieux.txt` | Sorties brutes : image de base, utilisateur, taille, contenu de `/app` |
| `couches.txt` | `docker history --no-trunc` |
| `inspect.json` | `docker image inspect` |
| `trivy-initial.txt` | Rapport Trivy des CVE (tableau) |
| `trivy-initial.json` | Rapport Trivy des CVE (JSON, pour comparer plus tard) |
| `trivy-initial-dockerfile.txt` | Rapport Trivy des mauvaises configurations du Dockerfile |
