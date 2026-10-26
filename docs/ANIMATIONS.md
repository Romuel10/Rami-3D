# Animations des cartes — 0.2.1

![Distribution, tri, pioche et pose](screenshots/animations.webp)

## Ce qui change

La distribution ouvre la main progressivement depuis la pioche. Chaque carte a un dos imprimé visible pendant son retournement. La pioche, la pose, les compléments et la défausse suivent un déplacement courbe avec rotation et changement de taille. Le tri fait glisser les cartes existantes, et la sélection se relève puis redescend en douceur.

Les fenêtres apparaissent en fondu et l’indication du joueur actif s’éclaire brièvement à chaque changement de tour. Ces animations sont ponctuelles : aucune boucle de mouvement ne continue sur une table au repos.

## Fonctionnement

- Les cartes visibles sont conservées par identifiant ; les dos anonymes de la pioche ont leurs propres clés.
- Une carte garde sa position à l’écran lorsqu’elle passe entre la main attachée à la caméra et la table en coordonnées du monde.
- Une nouvelle destination interrompt le trajet précédent à sa position actuelle. Une mise à jour identique ne relance pas l’animation.
- Le signal de sélection est connecté une seule fois et consulte le rôle actuel de la carte, notamment l’index de sa combinaison.
- Le relèvement visuel et la zone tactile suivent la même hauteur. Le redimensionnement recalcule immédiatement les positions ; quitter une partie libère les cartes et leurs animations.
- Textures et matériaux imprimés sont partagés. Les données utilisées sont celles de la main du joueur et de la table publique ; aucune main adverse n’est requise.

## Vérifications réalisées

Godot **4.6.3**, sous Linux :

- **229 contrôles d’animation** : distribution décalée, poses intermédiaires, tri, conservation des instances, pioche, défausse, carte révélée sous la défausse, pose, mise à jour des index de combinaison, interruption, redimensionnement et fermeture.
- **164 contrôles du rendu et de la sélection** en 1440×900 et 2400×1080, avec de vrais événements de souris dans le moteur physique. Cartes hautes d’au moins 249 pixels logiques et relèvement d’environ 24 pixels.
- Tests existants réussis : moteur (594 contrôles et cinq parties IA), interface (59), nouveautés (79), coach (46), défi de tri (45), musique (30), déduplication tactile, réseau local et serveur Internet.
- Aperçu enregistré avec le moteur graphique Compatibility et Mesa llvmpipe ; aucune image de synthèse externe n’est utilisée.

L’APK et les performances sur un téléphone physique doivent être vérifiés séparément. La compilation GitHub exécute les tests avant d’exporter l’APK ; les demandes de fusion produisent un artefact de test sans publier de version.

## Reproduire

```sh
godot --headless --path . --editor --import --quit
godot --headless --path . --script tests/test_animations.gd
godot --audio-driver Dummy --path . --script tests/test_hand_view.gd
godot --audio-driver Dummy --path . --fixed-fps 30 --write-movie builds/animations.avi --script tests/capture_animations.gd
```

Les deux dernières commandes nécessitent un affichage graphique, éventuellement Xvfb. Pour isoler les préférences, définir un `XDG_DATA_HOME` temporaire lors des vérifications. Le défi de tri reste un mode séparé ; ses échanges de cartes ne sont pas modifiés par cette mise à jour.
