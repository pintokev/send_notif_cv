#!/usr/bin/env bash
# Ajoute une nouvelle personne (un CV = un envoi de mail) à la veille d'offres.
#
# Le script pose les questions une par une, puis :
#   1. copie le CV dans data/<nom>/cv.pdf ;
#   2. crée ses réglages dans profils/<nom>.env ;
#   3. déclare son conteneur dans docker-compose.override.yml (fichier lu
#      automatiquement par Docker Compose et ignoré par git : pas de conflit au git pull) ;
#   4. propose une première recherche, puis l'envoi automatique quotidien.
#
# Usage : ./ajouter_cv.sh               (depuis le dossier du projet)
#         ./ajouter_cv.sh --principal   premier profil, « principal », déjà déclaré dans
#                                       docker-compose.yml (utilisé par installer.sh)

set -euo pipefail
cd "$(dirname "$0")"
source scripts/commun.sh

OVERRIDE=docker-compose.override.yml
principal=false
[[ ${1:-} == --principal ]] && principal=true

# ─── Vérifications préalables ──────────────────────────────────────────
verifier_docker
[[ -f .env ]] || erreur "Fichier .env introuvable : lance d'abord ./installer.sh."
existants=$(docker compose config --services 2>/dev/null) || erreur "docker compose config a échoué : vérifie docker-compose.yml."

echo
if $principal; then
    info "═══ Création du premier profil ═══"
    nom=principal
    if [[ -e data/$nom/cv.pdf ]]; then
        erreur "Le profil « $nom » a déjà un CV. Pour le modifier : nano profils/$nom.env. Pour ajouter une personne : ./ajouter_cv.sh"
    fi
    if [[ -e profils/$nom.env ]]; then
        confirmer "profils/$nom.env existe déjà. Le remplacer ?" n || { echo "Annulé, rien n'a été modifié."; exit 0; }
    fi
else
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
fi

# ─── 2. CV ─────────────────────────────────────────────────────────────
while true; do
    demander "Chemin du CV (PDF) sur cette machine (tu peux glisser le fichier dans cette fenêtre)"
    cv=$REPONSE
    cv=${cv#[\'\"]}  # guillemets ajoutés quand on glisse un fichier dans le terminal
    cv=${cv%[\'\"]}
    cv=${cv/#\~/$HOME}
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

# Sources à clé : proposées seulement si leur clé est dans le .env. Une source sans clé reste
# dans la liste (elle est ignorée tant que la clé manque), pour s'activer dès qu'on l'ajoute.
# WTTJ et les sites télétravail sont gratuits et toujours interrogés ; les sites carrière
# le sont dès que la personne a des entreprises cibles.
exclues=" "
if [[ -n $(lire_reglage .env FRANCETRAVAIL_CLIENT_ID)$(lire_reglage .env ADZUNA_APP_ID)$(lire_reglage .env SERPAPI_API_KEY) ]]; then
    echo
    info "Sources d'offres utilisant tes clés API"
fi
if [[ -n $(lire_reglage .env FRANCETRAVAIL_CLIENT_ID) ]] && ! confirmer "Chercher sur France Travail ?" o; then
    exclues+="francetravail "
fi
if [[ -n $(lire_reglage .env ADZUNA_APP_ID) ]] && ! confirmer "Chercher sur Adzuna ?" o; then
    exclues+="adzuna "
fi
if [[ -n $(lire_reglage .env SERPAPI_API_KEY) ]] && ! confirmer "Chercher sur Google Jobs (LinkedIn, Indeed, APEC… ; quota SerpApi partagé entre les personnes) ?" o; then
    exclues+="googlejobs "
fi
sources=""
for source in francetravail adzuna wttj googlejobs careersites remotive remoteok jobicy; do
    if [[ $exclues != *" $source "* ]]; then sources+=${sources:+,}$source; fi
done

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

# utilise_google <nom> : vrai si cette personne interroge Google Jobs
# (SOURCES de son profil, sinon celui du .env ; vide = toutes les sources)
utilise_google() {
    local fichier=profils/$1.env valeur
    grep -q '^SOURCES=' "$fichier" 2>/dev/null || fichier=.env
    valeur=$(lire_reglage "$fichier" SOURCES)
    valeur=${valeur// /}
    [[ -z $valeur || ,$valeur, == *,googlejobs,* ]]
}

# Quota SerpApi gratuit (250 recherches/mois) partagé entre les personnes qui utilisent Google Jobs
google=false
[[ ,$sources, == *,googlejobs,* ]] && google=true
nb_google=0
while IFS= read -r service; do
    if [[ -n $service && $service != "$nom" ]] && utilise_google "$service"; then
        nb_google=$((nb_google + 1))
    fi
done <<<"$existants"
$google && nb_google=$((nb_google + 1))
recherches_google=$(( 250 / (31 * (nb_google > 0 ? nb_google : 1)) ))
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
  Sources            : $sources
EOF
if $google; then
    echo "  Google Jobs        : $recherches_google recherches par jour (quota SerpApi partagé entre $nb_google personnes)"
fi
echo
confirmer "Créer cette personne ?" o || { echo "Annulé, rien n'a été modifié."; exit 0; }

# ─── Création ──────────────────────────────────────────────────────────
crees=()
annuler() {
    local ligne=$1 commande=$2
    trap - ERR
    set +e
    printf '\033[31m✘ Échec ligne %s : %s\033[0m\n' "$ligne" "$commande" >&2
    printf '\033[31m  Annulation des modifications…\033[0m\n' >&2
    for f in "${crees[@]}"; do
        rm -rf "$f" 2>/dev/null || sudo rm -rf "$f"
    done
    [[ -f $OVERRIDE.bak ]] && mv "$OVERRIDE.bak" "$OVERRIDE"
    exit 1
}
trap 'annuler "$LINENO" "$BASH_COMMAND"' ERR

# 1. CV (data/principal peut déjà exister : installer.sh le crée pour le mail de test)
if [[ -d data/$nom ]]; then crees+=("data/$nom/cv.pdf"); else crees+=("data/$nom"); fi
mkdir -p "data/$nom"
cp "$cv" "data/$nom/cv.pdf"
donner_au_conteneur "data/$nom"
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

# Sources interrogées (retirer un nom pour ne plus l'utiliser)
SOURCES=$sources
# Quota SerpApi gratuit (250 recherches/mois) partagé entre les personnes qui utilisent Google Jobs
GOOGLEJOBS_SEARCHES_PER_RUN=$recherches_google
EOF
chmod 600 "profils/$nom.env"
ok "Réglages créés dans profils/$nom.env"

# 3. Conteneur, dans docker-compose.override.yml (« principal » est déjà dans docker-compose.yml)
if ! $principal; then
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
    # Vérifie que Docker Compose accepte la nouvelle configuration (affiche son erreur sinon)
    if ! services_apres=$(docker compose config --services 2>&1); then
        printf '%s\n' "$services_apres" >&2
        false
    fi
    if ! grep -qx "$nom" <<<"$services_apres"; then
        printf 'Docker Compose ne voit pas le service « %s ». Services vus :\n%s\n' "$nom" "$services_apres" >&2
        false
    fi
    rm -f "$OVERRIDE.bak"
    ok "Conteneur « job-alert-$nom » déclaré dans $OVERRIDE"
fi
trap - ERR

# ─── Première recherche et envoi automatique ───────────────────────────
echo
construire_image
echo
choisir "Lancer une première recherche maintenant (2 à 5 minutes) ?" \
    "Oui, sans envoyer de mail : juste pour vérifier (aperçu)" \
    "Oui, et envoyer le mail à $mail_to" \
    "Non, plus tard"
case $REPONSE in
    1) lancer_recherche "$nom" --dry-run || true ;;
    2) lancer_recherche "$nom" || true ;;
esac

echo
echo "Envoi automatique : la recherche peut tourner toute seule tous les jours à $heure,"
echo "tant que cette machine et Docker restent allumés. Sinon, lance-la quand tu veux avec ./lancer.sh"
if confirmer "Activer l'envoi automatique quotidien pour $nom ?" o; then
    docker compose up -d "$nom"
    ok "« $nom » recevra ses offres tous les jours à $heure."
else
    echo "Pour l'activer plus tard : ./lancer.sh $nom"
fi

if $google && (( nb_google > 1 )); then
    echo
    info "Pense au quota Google Jobs : mets GOOGLEJOBS_SEARCHES_PER_RUN=$recherches_google dans le profil de chaque personne qui l'utilise"
    info "(et dans le .env pour « principal » s'il n'a pas de profils/principal.env), puis : docker compose up -d"
fi
echo
echo "Commandes utiles pour $nom :"
echo "  ./lancer.sh $nom                                    # lancer une recherche, activer ou arrêter l'envoi automatique"
echo "  docker compose logs -f $nom                         # suivre les logs de l'envoi automatique"
echo "  nano profils/$nom.env && docker compose up -d $nom   # modifier ses réglages"
