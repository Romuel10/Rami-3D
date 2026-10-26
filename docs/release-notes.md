# Rami Salon 3D — version de test Android

Jeu de rami en français avec table et cartes en 3D, adversaires contrôlés par l’ordinateur et parties privées de deux à quatre joueurs, chacun sur son téléphone.

- **Solo** : jouer contre un, deux ou trois adversaires.
- **Même Wi-Fi** : créer un salon sur un téléphone, puis le rejoindre avec son adresse et son code.
- **Internet** : créer ou rejoindre un salon sur un serveur commun. Le serveur est fourni dans `server/`, avec son guide de déploiement ; aucun serveur public n’est hébergé automatiquement.

Télécharger **`rami-3d.apk`** dans les fichiers de cette version et l’installer sur un téléphone Android 7.0 ou supérieur, ARM32 ou ARM64. Android peut demander d’autoriser l’installation depuis l’application utilisée pour télécharger le fichier. Le jeu fonctionne en paysage.

Cette préversion est signée avec une **clé de test temporaire**, créée pendant la compilation GitHub Actions. Elle diffère de celle de l’APK compilé localement et peut changer entre les compilations. Pour passer entre deux signatures différentes, désinstaller l’ancienne application avant d’installer la nouvelle.

Les règles, les échanges réseau et le serveur sont vérifiés automatiquement ; la signature de l’APK, l’intégrité ZIP et l’alignement Android sont contrôlés pendant la compilation. **Aucun essai sur téléphone physique n’a été effectué par ce workflow.** Les parties du serveur restent en mémoire et sont perdues lors de son redémarrage.

`SHA256SUMS` contient les empreintes des fichiers de cette compilation. `CI-BUILD-INFO.txt` indique le commit utilisé et le lien vers son exécution GitHub Actions. L’archive `rami-salon-3d-sources.zip` contient les sources de ce même commit.

Le workflow publie une version à partir de `version/name` dans `export_presets.cfg`. Une version existante et ses fichiers sont conservés ; les compilations suivantes restent téléchargeables dans les artefacts GitHub Actions.
