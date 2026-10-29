# Héberger le multijoueur sur Vercel

Ce dossier contient le serveur Internet Node.js de **Rami Salon 3D**, adapté aux WebSockets natifs des Vercel Functions. Le jeu Android conserve son protocole existant : rami 2–4 joueurs, Tri en duel 6/12 cartes, mains privées, code à six chiffres, reprise et défaite par abandon.

**Le code est prêt à déployer et testé localement. Aucun compte Vercel ni stockage de production n’est créé par ces fichiers.** Le déploiement nécessite votre compte Vercel et une base Redis externe. Les identifiants de cette base restent dans Vercel ; ils ne vont jamais dans l’APK, dans une invitation ou dans Git.

## Déployer

[Déployer sur Vercel](https://vercel.com/new/clone?repository-url=https%3A%2F%2Fgithub.com%2FRomuel10%2FRami-3D&root-directory=vercel&project-name=rami-salon&env=REDIS_URL&envDescription=Connexion%20Redis%20TLS%20pour%20conserver%20les%20parties)

Le bouton propose le dépôt et **Root Directory = `vercel`**. Pour garder les mises à jour du dépôt d’origine, vous pouvez aussi importer `Romuel10/Rami-3D` directement dans le tableau de bord Vercel, puis choisir cette même Root Directory.

1. Dans le projet Vercel, choisir **Framework Preset: Other**, **Root Directory: `vercel`**, Node.js **24.x** et l’installation `npm ci`. Il n’y a pas de compilation front-end ni de dossier `dist` à produire. `api/ws.mjs` exporte un serveur HTTP Node standard.
2. Dans **Storage / Marketplace**, connecter une base **Redis** ou **Upstash for Redis** au projet. Le stockage doit prendre en charge Redis TCP/TLS, Lua, les ensembles triés et Pub/Sub.
3. Vérifier la variable serveur **`REDIS_URL`**, de la forme `rediss://…`. Une URL REST `https://…` et un jeton REST seuls ne suffisent pas à `ioredis`. Utiliser la chaîne de connexion Redis TLS fournie par le stockage. Ne jamais coller sa valeur dans le chat ou dans le code.
4. Facultatif : définir **`RAMI_REDIS_PREFIX`**, par exemple `rami:production:`. Utiliser un préfixe distinct pour les environnements de test qui partagent une base.
5. Déployer, puis ouvrir `https://VOTRE-PROJET.vercel.app/health`. Le résultat doit contenir **`"ready": true`**. Sans Redis disponible, le serveur répond honnêtement **503** et ne crée aucune partie en mémoire temporaire.
6. Utiliser l’URL **Production** publique dans Android : `wss://VOTRE-PROJET.vercel.app/api/ws`. Une URL de prévisualisation protégée par une connexion Vercel ne peut pas être utilisée directement par les téléphones.
7. Créer un salon sur un téléphone et rejoindre son code depuis un autre. L’URL du serveur n’est à configurer qu’une fois par téléphone ou à intégrer comme adresse par défaut dans une prochaine compilation de l’APK.

Les quotas et les coûts dépendent des offres Vercel et Redis choisies. Le projet ne garantit pas un hébergement gratuit permanent. L’utilisation des WebSockets est bornée par la durée d’une Function ; le client sait se reconnecter avec sa place et ses cartes sauvegardées.

## Données et reprise

- Les salons et l’état du moteur restent dans Redis avec une expiration de 24 heures d’inactivité. Aucune main adverse, pioche ou graine aléatoire privée n’est transmise au client.
- Les mutations d’un salon sont sérialisées dans Redis. Un verrou muni d’un jeton de contrôle empêche un ancien détenteur de réécrire un état plus récent. L’enregistrement et la notification sont atomiques.
- Pub/Sub transporte uniquement le code du salon ; chaque instance reconstruit une vue privée différente pour chaque téléphone. Après une reconnexion Redis, les vues sont rechargées pour récupérer les notifications manquées.
- Un départ volontaire transmis au serveur entraîne un forfait immédiat. Une coupure détectée laisse 60 secondes pour revenir. En cas d’arrêt brutal d’une instance sans fermeture TCP, un bail de présence de 15 secondes détecte sa disparition, puis le délai de reprise s’applique.
- Un jeton privé valide peut reprendre sa propre place sur une nouvelle instance. L’ancienne connexion est invalidée ; sa fermeture tardive ne peut pas effacer la nouvelle place.
- Les salons à trois ou quatre joueurs continuent après élimination ; le dernier actif gagne. Le Tri reste limité à deux joueurs.

Redis est un stockage privé de parties : choisir TLS, conserver ses accès hors du dépôt et utiliser les sauvegardes proposées par votre fournisseur si vous souhaitez résister à la perte de la base elle-même. Le redémarrage d’une Function n’efface pas les parties ; la suppression de Redis les efface.

## Vérifier localement

Prérequis : Node.js 24, `redis-server` et, pour l’interopérabilité complète, Godot 4.6.3.

Depuis la racine du dépôt :

```sh
npm ci --prefix vercel
GODOT_BIN=/chemin/vers/godot npm test --prefix vercel
```

Les tests démarrent leurs propres serveurs Redis sur des ports locaux libres, puis les arrêtent. Si `redis-server` n’est pas dans le `PATH`, définir `REDIS_SERVER_BIN=/chemin/vers/redis-server`. Ils ne touchent pas à une base de production.

Les suites couvrent deux instances WebSocket distinctes, les actions concurrentes, les mains privées, le refus d’un troisième joueur en Tri, le redémarrage d’une instance, la reprise des cartes, le départ du créateur, les forfaits après délai et le démarrage à froid. Avec `GODOT_BIN`, le **vrai `RamiNetwork` du client Android** crée/rejoint/joue/reprend/abandonne un salon dans les trois formats.

Le moteur JavaScript est aussi comparé au moteur Godot avec des observations de combinaisons et d’actions. La CI génère ces observations avec `vercel/tests/export_godot_parity.gd`, puis passe leur fichier via `GODOT_PARITY_FILE` au test Node.

Pour lancer manuellement le service local, démarrer Redis séparément puis :

```sh
REDIS_URL=redis://127.0.0.1:6379 npm start --prefix vercel
```

L’adresse de test est `ws://127.0.0.1:7357/api/ws`. Le serveur Godot du dossier `server/` reste une autre option pour les ordinateurs/VPS ; le mode Wi-Fi direct entre téléphones ne nécessite pas Vercel.

## Références officielles

- [WebSockets sur Vercel Functions](https://vercel.com/docs/functions/websockets)
- [Stockage Redis sur Vercel](https://vercel.com/docs/redis)
- [Root Directory pour le bouton de déploiement](https://vercel.com/docs/deploy-button/build-settings)
