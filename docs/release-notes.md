# Rami Salon 3D 0.4.0 — abandons, reprise et apprentissage

- Abandon volontaire : défaite du joueur qui part et victoire de l’adversaire en duel.
- À trois ou quatre, élimination du joueur qui part et poursuite pour les autres. Le départ de l’hôte Wi-Fi ferme le salon et donne la victoire aux joueurs restants.
- Coupure réseau : pause et délai de reconnexion de 60 secondes avant le forfait.
- Places du salon libérées avant le début ; jeton de reprise conservé sur le téléphone après fermeture du jeu.
- Sauvegarde optionnelle des salons du serveur Internet, avec copie de secours et restauration validée.
- Suggestions corrigées pour les doubles exemplaires et les jokers.
- Gagnant du match calculé au cumul des manches ; égalités et éliminations affichées correctement.
- Premier tour guidé avec pioche, deux suites, ouverture à 33 points et défausse.
- Réglages Confort : taille des cartes, ordre des commandes pour les gauchers et désactivation des animations.
- Publication Android avec signature durable protégée dans les secrets GitHub.

Les grandes cartes en éventail, le plein écran, les douze leçons, les conseils contextuels, les musiques originales, le défi de tri séparé et les animations des versions précédentes sont inclus.

La publication de l’APK 0.4.0 exige une configuration unique de la clé Android : [instructions](SIGNING.md). Sans cette configuration, le workflow propose un APK d’essai dans ses artefacts, puis bloque la publication d’une version signée temporairement. Une ancienne installation signée autrement peut encore nécessiter une réinstallation avec perte des données locales.

Le serveur Internet fourni nécessite toujours votre hébergement et son adresse WSS. Aucune adresse de serveur public n’est préconfigurée. Les essais réseau et de rendu sont réalisés sous Linux ; l’installation et les performances sur les téléphones Android physiques restent à vérifier.
