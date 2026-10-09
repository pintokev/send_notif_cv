# Fonctions communes à installer.sh, ajouter_cv.sh et lancer.sh (chargées avec « source »).

CONTAINER_UID=1000  # utilisateur du conteneur (voir Dockerfile)
HEURE_REGEX='^([01][0-9]|2[0-3]):[0-5][0-9]$'  # HH:MM

info()      { printf '\033[36m%s\033[0m\n' "$*"; }
ok()        { printf '\033[32m✔ %s\033[0m\n' "$*"; }
attention() { printf '\033[33m! %s\033[0m\n' "$*"; }
erreur()    { printf '\033[31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

# demander "Question" [valeur par défaut] → réponse dans $REPONSE
demander() {
    local question=$1 defaut=${2:-}
    if [[ -n $defaut ]]; then
        read -r -p "$question [$defaut] : " REPONSE
        REPONSE=${REPONSE:-$defaut}
    else
        read -r -p "$question : " REPONSE
    fi
}

# confirmer "Question" o|n → code de retour 0 si oui
confirmer() {
    local question=$1 defaut=${2:-n} choix
    if [[ $defaut == o ]]; then choix="O/n"; else choix="o/N"; fi
    read -r -p "$question [$choix] : " REPONSE
    REPONSE=${REPONSE:-$defaut}
    [[ $REPONSE =~ ^[oOyY] ]]
}

# choisir "Question" "choix 1" "choix 2"… → numéro choisi dans $REPONSE (1 par défaut)
choisir() {
    local question=$1 i=1 choix
    shift
    echo "$question"
    for choix in "$@"; do
        printf '  %d) %s\n' "$i" "$choix"
        i=$((i + 1))
    done
    while true; do
        read -r -p "Ton choix [1] : " REPONSE
        REPONSE=${REPONSE:-1}
        if [[ $REPONSE =~ ^[1-9][0-9]*$ ]] && (( REPONSE <= $# )); then
            return 0
        fi
        echo "  → un nombre entre 1 et $#."
    done
}

# lire_reglage fichier CLE → valeur de CLE dans ce fichier (.env ou profil), sans guillemets
lire_reglage() {
    local valeur
    valeur=$(sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1 || true)
    valeur=${valeur%$'\r'}
    if [[ $valeur =~ ^\'(.*)\'$ || $valeur =~ ^\"(.*)\"$ ]]; then
        valeur=${BASH_REMATCH[1]}
    fi
    printf '%s' "$valeur"
}

# reglage_de <nom> CLE → valeur dans le profil de cette personne, sinon dans le .env (comme Docker Compose)
reglage_de() {
    if grep -q "^$2=" "profils/$1.env" 2>/dev/null; then
        lire_reglage "profils/$1.env" "$2"
    else
        lire_reglage .env "$2"
    fi
}

# ecrire_reglage fichier CLE valeur : remplace la ligne CLE= du fichier (ou l'ajoute ; crée le fichier).
# Les guillemets simples empêchent Docker Compose d'interpréter les « $ » d'un mot de passe.
ecrire_reglage() {
    local fichier=$1 valeur=$3
    if [[ -n $valeur && $valeur != *"'"* ]]; then
        valeur="'$valeur'"
    fi
    if [[ ! -f $fichier ]]; then
        (umask 077 && : > "$fichier")
    fi
    CLE=$2 VALEUR=$valeur awk -F= '
        $1 == ENVIRON["CLE"] && !fait { print ENVIRON["CLE"] "=" ENVIRON["VALEUR"]; fait = 1; next }
        { print }
        END { if (!fait) print ENVIRON["CLE"] "=" ENVIRON["VALEUR"] }
    ' "$fichier" > "$fichier.tmp"
    cat "$fichier.tmp" > "$fichier"  # garde les droits du fichier (600)
    rm -f "$fichier.tmp"
}

# Vérifie que Docker est installé, démarré et utilisable sans sudo
verifier_docker() {
    local sortie
    command -v docker >/dev/null || erreur "Docker n'est pas installé : https://docs.docker.com/engine/install/ (serveur) ou Docker Desktop (ordinateur)."
    if ! sortie=$(docker info 2>&1); then
        if grep -qi "permission denied" <<<"$sortie"; then
            erreur "Ton utilisateur n'a pas le droit d'utiliser Docker. Lance : sudo usermod -aG docker \$USER, déconnecte-toi, reconnecte-toi, puis réessaie."
        fi
        erreur "Docker ne répond pas : démarre-le (Docker Desktop, ou sudo systemctl start docker) puis réessaie."
    fi
    docker compose version >/dev/null 2>&1 || erreur "Docker Compose est introuvable (commande « docker compose »)."
}

# Construit l'image Docker, ou la reconstruit si le code a changé depuis (après un git pull).
# Le fichier témoin .image-construite date la dernière construction. Les envois automatiques
# actifs passent ensuite à la nouvelle version.
construire_image() {
    local actifs
    if docker image inspect job-alert >/dev/null 2>&1 && [[ -f .image-construite ]] \
        && [[ -z $(find app Dockerfile requirements.txt -newer .image-construite -print -quit) ]]; then
        return 0
    fi
    if docker image inspect job-alert >/dev/null 2>&1; then
        info "Le code a changé : mise à jour de l'image Docker…"
    else
        info "Construction de l'image Docker (quelques minutes la première fois)…"
    fi
    docker compose build
    touch .image-construite
    actifs=$(docker compose ps --status running --services 2>/dev/null || true)
    if [[ -n $actifs ]]; then
        # Recrée les conteneurs actifs avec la nouvelle image (un nom de service par mot)
        docker compose up -d $actifs
        ok "Envoi automatique relancé avec la nouvelle version : $(echo $actifs)"
    fi
}

# donner_au_conteneur dossier : le conteneur tourne avec l'utilisateur 1000 et doit pouvoir y écrire.
# Inutile sous macOS : Docker Desktop gère lui-même les droits.
donner_au_conteneur() {
    if [[ $(uname -s) == Darwin || $(id -u) == "$CONTAINER_UID" ]]; then
        return 0
    fi
    echo "Attribution de $1 à l'utilisateur du conteneur (sudo peut demander ton mot de passe)…"
    sudo chown -R "$CONTAINER_UID:$CONTAINER_UID" "$1"
}

# lancer_recherche <nom> [--dry-run] : recherche immédiate, sans attendre l'heure prévue
lancer_recherche() {
    local nom=$1
    shift
    echo "Recherche en cours pour « $nom » (2 à 5 minutes)…"
    if docker compose run --rm -T "$nom" python -m app run "$@" </dev/null; then
        if [[ ${1:-} == --dry-run ]]; then
            ok "Aucun mail envoyé. Aperçu du mail : data/$nom/last_email.html"
        else
            ok "Recherche terminée, mail envoyé."
        fi
        return 0
    fi
    attention "La recherche a échoué (voir le message ci-dessus). Corrige profils/$nom.env ou le .env, puis relance : ./lancer.sh $nom"
    return 1
}
