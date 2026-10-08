#!/usr/bin/env bash
# Ajoute une nouvelle personne (un CV = un envoi de mail) à la veille d'offres.
#
# Le script pose les questions une par une, puis :
#   1. copie le CV dans data/<nom>/cv.pdf ;
#   2. crée ses réglages dans profils/<nom>.env ;
#   3. déclare son conteneur dans docker-compose.override.yml (fichier lu
#      automatiquement par Docker Compose et ignoré par git : pas de conflit au git pull) ;
#   4. propose un test sans envoi de mail, puis démarre son conteneur.
#
# Usage : ./ajouter_cv.sh   (depuis le dossier du projet)

set -euo pipefail
cd "$(dirname "$0")"

OVERRIDE=docker-compose.override.yml
CONTAINER_UID=1000  # utilisateur du conteneur (voir Dockerfile)

info()   { printf '\033[36m%s\033[0m\n' "$*"; }
ok()     { printf '\033[32m✔ %s\033[0m\n' "$*"; }
erreur() { printf '\033[31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

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

# ─── Vérifications préalables ──────────────────────────────────────────
command -v docker >/dev/null || erreur "Docker n'est pas installé."
[[ -f .env ]] || erreur "Fichier .env introuvable : crée-le d'abord (cp .env.example .env)."
existants=$(docker compose config --services 2>/dev/null) || erreur "docker compose config a échoué : vérifie docker-compose.yml."

echo
info "═══ Ajout d'une nouvelle personne ═══"
echo "Personnes déjà configurées : $(echo "$existants" | tr '\n' ' ')"
echo

# ─── 1. Nom ────────────────────────────────────────────────────────────
while true; do
    demander "Nom court de la personne (minuscules, chiffres, tirets ; ex. alice)"
    nom=$REPONSE
    if [[ ! $nom =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        echo "  → uniquement des minuscules sans accent, des chiffres et des tirets."
    elif grep -qx "$nom" <<<"$existants"; then
        echo "  → « $nom » existe déjà."
    elif [[ -e profils/$nom.env || -e data/$nom ]]; then
        echo "  → profils/$nom.env ou data/$nom/ existe déjà : choisis un autre nom ou supprime-les."
    else
        break
    fi
done

# ─── 2. CV ─────────────────────────────────────────────────────────────
while true; do
    demander "Chemin du CV (PDF) sur cette machine"
    cv=${REPONSE/#\~/$HOME}
    if [[ ! -f $cv ]]; then
        echo "  → fichier introuvable : $cv"
    elif [[ $(head -c 4 "$cv") != "%PDF" ]]; then
        echo "  → ce fichier n'est pas un PDF."
    else
        break
    fi
done

# ─── 3. Mail ───────────────────────────────────────────────────────────
while true; do
    demander "Adresse mail qui recevra les offres (plusieurs : séparées par des virgules)"
    mail_to=$REPONSE
    if [[ $mail_to =~ ^[^@[:space:],]+@[^@[:space:],]+\.[^@[:space:],]+(,[[:space:]]*[^@[:space:],]+@[^@[:space:],]+\.[^@[:space:],]+)*$ ]]; then
        break
    fi
    echo "  → adresse invalide."
done

# ─── 4. Recherche ──────────────────────────────────────────────────────
echo
info "Recherche (laisse vide pour accepter la valeur proposée)"
demander "Ville autour de laquelle chercher (vide = toute la France)" ""
ville=$REPONSE
rayon=30
if [[ -n $ville ]]; then
    while true; do
        demander "Rayon de recherche en km" "30"
        [[ $REPONSE =~ ^[0-9]+$ ]] && { rayon=$REPONSE; break; }
        echo "  → un nombre entier, en km."
    done
fi
if confirmer "Inclure les offres 100 % télétravail ?" o; then teletravail=true; else teletravail=false; fi
demander "Critères en langage naturel (ex. CDI uniquement, pas de management ; vide = aucun)" ""
preferences=$REPONSE
demander "Mots à exclure des intitulés, séparés par des virgules" "stage,alternance"
exclusions=$REPONSE
demander "Entreprises cibles, séparées par des virgules (vide = aucune)" ""
entreprises=$REPONSE

# ─── 5. Envoi ──────────────────────────────────────────────────────────
echo
info "Envoi du mail"
while true; do
    demander "Heure d'envoi quotidienne (HH:MM, heure de Paris)" "21:15"
    [[ $REPONSE =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && { heure=$REPONSE; break; }
    echo "  → format attendu : HH:MM (ex. 08:30)."
done
while true; do
    demander "Score minimum (0-100) pour qu'une offre figure dans le mail" "60"
    [[ $REPONSE =~ ^[0-9]+$ ]] && (( REPONSE <= 100 )) && { score=$REPONSE; break; }
    echo "  → un nombre entre 0 et 100."
done
while true; do
    demander "Nombre maximum d'offres par mail" "15"
    [[ $REPONSE =~ ^[1-9][0-9]*$ ]] && { max_offres=$REPONSE; break; }
    echo "  → un nombre entier positif."
done

# Quota SerpApi gratuit (250 recherches/mois) partagé entre toutes les personnes
nb_personnes=$(( $(echo "$existants" | grep -c .) + 1 ))
recherches_google=$(( 250 / (31 * nb_personnes) ))
(( recherches_google < 1 )) && recherches_google=1
(( recherches_google > 6 )) && recherches_google=6

# ─── Récapitulatif ─────────────────────────────────────────────────────
echo
info "═══ Récapitulatif ═══"
cat <<EOF
  Nom                : $nom
  CV                 : $cv → data/$nom/cv.pdf
  Mail               : $mail_to
  Ville / rayon      : ${ville:-toute la France}${ville:+ / $rayon km}
  Télétravail        : $teletravail
  Critères           : ${preferences:-aucun}
  Mots exclus        : ${exclusions:-aucun}
  Entreprises cibles : ${entreprises:-aucune}
  Envoi              : tous les jours à $heure, score ≥ $score, $max_offres offres max
  Google Jobs        : $recherches_google recherches par jour (quota SerpApi partagé entre $nb_personnes personnes)
EOF
echo
confirmer "Créer cette personne ?" o || { echo "Annulé, rien n'a été modifié."; exit 0; }

# ─── Création ──────────────────────────────────────────────────────────
crees=()
annuler() {
    printf '\033[31m✘ Échec : annulation des modifications\033[0m\n' >&2
    for f in "${crees[@]}"; do rm -rf "$f"; done
    [[ -f $OVERRIDE.bak ]] && mv "$OVERRIDE.bak" "$OVERRIDE"
}
trap annuler ERR

# 1. CV
mkdir -p "data/$nom"
crees+=("data/$nom")
cp "$cv" "data/$nom/cv.pdf"
if [[ $(id -u) != "$CONTAINER_UID" ]]; then
    echo "Attribution du dossier à l'utilisateur du conteneur (sudo peut demander ton mot de passe)…"
    sudo chown -R "$CONTAINER_UID:$CONTAINER_UID" "data/$nom"
fi
ok "CV copié dans data/$nom/cv.pdf"

# 2. Profil : toutes les valeurs personnelles sont écrites, même vides,
#    pour ne jamais hériter de celles d'une autre personne via le .env commun.
mkdir -p profils
crees+=("profils/$nom.env")
cat > "profils/$nom.env" <<EOF
# Réglages de « $nom », créés par ajouter_cv.sh le $(date '+%d/%m/%Y').
# Ils écrasent ceux du .env commun. Après modification : docker compose up -d $nom

MAIL_TO=$mail_to

LOCATION_CITY=$ville
LOCATION_RADIUS_KM=$rayon
INCLUDE_REMOTE=$teletravail
CANDIDATE_PREFERENCES=$preferences
EXCLUDE_KEYWORDS=$exclusions
TARGET_COMPANIES=$entreprises
SEARCH_QUERIES=
EXTRA_KEYWORDS=

RUN_AT=$heure
MIN_SCORE=$score
MAX_RESULTS=$max_offres

# Quota SerpApi gratuit (250 recherches/mois) partagé entre toutes les personnes
GOOGLEJOBS_SEARCHES_PER_RUN=$recherches_google
EOF
chmod 600 "profils/$nom.env"
ok "Réglages créés dans profils/$nom.env"

# 3. Conteneur, dans docker-compose.override.yml
if [[ -f $OVERRIDE ]]; then
    cp "$OVERRIDE" "$OVERRIDE.bak"
else
    printf '# Personnes ajoutées avec ajouter_cv.sh. Fichier lu automatiquement par\n# Docker Compose en plus de docker-compose.yml, et ignoré par git.\n\nservices:\n' > "$OVERRIDE"
    crees+=("$OVERRIDE")
fi
cat >> "$OVERRIDE" <<EOF

  $nom:
    image: job-alert
    container_name: job-alert-$nom
    restart: unless-stopped
    env_file:
      - path: .env
      - path: profils/$nom.env
    volumes:
      - ./data/$nom:/data
    logging:
      driver: json-file
      options:
        max-size: "5m"
        max-file: "3"
EOF
docker compose config --services 2>/dev/null | grep -qx "$nom"
rm -f "$OVERRIDE.bak"
trap - ERR
ok "Conteneur « job-alert-$nom » déclaré dans $OVERRIDE"

# ─── Test et démarrage ─────────────────────────────────────────────────
echo
if ! docker image inspect job-alert >/dev/null 2>&1; then
    info "Construction de l'image Docker…"
    docker compose build
fi

if confirmer "Lancer un test maintenant (recherche complète, sans envoi de mail, ~2 à 5 min) ?" n; then
    docker compose run --rm "$nom" python -m app run --dry-run || \
        echo "Le test a échoué : corrige profils/$nom.env ou le .env, puis relance : docker compose run --rm $nom python -m app run --dry-run"
fi

if confirmer "Démarrer l'envoi quotidien pour $nom maintenant ?" o; then
    docker compose up -d "$nom"
    ok "« $nom » recevra ses offres tous les jours à $heure."
else
    echo "Pour démarrer plus tard : docker compose up -d $nom"
fi

if (( nb_personnes > 1 )); then
    echo
    info "Pense au quota Google Jobs : mets GOOGLEJOBS_SEARCHES_PER_RUN=$recherches_google dans le profil de chaque personne"
    info "(et dans le .env pour « principal » s'il n'a pas de profils/principal.env), puis : docker compose up -d"
fi
echo
echo "Commandes utiles pour $nom :"
echo "  docker compose logs -f $nom                              # suivre les logs"
echo "  docker compose run --rm $nom python -m app run --dry-run  # test sans envoi"
echo "  nano profils/$nom.env && docker compose up -d $nom        # modifier ses réglages"
