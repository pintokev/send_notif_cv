#!/usr/bin/env bash
# Installation guidée de la veille d'offres d'emploi :
#   1. crée le fichier .env : connexion à Claude, envoi des mails, sources d'offres ;
#   2. construit l'image Docker et envoie un mail de test ;
#   3. crée le premier profil (CV + adresse mail) avec ajouter_cv.sh --principal.
# Relancé plus tard, il permet de modifier le .env ou d'ajouter une personne.
#
# Usage : ./installer.sh   (depuis le dossier du projet)

set -euo pipefail
cd "$(dirname "$0")"
source scripts/commun.sh

ENV=.env                # fichier modifié par ecrire_env
nouvelle_install=true   # sinon, Entrée garde la valeur actuelle du .env
MAIL_REGEX='^[^@[:space:],]+@[^@[:space:],]+\.[^@[:space:],]+$'

# ecrire_env CLE valeur : remplace la ligne CLE= du fichier $ENV (ou l'ajoute)
ecrire_env() { ecrire_reglage "$ENV" "$@"; }

# demander_valeur "Question" CLE [secret] → $REPONSE. Entrée garde la valeur actuelle du .env.
demander_valeur() {
    local question=$1 cle=$2 secret=${3:-} actuel=""
    if ! $nouvelle_install; then
        actuel=$(lire_reglage "$ENV" "$cle")
    fi
    if [[ -n $actuel ]]; then
        question+=" (Entrée = garder la valeur actuelle)"
    fi
    if [[ -n $secret ]]; then
        read -r -s -p "$question : " REPONSE
        echo
    else
        read -r -p "$question : " REPONSE
    fi
    REPONSE=${REPONSE:-$actuel}
}

# demander_obligatoire "Question" CLE [secret] : comme demander_valeur, mais refuse une réponse vide
demander_obligatoire() {
    while true; do
        demander_valeur "$@"
        if [[ -n $REPONSE ]]; then
            return 0
        fi
        echo "  → cette valeur est obligatoire."
    done
}

configurer_claude() {
    echo
    info "─── Connexion à Claude ───"
    echo "Claude lit le CV et note chaque offre. Deux façons de s'y connecter :"
    choisir "Laquelle choisis-tu ?" \
        "Mon abonnement Claude Pro ou Max (inclus dans l'abonnement)" \
        "Une clé API Anthropic (facturée à l'usage)"
    if [[ $REPONSE == 1 ]]; then
        cat <<'EOF'

Il te faut un jeton lié à ton abonnement. Sur un ordinateur où Claude Code est installé
(https://claude.com/claude-code) et connecté à ton compte, tape dans un terminal :
    claude setup-token
puis copie le jeton affiché (il commence par sk-ant-oat). Garde-le secret.
EOF
        demander_obligatoire "Colle le jeton ici (la saisie reste invisible)" CLAUDE_CODE_OAUTH_TOKEN secret
        ecrire_env CLAUDE_CODE_OAUTH_TOKEN "$REPONSE"
        ecrire_env ANTHROPIC_API_KEY ""
    else
        echo
        echo "Crée une clé sur https://platform.claude.com → API Keys (elle commence par sk-ant-api)."
        demander_obligatoire "Colle la clé ici (la saisie reste invisible)" ANTHROPIC_API_KEY secret
        ecrire_env ANTHROPIC_API_KEY "$REPONSE"
        ecrire_env CLAUDE_CODE_OAUTH_TOKEN ""
        echo
        choisir "Modèle utilisé pour noter les offres :" \
            "Opus : la meilleure notation (environ 0,50 à 1 \$ par jour)" \
            "Haiku : notation un peu moins fine (quelques centimes par jour)"
        if [[ $REPONSE == 1 ]]; then
            ecrire_env CLAUDE_MODEL claude-opus-5-5
        else
            ecrire_env CLAUDE_MODEL claude-haiku-5-5
        fi
    fi
    ecrire_env CLAUDE_BACKEND auto
}

configurer_mail() {
    local hote port securite
    echo
    info "─── Envoi des mails ───"
    echo "Les offres sont envoyées depuis une adresse mail à toi."
    choisir "Quelle messagerie utilises-tu pour envoyer ?" \
        "Gmail" \
        "OVH" \
        "Autre (je connais ses paramètres SMTP)"
    case $REPONSE in
        1) hote=smtp.gmail.com port=587 securite=starttls ;;
        2) hote=ssl0.ovh.net port=465 securite=ssl ;;
        3)
            demander_obligatoire "Serveur SMTP (ex. smtp.exemple.fr)" SMTP_HOST
            hote=$REPONSE
            choisir "Sécurité de la connexion :" "STARTTLS (port 587 en général)" "SSL/TLS (port 465 en général)" "Aucune"
            case $REPONSE in
                1) securite=starttls port=587 ;;
                2) securite=ssl port=465 ;;
                3) securite=none port=25 ;;
            esac
            while true; do
                demander "Port" "$port"
                [[ $REPONSE =~ ^[0-9]+$ ]] && { port=$REPONSE; break; }
                echo "  → un nombre entier."
            done
            ;;
    esac

    while true; do
        demander_obligatoire "Adresse mail d'envoi" SMTP_USER
        [[ $REPONSE =~ $MAIL_REGEX ]] && break
        echo "  → adresse invalide."
    done
    local adresse=$REPONSE

    if [[ $hote == smtp.gmail.com ]]; then
        cat <<'EOF'

Gmail n'accepte pas ton mot de passe habituel : il faut un « mot de passe d'application ».
  1. Active la validation en deux étapes sur ton compte Google, si ce n'est pas déjà fait.
  2. Va sur https://myaccount.google.com/apppasswords, crée un mot de passe (nom : « offres »).
  3. Copie les 16 lettres affichées.
EOF
    fi
    demander_obligatoire "Mot de passe (la saisie reste invisible)" SMTP_PASSWORD secret
    local mot_de_passe=$REPONSE
    [[ $hote == smtp.gmail.com ]] && mot_de_passe=${mot_de_passe// /}

    ecrire_env SMTP_HOST "$hote"
    ecrire_env SMTP_PORT "$port"
    ecrire_env SMTP_SECURITY "$securite"
    ecrire_env SMTP_USER "$adresse"
    ecrire_env SMTP_PASSWORD "$mot_de_passe"
    ecrire_env MAIL_FROM "$adresse"
    # Destinataire par défaut (mail de test, alertes) ; chaque profil indique le sien
    ecrire_env MAIL_TO "$adresse"
}

configurer_sources() {
    echo
    info "─── Sources d'offres (facultatif) ───"
    cat <<'EOF'
Sans rien configurer, l'appli cherche déjà sur Welcome to the Jungle, Remotive, Remote OK et Jobicy.
Les trois sources ci-dessous sont gratuites et apportent beaucoup plus d'offres.
Laisse vide pour en ignorer une : tu pourras l'ajouter plus tard en relançant ce script.

• France Travail : https://francetravail.io → « Créer une application » → ajouter l'API « Offres d'emploi v2 »
EOF
    demander_valeur "  Identifiant client France Travail" FRANCETRAVAIL_CLIENT_ID
    ecrire_env FRANCETRAVAIL_CLIENT_ID "$REPONSE"
    demander_valeur "  Clé secrète France Travail" FRANCETRAVAIL_CLIENT_SECRET
    ecrire_env FRANCETRAVAIL_CLIENT_SECRET "$REPONSE"

    echo "• Adzuna : https://developer.adzuna.com → inscription gratuite"
    demander_valeur "  App ID Adzuna" ADZUNA_APP_ID
    ecrire_env ADZUNA_APP_ID "$REPONSE"
    demander_valeur "  App Key Adzuna" ADZUNA_APP_KEY
    ecrire_env ADZUNA_APP_KEY "$REPONSE"

    echo "• Google Jobs (LinkedIn, Indeed, APEC, HelloWork…) : https://serpapi.com → inscription gratuite, 250 recherches par mois"
    demander_valeur "  Clé SerpApi" SERPAPI_API_KEY
    ecrire_env SERPAPI_API_KEY "$REPONSE"
}

# ─── 0. Vérifications ──────────────────────────────────────────────────
echo
info "═══ Installation de la veille d'offres d'emploi ═══"
verifier_docker
ok "Docker est prêt."

# ─── 1. Fichier .env ───────────────────────────────────────────────────
if [[ -f .env ]]; then
    nouvelle_install=false
    echo
    echo "Le fichier .env existe déjà. Réponds « o » pour modifier une partie, Entrée pour la garder."
    cp -p .env .env.bak
    confirmer "Modifier la connexion à Claude ?" n && configurer_claude
    confirmer "Modifier l'envoi des mails ?" n && configurer_mail
    confirmer "Modifier les sources d'offres ?" n && configurer_sources
    if cmp -s .env .env.bak; then
        rm -f .env.bak
    else
        ok "Fichier .env mis à jour (ancienne version : .env.bak)."
    fi
else
    # Écrit dans un fichier temporaire : un .env à moitié rempli ne doit pas rester en cas d'abandon
    ENV=.env.nouveau
    trap 'rm -f .env.nouveau .env.nouveau.tmp' EXIT
    cp .env.example "$ENV"
    chmod 600 "$ENV"
    configurer_claude
    configurer_mail
    configurer_sources
    mv "$ENV" .env
    trap - EXIT
    ENV=.env
    nouvelle_install=false
    ok "Fichier .env créé."
fi

# ─── 2. Image Docker et mail de test ───────────────────────────────────
echo
construire_image
# Créé ici : sinon Docker le crée au nom de root et ajouter_cv.sh ne pourrait pas y copier le CV
mkdir -p data/principal
destinataire=$(lire_reglage profils/principal.env MAIL_TO)
destinataire=${destinataire:-$(lire_reglage .env MAIL_TO)}
echo
if confirmer "Envoyer un mail de test à $destinataire pour vérifier l'envoi ?" o; then
    while true; do
        if docker compose run --rm -T principal python -m app test-mail </dev/null; then
            ok "Mail de test envoyé : vérifie ta boîte de réception (et les spams)."
            break
        fi
        attention "L'envoi a échoué (voir le message ci-dessus) : souvent un mot de passe incorrect."
        confirmer "Ressaisir les paramètres d'envoi des mails ?" o || break
        configurer_mail
    done
fi

# ─── 3. Premier profil ─────────────────────────────────────────────────
if [[ -f data/principal/cv.pdf ]]; then
    echo
    ok "Le premier profil (« principal ») est déjà configuré."
    if confirmer "Ajouter une autre personne ?" n; then
        ./ajouter_cv.sh
    fi
else
    ./ajouter_cv.sh --principal
fi

echo
if [[ -f data/principal/cv.pdf ]]; then
    ok "Installation terminée."
else
    attention "Le premier profil n'a pas été créé : relance ./installer.sh quand tu veux."
fi
cat <<'EOF'

Pour la suite :
  ./lancer.sh        lancer une recherche quand tu veux, activer ou arrêter l'envoi automatique
  ./ajouter_cv.sh    ajouter une autre personne
  ./installer.sh     modifier la connexion à Claude, l'envoi des mails ou les sources
EOF
