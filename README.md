# Veille d'offres d'emploi à partir d'un CV

Tu donnes un CV (PDF) et une adresse mail. L'appli :

1. **analyse le CV** avec Claude pour en déduire le profil, les intitulés de poste à chercher et les mots-clés (une seule fois, tant que le CV ne change pas) ;
2. **collecte les offres récentes** autour de la ville choisie et/ou en télétravail sur :
   - France Travail, Adzuna, Welcome to the Jungle ;
   - **Google Jobs**, qui regroupe LinkedIn, Indeed, APEC, HelloWork et des sites carrière ;
   - **les sites carrière des entreprises cibles**, explorés par Claude avec la recherche web ;
   - Remotive, Remote OK et Jobicy (100 % télétravail) ;
3. **élimine les doublons** (même offre sur plusieurs sites, offres déjà vues) ;
4. **préfiltre par mots-clés** (gratuit) pour garder les offres les plus prometteuses ;
5. **fait noter ces offres par Claude** de 0 à 100, avec une phrase d'explication ;
6. **envoie un mail** avec les meilleures nouvelles offres.

La recherche se lance à la demande, ou automatiquement chaque jour à l'heure choisie. Plusieurs personnes peuvent être suivies, chacune avec son CV, son adresse et ses critères.

## Sommaire

- [Démarrage rapide](#démarrage-rapide)
- [Les scripts](#les-scripts) : [installer](#installer--la-mise-en-place), [ajouter_cv](#ajouter_cv--ajouter-une-personne), [lancer](#lancer--lutilisation-au-quotidien)
- [L'envoi automatique](#lenvoi-automatique)
- [Mettre à jour l'appli](#mettre-à-jour-lappli)
- [Connexion à Claude : abonnement ou clé API](#connexion-à-claude--abonnement-ou-clé-api)
- [Les sources d'offres](#les-sources-doffres)
- [Réglages](#réglages)
- [Coût et quotas](#coût-et-quotas)
- [Pour aller plus loin](#pour-aller-plus-loin) : installation manuelle, commandes, structure
- [Limites à connaître](#limites-à-connaître)

## Démarrage rapide

**Ce qu'il faut :**

| Quoi | Obligatoire | Où l'obtenir |
|---|---|---|
| Docker | oui | Serveur Linux : https://docs.docker.com/engine/install/ · Windows ou Mac : [Docker Desktop](https://www.docker.com/products/docker-desktop/), lancé |
| Abonnement Claude (Pro/Max) **ou** clé API Claude | oui, l'un des deux | voir [Connexion à Claude](#connexion-à-claude--abonnement-ou-clé-api) |
| Une adresse mail pour envoyer les offres | oui | Gmail (avec un mot de passe d'application), OVH, ou tout compte SMTP |
| Clés France Travail, Adzuna, SerpApi | non, mais conseillées | gratuites, voir [Les sources d'offres](#les-sources-doffres) |

Python n'est pas nécessaire : tout tourne dans Docker.

**Trois étapes :**

1. Récupère le projet : `git clone git@github.com:pintokev/send_notif_cv.git`, ou sur GitHub « Code → Download ZIP », puis décompresse.
2. Lance l'installation et réponds aux questions :
   - Linux ou Mac, dans un terminal ouvert dans le dossier du projet : `./installer.sh`
   - Windows : double-clic sur `installer.bat`
3. Ensuite, pour une recherche quand tu veux, ou pour activer l'envoi automatique : `./lancer.sh` ou double-clic sur `lancer.bat`.

## Les scripts

Trois scripts, en deux versions qui font exactement la même chose :

| Script | Linux, macOS | Windows | Sert à |
|---|---|---|---|
| **installer** | `./installer.sh` | `installer.bat` | la mise en place, une seule fois (et modifier les réglages communs plus tard) |
| **ajouter_cv** | `./ajouter_cv.sh` | `ajouter_cv.bat` | ajouter une personne |
| **lancer** | `./lancer.sh` | `lancer.bat` | tout le reste : recherches, envoi automatique, modification et suppression d'un profil |

- **Linux, macOS** : ouvre un terminal dans le dossier du projet et tape la commande.
- **Windows** : double-clique sur le fichier `.bat`. La fenêtre reste ouverte à la fin pour que tu puisses lire le résultat. Les `.bat` exécutent `scripts/windows.ps1`, avec PowerShell, inclus dans Windows.

**Pour répondre aux questions :**
- **Entrée** accepte la valeur proposée entre crochets, par exemple `[21:15]`.
- `[O/n]` : Entrée vaut oui. `[o/N]` : Entrée vaut non.
- Mots de passe, jetons et clés : la saisie reste **invisible**, c'est normal. Colle avec Ctrl+Maj+V dans un terminal Linux, ou clic droit sous Windows.
- Pour un fichier (le CV), tu peux **glisser le fichier dans la fenêtre** au lieu de taper son chemin.

Si Docker n'est pas installé ou pas démarré, les scripts s'arrêtent tout de suite avec un message qui indique quoi faire, sans rien modifier.

### installer : la mise en place

À lancer une fois au début. Il pose les questions dans cet ordre :

1. **Connexion à Claude** : abonnement Pro/Max (il explique comment obtenir le jeton) ou clé API. Avec une clé API, il demande aussi le modèle : Opus (meilleur) ou Haiku (moins cher).
2. **Envoi des mails** : Gmail, OVH ou autre serveur SMTP, puis l'adresse et le mot de passe. Pour Gmail, il explique comment créer le mot de passe d'application.
3. **Sources d'offres facultatives** : identifiants France Travail, Adzuna et SerpApi. Entrée pour en passer une.

Il écrit ces réponses dans le fichier `.env`. Si tu abandonnes en cours de route (Ctrl+C), aucun fichier à moitié rempli ne reste. Ensuite :

4. il construit l'image Docker (quelques minutes la première fois) ;
5. il envoie un **mail de test**. Si l'envoi échoue, il propose de ressaisir les paramètres du mail ;
6. il crée le **premier profil**, nommé « principal », avec les mêmes questions que [ajouter_cv](#ajouter_cv--ajouter-une-personne).

**Relancé plus tard**, il demande partie par partie si tu veux modifier Claude, le mail ou les sources. Entrée garde la valeur actuelle, et l'ancienne version du `.env` est gardée dans `.env.bak`. Il propose aussi d'ajouter une personne.

### ajouter_cv : ajouter une personne

Il pose les questions une par une :

| Question | Remarque |
|---|---|
| Nom court | minuscules, chiffres et tirets (ex. `alice`) ; sert à désigner la personne dans `lancer` |
| CV (PDF) | chemin du fichier, ou fichier glissé dans la fenêtre |
| Adresse qui reçoit les offres | plusieurs possibles, séparées par des virgules |
| Ville et rayon | vide = toute la France |
| Télétravail | inclure ou non les offres 100 % télétravail |
| Critères | en langage naturel, pris en compte par Claude dans la note (ex. « CDI uniquement, pas de management ») |
| Mots à exclure | offres ignorées si leur intitulé contient un de ces mots (par défaut : stage, alternance) |
| Entreprises cibles | Claude cherche sur leur site carrière, et leurs offres sont prioritaires (⭐ dans le mail) |
| Sources | France Travail, Adzuna, Google Jobs : proposées seulement si leur clé est dans le `.env` |
| Heure du mail | heure d'envoi quotidienne |
| Heure de la recherche | si elle doit avoir lieu plus tôt que le mail, par exemple la nuit ; « non » = au moment du mail |
| Score minimum, nombre d'offres max | ce qui figure dans le mail |
| Recherches Google Jobs par jour | voir [le quota SerpApi](#le-quota-serpapi-google-jobs) |

Il affiche un récapitulatif puis, après confirmation :

1. copie le CV dans `data/<nom>/cv.pdf` ;
2. crée les réglages de la personne dans `profils/<nom>.env` ;
3. déclare son conteneur Docker (`job-alert-<nom>`) dans `docker-compose.override.yml`. Ce fichier est lu automatiquement par Docker Compose et ignoré par git : pas de conflit au `git pull`, et la liste des personnes reste privée ;
4. propose une **première recherche**, avec ou sans envoi du mail ;
5. propose d'**activer l'envoi automatique** quotidien. C'est facultatif.

Si une étape échoue, tout ce qui a été créé est annulé.

**Sur un serveur**, le CV doit d'abord y être copié. Depuis ton ordinateur : `scp cv.pdf utilisateur@ip-du-serveur:~/` (sans oublier les deux-points), puis indique `~/cv.pdf` au script.

### lancer : l'utilisation au quotidien

`./lancer.sh` (ou `lancer.bat`) demande d'abord **pour qui** (s'il y a plusieurs profils), puis **quoi faire** :

| Option du menu | Ce qu'elle fait |
|---|---|
| Lancer une recherche et envoyer le mail | recherche complète tout de suite (2 à 5 minutes), puis envoi du mail |
| Lancer une recherche sans envoyer de mail (aperçu) | même recherche, mais le mail est seulement enregistré dans `data/<nom>/last_email.html` (ouvert dans le navigateur sous Windows et Mac). Les offres trouvées partiront avec le prochain mail |
| Envoyer un mail de test | vérifie que l'envoi des mails fonctionne |
| Voir le profil déduit du CV | métier, niveau, intitulés de poste cherchés et mots-clés déduits par Claude |
| Activer l'envoi automatique quotidien | demande l'heure du mail et l'heure de la recherche, puis lance l'envoi chaque jour |
| Changer les heures de l'envoi automatique | (quand il est actif) modifie l'heure du mail et/ou de la recherche |
| Arrêter l'envoi automatique quotidien | (quand il est actif) les recherches à la demande restent possibles |
| Modifier le profil | mêmes questions que [ajouter_cv](#ajouter_cv--ajouter-une-personne), avec les valeurs actuelles proposées : Entrée garde, `-` vide (par exemple pour retirer les entreprises cibles). Pour le CV, Entrée garde l'actuel ; un nouveau fichier le remplace et sera réanalysé |
| Supprimer ce profil | après confirmation, efface son conteneur, ses réglages, son CV et l'historique de ses offres |

**Tous les profils** : s'il y a plusieurs personnes, le choix « Tous les profils » exécute l'action pour chacune, l'une après l'autre, puis affiche un récapitulatif. Un échec n'arrête pas les suivantes, et un profil sans CV est ignoré. Pour l'envoi automatique, chacun garde ses heures.

**Sans menu**, en une commande (utile pour les habitués, ou pour un planificateur externe) :

```bash
./lancer.sh <nom> <action>     # Windows : lancer.bat <nom> <action>, dans un terminal ouvert dans le dossier
```

| Action | Exemple |
|---|---|
| `envoi` | `./lancer.sh alice envoi` |
| `apercu` | `./lancer.sh tous apercu` |
| `test-mail` | `./lancer.sh alice test-mail` |
| `profil` | `./lancer.sh alice profil` |
| `activer [mail [recherche]]` | `./lancer.sh alice activer 08:00 03:00` |
| `heure mail [recherche]` | `./lancer.sh alice heure 08:00 non` (« non » = plus de recherche séparée) |
| `arreter` | `./lancer.sh tous arreter` |
| `modifier` | `./lancer.sh alice modifier` |
| `supprimer` | `./lancer.sh alice supprimer` |

Avec `heure` ou `activer`, si seule l'heure du mail est donnée, l'heure de recherche ne change pas.

## L'envoi automatique

Une fois activé (depuis `lancer`, ou à la fin de `installer` / `ajouter_cv`), le conteneur de la personne tourne en arrière-plan et lance chaque jour :

- **soit tout à la même heure** : recherche puis mail, à l'heure du mail (`RUN_AT`) ;
- **soit en deux temps** : la recherche à l'heure de recherche (`SEARCH_AT`, par exemple 03:00), puis le mail à l'heure du mail (par exemple 08:00). Entre les deux, les offres notées attendent dans l'historique.

Le mode en deux temps est utile avec un abonnement Claude : la recherche consomme le quota la nuit, quand tu ne l'utilises pas. Avec plusieurs personnes, on peut aussi répartir les recherches sur des créneaux espacés.

**Bon à savoir :**
- **La machine et Docker doivent être allumés aux heures prévues.** Sur un serveur, lance une fois `sudo systemctl enable docker` : après un redémarrage, les envois automatiques repartent tout seuls. Sous Windows ou Mac, coche « Start Docker Desktop when you sign in » dans les réglages de Docker Desktop. Si la machine est éteinte, la recherche du jour est sautée ; les offres sont en général rattrapées le lendemain.
- **Une offre n'est jamais envoyée deux fois**, même si tu lances aussi des recherches à la main. Les bonnes offres qui n'ont pas eu de place dans le mail (limite du nombre d'offres) restent candidates pendant 7 jours.
- **Si la recherche de la nuit échoue**, un mail d'alerte arrive à l'heure du mail. Si elle n'a pas eu lieu (machine éteinte), le mail contient les offres en attente des jours précédents et le précise.
- **Mail sans offre** : par défaut, un mail « Aucune nouvelle offre pertinente » est envoyé. Pour ne rien recevoir dans ce cas, mets `SEND_IF_EMPTY=false` dans le profil.
- Sur un ordinateur personnel souvent éteint, lancer la recherche avec `lancer` quand tu le souhaites est souvent plus simple.

## Mettre à jour l'appli

```bash
git pull
./lancer.sh      # ou n'importe quel script
```

Si le code a changé, le script reconstruit l'image Docker (quelques secondes à quelques minutes) et relance les envois automatiques actifs avec la nouvelle version. Si rien n'a changé, il ne perd qu'environ une seconde.

## Connexion à Claude : abonnement ou clé API

L'appli utilise Claude pour trois tâches : analyser le CV, noter les offres et chercher sur les sites carrière. L'installeur te demande laquelle des deux connexions utiliser :

| | Abonnement Claude (Pro / Max) | Clé API |
|---|---|---|
| Ce qu'il faut | un abonnement, et Claude Code sur une machine pour générer un jeton (une seule fois) | une clé sur https://platform.claude.com → API Keys |
| Dans le `.env` | `CLAUDE_CODE_OAUTH_TOKEN=…` et `ANTHROPIC_API_KEY=` vide | `ANTHROPIC_API_KEY=sk-ant-…` |
| Facturation | incluse dans l'abonnement, dans la limite de ses quotas | à l'usage (voir [Coût et quotas](#coût-et-quotas)) |

**Obtenir le jeton d'abonnement** : sur une machine où [Claude Code](https://claude.com/claude-code) est installé et connecté à ton compte, tape `claude setup-token` dans un terminal, puis colle le jeton affiché dans l'installeur. Pas de Claude Code ? Installe-le juste pour cette étape (`curl -fsSL https://claude.ai/install.sh | bash` sous Linux et Mac, `irm https://claude.ai/install.ps1 | iex` dans PowerShell sous Windows). Le jeton se génère une seule fois et sert sur toutes tes machines. Garde-le secret, comme un mot de passe : il reste dans le `.env`, qui n'est jamais envoyé sur GitHub.

**Choix automatique** (`CLAUDE_BACKEND=auto`, par défaut) : si `ANTHROPIC_API_KEY` est renseignée, l'appli passe par l'API, sinon par l'abonnement. Les logs de chaque recherche indiquent le mode utilisé.

**À savoir avec un abonnement :**
- **Quotas partagés** : les recherches consomment les mêmes limites que ton usage personnel de Claude (claude.ai, Claude Code). Voir [Coût et quotas](#coût-et-quotas).
- **Usage personnel** : un abonnement est personnel. L'utiliser pour ta propre veille relève de ton usage. Pour traiter les CV d'autres personnes, vérifie que les conditions d'Anthropic le permettent, ou utilise une clé API.
- Claude Code est installé dans l'image Docker (environ 420 Mo au total), même si tu utilises une clé API.

## Les sources d'offres

| Source | Clé | Comment l'obtenir |
|---|---|---|
| Welcome to the Jungle | aucune | — |
| Remotive, Remote OK, Jobicy (100 % télétravail) | aucune | — |
| Sites carrière des entreprises cibles | aucune (utilise Claude) | s'active dès que la personne a des entreprises cibles |
| France Travail | identifiant + clé secrète | https://francetravail.io → « Créer une application » → ajouter l'API **Offres d'emploi v2** |
| Adzuna | App ID + App Key | https://developer.adzuna.com → inscription gratuite |
| Google Jobs (LinkedIn, Indeed, APEC, HelloWork…) | clé SerpApi | https://serpapi.com → inscription gratuite, 250 recherches par mois |

Une source sans clé est simplement ignorée. Pour ajouter une clé plus tard : relance `installer`. Chaque personne peut ensuite utiliser ou non les sources à clé (question dans `ajouter_cv`, ou « Modifier le profil » dans `lancer`).

**Comment se fait la recherche** : Claude déduit du CV jusqu'à 5 intitulés de poste (`MAX_QUERIES`), par exemple « Data analyst » ou « Analyste BI ». Chaque source est interrogée avec ces intitulés, autour de la ville et/ou en télétravail. Les offres des 2 derniers jours sont gardées (7 jours pour les sources à faible volume ou aux dates imprécises). Pour voir les intitulés déduits : `lancer`, puis « Voir le profil déduit du CV ». Pour les imposer : `SEARCH_QUERIES=` dans le profil.

### Le quota SerpApi (Google Jobs)

Une recherche SerpApi correspond à une recherche Google (« Data analyst Lyon », « Data analyst télétravail »…) et renvoie environ 10 offres. Chaque profil en fait plusieurs par jour (`GOOGLEJOBS_SEARCHES_PER_RUN`, 6 au maximum par défaut), et l'offre gratuite en permet **250 par mois, partagées entre toutes les personnes qui utilisent Google Jobs**.

`ajouter_cv` (et « Modifier le profil ») s'en occupe :
- il **propose** un nombre de recherches par jour calculé pour rester dans le quota (250 ÷ 31 jours ÷ nombre de personnes : 6 pour une personne, 4 pour deux, 2 pour trois) ;
- tu peux **choisir** un autre nombre ;
- il affiche le **total mensuel** de toutes les personnes. S'il dépasse 250, il propose de **réduire les autres profils** qui sont au-dessus de leur part (ceux qui sont en dessous ne sont jamais augmentés) ; leur envoi automatique est alors relancé. Si tu refuses, il prévient que Google Jobs s'arrêtera avant la fin du mois.

L'appli vérifie aussi le solde SerpApi avant chaque recherche et n'en lance jamais plus qu'il n'en reste. Supprimer une personne ne redonne pas automatiquement de recherches aux autres : modifie leur profil pour remonter leur valeur.

## Réglages

Les réglages sont dans deux fichiers :

```
.env                  réglages communs : connexion à Claude, envoi des mails, clés des sources…
profils/<nom>.env     réglages de chaque personne : ils remplacent ceux du .env
data/<nom>/           CV, historique des offres, cache du profil
```

Le plus simple est de passer par les scripts : `installer` pour le `.env`, « Modifier le profil » dans `lancer` pour une personne. Pour modifier un fichier à la main, applique ensuite le changement avec `docker compose up -d <nom>`, ou en réactivant l'envoi automatique dans `lancer`.

Réglages utiles (tous commentés dans `.env.example`) :

- **Résultats pas assez pertinents** : vérifie le profil déduit du CV, puis ajuste `SEARCH_QUERIES`, `EXTRA_KEYWORDS`, `EXCLUDE_KEYWORDS`, ou précise les critères (`CANDIDATE_PREFERENCES`, ex. « CDI uniquement, salaire > 45 k€, pas de poste managérial »).
- **Trop ou pas assez d'offres dans le mail** : `MIN_SCORE` (score minimum) et `MAX_RESULTS` (nombre maximum).
- **Modèle de Claude** : `CLAUDE_MODEL=claude-opus-5-5` (défaut, meilleure notation) ou `claude-haiku-5-5` (plus rapide, beaucoup moins cher et moins gourmand en quota, notation un peu moins fine).
- **Nombre d'offres notées par Claude** : `PREFILTER_TOP_K` (60 par défaut). Le baisser réduit le coût et la consommation de quota.

Un réglage invalide (heure mal écrite, nombre qui n'en est pas un…) ne bloque pas l'appli : il est remplacé par sa valeur par défaut et signalé dans les logs, et par mail au démarrage de l'envoi automatique.

## Coût et quotas

**Avec un abonnement Claude**, rien n'est facturé en plus, mais chaque recherche consomme ton quota. Ordre de grandeur pour une recherche : environ 100 000 tokens sans entreprises cibles, 200 000 à 350 000 avec 5 entreprises cibles. Pour mesurer ton cas : note ta consommation (claude.ai → Paramètres → Utilisation), lance un aperçu avec `lancer`, sans utiliser Claude entre-temps, puis compare. La première recherche coûte un peu plus, car elle inclut l'analyse du CV. Chaque personne compte séparément : deux profils, c'est environ deux fois plus.

**Avec une clé API**, estimations par profil :

| Poste | Coût estimé |
|---|---|
| Analyse du CV | une seule fois, quelques centimes |
| Notation des offres avec Opus (défaut) | 0,50 à 1 $ par recherche |
| Notation des offres avec Haiku | quelques centimes par recherche |
| Sites carrière (recherche web) | 10 à 20 centimes par entreprise cible et par recherche |
| Google Jobs (SerpApi) | gratuit jusqu'à 250 recherches par mois |

La consommation réelle est visible dans la console Anthropic et sur le tableau de bord SerpApi. Pour réduire le coût ou le quota consommé, par ordre d'efficacité : passer à Haiku, baisser `PREFILTER_TOP_K`, avoir moins d'entreprises cibles (ou baisser `CAREER_SEARCHES_PER_COMPANY`).

Pour voir le détail des tokens consommés : `docker compose run --rm <nom> python -m app run --dry-run -v`.

## Pour aller plus loin

### Installation manuelle (sans les scripts)

```bash
# 1. Récupérer le projet
git clone git@github.com:pintokev/send_notif_cv.git
cd send_notif_cv

# 2. Réglages communs (connexion à Claude, mail, sources…)
cp .env.example .env
nano .env

# 3. Le CV du profil « principal » (déclaré dans docker-compose.yml)
mkdir -p data/principal
cp /chemin/vers/ton_cv.pdf data/principal/cv.pdf
sudo chown -R 1000:1000 data   # le conteneur tourne avec l'utilisateur 1000

# 4. Vérifier la configuration
docker compose build
docker compose run --rm principal python -m app test-mail       # mail de test
docker compose run --rm principal python -m app profile         # profil déduit du CV
docker compose run --rm principal python -m app run --dry-run   # recherche sans envoi

# 5. Activer l'envoi automatique
docker compose up -d
docker compose logs -f
```

Pour ajouter une personne à la main : déclare un service dans `docker-compose.override.yml` sur le modèle du bloc `deuxieme` commenté dans `docker-compose.yml`, crée `profils/<nom>.env` à partir de `profils/exemple.env` (au minimum `MAIL_TO`, et redéfinis ou vide les réglages personnels du `.env`), puis dépose son CV dans `data/<nom>/cv.pdf`. Crée le dossier toi-même, sinon Docker le crée au nom de `root` et le conteneur ne peut pas y écrire.

Pour supprimer une personne à la main : `docker compose rm -sf <nom>`, retire son bloc de `docker-compose.override.yml`, puis efface `profils/<nom>.env` et `data/<nom>/`.

Attention : `docker compose up -d` sans nom de profil active l'envoi automatique de **tous** les profils.

### Commandes de l'appli

À lancer dans le conteneur : `docker compose run --rm <nom> python -m app <commande>`.

| Commande | Rôle |
|---|---|
| `schedule` | mode par défaut du conteneur : tourne en continu, recherche et mail chaque jour |
| `run` | recherche puis envoi du mail, tout de suite |
| `run --dry-run` | recherche sans envoi : affiche le résultat et écrit `data/<nom>/last_email.html` |
| `search` | recherche sans envoi : les offres notées attendent le prochain mail |
| `send [--dry-run]` | envoie les offres déjà notées et pas encore envoyées |
| `profile [--refresh]` | affiche le profil déduit du CV (`--refresh` force une nouvelle analyse) |
| `test-mail` | envoie un mail de test |

Ajoute `-v` pour des logs détaillés, dont la consommation de tokens.

### Structure du projet

```
installer.sh / .bat    installation guidée : .env, mail de test, premier profil
ajouter_cv.sh / .bat   ajout d'une personne (et modification, via lancer)
lancer.sh / .bat       recherches à la demande, envoi automatique, modification et suppression
scripts/
  commun.sh            fonctions communes aux scripts .sh
  windows.ps1          version Windows des trois scripts, appelée par les .bat
app/
  __main__.py          commandes et planificateur
  pipeline.py          recherche (collecte, préfiltre, notation) et envoi du mail
  config.py            lecture des réglages
  candidate.py         lecture du CV et extraction du profil par Claude
  llm.py               appels à Claude : via l'API, ou aiguillage vers claude_code.py
  claude_code.py       appels à Claude via Claude Code (abonnement)
  sources/             un fichier par source d'offres
  prefilter.py         tri gratuit par mots-clés
  scorer.py            notation des offres par Claude
  storage.py           historique SQLite (data/<nom>/jobs.sqlite3)
  mailer.py            composition et envoi du mail
  templates/           modèle HTML du mail
profils/               réglages de chaque personne (exemple.env fourni)
data/<nom>/            CV, historique, cache du profil, dernier aperçu
```

## Limites à connaître

- **LinkedIn et Indeed** n'ont pas d'API publique et interdisent la collecte automatique. Google Jobs et Adzuna en reprennent une partie.
- **Welcome to the Jungle** n'a pas d'API officielle : l'appli interroge l'index de recherche public de leur site. S'il change, cette source tombera en erreur (signalé en bas du mail) sans bloquer les autres.
- **Remotive** publie peu d'offres, avec un délai. Les sites 100 % télétravail, Google Jobs (qui ne trie pas par date) et les sites carrière sont donc interrogés sur 7 jours (`EXTENDED_MAX_DAYS_OLD`) au lieu de 2. Les offres télétravail réservées aux résidents d'autres pays (ex. « USA only ») sont écartées.
- **Google Jobs** renvoie environ 10 offres par recherche ; avec l'offre gratuite de SerpApi, les pages suivantes ne sont pas demandées.
- **Sites carrière** : Claude ne voit que ce que la recherche web trouve. Les sites qui chargent leurs offres en JavaScript sont parfois mal couverts. Une offre n'est gardée que si son lien apparaît réellement dans les pages trouvées, pour éviter tout lien inventé.
- **Abonnement Claude** : si la limite d'utilisation est atteinte pendant une recherche, elle échoue et un mail d'alerte est envoyé (`NOTIFY_ERRORS`).
