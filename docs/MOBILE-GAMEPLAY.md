# Rami Salon 3D 0.3.0 — interactions et reprise

## Vérification automatisée

Le workflow Android exécute les tests existants du moteur, des réseaux, de l’interface, des animations, du tactile, du guide, du tri et de la musique avant de compiler l’APK. Les nouveaux contrôles couvrent :

- `tests/test_mobile_gameplay.gd` : 135 contrôles, sauvegarde avant/après pioche, copie de secours, rejet d’états incohérents, état du générateur aléatoire, aperçu de l’ouverture et des compléments, neuf manches complètes réparties sur les trois difficultés, fin de manche avec deux cartes en mode facile, distribution suivante identique après reprise, conservation de 108 cartes, scores et statistiques sans doublons, invitations valides/invalides et connexion WebSocket réelle depuis l’invitation.
- `tests/test_mobile_ui.gd` : 61 contrôles avec rendu, reprise par les callbacks de l’application, sons indépendants de la musique, rangement et ordre mémorisé, second doigt, annulation, pose invalide, pose de deux groupes pour l’ouverture, défausse gagnante, manche suivante, complément et annulation sur mise à jour réseau. Les événements de toucher passent par `Input.parse_input_event` et les collisions 3D en 1440×900 et 2400×1080.
- `tests/test_hand_view.gd` : 164 contrôles du rendu et de la sélection ; les dos adverses sont vérifiés séparément des cartes publiques.
- `tests/test_animations.gd` : 359 contrôles, conservation des instances et des destinations pendant les changements de scène et les actions rapides, avec les nouvelles mains adverses.

Le test d’interface attend la fin des actions successives de l’IA dans un délai borné. Il ne suppose plus que toutes les actions d’un tour se produisent en une seule mise à jour.

Pour un environnement de test isolé :

```sh
XDG_DATA_HOME=/tmp/rami-test-mobile godot --headless --path . --script tests/test_mobile_gameplay.gd
LIBGL_ALWAYS_SOFTWARE=1 XDG_DATA_HOME=/tmp/rami-test-gestes xvfb-run -a godot --audio-driver Dummy --path . --script tests/test_mobile_ui.gd
```

Les fichiers de test utilisent le répertoire utilisateur Godot de l’environnement choisi. Utiliser un répertoire temporaire pour garder sa partie personnelle.

## Données et confidentialité

Le fichier solo contient uniquement la partie locale, les préférences de difficulté et l’ordre de la main. L’écriture passe par un fichier temporaire, puis une rotation vers une copie de secours ; les objets exécutables ne sont pas désérialisés. La restauration valide les identités des 108 cartes, les poses, le tour et l’historique des scores avant de remplacer l’état courant. Le générateur aléatoire est mémorisé pour conserver les futurs recyclages de la défausse.

Les mains adverses affichées en réseau utilisent uniquement le nombre public de cartes et des dos génériques. Les invitations transportent l’adresse du serveur et le code du salon, sans jeton de reconnexion ni carte privée. Les secrets et les bases Supabase des autres applications ne sont pas nécessaires à cette fonctionnalité.

## Essais restant à faire sur appareil

Installation de l’APK, passage réel en arrière-plan/appel entrant, sortie forcée Android, qualité audio et performances sur les téléphones ciblés. Le lien d’invitation se colle dans le jeu ; aucun gestionnaire Android de lien profond n’est installé. Les parties Internet nécessitent toujours le serveur décrit dans `server/README.md`.

Les aperçus de documentation sont exclus de l’import Godot par `docs/.gdignore`. Le contrôle des journaux utilise `grep`, disponible sur les runners GitHub.
