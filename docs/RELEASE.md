# Procédure de publication (archive App Store)

## Pourquoi

Sur le Mac du développeur, `Triva/Resources/searxng-instances.json` diffère volontairement de la
version commitée (`git update-index --skip-worktree`) : il contient une instance SearXNG
personnelle. Une archive faite depuis ce dossier la publierait dans l'app, et le développeur
deviendrait responsable des recherches reçues (RGPD, art. 4(7) : audit légal, constat n° 21).

## Procédure

1. **Toujours archiver depuis un clone propre**, jamais depuis le dossier de travail :

   ```bash
   git clone <url-du-dépôt> /chemin/vers/Triva-release
   cd /chemin/vers/Triva-release
   git checkout <commit-ou-tag-à-publier>
   ```

2. Lancer le garde-fou sur les sources du clone :

   ```bash
   scripts/check-release-resources.sh
   ```

3. Dans Xcode (ouvert sur le clone) : `Product > Archive`.

4. Relancer le garde-fou sur le `.app` produit par l'archive (il vérifie la copie embarquée) :

   ```bash
   scripts/check-release-resources.sh \
     ~/Library/Developer/Xcode/Archives/<date>/Triva.xcarchive/Products/Applications/Triva.app
   ```

   Le script doit afficher `OK`. Sur un échec (code de sortie 1), ne PAS envoyer l'archive.

5. `Product > Archive > Generate Privacy Report` : vérifier qu'aucune API à raison obligatoire
   n'apparaît en plus de `UserDefaults` (CA92.1) dans `Triva/PrivacyInfo.xcprivacy`.

## Ce que contrôle le script

`scripts/check-release-resources.sh` échoue si `searxng-instances.json` (répertoire de travail, et
bundle si un `.app` est passé) :

- diffère de `git show HEAD:Triva/Resources/searxng-instances.json`, ou
- contient `duckdns`.

Il n'est **pas** une phase de build : il échouerait sur le Mac du développeur, c'est voulu.
