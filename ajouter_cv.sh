#!/usr/bin/env bash
# Ajoute une nouvelle personne (un CV = un envoi de mail) à la veille d'offres, ou modifie
# les réglages d'une personne existante.
#
# Pour un ajout, le script pose les questions une par une, puis :
#   1. copie le CV dans data/<nom>/cv.pdf ;
#   2. crée ses réglages dans profils/<nom>.env ;
#   3. déclare son conteneur dans docker-compose.override.yml (fichier lu
#      automatiquement par Docker Compose et ignoré par git : pas de conflit au git pull) ;
#   4. propose une première recherche, puis l'envoi automatique quotidien.
#
# Usage : ./ajouter_cv.sh                 (depuis le dossier du projet)
#         ./ajouter_cv.sh --principal     premier profil, « principal », déjà déclaré dans
#                                         docker-compose.yml (utilisé par installer.sh)
#         ./ajouter_cv.sh --modifier <nom>  mêmes questions, valeurs actuelles proposées
#                                         (utilisé par lancer.sh)

set -euo pipefail
cd "$(dirname "$0")"
source scripts/commun.sh

OVERRIDE=docker-compose.override.yml
principal=false
modifier=false
case ${1:-} in
    --principal) principal=true ;;
    --modifier) modifier=true ;;
esac

# demander_texte "Question" [valeur proposée] → $REPONSE ; « - » vide la valeur
demander_texte() {
    demander "$@"
    if [[ $REPONSE == - ]]; then REPONSE=""; fi
}

# ─── Vérifications préalables ──────────────────────────────────────────
verifier_docker
[[ -f .env ]] || erreur "Fichier .env introuvable : lance d'abord ./installer.sh."
existants=$(docker compose config --services 2>/dev/null) || erreur "docker compose config a échoué : vérifie docker-compose.yml."

echo
if $modifier; then
    nom=${2:-}
    grep -qx -- "$nom" <<<"$existants" || erreur "Profil « $nom » inconnu. Profils existants : $(echo "$existants" | tr '\n' ' ')"
    [[ -f data/$nom/cv.pdf ]] || erreur "Pas de CV pour « $nom » : dépose-le dans data/$nom/cv.pdf."
    info "═══ Modification du profil « $nom » ═══"
    echo "Entrée garde la valeur actuelle (entre crochets), « - » la vide."
elif $principal; then
    info "═══ Création du premier profil ═══"
    nom=principal
    if [[ -e data/$nom/cv.pdf ]]; then
        erreur "Le profil « $nom » a déjà un CV. Pour le modifier : ./lancer.sh $nom. Pour ajouter une personne : ./ajouter_cv.sh"
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
        elif [[ $nom == tous ]]; then
            echo "  → « tous » est réservé (./lancer.sh tous agit sur tous les profils)."
        elif grep -qx "$nom" <<<"$existants"; then
            echo "  → « $nom » existe déjà."
        elif [[ -e profils/$nom.env || -e data/$nom ]]; then
            echo "  → profils/$nom.env ou data/$nom/ existe déjà : choisis un autre nom ou supprime-les."
        else
            break
        fi
    done
fi

# Valeurs proposées : celles du profil pour une modification, sinon les valeurs par défaut
if $modifier; then
    d_mail=$(reglage_de "$nom" MAIL_TO)
    d_ville=$(reglage_de "$nom" LOCATION_CITY)
    d_rayon=$(reglage_de "$nom" LOCATION_RADIUS_KM)
    # Même lecture que l'appli (app/config.py) : vide = oui, sinon oui seulement pour 1/true/yes/oui/on
    d_teletravail=$(reglage_de "$nom" INCLUDE_REMOTE)
    d_teletravail=${d_teletravail,,}
    if [[ -z $d_teletravail || $d_teletravail =~ ^(1|true|yes|oui|on)$ ]]; then d_teletravail=o; else d_teletravail=n; fi
    d_preferences=$(reglage_de "$nom" CANDIDATE_PREFERENCES)
    d_exclusions=$(reglage_de "$nom" EXCLUDE_KEYWORDS)
    d_entreprises=$(reglage_de "$nom" TARGET_COMPANIES)
    d_sources=$(reglage_de "$nom" SOURCES)
    d_sources=${d_sources// /}
    d_heure=$(reglage_de "$nom" RUN_AT)
    d_heure=${d_heure:-21:00}  # RUN_AT vide : l'appli envoie à 21:00
    d_recherche=$(reglage_de "$nom" SEARCH_AT)
    d_score=$(reglage_de "$nom" MIN_SCORE)
    d_max=$(reglage_de "$nom" MAX_RESULTS)
else
    d_mail="" d_ville="" d_rayon="" d_teletravail=o d_preferences="" d_exclusions="stage,alternance"
    d_entreprises="" d_sources="" d_heure="" d_recherche="" d_score="" d_max=""
fi
d_rayon=${d_rayon:-30} d_heure=${d_heure:-21:15} d_score=${d_score:-60} d_max=${d_max:-15}

# ─── 2. CV ─────────────────────────────────────────────────────────────
while true; do
    if $modifier; then
        demander "Nouveau CV (PDF) : chemin ou fichier glissé dans cette fenêtre (Entrée = garder l'actuel)" ""
        [[ -z $REPONSE ]] && { cv=""; break; }
    else
        demander "Chemin du CV (PDF) sur cette machine (tu peux glisser le fichier dans cette fenêtre)"
    fi
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
    demander "Adresse mail qui recevra les offres (plusieurs : séparées par des virgules)" "$d_mail"
    mail_to=$REPONSE
    if [[ $mail_to =~ ^[^@[:space:],]+@[^@[:space:],]+\.[^@[:space:],]+(,[[:space:]]*[^@[:space:],]+@[^@[:space:],]+\.[^@[:space:],]+)*$ ]]; then
        break
    fi
    echo "  → adresse invalide."
done

# ─── 4. Recherche ──────────────────────────────────────────────────────
echo
info "Recherche (Entrée = valeur proposée, « - » = vide)"
demander_texte "Ville autour de laquelle chercher (vide = toute la France)" "$d_ville"
ville=$REPONSE
rayon=$d_rayon
if [[ -n $ville ]]; then
    while true; do
        demander "Rayon de recherche en km" "$d_rayon"
        [[ $REPONSE =~ ^[0-9]+$ ]] && { rayon=$REPONSE; break; }
        echo "  → un nombre entier, en km."
    done
fi
if confirmer "Inclure les offres 100 % télétravail ?" "$d_teletravail"; then teletravail=true; else teletravail=false; fi
demander_texte "Critères en langage naturel (ex. CDI uniquement, pas de management ; vide = aucun)" "$d_preferences"
preferences=$REPONSE
demander_texte "Mots à exclure des intitulés, séparés par des virgules" "$d_exclusions"
exclusions=$REPONSE
demander_texte "Entreprises cibles, séparées par des virgules (vide = aucune)" "$d_entreprises"
entreprises=$REPONSE

# Sources à clé : proposées seulement si leur clé est dans le .env. Les autres sources gardent
# leur état actuel (toutes pour un nouveau profil) : une source sans clé reste dans la liste,
# ignorée tant que la clé manque, pour s'activer dès qu'on l'ajoute. WTTJ et les sites
# télétravail sont gratuits ; les sites carrière ne servent que s'il y a des entreprises cibles.
utilisee() { [[ -z $d_sources || ,$d_sources, == *,$1,* ]]; }
defaut_source() { if utilisee "$1"; then echo o; else echo n; fi; }
if [[ -n $(lire_reglage .env FRANCETRAVAIL_CLIENT_ID)$(lire_reglage .env ADZUNA_APP_ID)$(lire_reglage .env SERPAPI_API_KEY) ]]; then
    echo
    info "Sources d'offres utilisant tes clés API"
fi
choisies=" "
for source in francetravail adzuna wttj googlejobs careersites remotive remoteok jobicy; do
    case $source in
        francetravail) cle=FRANCETRAVAIL_CLIENT_ID question="Chercher sur France Travail ?" ;;
        adzuna) cle=ADZUNA_APP_ID question="Chercher sur Adzuna ?" ;;
        googlejobs) cle=SERPAPI_API_KEY question="Chercher sur Google Jobs (LinkedIn, Indeed, APEC… ; quota SerpApi partagé entre les personnes) ?" ;;
        *) cle="" ;;
    esac
    if [[ -n $cle && -n $(lire_reglage .env "$cle") ]]; then
        if confirmer "$question" "$(defaut_source "$source")"; then choisies+="$source "; fi
    elif utilisee "$source"; then
        choisies+="$source "
    fi
done
sources=""
for source in $choisies; do sources+=${sources:+,}$source; done

# ─── 5. Envoi ──────────────────────────────────────────────────────────
echo
info "Envoi du mail"
while true; do
    demander "Heure d'envoi quotidienne (HH:MM, heure de Paris)" "$d_heure"
    [[ $REPONSE =~ $HEURE_REGEX ]] && { heure=$REPONSE; break; }
    echo "  → format attendu : HH:MM (ex. 08:30)."
done
echo "La recherche peut avoir lieu plus tôt que le mail, par exemple la nuit : les offres notées attendent l'heure du mail."
while true; do
    demander "Heure de la recherche (HH:MM, ex. 03:00 ; « non » = au moment du mail)" "${d_recherche:-non}"
    if [[ $REPONSE == non || $REPONSE == - || $REPONSE =~ $HEURE_REGEX ]]; then
        heure_recherche=$REPONSE
        [[ $heure_recherche == non || $heure_recherche == - || $heure_recherche == "$heure" ]] && heure_recherche=""
        break
    fi
    echo "  → format attendu : HH:MM (ex. 03:00), ou « non »."
done
if [[ -n $heure_recherche ]]; then
    horaire="recherche à $heure_recherche, mail à $heure"
else
    horaire="à $heure"
fi
while true; do
    demander "Score minimum (0-100) pour qu'une offre figure dans le mail" "$d_score"
    [[ $REPONSE =~ ^[0-9]+$ ]] && (( 10#$REPONSE <= 100 )) && { score=$REPONSE; break; }
    echo "  → un nombre entre 0 et 100."
done
while true; do
    demander "Nombre maximum d'offres par mail" "$d_max"
    [[ $REPONSE =~ ^[1-9][0-9]*$ ]] && { max_offres=$REPONSE; break; }
    echo "  → un nombre entier positif."
done

# utilise_google <nom> : vrai si cette personne interroge Google Jobs
# (SOURCES de son profil, sinon celui du .env ; vide = toutes les sources)
utilise_google() {
    local valeur
    valeur=$(reglage_de "$1" SOURCES)
    valeur=${valeur// /}
    [[ -z $valeur || ,$valeur, == *,googlejobs,* ]]
}

# valeur_google <nom> → recherches Google Jobs par jour de cette personne (6 par défaut)
valeur_google() {
    local valeur
    valeur=$(reglage_de "$1" GOOGLEJOBS_SEARCHES_PER_RUN)
    if [[ $valeur =~ ^[0-9]+$ ]]; then echo "$valeur"; else echo 6; fi
}

# Quota SerpApi gratuit (250 recherches/mois) partagé entre les personnes qui utilisent Google Jobs.
# Seuls les profils avec un CV comptent (« principal » peut exister sans être utilisé).
QUOTA_SERPAPI=250
google=false
[[ ,$sources, == *,googlejobs,* ]] && google=true
autres_google=""  # autres personnes qui utilisent Google Jobs, séparées par des espaces
nb_autres=0
somme_autres=0
while IFS= read -r service; do
    if [[ -n $service && $service != "$nom" && -f data/$service/cv.pdf ]] && utilise_google "$service"; then
        autres_google+="$service "
        nb_autres=$((nb_autres + 1))
        somme_autres=$((somme_autres + $(valeur_google "$service")))
    fi
done <<<"$existants"
autres_google=${autres_google% }
nb_google=$((nb_autres + 1))
conseil=$(( QUOTA_SERPAPI / (31 * nb_google) ))
(( conseil < 1 )) && conseil=1
(( conseil > 6 )) && conseil=6
recherches_google=$conseil
reequilibrage=""  # nouvelle valeur pour les autres personnes, si elles doivent être réduites
total_google=0
if $google; then
    echo
    echo "Google Jobs : $QUOTA_SERPAPI recherches gratuites par mois, partagées entre les $nb_google personnes qui l'utilisent."
    echo "Conseillé : $conseil recherches par jour chacune (plus de recherches = plus d'offres)."
    if $modifier; then d_google=$(valeur_google "$nom"); else d_google=$conseil; fi
    while true; do
        demander "Recherches Google Jobs par jour pour $nom" "$d_google"
        [[ $REPONSE =~ ^[1-9][0-9]*$ ]] && { recherches_google=$REPONSE; break; }
        echo "  → un nombre entier positif."
    done
    total_google=$(( (somme_autres + recherches_google) * 31 ))
    if (( total_google > QUOTA_SERPAPI && nb_autres > 0 )); then
        reduit=$(( (QUOTA_SERPAPI - recherches_google * 31) / (31 * nb_autres) ))
        (( reduit < 1 )) && reduit=1
        # Seules les personnes au-dessus de cette valeur sont réduites (jamais augmentées)
        a_reduire="" somme_reduite=0
        for service in $autres_google; do
            valeur=$(valeur_google "$service")
            if (( valeur > reduit )); then a_reduire+="$service "; valeur=$reduit; fi
            somme_reduite=$((somme_reduite + valeur))
        done
        a_reduire=${a_reduire% }
        attention "Au total : $total_google recherches par mois pour toutes les personnes, au-delà des $QUOTA_SERPAPI gratuites."
        if [[ -n $a_reduire ]] && confirmer "Ramener $a_reduire à $reduit recherches par jour ?" o; then
            reequilibrage=$reduit
            autres_google=$a_reduire
            total_google=$(( (somme_reduite + recherches_google) * 31 ))
        fi
    fi
    if (( total_google > QUOTA_SERPAPI )); then
        attention "Le quota sera dépassé : Google Jobs s'arrêtera avant la fin du mois, quand il sera épuisé."
    fi
fi

# Applique la réduction acceptée aux autres personnes, et relance leur envoi automatique s'il est actif
appliquer_reequilibrage() {
    local service actifs relancer=""
    [[ -n $reequilibrage ]] || return 0
    actifs=$(docker compose ps --status running --services 2>/dev/null || true)
    for service in $autres_google; do
        ecrire_reglage "profils/$service.env" GOOGLEJOBS_SEARCHES_PER_RUN "$reequilibrage"
        if grep -qx -- "$service" <<<"$actifs"; then relancer+="$service "; fi
    done
    ok "Google Jobs : $reequilibrage recherches par jour pour $autres_google"
    if [[ -n $relancer ]]; then
        docker compose up -d $relancer  # un nom de service par mot
    fi
}

# ─── Récapitulatif ─────────────────────────────────────────────────────
if $modifier; then
    cv_recap=${cv:-inchangé}${cv:+ → data/$nom/cv.pdf}
else
    cv_recap="$cv → data/$nom/cv.pdf"
fi
echo
info "═══ Récapitulatif ═══"
cat <<EOF
  Nom                : $nom
  CV                 : $cv_recap
  Mail               : $mail_to
  Ville / rayon      : ${ville:-toute la France}${ville:+ / $rayon km}
  Télétravail        : $teletravail
  Critères           : ${preferences:-aucun}
  Mots exclus        : ${exclusions:-aucun}
  Entreprises cibles : ${entreprises:-aucune}
  Envoi              : tous les jours $horaire, score ≥ $score, $max_offres offres max
  Sources            : $sources
EOF
if $google; then
    echo "  Google Jobs        : $recherches_google recherches par jour"
    if [[ -n $reequilibrage ]]; then
        echo "                       (et $reequilibrage pour $autres_google) : $total_google recherches par mois sur $QUOTA_SERPAPI"
    else
        echo "                       (toutes personnes : $total_google recherches par mois sur $QUOTA_SERPAPI)"
    fi
fi
echo

# ─── Modification : mise à jour du profil existant ─────────────────────
if $modifier; then
    confirmer "Enregistrer ces modifications ?" o || { echo "Annulé, rien n'a été modifié."; exit 0; }
    if [[ -n $cv ]]; then
        cp "$cv" "data/$nom/cv.pdf" 2>/dev/null || sudo cp "$cv" "data/$nom/cv.pdf"
        donner_au_conteneur "data/$nom"
        ok "Nouveau CV copié : il sera analysé à la prochaine recherche."
    fi
    profil=profils/$nom.env
    ecrire_reglage "$profil" MAIL_TO "$mail_to"
    ecrire_reglage "$profil" LOCATION_CITY "$ville"
    ecrire_reglage "$profil" LOCATION_RADIUS_KM "$rayon"
    ecrire_reglage "$profil" INCLUDE_REMOTE "$teletravail"
    ecrire_reglage "$profil" CANDIDATE_PREFERENCES "$preferences"
    ecrire_reglage "$profil" EXCLUDE_KEYWORDS "$exclusions"
    ecrire_reglage "$profil" TARGET_COMPANIES "$entreprises"
    ecrire_reglage "$profil" RUN_AT "$heure"
    ecrire_reglage "$profil" SEARCH_AT "$heure_recherche"
    ecrire_reglage "$profil" MIN_SCORE "$score"
    ecrire_reglage "$profil" MAX_RESULTS "$max_offres"
    ecrire_reglage "$profil" SOURCES "$sources"
    if $google; then ecrire_reglage "$profil" GOOGLEJOBS_SEARCHES_PER_RUN "$recherches_google"; fi
    ok "Réglages enregistrés dans $profil"
    if docker compose ps --status running --services 2>/dev/null | grep -qx -- "$nom"; then
        docker compose up -d "$nom"  # recrée le conteneur avec les nouveaux réglages
        ok "Envoi automatique relancé avec les nouveaux réglages (tous les jours, $horaire)."
    fi
    appliquer_reequilibrage
    exit 0
fi

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

# Heure du mail, et heure de la recherche si elle a lieu plus tôt (vide = au moment du mail)
RUN_AT=$heure
SEARCH_AT=$heure_recherche
MIN_SCORE=$score
MAX_RESULTS=$max_offres

# Sources interrogées (retirer un nom pour ne plus l'utiliser)
SOURCES=$sources
# Recherches Google Jobs par jour (quota SerpApi gratuit de 250 par mois, partagé entre les personnes)
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
appliquer_reequilibrage

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
echo "Envoi automatique : la recherche peut tourner toute seule tous les jours ($horaire),"
echo "tant que cette machine et Docker restent allumés. Sinon, lance-la quand tu veux avec ./lancer.sh"
if confirmer "Activer l'envoi automatique quotidien pour $nom ?" o; then
    docker compose up -d "$nom"
    ok "« $nom » recevra ses offres tous les jours ($horaire)."
else
    echo "Pour l'activer plus tard : ./lancer.sh $nom"
fi

echo
echo "Commandes utiles pour $nom :"
echo "  ./lancer.sh $nom                                    # lancer une recherche, activer ou arrêter l'envoi automatique"
echo "  docker compose logs -f $nom                         # suivre les logs de l'envoi automatique"
echo "  nano profils/$nom.env && docker compose up -d $nom   # modifier ses réglages"
