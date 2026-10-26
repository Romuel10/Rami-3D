# Rami Salon 3D 0.3.0 — le jeu au bout des doigts

- Glisser-déposer pour ranger la main, poser la sélection, compléter et défausser.
- Effets sonores originaux avec volume indépendant de la musique.
- Sauvegarde automatique et reprise complète des parties solo, y compris pendant le tour d’un adversaire.
- Points sélectionnés pour l’ouverture à 30 et surbrillance des compléments possibles.
- Trois difficultés solo et matchs de 1, 3 ou 5 manches.
- Classement cumulé, égalités et statistiques personnelles de manches, victoires et pénalités.
- Mains adverses de dos, actions successives et célébration de fin de manche.
- Invitation à copier dans le salon puis à coller chez l’ami : aucune adresse à retaper.

Les animations de distribution, de sélection et de déplacement ajoutées en 0.2.1 sont incluses.

Les invitations Wi-Fi exigent le même réseau. Les invitations Internet nécessitent un serveur WebSocket accessible : aucun serveur public n’est déployé avec cet APK. Le texte d’invitation se colle dans le jeu ; il n’ouvre pas automatiquement l’application.

Les sauvegardes et statistiques sont locales à l’appareil. Une nouvelle partie remplace la reprise précédente. En fin de manche : figures 10 points, as 11, jokers 20, nombres à leur valeur. Le plus petit cumul gagne le match.

Les tests couvrent le moteur, les réseaux, la reprise, les scores, les difficultés, les sons, les animations et de vrais événements tactiles sur des fenêtres de 1440×900 et 2400×1080. Aucun essai sur téléphone Android physique n’a été effectué dans cet environnement.

L’APK d’essai vise Android 7 ou supérieur, ARM32/ARM64. La signature de test GitHub peut changer d’une compilation à l’autre. Si Android refuse la mise à jour, désinstaller l’ancien APK efface aussi les parties et statistiques locales ; faire ce choix seulement en connaissance de cause.

**SHA256SUMS** et **CI-BUILD-INFO.txt** identifient la compilation. Les demandes de fusion produisent des APK dans les artefacts Actions ; seule la branche principale peut publier une version GitHub.
