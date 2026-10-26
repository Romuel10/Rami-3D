# Rami Salon 3D 0.2.1 — des cartes en mouvement

Les cartes suivent maintenant leurs déplacements au lieu de disparaître et de réapparaître à chaque action.

- Distribution progressive avec retournement depuis la pioche.
- Déplacements courbes pour piocher, poser, compléter et défausser.
- Tri de la main par glissement des cartes et relèvement doux de la sélection.
- Les cartes conservent leur position visible lorsqu’une nouvelle action interrompt un mouvement.
- Fondus discrets pour les fenêtres et les indications de tour.
- Réutilisation des cartes et des matériaux ; les animations cessent lorsque la table est au repos.

Les règles, les modes solo et multijoueur, le guide, les compositions originales et le défi de tri sont conservés. Le multijoueur Internet nécessite d’héberger le serveur fourni.

Les tests couvrent les déplacements rapides, les entrées tactiles, les mises à jour réseau et la lisibilité sur des fenêtres de 1440×900 et 2400×1080. Aucun essai sur téléphone physique n’a été effectué dans cet environnement.

L’APK d’essai vise Android 7 ou supérieur, ARM32/ARM64. Les signatures de test GitHub peuvent changer entre compilations ; si Android refuse la mise à jour, désinstallez l’ancienne version d’essai avant d’installer celle-ci.

Les empreintes de la compilation figurent dans **SHA256SUMS**. **CI-BUILD-INFO.txt** indique son commit et son exécution GitHub. Les compilations des demandes de fusion restent dans les artefacts Actions ; seule la branche principale peut publier une version.
