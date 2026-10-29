# Essayer Rami Salon 3D sur un téléphone Android

Les tests Linux et les vérifications d’un APK ne remplacent pas un essai sur téléphone. L’outil `scripts/test-android-device.py` distingue les contrôles du fichier, l’installation, le lancement et les contrôles manuels encore à réaliser. Il ne désinstalle jamais le jeu et n’efface pas ses données.

## Vérifier le fichier sans toucher au téléphone

Installer Python 3, Java et le SDK Android avec `platform-tools` et les build-tools 36 ou plus récents. Décompresser l’artefact GitHub : le fichier à vérifier est `rami-3d.apk`, pas l’archive ZIP.

```sh
python3 scripts/test-android-device.py --apk builds/rami-3d.apk --sdk /chemin/vers/android-sdk
```

L’outil contrôle la signature, l’intégrité ZIP, l’alignement 16 Ko et le manifeste : package, version, API minimale, architectures et activité de lancement. Il reconnaît aussi l’alias de lancement utilisé par Godot, parfois absent du résultat `aapt dump badging`.

Le rapport par défaut est `builds/android-device-report.json`. Sans les options d’installation ou de lancement, son statut reste `host_checks_passed_device_pending`, même si un téléphone est branché. Aucun essai physique n’est alors déclaré réussi.

## Choisir un appareil et installer sans désinstaller

Sur le téléphone, activer le débogage USB, puis accepter la connexion à l’ordinateur. Afficher les appareils avec le `adb` du même SDK :

```sh
/chemin/vers/android-sdk/platform-tools/adb devices
```

Remplacer `SERIE_DU_TELEPHONE` par la série affichée localement. La série n’est pas copiée dans le rapport.

```sh
python3 scripts/test-android-device.py --apk builds/rami-3d.apk --sdk /chemin/vers/android-sdk --serial SERIE_DU_TELEPHONE --install --launch --seconds 15
```

`--install` utilise uniquement `adb install -r`. Si le jeu est déjà installé, l’outil lit son APK public pour comparer le certificat et le code de version. Il refuse une signature différente ou un retour à une version inférieure. L’installation Android vérifie également la signature. Aucun contournement avec désinstallation, effacement des données ou installation forcée d’une ancienne version n’est tenté.

`--launch` seul ne change pas l’application installée. Il vérifie qu’elle correspond exactement au fichier APK fourni avant de lancer le jeu : il ne valide pas par erreur une ancienne version. L’activité Godot est ouverte, le processus est observé pendant la durée demandée (1 à 60 secondes), puis les erreurs de l’application sont contrôlées. Aucun arrêt forcé n’est demandé au jeu.

Un lancement réussi produit `device_smoke_passed_manual_checks_pending`. Il ne certifie pas la fluidité, le son ou la durée de batterie. Un émulateur est identifié séparément et ne compte pas comme essai physique réussi. Les rapports et journaux générés sont locaux, avec droits `0600` sur Unix ; le journal est limité au processus du jeu.

## Vérifications manuelles après le lancement

Pour chaque appareil, relever le modèle, la version Android, le mode de rendu choisi, la durée de l’essai et les observations réelles.

| Cas | Action à essayer | Résultat attendu |
| --- | --- | --- |
| Affichage | Paysage, plein écran, téléphone avec encoche | Valeurs lisibles, main entière et boutons accessibles |
| Cartes | Toucher, glisser, sélectionner, désélectionner, trier | Une seule action par geste ; la bonne carte bouge |
| Tri | Jouer aux formats 6 et 12, regrouper les cartes | Tris privés, pioche avant défausse, bon objectif de victoire |
| Apprentissage | Finir les tutoriels du rami et du Tri | Actions réellement jouées et erreurs expliquées |
| Reprise | Retour à l’accueil, fermeture/réouverture | Même main, ordre, tour et mode solo |
| Arrière-plan | Verrouiller, changer d’application, revenir | Son arrêté en arrière-plan ; reprise sans double action |
| Son | Musique et effets activés puis coupés séparément | Réglages indépendants et conservés |
| Réseau Wi-Fi | Deux téléphones, perte puis retour de réseau | Mains privées, pause, reprise ; forfait au-delà du délai |
| Abandon | Quitter volontairement un duel | Défaite de l’absent, victoire de l’adversaire |
| Internet | Même serveur déployé, deux téléphones sur réseaux distincts | Code de salon commun, même état, mains privées |
| Charge | Jouer plusieurs manches pendant 15 à 20 minutes | Noter la fluidité, la chauffe et la batterie, sans inventer de mesure |
| Mise à jour | Installer la version suivante avec la même clé | Sauvegarde et préférences conservées |

## État observé dans l’environnement de développement

Le 29 octobre 2026, `adb devices` ne listait aucun téléphone ni émulateur. Le contrôle réel de l’APK local 0.7.0 a réussi : signature, ZIP, alignement 16 Ko, package `fr.ramisalon.jeu`, API minimale 24, ARM64/ARMv7 et alias `com.godot.game.GodotAppLauncher`. Le rapport local `builds/android-device-readiness-v0.7.0.json` indique `connected_devices: 0`, `physical_device_tested: false` et `device_test: not_run`.

Cette observation ne constitue pas un essai sur appareil. Le prochain APK doit lui aussi être vérifié avant son installation ; l’empreinte et le certificat du fichier effectivement testé sont conservés dans le rapport.

## Tests du vérificateur

```sh
python3 tests/test_android_device_setup.py
```

Les appareils sont simulés dans cette suite : elle vérifie les refus de signature/downgrade/API/architecture incompatibles, l’obligation d’une série explicite, la conservation des données, la détection d’un arrêt ou redémarrage du processus et l’absence de fausse validation d’une autre version installée. Les essais physiques restent à réaliser avec un appareil connecté.
