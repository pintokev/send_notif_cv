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
| Clé API Claude **ou** abonnement Claude (Pro/Max) | oui, l'un des deux | voir [Clé API ou abonnement Claude](#clé-api-ou-abonnement-claude) |
| Compte SMTP | oui | Gmail (mot de passe d'application : https://myaccount.google.com/apppasswords), OVH, Brevo… |
| Identifiants France Travail | conseillé | https://francetravail.io → « Créer une application » → ajouter l'API **Offres d'emploi v2** |
| Clé Adzuna | conseillé | https://developer.adzuna.com → inscription gratuite |
| Clé SerpApi (Google Jobs) | conseillé | https://serpapi.com → inscription gratuite (250 recherches/mois) |

Welcome to the Jungle, Remotive, Remote OK et Jobicy ne demandent aucune clé. La recherche sur les sites carrière utilise Claude (clé API ou abonnement) et s'active dès que `TARGET_COMPANIES` est rempli. Une source sans identifiants est simplement ignorée.

## Clé API ou abonnement Claude

L'appli a besoin de Claude pour trois tâches : analyser le CV, noter les offres et chercher sur les sites carrière. Deux façons de s'y connecter :

| | Clé API | Abonnement Claude (Pro / Max) |
|---|---|---|
| Ce qu'il faut | Une clé sur https://platform.claude.com → API Keys | Un abonnement Claude, et Claude Code sur une machine pour générer un jeton |
| Dans le `.env` | `ANTHROPIC_API_KEY=sk-ant-…` | `ANTHROPIC_API_KEY=` (vide) et `CLAUDE_CODE_OAUTH_TOKEN=…` |
| Facturation | À l'usage (voir [Coût](#coût)) | Incluse dans l'abonnement, dans la limite de ses quotas |
| Comment l'appli appelle Claude | Directement via l'API Anthropic | Via Claude Code, installé dans l'image Docker, en mode non interactif |

**Choix automatique** (`CLAUDE_BACKEND=auto`, par défaut) : si `ANTHROPIC_API_KEY` est renseignée, l'appli passe par l'API ; sinon, par l'abonnement. Pour forcer un mode : `CLAUDE_BACKEND=api` ou `CLAUDE_BACKEND=subscription`. Au début de chaque exécution, les logs indiquent le mode utilisé (`Claude : via l'API…` ou `Claude : via ton abonnement…`).

### Utiliser son abonnement

1. Sur une machine où Claude Code est installé et connecté à ton abonnement (ton ordinateur, par exemple), lance :
   ```bash
   claude setup-token
   ```
   Suis les instructions : la commande affiche un jeton longue durée lié à ton abonnement.
2. Dans le `.env` du serveur :
   ```env
   ANTHROPIC_API_KEY=
   CLAUDE_CODE_OAUTH_TOKEN=le_jeton_affiché
   ```
3. Vérifie avec `docker compose run --rm principal python -m app run --dry-run`. Les logs doivent afficher `Claude : via ton abonnement (Claude Code)`.

Ce jeton donne accès à ton abonnement : garde-le secret, comme une clé API. Il reste dans le `.env`, qui n'est jamais envoyé sur GitHub.

**À savoir avant de choisir l'abonnement :**
- **Quotas partagés** : les exécutions consomment les mêmes limites d'utilisation que ton usage personnel de Claude (Claude Code, claude.ai). Une exécution complète (CV, environ 60 offres notées, recherche sur les sites carrière) peut en prendre une part notable, surtout avec Opus et beaucoup d'entreprises cibles. Si la limite est atteinte, l'exécution échoue et un mail d'alerte est envoyé (`NOTIFY_ERRORS`).
- **Conditions d'utilisation** : un abonnement est personnel. L'utiliser pour automatiser ta propre veille relève de ton usage. Pour traiter les CV d'autres personnes (voir [Plusieurs CV](#plusieurs-cv)), vérifie que les conditions d'Anthropic le permettent, ou utilise une clé API.
- **Recherche sur les sites carrière** : en mode abonnement, Claude Code n'a pas de plafond strict par appel. La limite `CAREER_SEARCHES_PER_COMPANY` lui est donnée comme consigne, et il la respecte en général.
- **Image Docker** : Claude Code est installé dans l'image (environ 420 Mo au total), même si tu utilises une clé API.

## Installation simple (recommandé)

Il faut seulement [Docker](https://docs.docker.com/engine/install/) sur un serveur Linux, ou [Docker Desktop](https://www.docker.com/products/docker-desktop/) sur un ordinateur Windows ou Mac, démarré. Récupère le projet (`git clone`, ou bouton « Code → Download ZIP » sur GitHub), puis :

| | Linux, macOS | Windows |
|---|---|---|
| Installer | `./installer.sh` | double-clic sur `installer.bat` |
| Lancer une recherche | `./lancer.sh` | double-clic sur `lancer.bat` |
| Ajouter une personne | `./ajouter_cv.sh` | double-clic sur `ajouter_cv.bat` |

**L'installeur** pose les questions une par une, avec les liens utiles :

1. connexion à Claude (abonnement ou clé API), envoi des mails (Gmail, OVH ou autre), sources d'offres facultatives. Il crée le `.env` ;
2. construit l'image Docker et envoie un mail de test. En cas d'échec, il propose de ressaisir les paramètres ;
3. crée le premier profil (« principal ») : CV, adresse qui reçoit les offres, ville, critères…
4. propose une première recherche, puis l'envoi automatique quotidien. Celui-ci est facultatif.

Relancé plus tard, il permet de modifier une partie du `.env` (l'ancienne version est gardée dans `.env.bak`) ou d'ajouter une personne.

**`lancer`** déclenche une recherche à la demande, sans attendre l'heure prévue : avec envoi du mail, ou en aperçu, sans envoi (le mail est alors enregistré dans `data/<profil>/last_email.html`, et ouvert dans le navigateur sous Windows et macOS). Il permet aussi d'envoyer un mail de test, de voir le profil déduit du CV, et d'activer l'envoi automatique quotidien à l'heure de ton choix, d'en changer l'heure ou de l'arrêter. Sans question : `./lancer.sh <profil> <action>`, avec l'action `envoi`, `apercu`, `test-mail`, `profil`, `activer [HH:MM]`, `heure HH:MM` ou `arreter`.

L'envoi automatique ne fonctionne que si la machine et Docker sont allumés à l'heure prévue. Sur un ordinateur personnel, lancer la recherche avec `lancer` quand tu le souhaites est souvent plus simple.

Sous Windows, les fichiers `.bat` exécutent `scripts/windows.ps1` (PowerShell, inclus dans Windows).

## Installation manuelle sur le VPS

```bash
# 1. Récupérer le projet
git clone git@github.com:pintokev/send_notif_cv.git
cd send_notif_cv

# 2. Réglages communs (clé API Claude ou jeton d'abonnement, SMTP, sources…)
cp .env.example .env
nano .env

# 3. Ton CV (service « principal » du docker-compose.yml)
mkdir -p data/principal
cp /chemin/vers/ton_cv.pdf data/principal/cv.pdf
sudo chown -R 1000:1000 data   # le conteneur tourne avec l'utilisateur 1000

# 4. Vérifier la configuration
docker compose build
docker compose run --rm principal python -m app test-mail       # mail de test
docker compose run --rm principal python -m app profile         # profil déduit du CV
docker compose run --rm principal python -m app run --dry-run   # recherche sans envoi

# 5. Lancer pour de bon (redémarre automatiquement avec le VPS)
docker compose up -d
docker compose logs -f
```

Le conteneur reste actif et déclenche la recherche chaque jour à `RUN_AT` (21:00, heure de Paris par défaut). Si le VPS est éteint à l'heure prévue, la recherche du jour est sautée ; les offres seront rattrapées le lendemain grâce à la fenêtre `MAX_DAYS_OLD` de 2 jours.

Pour que tout redémarre avec le VPS, Docker doit être lancé au démarrage (`sudo systemctl enable docker`). Utilise ensuite toujours `docker compose up -d` : après un `docker compose stop` ou `down`, le conteneur ne repart pas tout seul.

## Plusieurs CV

Chaque CV tourne dans son propre conteneur, avec son destinataire, ses réglages et son historique :

```
.env                    réglages communs (clés API, SMTP…)
profils/<nom>.env       réglages propres à un CV : ils écrasent ceux de .env
data/<nom>/cv.pdf       le CV, avec son historique et son cache
```

### Ajouter une personne avec le script (recommandé)

Depuis le dossier du projet, sur le serveur :

```bash
./ajouter_cv.sh
```

Le script pose les questions une par une : nom, chemin du CV (PDF), adresse mail, ville et rayon, télétravail, critères, mots exclus, entreprises cibles, sources à utiliser, heure d'envoi, score minimum, nombre d'offres. Il affiche ensuite un récapitulatif et, après confirmation :

1. copie le CV dans `data/<nom>/cv.pdf` et donne les droits au conteneur ;
2. crée `profils/<nom>.env`. Tous les réglages personnels y sont écrits, même vides, pour que la personne n'hérite jamais des critères d'une autre via le `.env` commun ;
3. déclare son conteneur `job-alert-<nom>` dans `docker-compose.override.yml`. Docker Compose lit ce fichier automatiquement en plus de `docker-compose.yml`, et il est ignoré par git : pas de conflit au `git pull`, et la liste des personnes reste privée ;
4. propose une première recherche (avec ou sans envoi du mail), puis l'envoi automatique quotidien, qui reste facultatif.

Pour les sources qui utilisent tes clés API (France Travail, Adzuna, Google Jobs), il demande si la personne doit les utiliser. Seules les sources dont la clé est dans le `.env` sont proposées. Le choix est écrit dans `SOURCES` de son profil : retire un nom de cette liste pour ne plus utiliser la source. Welcome to the Jungle et les sites télétravail sont gratuits et toujours interrogés. Les sites carrière ne le sont que si la personne a des entreprises cibles.

Il calcule aussi le nombre de recherches Google Jobs par jour pour rester dans le quota gratuit de SerpApi, partagé entre les personnes qui utilisent Google Jobs. Pense à reporter cette valeur dans leurs profils, comme il te l'indique à la fin.

Le CV doit d'abord être présent sur le serveur. Depuis ta machine : `scp cv.pdf user@ip-du-serveur:~/` (sans oublier les deux-points), puis indique `~/cv.pdf` au script.

Pour **modifier** une personne : `nano profils/<nom>.env`, puis `docker compose up -d <nom>`. Pour la **supprimer** : `docker compose rm -sf <nom>`, retire son bloc de `docker-compose.override.yml`, puis supprime `profils/<nom>.env` et `data/<nom>/`.

### Ajouter une personne à la main

1. Dans `docker-compose.yml`, décommente le bloc `deuxieme` et remplace `deuxieme` par le nom choisi (ex. `alice`) partout.
2. Crée ses réglages : `cp profils/exemple.env profils/alice.env`, puis renseigne au minimum `MAIL_TO`, et redéfinis (ou vide) les réglages personnels du `.env` : `CANDIDATE_PREFERENCES`, `TARGET_COMPANIES`, `LOCATION_CITY`, `EXCLUDE_KEYWORDS`.
3. Dépose son CV : `mkdir -p data/alice && cp cv_alice.pdf data/alice/cv.pdf && sudo chown -R 1000:1000 data`. Crée bien le dossier toi-même : sinon Docker le crée au nom de `root` et le conteneur ne pourra pas y écrire.
4. Vérifie avec `docker compose run --rm alice python -m app run --dry-run`, puis lance `docker compose up -d`.

Dans les commandes, remplace `principal` par le nom du profil visé. `docker compose up -d` et `docker compose logs -f` agissent sur tous les CV à la fois.

Le quota gratuit de SerpApi (250 recherches par mois) est partagé entre tous les CV qui utilisent Google Jobs : avec 2 CV, mets `GOOGLEJOBS_SEARCHES_PER_RUN=4` dans chaque profil. Pour qu'un CV n'utilise pas une source, retire-la de `SOURCES` dans son profil (ex. `SOURCES=francetravail,adzuna,wttj,careersites,remotive,remoteok,jobicy` sans Google Jobs). Les profils (`profils/*.env`) ne sont pas envoyés sur GitHub, sauf `profils/exemple.env`.

## Commandes

| Commande | Rôle |
|---|---|
| `python -m app schedule` | Mode par défaut du conteneur : tourne en continu, lance la recherche chaque jour |
| `python -m app run` | Lance une recherche et envoie le mail immédiatement |
| `python -m app run --dry-run` | Lance une recherche sans envoyer de mail : affiche le résultat et écrit `data/<profil>/last_email.html` |
| `python -m app profile [--refresh]` | Affiche le profil, les requêtes et les mots-clés déduits du CV (`--refresh` force une nouvelle analyse) |
| `python -m app test-mail` | Envoie un mail de test |

Ajoute `-v` pour des logs détaillés (dont la consommation de tokens). Avec Docker : `docker compose run --rm principal python -m app <commande>` (remplace `principal` par le nom du profil).

## Réglages utiles

Les réglages sont dans `.env` (voir `.env.example`, chaque variable y est commentée), éventuellement redéfinis par CV dans `profils/<nom>.env`.

- **Résultats pas assez pertinents** : vérifie `python -m app profile`, puis ajuste `SEARCH_QUERIES`, `EXTRA_KEYWORDS`, `EXCLUDE_KEYWORDS`, ou décris tes critères dans `CANDIDATE_PREFERENCES` (ex. « CDI uniquement, salaire > 45 k€, pas de poste managérial »). Claude en tient compte dans la note.
- **Entreprises qui t'intéressent particulièrement** : `TARGET_COMPANIES=L'Oréal,LVMH,Decathlon`. Claude va chercher chaque jour sur leur site carrière, et leurs offres venant de toutes les sources sont prioritaires et marquées d'une ⭐ dans le mail.
- **Trop ou pas assez d'offres dans le mail** : `MIN_SCORE` et `MAX_RESULTS`.
- **Mise à jour du CV** : remplace `data/<profil>/cv.pdf`. Il sera réanalysé automatiquement à la prochaine exécution.
- **Changer l'heure** : `RUN_AT=08:30`, puis `docker compose up -d` pour appliquer.
- **Après une modification du `.env` ou d'un profil** : `docker compose up -d` (les conteneurs concernés sont recréés).

## Coût

| Poste | Coût estimé |
|---|---|
| **Avec un abonnement Claude** | **rien de plus que l'abonnement** : tout ce qui concerne Claude ci-dessous est inclus, dans la limite des quotas |
| Analyse du CV | une seule fois, quelques centimes |
| Notation des offres, `CLAUDE_MODEL=claude-opus-5-5` (défaut) | 0,50 à 1 $ par jour |
| Notation des offres, `CLAUDE_MODEL=claude-haiku-5-5` | quelques centimes par jour (notation un peu moins fine) |
| Google Jobs (SerpApi) | gratuit jusqu'à 250 recherches par mois (6 par jour par défaut) |
| Sites carrière (recherche web Claude) | 10 à 20 centimes par entreprise et par jour : 1 centime par recherche, plus le texte des pages lues |

Les lignes Claude ci-dessus concernent le mode clé API. Ce sont des estimations : la consommation réelle est visible dans la console Anthropic et sur le tableau de bord SerpApi. Pour réduire le coût : baisser `PREFILTER_TOP_K`, `CAREER_SEARCHES_PER_COMPANY` ou le nombre d'entreprises cibles.

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
  llm.py           appels à Claude : via l'API (clé API), ou aiguillage vers claude_code.py
  claude_code.py   appels à Claude via Claude Code (abonnement)
  sources/         un fichier par source (sites d'offres, Google Jobs, sites carrière)
  prefilter.py     tri gratuit par mots-clés
  scorer.py        notation des offres par Claude
  storage.py       historique SQLite (data/<profil>/jobs.sqlite3)
  mailer.py        composition et envoi du mail
  templates/       modèle HTML du mail
installer.sh       installation guidée : .env, mail de test, premier profil
lancer.sh          recherche à la demande, activation de l'envoi automatique
ajouter_cv.sh      ajout interactif d'une personne (CV + mail)
*.bat              mêmes scripts pour Windows (double-clic), via scripts/windows.ps1
scripts/           fonctions communes aux scripts .sh, version Windows
profils/           réglages propres à chaque CV (exemple.env fourni)
data/<profil>/     CV, cache du profil, base SQLite (volume Docker)
```
