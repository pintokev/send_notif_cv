#!/usr/bin/env bash
# Lance une recherche à la demande, sans attendre l'heure prévue,
# et active ou arrête l'envoi automatique quotidien.
#
# Usage : ./lancer.sh                 avec des menus
#         ./lancer.sh <nom>           avec des menus, pour cette personne (« tous » : tous les profils)
#         ./lancer.sh <nom> <action>  sans question. Actions : envoi, apercu, test-mail, profil,
#                                     activer [mail [recherche]], heure mail [recherche], arreter
#                                     (heures en HH:MM ; recherche « non » = au moment du mail ;
#                                     avec « tous », chacun garde ses heures)

set -euo pipefail
cd "$(dirname "$0")"
source scripts/commun.sh

HEURE_REGEX='^([01][0-9]|2[0-3]):[0-5][0-9]$'

verifier_docker
[[ -f .env ]] || erreur "Rien n'est encore installé : lance d'abord ./installer.sh"
services=$(docker compose config --services 2>/dev/null) || erreur "docker compose config a échoué : vérifie docker-compose.yml."
actifs=$(docker compose ps --status running --services 2>/dev/null || true)

profils=()
while IFS= read -r service; do
    if [[ -n $service ]]; then profils+=("$service"); fi
done <<<"$services"

est_actif() { grep -qx "$1" <<<"$actifs"; }

# reglage_de <nom> CLE → valeur du profil, sinon du .env (comme Docker Compose)
reglage_de() {
    if grep -q "^$2=" "profils/$1.env" 2>/dev/null; then
        lire_reglage "profils/$1.env" "$2"
    else
        lire_reglage .env "$2"
    fi
}

# heure_de <nom> → heure du mail (21:00 par défaut)
heure_de() {
    local heure
    heure=$(reglage_de "$1" RUN_AT)
    printf '%s' "${heure:-21:00}"
}

# recherche_de <nom> → heure de la recherche si elle a lieu avant le mail, sinon vide
recherche_de() {
    local recherche
    recherche=$(reglage_de "$1" SEARCH_AT)
    if [[ $recherche != "$(heure_de "$1")" ]]; then printf '%s' "$recherche"; fi
}

# horaire_de <nom> → « à 21:00 » ou « recherche à 03:00, mail à 21:00 »
horaire_de() {
    local recherche
    recherche=$(recherche_de "$1")
    if [[ -n $recherche ]]; then
        printf 'recherche à %s, mail à %s' "$recherche" "$(heure_de "$1")"
    else
        printf 'à %s' "$(heure_de "$1")"
    fi
}

# executer <nom> <action> : exécute l'action pour une personne → code de retour 0 si elle a réussi
executer() {
    local nom=$1 action=$2 horaire
    horaire=$(horaire_de "$nom")
    case $action in
        envoi)
            lancer_recherche "$nom"
            ;;
        apercu)
            lancer_recherche "$nom" --dry-run || return 1
            # Ouvre l'aperçu dans le navigateur s'il y a un écran (pas sur un serveur)
            if [[ $(uname -s) == Darwin ]]; then
                open "data/$nom/last_email.html" || true
            elif [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]] && command -v xdg-open >/dev/null; then
                xdg-open "data/$nom/last_email.html" >/dev/null 2>&1 || true
            fi
            ;;
        test-mail)
            if ! docker compose run --rm -T "$nom" python -m app test-mail </dev/null; then
                attention "L'envoi du mail de test a échoué pour « $nom » (voir le message ci-dessus)."
                return 1
            fi
            ok "Mail de test envoyé pour « $nom » : vérifie la boîte de réception (et les spams)."
            ;;
        profil)
            docker compose run --rm -T "$nom" python -m app profile </dev/null
            ;;
        activer | heure)
            if [[ $action == activer ]] || est_actif "$nom"; then
                docker compose up -d "$nom" || return 1  # recrée le conteneur si l'heure a changé
                ok "Envoi automatique activé pour « $nom » : tous les jours, $horaire, tant que Docker tourne."
            else
                ok "Heures enregistrées ($horaire). L'envoi automatique n'est pas actif : ./lancer.sh $nom activer"
            fi
            ;;
        arreter)
            docker compose stop "$nom" || return 1
            ok "Envoi automatique arrêté pour « $nom ». Tu peux toujours lancer une recherche avec ./lancer.sh"
            ;;
    esac
}

# ─── Personne ──────────────────────────────────────────────────────────
nom=${1:-}
if [[ -z $nom ]]; then
    if (( ${#profils[@]} == 1 )); then
        nom=${profils[0]}
    else
        options=()
        for p in "${profils[@]}"; do
            if est_actif "$p"; then options+=("$p (envoi automatique actif)"); else options+=("$p"); fi
        done
        echo
        choisir "Pour qui ?" "${options[@]}" "Tous les profils"
        if (( REPONSE > ${#profils[@]} )); then nom=tous; else nom=${profils[REPONSE - 1]}; fi
    fi
elif [[ $nom != tous ]] && ! grep -qx -- "$nom" <<<"$services"; then
    erreur "Profil « $nom » inconnu. Profils existants : $(echo "$services" | tr '\n' ' ')(ou « tous »)"
fi

# ─── Action ────────────────────────────────────────────────────────────
action=${2:-}
if [[ $nom == tous ]]; then
    if [[ -z $action ]]; then
        echo
        choisir "Que veux-tu faire pour tous les profils, l'un après l'autre ?" \
            "Lancer une recherche et envoyer le mail" \
            "Lancer une recherche sans envoyer de mail (aperçu)" \
            "Envoyer un mail de test" \
            "Activer l'envoi automatique quotidien (chacun à ses heures)" \
            "Arrêter l'envoi automatique quotidien"
        actions=(envoi apercu test-mail activer arreter)
        action=${actions[REPONSE - 1]}
    fi
    case $action in
        envoi | apercu | test-mail | profil | activer | arreter) ;;
        heure) erreur "Pour changer les heures, choisis un profil : ./lancer.sh <nom> heure HH:MM [HH:MM]" ;;
        *) erreur "Action inconnue : $action (envoi, apercu, test-mail, profil, activer ou arreter)" ;;
    esac
    [[ -z ${3:-} ]] || erreur "Avec « tous », chacun garde ses heures : ./lancer.sh <nom> $action HH:MM pour en changer."
else
    [[ -f data/$nom/cv.pdf ]] || erreur "Pas de CV pour « $nom » : dépose-le dans data/$nom/cv.pdf, ou lance ./installer.sh"
    heure=$(heure_de "$nom")
    recherche=$(recherche_de "$nom")
    if [[ -z $action ]]; then
        options=(
            "Lancer une recherche et envoyer le mail"
            "Lancer une recherche sans envoyer de mail (aperçu)"
            "Envoyer un mail de test"
            "Voir le profil déduit du CV (métier, mots-clés, requêtes)"
        )
        actions=(envoi apercu test-mail profil)
        if est_actif "$nom"; then
            options+=("Changer les heures de l'envoi automatique (actuellement tous les jours, $(horaire_de "$nom"))"
                      "Arrêter l'envoi automatique quotidien")
            actions+=(heure arreter)
        else
            options+=("Activer l'envoi automatique quotidien, aux heures de ton choix")
            actions+=(activer)
        fi
        echo
        choisir "Que veux-tu faire pour « $nom » ?" "${options[@]}"
        action=${actions[REPONSE - 1]}
    fi
    case $action in
        envoi | apercu | test-mail | profil | activer | heure | arreter) ;;
        *) erreur "Action inconnue : $action (envoi, apercu, test-mail, profil, activer, heure ou arreter)" ;;
    esac

    # Heures de l'envoi automatique : en arguments, sinon demandées (Entrée = heure actuelle).
    # Heure de la recherche : « non » (ou vide en argument) = au moment du mail.
    if [[ $action == activer || $action == heure ]]; then
        nouvelle_heure=${3:-}
        nouvelle_recherche=${4:-}
        if [[ -n $nouvelle_heure && ! $nouvelle_heure =~ $HEURE_REGEX ]]; then
            erreur "Heure du mail invalide : $nouvelle_heure (format attendu : HH:MM, ex. 08:30)"
        fi
        if [[ -n $nouvelle_recherche && $nouvelle_recherche != non && ! $nouvelle_recherche =~ $HEURE_REGEX ]]; then
            erreur "Heure de recherche invalide : $nouvelle_recherche (HH:MM, ex. 03:00, ou « non »)"
        fi
        if [[ -z $nouvelle_heure ]]; then
            while true; do
                demander "Heure du mail, tous les jours (HH:MM)" "$heure"
                [[ $REPONSE =~ $HEURE_REGEX ]] && { nouvelle_heure=$REPONSE; break; }
                echo "  → format attendu : HH:MM (ex. 08:30)."
            done
            echo "La recherche peut avoir lieu plus tôt, par exemple la nuit : les offres notées attendent l'heure du mail."
            while true; do
                demander "Heure de la recherche (HH:MM, ex. 03:00 ; « non » = au moment du mail)" "${recherche:-non}"
                if [[ $REPONSE == non || $REPONSE =~ $HEURE_REGEX ]]; then nouvelle_recherche=$REPONSE; break; fi
                echo "  → format attendu : HH:MM (ex. 03:00), ou « non »."
            done
        elif [[ -z $nouvelle_recherche ]]; then
            nouvelle_recherche=${recherche:-non}  # heure du mail seule en argument : la recherche ne change pas
        fi
        if [[ $nouvelle_recherche == non || $nouvelle_recherche == "$nouvelle_heure" ]]; then nouvelle_recherche=""; fi
        if [[ $nouvelle_heure != "$heure" ]]; then
            ecrire_reglage "profils/$nom.env" RUN_AT "$nouvelle_heure"
        fi
        if [[ $nouvelle_recherche != "$recherche" ]]; then
            ecrire_reglage "profils/$nom.env" SEARCH_AT "$nouvelle_recherche"
        fi
    fi
fi

# ─── Exécution ─────────────────────────────────────────────────────────
echo
construire_image

if [[ $nom != tous ]]; then
    executer "$nom" "$action" || exit 1
    exit 0
fi

# Tous les profils, l'un après l'autre : un échec n'arrête pas les suivants
bilan=()
echecs=0
for p in "${profils[@]}"; do
    echo
    info "═══ $p ═══"
    if [[ ! -f data/$p/cv.pdf ]]; then
        attention "Pas de CV dans data/$p/cv.pdf : profil ignoré."
        bilan+=("- $p : ignoré (pas de CV)")
    elif executer "$p" "$action"; then
        bilan+=("✔ $p : OK")
    else
        bilan+=("✘ $p : échec (voir plus haut)")
        echecs=$((echecs + 1))
    fi
done
echo
info "═══ Récapitulatif ═══"
printf '  %s\n' "${bilan[@]}"
(( echecs == 0 )) || exit 1
