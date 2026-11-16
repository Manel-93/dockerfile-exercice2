FROM node:18-alpine
WORKDIR /app
COPY package.json package-lock.json ./

# Copier les fichiers et dossiers présents à la racine (adaptez selon votre arborescence)
COPY images ./images    
COPY public ./public
# (ou copiez tout le dossier courant si nécessaire avec : COPY . . )

RUN npm install \
    && npm install -g serve \
    && npm run build \
    && rm -rf node_modules
EXPOSE 3000
CMD [ "serve", "-s", "build" ]