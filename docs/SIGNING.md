# Signature Android durable

Une mise à jour Android doit conserver le même nom de package **et le même certificat de signature** que l’application déjà installée. Les versions d’essai précédentes créaient une nouvelle clé sur chaque machine de compilation : leur remplacement pouvait nécessiter une désinstallation, ce qui efface les sauvegardes et statistiques de l’appareil.

À partir de la version 0.4.0, le workflow peut utiliser une clé durable protégée dans les secrets GitHub Actions. **Il ne publie plus de version avec une clé temporaire.** Quand aucun secret n’est configuré, les tests et la compilation restent disponibles, puis l’APK est proposé seulement dans les artefacts du workflow ; la publication est ignorée avec un message explicite. Une compilation valide reste verte dans Actions : l’absence de clé durable n’est pas une erreur de l’APK. Une configuration partielle ou une clé incorrecte reste une véritable erreur, signalée comme telle.

Cette correction empêche les prochaines publications de changer de signature par inadvertance. Elle ne permet pas de récupérer une clé éphémère d’une ancienne exécution déjà supprimée. Le premier passage depuis un APK ancien signé autrement peut encore nécessiter une réinstallation. La version stable doit ensuite garder la même clé et un `version/code` croissant.

## Configuration à faire une seule fois

Sur un ordinateur dont vous contrôlez le compte GitHub :

1. Installer Java (pour `keytool`), Python 3 et [GitHub CLI](https://cli.github.com/).
2. Se connecter avec `gh auth login` au compte autorisé à gérer les secrets de `Romuel10/Rami-3D`.
3. Depuis les sources du projet, lancer :

```sh
python3 scripts/setup-signing.py --create --repository Romuel10/Rami-3D
```

Le script demande un mot de passe, crée la clé **hors du dépôt**, vérifie celle-ci, puis envoie les quatre secrets à GitHub par l’entrée standard. Il n’affiche jamais la clé ni les mots de passe et refuse de remplacer une clé existante. Les mots de passe du magasin et de la clé sont identiques, ce qu’exige ce profil d’export Godot.

Pour réutiliser une clé durable déjà créée :

```sh
python3 scripts/setup-signing.py --repository Romuel10/Rami-3D --keystore /chemin/prive/rami-salon.jks --alias ramisalon
```

L’option `--prepare-only` crée ou valide la clé localement sans modifier GitHub. Une automatisation contrôlée peut utiliser `--password-env NOM_VARIABLE` ; le script lit alors le mot de passe depuis cette variable, sans le placer dans les arguments de commande.

Sauvegarder le fichier de clé et son mot de passe dans un emplacement privé et durable. Ne pas les ajouter au code, à un cache GitHub, aux captures, aux artefacts de compilation ou à une version publique.

## Secrets attendus par le workflow

Les secrets de dépôt se trouvent dans **Settings → Secrets and variables → Actions** :

| Secret | Contenu |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Fichier de clé encodé en base64 |
| `ANDROID_KEYSTORE_PASSWORD` | Mot de passe du magasin de clés |
| `ANDROID_KEY_ALIAS` | Alias de la clé, par défaut `ramisalon` |
| `ANDROID_KEY_PASSWORD` | Même mot de passe que celui du magasin pour ce profil Godot |

Le script configure ces valeurs sans devoir les copier dans le chat. Si le compte utilisé ne peut pas gérer les secrets, un propriétaire du dépôt doit effectuer cette configuration.

Une configuration partielle est rejetée. Une clé ou un mot de passe incorrect arrête aussi le workflow avant publication. Les secrets ne sont accessibles à l’étape de signature que pour la branche `main`, hors demandes de fusion. Les fichiers temporaires de signature sont supprimés à la fin du travail.

## Après la configuration

Dans l’onglet **Actions**, ouvrir **Android APK → Run workflow → main**. Les tests, l’APK, sa signature, son intégrité et son alignement sont vérifiés avant publication. `CI-BUILD-INFO.txt` indique `Signing mode: durable` et `android-signature.txt` permet d’inspecter le certificat public.

Pour les versions suivantes, garder cette clé et augmenter `version/code` dans `export_presets.cfg`. Ne pas relancer le script avec `--create` pour une mise à jour. Un changement de clé nécessite une stratégie de migration Android distincte ; ce workflow ne modifie pas silencieusement la clé configurée.

## Télécharger et installer un APK de test GitHub

Dans **Actions → Android APK**, ouvrir une compilation réussie : son résumé contient un lien direct **Télécharger l’APK de test (archive ZIP)**. Le même fichier apparaît dans la section **Artifacts**. Télécharger l’archive `rami-android-…` et la décompresser : c’est le fichier **rami-3d.apk** à l’intérieur qui s’installe sur Android, pas le ZIP. Le téléchargement d’un artefact demande une connexion GitHub ; les APK d’une ancienne page **Releases** peuvent correspondre à une version antérieure du jeu.

En cas de message « Application non installée », « Package en conflit » ou d’échec d’une mise à jour, comparer d’abord les certificats de l’APK et de l’application installée. Les APK de test temporaires de deux compilations peuvent être signés avec des clés différentes. Ne pas désinstaller une ancienne version sans savoir que cette action efface les sauvegardes et statistiques locales. La configuration d’une clé durable évite ces changements pour les publications suivantes ; elle ne récupère pas les clés de test passées.

Ces points n’expliquent pas tous les plantages Android. Pour diagnostiquer un arrêt au lancement ou en partie, relever le message exact, la version Android, le modèle du téléphone et, si possible, le journal `adb logcat` de ce lancement.
