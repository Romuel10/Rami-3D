# Rami Salon 3D 0.7.0 — apprendre, organiser et jouer en ligne

- Tutoriel interactif du Tri à 6/12 cartes, jusqu’à une vraie défausse gagnante.
- Tris espacés et regroupés dans la main privée, avec retour au rangement libre par tri ou glissement manuel.
- Gestes adverses de réflexion, pioche, pose et défausse ; mouvements courts et réduction des animations respectée.
- Sons originaux de papier et feutre, volume indépendant et silence en arrière-plan.
- Mode économie de batterie à 30 images/s sans ombres ; mode normal limité à 60 images/s.
- Serveur Internet adapté à Vercel : WebSocket Node, parties privées et reconnexion stockées dans Redis entre les instances.
- Adresse Vercel HTTPS mémorisée, puis connexion avec le code du salon.
- Outil Android de vérification et d’essai sur appareil explicitement choisi ; contrôle de configuration de signature durable.

L’APK d’essai a été vérifié sous Linux : signature, intégrité, alignement et réglages. Aucun téléphone Android physique n’a été utilisé ici.

Le code du serveur Vercel est prêt à déployer ; aucun compte Vercel/Redis de production n’est connecté et aucune adresse publique n’est préconfigurée. Le jeu solo et le Wi-Fi fonctionnent sans serveur Internet. Une clé Android durable reste nécessaire pour publier des mises à jour GitHub avec la même signature.
