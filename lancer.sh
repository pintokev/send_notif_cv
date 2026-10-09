#!/usr/bin/env bash
# Lance une recherche à la demande, sans attendre l'heure prévue,
# et active ou arrête l'envoi automatique quotidien.
#
# Usage : ./lancer.sh                 avec des menus
#         ./lancer.sh <nom>           avec des menus, pour cette personne (« tous » : tous les profils)
#         ./lancer.sh <nom> <action>  sans question. Actions : envoi, apercu, test-mail,
#                                     profil, activer [HH:MM], heure HH:MM, arreter
#                                     (avec « tous », chacun garde son heure)

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

# heure_de <nom> → heure de l'envoi automatique (profil, sinon .env, sinon 21:00)
heure_de() {
    local heure
    heure=$(lire_reglage "profils/$1.env" RUN_AT)
    heure=${heure:-$(lire_reglage .env RUN_AT)}
    printf '%s' "${heure:-21:00}"
}

# executer <nom> <action> : exécute l'action pour une personne → code de retour 0 si elle a réussi
executer() {
    local nom=$1 action=$2 heure
    heure=$(heure_de "$nom")
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
                ok "Envoi automatique activé : « $nom » recevra ses offres tous les jours à $heure, tant que Docker tourne."
            else
                ok "Heure enregistrée ($heure). L'envoi automatique n'est pas actif : ./lancer.sh $nom activer"
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
            "Activer l'envoi automatique quotidien (chacun à son heure)" \
            "Arrêter l'envoi automatique quotidien"
        actions=(envoi apercu test-mail activer arreter)
        action=${actions[REPONSE - 1]}
    fi
    case $action in
        envoi | apercu | test-mail | profil | activer | arreter) ;;
        heure) erreur "Pour changer l'heure, choisis un profil : ./lancer.sh <nom> heure HH:MM" ;;
        *) erreur "Action inconnue : $action (envoi, apercu, test-mail, profil, activer ou arreter)" ;;
    esac
    [[ -z ${3:-} ]] || erreur "Avec « tous », chacun garde son heure : ./lancer.sh <nom> $action HH:MM pour en changer."
else
    [[ -f data/$nom/cv.pdf ]] || erreur "Pas de CV pour « $nom » : dépose-le dans data/$nom/cv.pdf, ou lance ./installer.sh"
    heure=$(heure_de "$nom")
    if [[ -z $action ]]; then
        options=(
            "Lancer une recherche et envoyer le mail"
            "Lancer une recherche sans envoyer de mail (aperçu)"
            "Envoyer un mail de test"
            "Voir le profil déduit du CV (métier, mots-clés, requêtes)"
        )
        actions=(envoi apercu test-mail profil)
        if est_actif "$nom"; then
            options+=("Changer l'heure de l'envoi automatique (actuellement tous les jours à $heure)"
                      "Arrêter l'envoi automatique quotidien")
            actions+=(heure arreter)
        else
            options+=("Activer l'envoi automatique quotidien, à l'heure de ton choix")
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

    # Nouvelle heure de l'envoi automatique : en argument, sinon demandée (Entrée = heure actuelle)
    if [[ $action == activer || $action == heure ]]; then
        nouvelle_heure=${3:-}
        if [[ -n $nouvelle_heure && ! $nouvelle_heure =~ $HEURE_REGEX ]]; then
            erreur "Heure invalide : $nouvelle_heure (format attendu : HH:MM, ex. 08:30)"
        fi
        while [[ ! $nouvelle_heure =~ $HEURE_REGEX ]]; do
            if [[ -n $nouvelle_heure ]]; then echo "  → format attendu : HH:MM (ex. 08:30)."; fi
            demander "Heure de l'envoi automatique, tous les jours (HH:MM)" "$heure"
            nouvelle_heure=$REPONSE
        done
        if [[ $nouvelle_heure != "$heure" ]]; then
            ecrire_reglage "profils/$nom.env" RUN_AT "$nouvelle_heure"
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
