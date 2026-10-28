# Version 0.6.0 — table physique et téléchargement Android

Le plateau utilise des maillages pour le bois, la bordure, le cuir, le feutre et les coutures. Les textures sont générées localement à partir de bruit et de trame, sans service distant. Les matériaux et les textures sont partagés entre les parties. Un seul éclairage projette des ombres ; le rendu reste compatible avec le moteur Compatibility de Godot sur Android.

Les adversaires occupent des places distinctes autour du plateau, avec des cartes dressées, des mains, des manches et un dossier de siège. Les cartes adverses sont des dos génériques construits à partir du nombre public de cartes ; aucune valeur cachée n’est nécessaire au rendu. Ces dos ne possèdent pas de collision de sélection. La géométrie décorative ne participe jamais au picking.

Les grandes cartes du joueur conservent leurs dimensions, leurs valeurs accessibles, leurs collisions et leurs animations. Le carton possède des chants biseautés, un matériau papier mat et un grain discret. Les figures V/D/R sont illustrées et les dos disposent d’un motif gravé symétrique. Ces ressources sont générées par le projet.

Les éléments de décor ne sont pas recréés à chaque action. Les places s’adaptent au nombre de joueurs et à la place du téléphone qui observe la partie, y compris pour un client autre que l’hôte.

## Erreur GitHub Actions corrigée

Les anciennes compilations 0.4.0 et 0.5.0 avaient créé et envoyé l’APK dans leurs artefacts. Elles étaient affichées en échec uniquement parce que les quatre secrets de signature durable n’étaient pas configurés.

La version 0.6.0 affiche une compilation réussie lorsque les tests, l’export, la signature de test et l’upload ont réussi. La publication dans Releases est simplement ignorée tant que la clé durable n’est pas configurée. Un résumé fournit le lien vers l’archive de l’APK et les instructions pour extraire `rami-3d.apk`. Une configuration partielle ou invalide de la clé reste rejetée.

## Vérifications

La [compilation Android 40736372281](https://github.com/Romuel10/Rami-3D/actions/runs/40736372281) est terminée avec le statut **success**. Tests, rendus, export et upload ont réussi. L’[archive APK 0.6.0](https://github.com/Romuel10/Rami-3D/actions/runs/40736372281/artifacts/12836114444) est disponible ; la publication dans Releases a été ignorée comme prévu en l’absence de clé durable.

`tests/test_table_realism.gd` contrôle les matériaux texturés, les places distinctes, la profondeur, les dos privés dressés, l’absence de collisions décoratives, la conservation des instances et le changement de place entre hôte et client. En rendu 1440×900 et 2400×1080, les 13 cartes du joueur restent contenues dans l’écran, hautes de plus de 200 pixels logiques, séparées des boutons et sélectionnables par leurs coins de valeur.

Les suites historiques vérifient aussi les gestes réels, les nouvelles destinations d’animation, le Tri, les sauvegardes, les forfaits et les commandes de l’interface. Le workflow Android exécute ces suites avant l’export.

Aucun téléphone physique n’a été utilisé ici. La fluidité, la chauffe et l’installation restent à vérifier sur les appareils ciblés. La clé Android durable et l’hébergement Internet sont des configurations distinctes du rendu.
