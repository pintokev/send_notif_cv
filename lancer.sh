#!/usr/bin/env bash
# Lance une recherche à la demande, sans attendre l'heure prévue,
# et active ou arrête l'envoi automatique quotidien.
#
# Usage : ./lancer.sh                 avec des menus
#         ./lancer.sh <nom>           avec des menus, pour cette personne
#         ./lancer.sh <nom> <action>  sans question. Actions : envoi, apercu, test-mail,
#                                     profil, activer [HH:MM], heure HH:MM, arreter

set -euo pipefail
cd "$(dirname "$0")"
source scripts/commun.sh

verifier_docker
[[ -f .env ]] || erreur "Rien n'est encore installé : lance d'abord ./installer.sh"
services=$(docker compose config --services 2>/dev/null) || erreur "docker compose config a échoué : vérifie docker-compose.yml."
actifs=$(docker compose ps --status running --services 2>/dev/null || true)

profils=()
while IFS= read -r service; do
    if [[ -n $service ]]; then profils+=("$service"); fi
done <<<"$services"

est_actif() { grep -qx "$1" <<<"$actifs"; }

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
        choisir "Pour qui ?" "${options[@]}"
        nom=${profils[REPONSE - 1]}
    fi
elif ! grep -qx -- "$nom" <<<"$services"; then
    erreur "Profil « $nom » inconnu. Profils existants : $(echo "$services" | tr '\n' ' ')"
fi
[[ -f data/$nom/cv.pdf ]] || erreur "Pas de CV pour « $nom » : dépose-le dans data/$nom/cv.pdf, ou lance ./installer.sh"

heure=$(lire_reglage "profils/$nom.env" RUN_AT)
heure=${heure:-$(lire_reglage .env RUN_AT)}
heure=${heure:-21:00}

# ─── Action ────────────────────────────────────────────────────────────
action=${2:-}
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

# Nouvelle heure de l'envoi automatique : en argument, sinon demandée (Entrée = heure actuelle)
if [[ $action == activer || $action == heure ]]; then
    nouvelle_heure=${3:-}
    if [[ -n $nouvelle_heure && ! $nouvelle_heure =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        erreur "Heure invalide : $nouvelle_heure (format attendu : HH:MM, ex. 08:30)"
    fi
    while [[ ! $nouvelle_heure =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; do
        if [[ -n $nouvelle_heure ]]; then echo "  → format attendu : HH:MM (ex. 08:30)."; fi
        demander "Heure de l'envoi automatique, tous les jours (HH:MM)" "$heure"
        nouvelle_heure=$REPONSE
    done
    if [[ $nouvelle_heure != "$heure" ]]; then
        ecrire_reglage "profils/$nom.env" RUN_AT "$nouvelle_heure"
        heure=$nouvelle_heure
    fi
fi

echo
construire_image
case $action in
    envoi)
        lancer_recherche "$nom" || exit 1
        ;;
    apercu)
        lancer_recherche "$nom" --dry-run || exit 1
        # Ouvre l'aperçu dans le navigateur s'il y a un écran (pas sur un serveur)
        if [[ $(uname -s) == Darwin ]]; then
            open "data/$nom/last_email.html" || true
        elif [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]] && command -v xdg-open >/dev/null; then
            xdg-open "data/$nom/last_email.html" >/dev/null 2>&1 || true
        fi
        ;;
    test-mail)
        docker compose run --rm -T "$nom" python -m app test-mail </dev/null
        ok "Mail de test envoyé : vérifie la boîte de réception (et les spams)."
        ;;
    profil)
        docker compose run --rm -T "$nom" python -m app profile </dev/null
        ;;
    activer | heure)
        if [[ $action == activer ]] || est_actif "$nom"; then
            docker compose up -d "$nom"  # recrée le conteneur si l'heure a changé
            ok "Envoi automatique activé : « $nom » recevra ses offres tous les jours à $heure, tant que Docker tourne."
        else
            ok "Heure enregistrée ($heure). L'envoi automatique n'est pas actif : ./lancer.sh $nom activer"
        fi
        ;;
    arreter)
        docker compose stop "$nom"
        ok "Envoi automatique arrêté pour « $nom ». Tu peux toujours lancer une recherche avec ./lancer.sh"
        ;;
    *)
        erreur "Action inconnue : $action (envoi, apercu, test-mail, profil, activer, heure ou arreter)"
        ;;
esac
