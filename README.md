# Veille d'offres d'emploi à partir d'un CV

Chaque jour à heure fixe, l'appli :

1. **analyse ton CV (PDF)** avec Claude pour en déduire ton profil, les requêtes de recherche et les mots-clés (une seule fois, résultat mis en cache tant que le CV ne change pas) ;
2. **collecte les offres récentes** autour de ta ville et/ou en télétravail sur :
   - France Travail, Adzuna, Welcome to the Jungle ;
   - **Google Jobs**, qui regroupe LinkedIn, Indeed, APEC, HelloWork et des sites carrière ;
   - **les sites carrière de tes entreprises cibles**, explorés par Claude avec la recherche web ;
   - Remotive, Remote OK et Jobicy (100 % télétravail) ;
3. **élimine les doublons** (même offre sur plusieurs sites, offres déjà vues les jours précédents) ;
4. **préfiltre par mots-clés** (gratuit) pour garder les offres les plus prometteuses ;
5. **fait noter ces offres par Claude** de 0 à 100 avec une phrase d'explication ;
6. **t'envoie un mail** avec les meilleures nouvelles offres.

Une offre n'est jamais envoyée deux fois. Les bonnes offres qui n'ont pas trouvé de place dans le mail du jour (limite `MAX_RESULTS`) restent candidates les jours suivants, pendant 7 jours.

## Prérequis

| Quoi | Obligatoire | Où l'obtenir |
|---|---|---|
| Clé API Claude | oui | https://platform.claude.com → API Keys |
| Compte SMTP | oui | Gmail (mot de passe d'application : https://myaccount.google.com/apppasswords), OVH, Brevo… |
| Identifiants France Travail | conseillé | https://francetravail.io → « Créer une application » → ajouter l'API **Offres d'emploi v2** |
| Clé Adzuna | conseillé | https://developer.adzuna.com → inscription gratuite |
| Clé SerpApi (Google Jobs) | conseillé | https://serpapi.com → inscription gratuite (250 recherches/mois) |

Welcome to the Jungle, Remotive, Remote OK et Jobicy ne demandent aucune clé. La recherche sur les sites carrière utilise ta clé Claude et s'active dès que `TARGET_COMPANIES` est rempli. Une source sans identifiants est simplement ignorée.

## Installation sur le VPS

```bash
# 1. Copier le projet sur le VPS (depuis ta machine)
scp -r send_notif_cv user@ton-vps:~/

# 2. Sur le VPS
cd ~/send_notif_cv
cp .env.example .env
nano .env                     # remplir les clés, la ville, le SMTP…

mkdir -p data
cp /chemin/vers/ton_cv.pdf data/cv.pdf
sudo chown -R 1000:1000 data  # le conteneur tourne avec l'utilisateur 1000

# 3. Vérifier la configuration
docker compose build
docker compose run --rm job-alert python -m app test-mail       # mail de test
docker compose run --rm job-alert python -m app profile         # profil déduit du CV
docker compose run --rm job-alert python -m app run --dry-run   # recherche sans envoi

# 4. Lancer pour de bon (redémarre automatiquement avec le VPS)
docker compose up -d
docker compose logs -f
```

Le conteneur reste actif et déclenche la recherche chaque jour à `RUN_AT` (21:00, heure de Paris par défaut). Si le VPS est éteint à l'heure prévue, la recherche du jour est sautée ; les offres seront rattrapées le lendemain grâce à la fenêtre `MAX_DAYS_OLD` de 2 jours.

## Commandes

| Commande | Rôle |
|---|---|
| `python -m app schedule` | Mode par défaut du conteneur : tourne en continu, lance la recherche chaque jour |
| `python -m app run` | Lance une recherche et envoie le mail immédiatement |
| `python -m app run --dry-run` | Lance une recherche sans envoyer de mail : affiche le résultat et écrit `data/last_email.html` |
| `python -m app profile [--refresh]` | Affiche le profil, les requêtes et les mots-clés déduits du CV (`--refresh` force une nouvelle analyse) |
| `python -m app test-mail` | Envoie un mail de test |

Ajoute `-v` pour des logs détaillés (dont la consommation de tokens). Avec Docker : `docker compose run --rm job-alert python -m app <commande>`.

## Réglages utiles

Tous les réglages sont dans `.env` (voir `.env.example`, chaque variable y est commentée).

- **Résultats pas assez pertinents** : vérifie `python -m app profile`, puis ajuste `SEARCH_QUERIES`, `EXTRA_KEYWORDS`, `EXCLUDE_KEYWORDS`, ou décris tes critères dans `CANDIDATE_PREFERENCES` (ex. « CDI uniquement, salaire > 45 k€, pas de poste managérial »). Claude en tient compte dans la note.
- **Entreprises qui t'intéressent particulièrement** : `TARGET_COMPANIES=L'Oréal,LVMH,Decathlon`. Claude va chercher chaque jour sur leur site carrière, et leurs offres venant de toutes les sources sont prioritaires et marquées d'une ⭐ dans le mail.
- **Trop ou pas assez d'offres dans le mail** : `MIN_SCORE` et `MAX_RESULTS`.
- **Mise à jour du CV** : remplace `data/cv.pdf`. Il sera réanalysé automatiquement à la prochaine exécution.
- **Changer l'heure** : `RUN_AT=08:30`, puis `docker compose up -d` pour appliquer.
- **Après une modification du `.env`** : `docker compose up -d` (le conteneur est recréé).

## Coût

| Poste | Coût estimé |
|---|---|
| Analyse du CV | une seule fois, quelques centimes |
| Notation des offres, `CLAUDE_MODEL=claude-opus-5-5` (défaut) | 0,50 à 1 $ par jour |
| Notation des offres, `CLAUDE_MODEL=claude-haiku-5-5` | quelques centimes par jour (notation un peu moins fine) |
| Google Jobs (SerpApi) | gratuit jusqu'à 250 recherches par mois (6 par jour par défaut) |
| Sites carrière (recherche web Claude) | 10 à 20 centimes par entreprise et par jour : 1 centime par recherche, plus le texte des pages lues |

Ce sont des estimations : la consommation réelle est visible dans la console Anthropic et sur le tableau de bord SerpApi. Pour réduire le coût : baisser `PREFILTER_TOP_K`, `CAREER_SEARCHES_PER_COMPANY` ou le nombre d'entreprises cibles.

## Limites à connaître

- **LinkedIn et Indeed** n'ont pas d'API publique et interdisent le scraping. Adzuna agrège une partie des offres présentes sur ces sites.
- **Welcome to the Jungle** n'a pas d'API officielle : l'appli interroge l'index de recherche public de leur site. Si celui-ci change, cette source tombera en erreur (signalé en bas du mail) sans bloquer les autres.
- **Remotive** publie ses offres avec un délai et en petit nombre. Les sites 100 % télétravail, Google Jobs (qui ne trie pas par date) et les sites carrière sont donc interrogés sur 7 jours (`EXTENDED_MAX_DAYS_OLD`) au lieu de 2. Le dédoublonnage évite de recevoir deux fois la même offre. Les offres télétravail réservées aux résidents d'autres pays (ex. « USA only ») sont écartées.
- **Google Jobs** renvoie environ 10 offres par recherche. Avec l'offre gratuite de SerpApi, on ne demande pas les pages suivantes.
- **Sites carrière** : Claude ne voit que ce que la recherche web trouve. Les sites qui chargent leurs offres en JavaScript sont parfois mal couverts. Pour éviter tout lien inventé, une offre n'est gardée que si son lien apparaît réellement dans les pages trouvées.
- En cas d'échec complet d'une exécution, un mail d'alerte est envoyé (`NOTIFY_ERRORS`).

## Structure

```
app/
  __main__.py      commandes et planificateur
  pipeline.py      enchaînement complet d'une exécution
  candidate.py     lecture du CV et extraction du profil par Claude
  sources/         un fichier par source (sites d'offres, Google Jobs, sites carrière)
  prefilter.py     tri gratuit par mots-clés
  scorer.py        notation des offres par Claude
  storage.py       historique SQLite (data/jobs.sqlite3)
  mailer.py        composition et envoi du mail
  templates/       modèle HTML du mail
data/              CV, cache du profil, base SQLite (volume Docker)
```
