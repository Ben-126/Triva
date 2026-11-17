#!/bin/bash
# Garde-fou de publication (audit légal n° 21).
#
# Échoue si Triva/Resources/searxng-instances.json :
#   - diffère de la version commitée (`git show HEAD:...`), OU
#   - contient « duckdns » (instance personnelle du développeur).
# Si un chemin .app est donné, fait le même contrôle sur la copie embarquée dans le bundle.
#
# Usage : scripts/check-release-resources.sh [chemin/vers/Triva.app]
#
# NON branché comme phase de build : il échoue volontairement sur le Mac du développeur, dont la
# copie locale est différente (skip-worktree). À lancer avant chaque archive App Store.

set -u

REL="Triva/Resources/searxng-instances.json"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-}"
FAILED=0

fail() {
    echo "ÉCHEC : $1" >&2
    FAILED=1
}

COMMITTED="$(mktemp)"
trap 'rm -f "$COMMITTED"' EXIT

if ! git -C "$ROOT" show "HEAD:$REL" > "$COMMITTED" 2>/dev/null; then
    echo "ÉCHEC : impossible de lire HEAD:$REL (dépôt git absent ou fichier non commité)." >&2
    exit 1
fi

check_file() {
    local label="$1" file="$2"
    if [ ! -f "$file" ]; then
        fail "$label : fichier introuvable ($file)"
        return
    fi
    if ! cmp -s "$file" "$COMMITTED"; then
        fail "$label : diffère de la version commitée (HEAD)."
    fi
    if grep -qi "duckdns" "$file"; then
        fail "$label : contient « duckdns » (instance personnelle)."
    fi
}

check_file "répertoire de travail" "$ROOT/$REL"

if [ -n "$APP" ]; then
    if [ ! -d "$APP" ]; then
        echo "ÉCHEC : $APP n'est pas un dossier .app." >&2
        exit 1
    fi
    # iOS : à la racine du bundle ; macOS : Contents/Resources.
    BUNDLED="$(find "$APP" -name "searxng-instances.json" -type f 2>/dev/null | head -n 1)"
    if [ -z "$BUNDLED" ]; then
        fail "bundle : searxng-instances.json introuvable dans $APP"
    else
        check_file "bundle ($BUNDLED)" "$BUNDLED"
    fi
fi

if [ "$FAILED" -ne 0 ]; then
    echo "Ne PAS publier. Archiver depuis un clone propre (voir docs/RELEASE.md)." >&2
    exit 1
fi
echo "OK : searxng-instances.json conforme à HEAD, sans instance personnelle."
