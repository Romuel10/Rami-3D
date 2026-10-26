# Musiques originales du salon

Ces trois compositions instrumentales ont été créées pour **Rami Salon 3D**, le 26 octobre 2026. Mélodies, harmonies, synthèse des instruments et mixage sont programmés dans `generate_music.py`. Aucun enregistrement, morceau commercial ou échantillon téléchargé n’est utilisé.

| Fichier | Ambiance | Durée |
| --- | --- | --- |
| `salon.ogg` | Cordes pincées douces, basse ronde et percussion légère | 48 s |
| `piano.ogg` | Piano feutré et accords aérés | 53,33 s |
| `chill.ogg` | Piano électrique doux et rythme discret | 45,71 s |

Les fichiers sont stéréo, au format Ogg Vorbis et à 32 kHz. Chaque morceau contient seize mesures et boucle avec les réverbérations de sa fin reportées au début. Le mixage vise une moyenne de −17 dBFS ; le jeu permet de régler le volume ou de couper complètement la musique.

## Droits d’utilisation

Les compositions, les sons synthétisés, les trois fichiers Ogg et le script de génération de ce dossier sont dédiés au domaine public sous **CC0 1.0 Universal** : <https://creativecommons.org/publicdomain/zero/1.0/>. Ils peuvent être réutilisés, modifiés et distribués, y compris dans un jeu commercial, sans redevance et sans attribution obligatoire. Ce choix ne change pas les licences des autres fichiers du projet.

Crédit facultatif : « Musiques originales : Rami Salon 3D — synthèse et composition procédurales ».

## Reproduire les fichiers

Avec Python 3, NumPy, SciPy et FFmpeg installés :

```sh
python3 assets/music/generate_music.py
```

Les fichiers Ogg sont écrits dans ce dossier. Les WAV intermédiaires sont placés dans un dossier temporaire extérieur au projet. Les options `--output-dir` et `--wav-dir` permettent de choisir d’autres destinations. Ces dépendances servent uniquement à recréer les fichiers ; le jeu lit directement les musiques Ogg fournies.
