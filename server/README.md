# Serveur Internet de Rami Salon 3D

Le mode Wi-Fi fonctionne directement entre téléphones. Le mode Internet utilise ce serveur : les joueurs créent un salon, partagent son code à six chiffres et jouent chacun avec leur main privée. Le serveur vérifie chaque action et conserve les cartes cachées. Un salon accueille deux à quatre joueurs.

**Ce dépôt contient le serveur prêt à lancer ; aucun serveur public n’est hébergé automatiquement.** Il faut un ordinateur ou un VPS joignable par les joueurs. Le jeu ne demande aucun compte et le serveur ne conserve rien sur disque. Un redémarrage termine les salons en cours.

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
ExecStart=/usr/local/bin/godot --headless --path /srv/rami-3d --script server/server.gd -- --port=7357
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

Une coupure réseau suspend la partie. Le client tente de rejoindre sa place grâce à un jeton associé à sa connexion ; les autres joueurs ne peuvent pas prendre cette place. Fermer complètement l’application ou quitter volontairement le salon efface ce jeton côté téléphone : la reprise de cette place n’est alors plus possible. Après une partie, créer un nouveau salon pour rejouer.

## Limites de cette première version

- Les salons et parties sont en mémoire ; aucune reprise après redémarrage du serveur.
- Un joueur qui quitte définitivement peut bloquer sa partie. Créer un nouveau salon dans ce cas.
- 64 salons et 256 connexions au maximum par processus ; salons entièrement déconnectés supprimés après 15 minutes, salons inactifs après 24 heures.
- Un code de salon facilite une invitation privée mais ne remplace pas un compte ou une authentification forte.
- L’hébergement public, le domaine et les certificats doivent être configurés sur le serveur choisi.

## Vérification

Le test utilise uniquement Python et lance temporairement le serveur sur un port local libre :

```sh
GODOT_BIN=/chemin/vers/godot python3 tests/test_internet.py
```

Il vérifie les salons indépendants, les droits de l’hôte, les mains privées, l’ordre des tours, la pause lors d’une déconnexion et la reconnexion sans perte de main.
