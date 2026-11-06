# Rami Salon 3D 0.8.0 — salons Internet sur Supabase

- Serveur Internet hébergé dans le projet Supabase du jeu, avec adresse intégrée à l’application.
- Rami à 2–4 joueurs ; Tri en duel à 6 ou 12 cartes.
- Création et invitation par code à six chiffres, sans compte à créer pour les joueurs.
- Cartes privées et actions vérifiées par le serveur. Les salons sont sauvegardés dans Postgres, avec verrouillage des actions concurrentes.
- Reconnexion à la même place pendant 60 secondes, y compris dans le salon d’attente. La rotation des connexions du service reprend le même salon.
- Les modes solo et Wi-Fi restent disponibles. Les adresses de serveurs personnalisés peuvent toujours être mémorisées.

Dans **Jouer avec des amis → Internet**, créer un salon puis transmettre son code. Pour le Tri, choisir d’abord le duel et le format 6/12 cartes.

Les tests automatiques ne remplacent pas un essai sur téléphone Android physique. Les compilations sans clé de signature durable restent des APK de test disponibles dans les artefacts GitHub Actions.
