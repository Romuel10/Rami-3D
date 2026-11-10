# Salons Rami/Tri sur Supabase

Projet : `mppunkypxdqyazoojksv`. Le client utilise directement :

```
wss://mppunkypxdqyazoojksv.supabase.co/functions/v1/rami-online
```

[État public](https://mppunkypxdqyazoojksv.supabase.co/functions/v1/rami-online/health) · [Fonctions du projet](https://supabase.com/dashboard/project/mppunkypxdqyazoojksv/functions)

## Jouer

Tous les joueurs installent la même version, choisissent **Jouer avec des amis**, puis créent ou rejoignent un salon avec son code à six chiffres. Pour le Tri, choisir d’abord 6 ou 12 cartes par joueur. L’hôte lance la partie quand tout le monde est présent. Le téléphone de l’hôte ne fait pas fonctionner le serveur Internet.

Depuis la version 0.10.0, l’application utilise toujours ce serveur pour le menu entre amis. Les joueurs saisissent uniquement le code ; aucun réglage d’adresse n’est affiché.

## Fonctionnement

L’Edge Function exécute le même moteur JavaScript que `vercel/lib/engine.mjs`, vérifié contre le moteur Godot. Le protocole WebSocket reste celui de `scripts/network_manager.gd`. Chaque action relit l’état durable ; seule `viewFor` envoie une vue privée au joueur concerné. Les instances interrogent les versions enregistrées toutes les secondes pour synchroniser les autres téléphones.

Les mains, la pioche et les jetons de session restent dans `rami_private.rooms`, hors des schémas exposés. RLS est activé, sans accès `anon`/`authenticated`. Les cinq RPC sont `SECURITY INVOKER`, accordés uniquement à `service_role`. Le worker lit la clé secrète injectée par Supabase ; aucune clé d’administration n’est compilée dans l’APK ni stockée dans le dépôt.

Les connexions n’utilisent pas le contrôle JWT du point d’entrée : les joueurs créent/rejoignent un salon par invitation, puis leur place s’authentifie avec un jeton aléatoire privé de 192 bits dans les messages WSS. Un jeton de joueur ne donne accès qu’à sa propre place. Les paquets ont une limite de 32 Kio et de 30 messages/s par connexion ; le stockage limite le service à 64 salons non expirés.

Un bail Postgres de huit secondes sérialise les modifications d’un salon. Le jeton de verrou et le numéro de version empêchent un ancien worker d’écraser une sauvegarde récente. Sauvegarde et libération du verrou sont atomiques. Une perte réseau conserve la place 60 secondes ; un départ volontaire avant le démarrage la libère, pendant la partie il vaut abandon.

Les Edge Functions ont une durée maximale. Le serveur renouvelle chaque connexion au bout de 100 secondes. Le client tente immédiatement de reprendre sa place après une coupure et garde la main affichée pendant le premier essai. Un arrêt imprévu du worker est détecté après expiration du bail de présence de 15 secondes, puis applique le délai de reconnexion.

Le départ du dernier joueur libère le salon. Les salons expirent après 24 heures sans action de jeu et les lignes expirées sont purgées lors des créations suivantes.

Un match peut compter une, trois ou cinq manches. Dans un tournoi, les quatre places restent stables et chaque duel possède sa propre session. Les joueurs en attente reçoivent le tableau et le résultat des duels. Les vues de jeu sont envoyées uniquement aux deux joueurs du duel courant.

Les salons Internet de rami et de Tri peuvent utiliser une mise en Kirobo. Chaque joueur dispose d’un portefeuille privé et accepte sa mise avant le départ. La réservation et le règlement sont atomiques avec la sauvegarde du salon. La cagnotte revient au seul premier, ou chaque mise est rendue en cas d’égalité en tête ou d’expiration sans résultat. Les victoires solo sont enregistrées sur l’appareil puis synchronisées par reçus dédupliqués.

## Redéployer

Avec Supabase CLI installé, consulter `supabase --help` puis les aides des commandes de votre version. Appliquer les migrations de `supabase/migrations` au projet lié, puis déployer `rami-online` avec les fichiers de cette fonction et ses dépendances relatives dans `vercel/lib`. `supabase/config.toml` déclare l’entrée et son authentification de session. Ne pas activer le JWT de passerelle sans modifier le protocole du client.

Les variables `SUPABASE_URL` et `SUPABASE_SECRET_KEYS` sont injectées par Supabase. Le code accepte également la variable historique `SUPABASE_SERVICE_ROLE_KEY`. Ne jamais mettre ces secrets dans un message, une URL publique ou le dépôt.

## Vérifier

Les tests de règles et de protocole locaux nécessitent Node.js 24 et `redis-server` (voir aussi `vercel/README.md`) :

```bash
npm ci --prefix vercel
npm test --prefix vercel
```

Le script `supabase/tests/storage.sql` vérifie les verrous, les versions, les droits et les suppressions, dans une transaction entièrement annulée. L’exécuter avec une connexion SQL privilégiée de développement.

Pour tester explicitement un service déployé, sans clé administrative :

```bash
node supabase/tests/live.mjs wss://mppunkypxdqyazoojksv.supabase.co/functions/v1/rami-online --rotation
node supabase/tests/live.mjs wss://mppunkypxdqyazoojksv.supabase.co/functions/v1/rami-online --kirobo
```

Il crée des salons QA pour Rami à quatre et Tri 6/12, vérifie les mains privées, les refus d’actions, la reprise et l’abandon. `--rotation` attend aussi le renouvellement réel d’une connexion du salon d’attente. Ces essais consomment temporairement des salons et des requêtes du projet ; ils ne sont pas lancés automatiquement à chaque CI.

## Salons et vocal (0.10.0)

Le nombre `player_count` choisi par l’hôte est contrôlé à chaque entrée et au lancement : 2, 3 ou 4 au Rami et au Tri. Sans ce champ, un ancien salon garde sa capacité habituelle, jusqu’à quatre joueurs au Rami et deux au Tri. Les votes `rematch` sont liés au `session_id` terminé ; les codes et jetons privés sont conservés pour la revanche. Les départs libèrent les places dans le salon suivant, avec une nouvelle annonce d’index avant toute main privée.

Le vocal utilise des canaux **Realtime Broadcast privés**, exclusivement entre workers Supabase. Le secret de serveur et le nom aléatoire du canal ne sont jamais envoyés aux téléphones. Aucun droit `anon`/`authenticated` supplémentaire n’est créé. Les paquets audio IMA ADPCM indépendants de 80 ms / 16 kHz passent par la connexion WSS authentifiée du jeu ; le serveur impose le véritable émetteur, valide taille/format/séquence et limite le débit. L’audio ne passe jamais par les RPC Postgres et n’est ni stocké ni journalisé. Les files sont bornées et les données anciennes sont abandonnées en cas de congestion. Le canal est fermé lorsque le worker n’a plus de joueur dans ce salon. Le bouton vocal est désactivé si Realtime n’est pas prêt.

SDK de serveur épinglé : `@supabase/supabase-js@2.119.0` (verrou npm dans `vercel/package-lock.json`). Après déploiement, exécuter `NODE_USE_ENV_PROXY=1 node supabase/tests/social.mjs wss://mppunkypxdqyazoojksv.supabase.co/functions/v1/rami-online` pour le contrôle réel des places et du relais vocal. Les tests locaux couvrent aussi les revanches, les reconnexions et l’absence de fuite entre mains.
