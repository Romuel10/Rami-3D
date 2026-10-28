# Serveur Internet de Rami Salon 3D

Le mode Wi-Fi fonctionne directement entre téléphones. Le mode Internet utilise ce serveur : les joueurs créent un salon, partagent son code à six chiffres et jouent chacun avec leur main privée. Le serveur vérifie chaque action et conserve les cartes cachées. Un salon accueille deux à quatre joueurs.

**Ce dépôt contient le serveur prêt à lancer ; aucun serveur public n’est hébergé automatiquement.** Il faut un ordinateur ou un VPS joignable par les joueurs. Le jeu ne demande aucun compte. Par défaut, les salons restent en mémoire. Une option de sauvegarde permet de reprendre les salons après un redémarrage.

## Lancement sur un ordinateur

Installer [Godot 4.6.3](https://godotengine.org/download/archive/4.6.3-stable/) pour le système du serveur, puis, depuis le dossier du projet :

```sh
godot --headless --path . --script server/server.gd -- --port=7357
```

La ligne `RAMI_SERVER_READY port=7357` confirme l’écoute. Avec le serveur sur un ordinateur du même Wi-Fi, saisir son adresse, par exemple `ws://192.168.1.20:7357`, dans le champ serveur Internet du jeu. L’adresse d’exemple doit être remplacée par celle de l’ordinateur.

## Accès par Internet

Utiliser un nom de domaine associé à un VPS. Copier le projet sur ce VPS, installer Godot 4.6.3 et lancer la commande ci-dessus. Mettre un reverse proxy TLS devant le serveur ; les joueurs utilisent alors, par exemple, `wss://rami.votre-domaine.fr`.

Exemple de configuration [Caddy](https://caddyserver.com/docs/) (remplacer le domaine) :

```caddyfile
rami.votre-domaine.fr {
    reverse_proxy 127.0.0.1:7357
}
```

Ouvrir les ports publics 80 et 443 pour Caddy et garder le port 7357 réservé au proxy dans le pare-feu. Caddy transporte les connexions WebSocket et gère le certificat HTTPS. L’application prend en charge les adresses `ws://` et `wss://`. Pour une connexion distante, utiliser `wss://` afin de chiffrer cartes et jetons de reconnexion.

Exemple de service Linux `systemd` (adapter les chemins et créer un utilisateur système `rami` propriétaire du projet) :

```ini
[Unit]
Description=Rami Salon game server
After=network-online.target
Wants=network-online.target

[Service]
User=rami
WorkingDirectory=/srv/rami-3d
ExecStart=/usr/local/bin/godot --headless --path /srv/rami-3d --script server/server.gd -- --port=7357 --state-file=/var/lib/rami/rooms.json
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
Environment=HOME=/var/lib/rami
StateDirectory=rami

[Install]
WantedBy=multi-user.target
```

## Jouer

1. Tous les joueurs saisissent la même adresse de serveur.
2. Le premier crée un salon et transmet son code.
3. Les autres rejoignent le salon avec ce code.
4. L’hôte lance la partie quand les joueurs sont connectés.

## Départs, forfaits et reconnexion

Avant le début, quitter un salon libère sa place et transfère le rôle de créateur si nécessaire. Pendant un match :

- **Quitter volontairement** transmet un abandon authentifié : le joueur perd immédiatement sa participation. À deux, l’adversaire gagne le match. À trois ou quatre, le joueur est éliminé ; les autres continuent et les tours sautent sa place. Le dernier joueur actif gagne par forfait.
- **Une coupure de connexion** suspend la partie et laisse **60 secondes** à chaque absent pour revenir. Après ce délai, l’absence devient un forfait. Un téléphone hors ligne ne peut transmettre un abandon immédiatement ; le délai s’applique jusqu’à réception de cet abandon ou à son expiration.
- **La reprise** conserve la même main et la même place grâce à un jeton enregistré sur le téléphone. Elle fonctionne aussi après fermeture du jeu avec **Retrouver mon salon**, dans le délai accordé. Une place éliminée ne peut plus être récupérée.
- **L’hôte Wi-Fi** héberge le serveur sur son téléphone. S’il abandonne, la table ferme et les autres joueurs actifs sont déclarés gagnants. Sur ce serveur Internet dédié, le départ du créateur élimine seulement ce joueur.

Après un match terminé, créer un nouveau salon pour rejouer.

## Conserver les salons après redémarrage

Choisir un fichier privé accessible en écriture à l’utilisateur du service, hors du dépôt et des répertoires servis par le proxy :

```sh
godot --headless --path . --script server/server.gd -- --port=7357 --state-file=/var/lib/rami/rooms.json
```

Le serveur enregistre les salons, cartes, scores et jetons de reprise avec une écriture temporaire et une copie de secours `.bak`. Au démarrage, il valide les parties avant restauration et marque tous les téléphones déconnectés. Ils disposent alors de 60 secondes depuis le redémarrage pour rejoindre leur place. La copie de secours est utilisée si le fichier principal est endommagé.

Ce fichier contient les mains privées et les jetons d’accès : il est créé avec les droits `0600` sur Unix. Garder le répertoire privé, conserver les deux fichiers ensemble et sauvegarder ce volume pour une reprise après perte de machine. Sans `--state-file`, un redémarrage termine les salons.

## Limites

- La reconnexion a une durée limitée ; elle ne prolonge pas indéfiniment un match.
- 64 salons et 256 connexions au maximum par processus ; salons entièrement déconnectés supprimés après 15 minutes, salons inactifs après 24 heures.
- Un code de salon facilite une invitation privée mais ne remplace pas un compte ou une authentification forte.
- L’hébergement public, le domaine et les certificats doivent être configurés sur le serveur choisi.

## Vérification

Le test utilise uniquement Python et lance temporairement le serveur sur un port local libre :

```sh
GODOT_BIN=/chemin/vers/godot python3 tests/test_internet.py
GODOT_BIN=/chemin/vers/godot python3 tests/test_forfeit_server.py
GODOT_BIN=/chemin/vers/godot python3 tests/test_server_restart.py
```

Ces tests vérifient aussi les départs volontaires, les forfaits après délai, les parties à trois joueurs, la reprise après fermeture du client, la restauration du serveur et la récupération depuis une copie de secours. Le premier vérifie les salons indépendants, les droits de l’hôte, les mains privées, l’ordre des tours, la pause lors d’une déconnexion et la reconnexion sans perte de main.
