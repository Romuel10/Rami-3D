# Rami Salon 3D

Jeu Android de rami en français : une table et des cartes en 3D, un mode solo contre 1 à 3 ordinateurs, et des parties privées à 2–4 joueurs où chacun utilise son téléphone. Projet réalisé avec Godot 4.6.3, sans publicité, compte ni achat intégré.

## Télécharger

- [Installer l’APK Android v0.1.0 — 57 Mo](https://github.com/Romuel10/Rami-3D/releases/download/v0.1.0/rami-3d.apk)
- [Version et fichiers téléchargeables](https://github.com/Romuel10/Rami-3D/releases/tag/v0.1.0)
- [Rapport de vérification](docs/VERIFICATION.txt)

![Une table de rami en 3D](docs/screenshots/game.png)

## Installer et jouer

1. Télécharger `rami-3d.apk` depuis la version ci-dessus sur un téléphone Android 7 ou ultérieur (ARM 32/64 bits).
2. Ouvrir l’APK et autoriser l’installation depuis l’application utilisée pour ouvrir ce fichier, si Android le demande.
3. Lancer **Rami Salon 3D**. Le jeu s’affiche en paysage.
4. Choisir **Jouer contre l’ordinateur** pour une partie immédiate sans connexion.

L’APK fourni est signé pour les essais. Ce n’est pas une publication sur Google Play. L’installation et les performances restent à vérifier sur des téléphones physiques ; les essais de cette livraison ont été effectués sous Linux avec Godot et sur des connexions réseau locales distinctes.

## Avec des amis sur le même Wi-Fi

Tous les téléphones doivent être connectés au même Wi-Fi ou au même point d’accès, avec les communications entre appareils autorisées.

- Sur le premier téléphone : **Jouer avec des amis → Même Wi-Fi → Créer un salon**.
- Transmettre l’adresse affichée (par exemple `192.168.1.20:7357`) et le code à six chiffres.
- Sur chaque autre téléphone : **Même Wi-Fi**, saisir cette adresse et ce code, puis **Rejoindre le salon**.
- L’hôte touche **Commencer la partie** quand les joueurs sont présents.

L’hôte garde le jeu ouvert pendant la partie. Les adresses et codes figurant dans ce guide sont des exemples. Si le salon reste inaccessible, vérifier que le réseau Wi-Fi ne bloque pas les communications entre appareils ; les réseaux invités les bloquent souvent.

## Avec des amis par Internet

Le client Android et le serveur Internet sont implémentés et testés ensemble. **Aucun serveur public n’est actuellement hébergé : il faut d’abord installer le serveur fourni sur un ordinateur/VPS accessible par Internet.** Le guide [server/README.md](server/README.md) donne la commande de lancement et la configuration WSS.

Une fois le serveur accessible :

1. Tous les joueurs choisissent **Internet** et saisissent la même adresse `wss://…`.
2. Le premier crée un salon et partage son code.
3. Les autres saisissent le code et rejoignent le salon.
4. Le créateur commence la partie.

Chaque connexion reçoit uniquement sa propre main. Le serveur valide les actions et suspend la partie pendant une coupure réseau. La reconnexion automatique ou le bouton **Se reconnecter** récupère la même place tant que l’application reste ouverte. Un arrêt complet du jeu efface le jeton de reconnexion ; les salons ne survivent pas à un redémarrage du serveur. Pour rejouer en multijoueur, créer un nouveau salon.

## Règles de cette version

- 108 cartes : deux jeux de 52 cartes et quatre jokers. Treize cartes par joueur.
- À chaque tour : piocher, poser/compléter si possible, puis défausser une carte.
- Brelan/carré : trois/quatre valeurs identiques avec des couleurs différentes.
- Suite : au moins trois cartes consécutives de même couleur. As avant le 2 ou après le roi ; pas de roi-as-2.
- Première pose : au moins 30 points en une ou plusieurs combinaisons. Nombres à leur valeur, figures à 10, as à 1 dans une suite basse et à 11 en suite haute ou en brelan. Le joker prend la valeur de la carte remplacée.
- Au plus la moitié des cartes d’une combinaison peuvent être des jokers.
- Après l’ouverture, on peut compléter les combinaisons de tous les joueurs.
- Il faut garder une carte pour la défausse finale. Le premier à vider sa main gagne la manche.
- La pioche épuisée recycle la défausse en conservant sa carte visible.

Touchez les cartes pour les sélectionner. **Suggestion** sélectionne des combinaisons compatibles avec l’ouverture à 30 points ; **Poser** les joue. **Compléter** propose toutes les combinaisons existantes, même celles qui ne sont plus affichées sur la table lorsque celle-ci contient plus de huit groupes. **Trier** alterne couleur et valeur.

## Ouvrir et compiler le projet

Ouvrir `project.godot` dans Godot 4.6.3. La scène principale est `main.tscn`. La version utilise le moteur graphique Compatibility pour limiter les exigences matérielles.

Pour compiler l’APK, installer les modèles d’export Android de Godot 4.6.3, Java et le SDK Android (platform-tools et build-tools 36), puis configurer leurs chemins dans les paramètres de l’éditeur Godot. Le profil `Android` est fourni sans chemin local ni secret de signature.

```sh
godot --headless --path . --editor --import --quit
godot --headless --path . --export-debug Android builds/rami-3d.apk
```

Avant une distribution Google Play, préparer une signature de production et un export AAB, puis tester l’application sur les téléphones ciblés.

## Vérifications

```sh
godot --headless --path . --script tests/test_engine.gd
godot --headless --path . --script tests/test_network.gd
godot --headless --path . --script tests/test_game_ui.gd
godot --headless --path . --script tests/test_card_input.gd
GODOT_BIN=/chemin/vers/godot python3 tests/test_internet.py
```

Le moteur est testé pour la validité des poses, les jokers, l’ordre des tours, la conservation des cartes et les parties IA complètes. Les tests réseau vérifient les mains privées, les salons distincts, les codes, les droits du créateur, la pause et la reconnexion. Le test d’intégration `tests/test_game_ui.gd` couvre une vraie partie via l’interface.

## Fichiers principaux

- `scripts/main.gd` : interface et table 3D.
- `scripts/card_3d.gd` : cartes, graphismes vectoriels et sélection tactile.
- `scripts/rami_engine.gd` : règles et IA.
- `scripts/network_manager.gd` : client réseau et hôte Wi-Fi.
- `server/server.gd` : serveur Internet indépendant avec salons privés.

Les graphismes des cartes et l’icône sont générés pour ce projet. Les polices Open Sans et Noto Serif sont accompagnées de leurs notices de licence dans `assets/`. Godot est distribué sous [licence MIT](https://godotengine.org/license/).
