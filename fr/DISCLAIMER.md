> [🇬🇧 English version](../en/DISCLAIMER.md)

# Avertissement

Ce kit est fourni **« en l'état », sans aucune garantie**, expresse ou implicite. Les auteurs et
contributeurs ne sauraient être tenus responsables de tout dommage, perte de configuration, ou
interruption de service résultant de son utilisation.

**Portée :** ce kit duplique la *configuration Intune clonable* d'un tenant à l'autre. Ce n'est **pas** une migration d'appareils, d'identités ou de tenant — les appareils se réinscrivent et les secrets et jetons sont recréés / réappariés manuellement.

- Il **écrit** dans un tenant Microsoft Intune. Une mauvaise cible peut modifier une production.
- **Toujours** commencer sur un tenant de **bac à sable / test**, en mode aperçu (PREVIEW), et faire
  une **sauvegarde** de la cible avant toute écriture (voir `EXECUTER.md`, étape de sauvegarde).
- Vous êtes seul responsable de disposer des **autorisations** nécessaires sur les tenants concernés.
- Certaines données ne se migrent **jamais** automatiquement (secrets, binaires d'applications) : c'est
  une limite de Microsoft Intune, pas un défaut du kit.
- Vérifiez la conformité de l'usage avec les politiques de votre organisation avant tout déploiement.
