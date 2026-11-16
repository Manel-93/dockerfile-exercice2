# TP Sécurité Docker

## Partie 1 : état des lieux de l'image initiale

### 1. L'image utilisée est-elle adaptée à une utilisation en production ?

Non, pour plusieurs raisons :

- Elle est basée sur Node 18, qui n'est plus mis à jour depuis avril 2025. Les failles découvertes depuis ne seront jamais corrigées.
- Le scan avec Trivy trouve 139 vulnérabilités connues, dont 3 critiques et 43 élevées.
- L'application tourne avec l'utilisateur root, donc avec tous les droits dans le conteneur.
- L'image pèse 221 MB alors que le site lui-même ne fait que quelques centaines de Ko. Elle contient tous les outils de développement (Node, npm, yarn…).
- Des fichiers qui n'ont rien à faire là sont copiés dedans, notamment le dossier `.git` avec tout l'historique du projet.
- Le serveur `serve` est pratique pour tester, mais il n'est pas prévu pour la production.

Elle convient pour un exercice ou du développement, pas pour la production.

### 2. Quels composants sont réellement nécessaires pour exécuter l'application ?

L'application est un simple site statique : une fois compilée avec `npm run build`, il ne reste qu'un dossier `dist/` avec du HTML, du JavaScript et du CSS. Rien ne tourne côté serveur.

| Composant | Utile pour compiler ? | Utile pour faire tourner le site ? |
|---|---|---|
| Node.js, npm, Vite | Oui | Non |
| Les sources (`main.js`, `index.html`…) | Oui | Non |
| `.git`, `README.md`, `Dockerfile` | Non | Non |
| Le dossier `dist/` | C'est le résultat | Oui |
| Un serveur web simple (nginx par exemple) | Non | Oui |

Pour faire tourner le site, il suffit donc du dossier `dist/` et d'un petit serveur web. Tout le reste ne sert qu'à la compilation.

### 3. Quels risques de sécurité identifiez-vous ?

1. **L'utilisateur root** : si quelqu'un arrive à exploiter une faille de l'application, il a tous les droits dans le conteneur, et il lui est plus facile d'essayer d'en sortir pour atteindre la machine.
2. **Les vulnérabilités connues** : 139 failles, entre autres dans OpenSSL (le chiffrement), dans des bibliothèques système et dans npm.
3. **Une version de Node abandonnée** : plus aucun correctif ne sortira.
4. **Trop d'outils dans l'image** : npm, un shell, le gestionnaire de paquets… Un attaquant pourrait s'en servir pour télécharger et lancer ses propres programmes.
5. **Une fuite d'informations** : le dossier `.git` contient l'historique du projet, les noms et e-mails des auteurs, et éventuellement des mots de passe ajoutés par erreur.
6. **Des versions non fixées** : l'image et `serve` ne sont pas figés sur une version précise. Le résultat peut donc changer d'un build à l'autre sans qu'on le sache.
7. **Aucune limite au lancement** : le conteneur peut utiliser toute la mémoire et tout le processeur de la machine, et il garde les droits par défaut de Docker.
8. **Pas de vérification de santé** (`HEALTHCHECK`) : si l'application plante, personne n'est prévenu.

### 4. Quelles améliorations recommanderiez-vous en priorité ?

1. Séparer la compilation et l'exécution (build en plusieurs étapes), pour ne garder que le site compilé dans une image légère avec nginx.
2. Faire tourner l'application avec un utilisateur normal plutôt que root.
3. Utiliser une image de base récente et maintenue, avec une version précise.
4. Ajouter un fichier `.dockerignore` pour ne plus copier `.git` et les fichiers inutiles.
5. Utiliser `npm ci` pour installer exactement les versions prévues.
6. Limiter les ressources et les droits du conteneur au lancement.
7. Ajouter un `HEALTHCHECK`.
8. Scanner l'image régulièrement avec Trivy.

### Tableau : état initial de l'image et risques identifiés

| Critère | Constat | Risque | Gravité |
|---|---|---|---|
| Image de base | `node:18-alpine`, Node 18 plus maintenu | Failles non corrigées | Élevée |
| Version | Pas de version précise | Image qui change d'un build à l'autre | Moyenne |
| Utilisateur | root | Attaquant avec tous les droits | Élevée |
| Taille | 221 MB | Beaucoup de choses inutiles à attaquer | Moyenne |
| Outils présents | Node, npm, yarn, serve, shell | Outils réutilisables par un attaquant | Élevée |
| Vulnérabilités | 139 (3 critiques, 43 élevées, 55 moyennes, 38 faibles) | Failles connues exploitables | Critique |
| Fichiers copiés | `.git`, sources, Dockerfile (pas de `.dockerignore`) | Fuite d'informations | Moyenne |
| Limites au lancement | Aucune | Saturation de la machine, droits trop larges | Élevée |
| Surveillance | Pas de `HEALTHCHECK` | Panne non détectée | Faible |

---

## Partie 2 : image sécurisée, comparatif et analyse

### Construction et vérification

```bash
docker build -t quiz-docker:secure .
docker compose up -d
```

Le conteneur démarre bien et Docker l'indique comme « healthy ». En ouvrant http://localhost:8090 dans le navigateur, on retrouve la page du quiz avec le bouton « Commencer », et le quiz fonctionne normalement. J'ai utilisé le port 8090 car le 8080 était déjà pris sur ma machine.

### Publication sur Docker Hub

```bash
docker tag quiz-docker:secure 70288/quiz-docker:secure
docker tag quiz-docker:secure 70288/quiz-docker:1.0.0
docker push 70288/quiz-docker:secure
docker push 70288/quiz-docker:1.0.0
```

L'image est disponible sur https://hub.docker.com/r/70288/quiz-docker. J'ai ajouté un tag `1.0.0` en plus de `secure`, pour avoir une version précise. Pour vérifier, j'ai supprimé l'image de mon poste, je l'ai retéléchargée depuis Docker Hub (`docker pull`) et elle fonctionne.

Je n'ai publié que l'image sécurisée : mettre en ligne l'image initiale, avec ses 139 failles et son dossier `.git`, n'aurait pas eu de sens.

### Tableau comparatif

| Critère | Image initiale | Image sécurisée |
|---|---|---|
| Image de base | `node:18-alpine` (plus maintenue) | `nginx-unprivileged` 1.30.6, version légère et à jour |
| Version de l'image | Approximative (`18-alpine`) | Précise et figée |
| Taille | 221 MB | 33,4 MB |
| Outils de développement (Node, npm, yarn…) | Présents | Absents |
| `.git` et sources dans l'image | Oui | Non, seulement le site compilé |
| Utilisation de `.dockerignore` | Non | Oui |
| Utilisation de `COPY` plutôt que `ADD` | Oui | Oui |
| Build multi-étapes | Non | Oui |
| Utilisateur | root | nginx (utilisateur normal) |
| Droits spéciaux Linux (capabilities) | Ceux par défaut de Docker | Aucun |
| Fichiers modifiables dans le conteneur | Oui | Non (lecture seule) |
| Limite de mémoire | Aucune | 64 MB |
| Limite de processeur | Aucune | 0,5 CPU |
| Limite du nombre de processus | Aucune | 50 |
| Accès au socket Docker | Non (mais utilisé pour le scan Trivy) | Non, même pour le scan |
| Vérification de santé (`HEALTHCHECK`) | Non | Oui |
| CVE critiques | 3 | 0 |
| CVE élevées | 43 | 0 |
| CVE moyennes | 55 | 0 |
| CVE faibles | 38 | 0 |
| Total CVE | 139 | 0 |
| Problèmes signalés dans le Dockerfile | 2 (root, pas de healthcheck) | 0 |

### 1. Quelles modifications ont apporté les améliorations les plus significatives ?

La plus importante est **le build en plusieurs étapes**. Node et npm servent seulement à compiler le site dans une première étape. L'image finale ne garde que le résultat, servi par nginx. Rien que ça a supprimé 39 failles (toutes celles de npm) et environ 190 MB.

Ensuite, **le passage à une image de base récente** (Alpine 3.24 mise à jour) a fait disparaître les 100 autres failles, qui venaient du système.

Enfin, **l'utilisateur non-root et les restrictions au lancement** (lecture seule, aucun droit spécial, limites de ressources) ne retirent pas de failles, mais si l'une d'elles était exploitée un jour, l'attaquant serait très limité dans ce qu'il peut faire.

### 2. La taille de l'image a-t-elle diminué ? Pourquoi ?

Oui, elle passe de 221 MB à 33,4 MB, soit environ 85 % de moins.

C'est surtout grâce au build en plusieurs étapes : Node prenait à lui seul plus de 120 MB, et il n'est plus dans l'image finale. Il ne reste que nginx (environ 21 MB) et le site compilé (moins de 60 Ko). Le `.dockerignore` évite aussi de copier des fichiers inutiles comme le dossier `.git`.

### 3. Quelles recommandations concernent le Dockerfile et lesquelles concernent l'exécution du conteneur ?

**Dans le Dockerfile** (ce qu'il y a dans l'image) :
- utiliser une image de base minimale ;
- utiliser des versions précises ;
- ne pas utiliser root (`USER`) ;
- préférer `COPY` à `ADD` ;
- faire un build en plusieurs étapes ;
- ajouter un `.dockerignore` (ce n'est pas le Dockerfile lui-même, mais ça concerne aussi la construction).

**Au lancement du conteneur** (ce que le conteneur a le droit de faire) :
- limiter la mémoire, le processeur et le nombre de processus ;
- retirer les droits spéciaux et mettre les fichiers en lecture seule ;
- ne pas donner accès au socket Docker.

**Les deux** : ne pas utiliser root (je l'ai mis dans le Dockerfile et dans le `docker-compose.yml`) et vérifier régulièrement la sécurité.

Les deux côtés se complètent. Une image propre lancée avec trop de droits reste dangereuse. À l'inverse, des limites au lancement ne corrigent pas les failles d'une image.

### 4. Votre image est-elle désormais totalement sécurisée ? Justifiez votre réponse.

Non. Elle est beaucoup plus sûre qu'au départ, mais on ne peut jamais dire qu'une image est totalement sécurisée :

- Le « 0 faille » ne vaut que pour aujourd'hui. De nouvelles failles sont découvertes tout le temps, et dans quelques semaines il y en aura sûrement de nouvelles.
- Trivy ne trouve que les failles déjà connues. Il ne voit pas les failles encore inconnues, ni les erreurs dans le code de l'application.
- Il reste un shell et quelques outils dans l'image, parce que nginx en a besoin pour démarrer.
- Le site est servi en HTTP, sans chiffrement.
- Les protections au lancement ne marchent que si on les utilise : quelqu'un qui lance l'image avec un simple `docker run` sans options n'en profite pas.

La sécurité, c'est quelque chose qu'il faut entretenir en scannant et en mettant à jour régulièrement.

### 5. Quelles mesures complémentaires proposeriez-vous pour un déploiement en production ?

- **Scanner automatiquement** l'image à chaque modification et régulièrement (par exemple chaque nuit), et bloquer le déploiement s'il y a des failles graves.
- **Mettre à jour régulièrement** l'image de base et reconstruire l'image, idéalement avec un outil qui le propose automatiquement (Dependabot ou Renovate).
- **Signer l'image**, pour être sûr que celle qu'on déploie est bien la nôtre.
- **Passer en HTTPS** avec un reverse proxy devant le conteneur.
- **Utiliser une image encore plus minimale** (de type « distroless »), sans shell.
- **Mettre l'image dans un dépôt privé** plutôt que public.
- **Surveiller le conteneur** : récupérer les journaux et être alerté en cas de comportement anormal, par exemple si quelqu'un ouvre un shell dedans.
- **Imposer les règles de sécurité au niveau de la plateforme** (par exemple dans Kubernetes), pour qu'un conteneur lancé en root ou sans limites soit automatiquement refusé.
- **Garder la machine hôte et Docker à jour.**
