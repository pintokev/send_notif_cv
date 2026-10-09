# Fonctions communes à installer.sh, ajouter_cv.sh et lancer.sh (chargées avec « source »).

CONTAINER_UID=1000  # utilisateur du conteneur (voir Dockerfile)

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

# Construit l'image Docker si elle n'existe pas encore
construire_image() {
    if ! docker image inspect job-alert >/dev/null 2>&1; then
        info "Construction de l'image Docker (quelques minutes la première fois)…"
        docker compose build
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
