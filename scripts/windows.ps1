# Version Windows de installer.sh, ajouter_cv.sh et lancer.sh, appelée par installer.bat,
# ajouter_cv.bat et lancer.bat :
#   installer  crée le .env, envoie un mail de test et crée le premier profil ;
#   ajouter    ajoute une personne (CV + adresse mail) ;
#   lancer     lance une recherche à la demande, active ou arrête l'envoi automatique,
#              modifie ou supprime un profil.
# Fichier enregistré en UTF-8 avec BOM : sans BOM, Windows PowerShell 5.1 lit mal les accents.

param(
    [Parameter(Mandatory = $true)][ValidateSet('installer', 'ajouter', 'lancer')][string]$Commande,
    [string]$Nom = '',
    [string]$Action = '',
    [string]$Heure = '',
    [string]$Recherche = ''
)

$ErrorActionPreference = 'Stop'
$Racine = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $Racine
[Environment]::CurrentDirectory = $Racine  # chemins relatifs des appels .NET ([IO.File]…)
$Utf8 = New-Object System.Text.UTF8Encoding($false)  # fichiers sans BOM, lisibles par Docker Compose
try { [Console]::OutputEncoding = $Utf8 } catch { }   # accents dans la sortie de Docker

$Override = 'docker-compose.override.yml'
$MailRegex = '^[^@\s,]+@[^@\s,]+\.[^@\s,]+$'
$HeureRegex = '^([01][0-9]|2[0-3]):[0-5][0-9]$'
$MailsRegex = '^[^@\s,]+@[^@\s,]+\.[^@\s,]+(,\s*[^@\s,]+@[^@\s,]+\.[^@\s,]+)*$'

# ─── Affichage et questions ────────────────────────────────────────────

function Info([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Ok([string]$Message) { Write-Host "[OK] $Message" -ForegroundColor Green }
function Attention([string]$Message) { Write-Host "[!] $Message" -ForegroundColor Yellow }
function Erreur([string]$Message) { Write-Host "[X] $Message" -ForegroundColor Red; exit 1 }

# Demander "Question" [défaut] → réponse
function Demander([string]$Question, [string]$Defaut = '') {
    if ($Defaut) {
        $r = Read-Host "$Question [$Defaut]"
        if (-not $r) { $r = $Defaut }
    } else {
        $r = Read-Host $Question
    }
    return "$r".Trim()
}

# Confirmer "Question" o|n → $true si oui
function Confirmer([string]$Question, [string]$Defaut = 'n') {
    $choix = if ($Defaut -eq 'o') { 'O/n' } else { 'o/N' }
    $r = Read-Host "$Question [$choix]"
    if (-not $r) { $r = $Defaut }
    return ($r -match '^[oOyY]')
}

# Choisir "Question" @('choix 1', 'choix 2'…) → numéro choisi (1 par défaut)
function Choisir([string]$Question, [string[]]$Choix) {
    Write-Host $Question
    for ($i = 0; $i -lt $Choix.Count; $i++) { Write-Host ('  {0}) {1}' -f ($i + 1), $Choix[$i]) }
    while ($true) {
        $r = Read-Host 'Ton choix [1]'
        if (-not $r) { $r = '1' }
        if ($r -match '^[1-9][0-9]*$' -and [int]$r -le $Choix.Count) { return [int]$r }
        Write-Host "  → un nombre entre 1 et $($Choix.Count)."
    }
}

function Lire-Secret([string]$Question) {
    $secret = Read-Host $Question -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
    try { return ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)).Trim() }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

# ─── Fichiers .env ─────────────────────────────────────────────────────

# Écrit un fichier en UTF-8 sans BOM, avec des fins de ligne Unix
function Ecrire-Texte([string]$Chemin, [string]$Texte) {
    [IO.File]::WriteAllText($Chemin, ($Texte -replace "`r`n", "`n"), $Utf8)
}

# Lire-Reglage fichier CLE → valeur de CLE dans ce fichier (.env ou profil), sans guillemets
function Lire-Reglage([string]$Fichier, [string]$Cle) {
    if (-not (Test-Path -LiteralPath $Fichier)) { return '' }
    $valeur = ''
    foreach ($ligne in [IO.File]::ReadAllLines($Fichier, $Utf8)) {
        if ($ligne.StartsWith("$Cle=")) { $valeur = $ligne.Substring($Cle.Length + 1).Trim() }
    }
    if ($valeur.Length -ge 2 -and ($valeur[0] -eq "'" -or $valeur[0] -eq '"') -and $valeur[-1] -eq $valeur[0]) {
        $valeur = $valeur.Substring(1, $valeur.Length - 2)
    }
    return $valeur
}

# Ecrire-Reglage fichier CLE valeur : remplace la ligne CLE= du fichier (ou l'ajoute ; crée le fichier).
# Les guillemets simples empêchent Docker Compose d'interpréter les « $ » d'un mot de passe.
function Ecrire-Reglage([string]$Fichier, [string]$Cle, [string]$Valeur) {
    if ($Valeur -and -not $Valeur.Contains("'")) { $Valeur = "'$Valeur'" }
    $lignes = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $Fichier) { $lignes.AddRange([IO.File]::ReadAllLines($Fichier, $Utf8)) }
    $fait = $false
    for ($i = 0; $i -lt $lignes.Count; $i++) {
        if (-not $fait -and $lignes[$i].StartsWith("$Cle=")) { $lignes[$i] = "$Cle=$Valeur"; $fait = $true }
    }
    if (-not $fait) { $lignes.Add("$Cle=$Valeur") }
    Ecrire-Texte $Fichier (($lignes -join "`n") + "`n")
}

# ─── Docker ────────────────────────────────────────────────────────────

# Exécute docker en affichant sa sortie → $true si la commande a réussi
function Lancer-Docker {
    & docker @args | Out-Host
    return ($LASTEXITCODE -eq 0)
}

# Exécute docker sans rien afficher → @{ Code; Lignes }
function Capturer-Docker {
    $ancien = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'  # les messages de docker sur stderr ne sont pas des erreurs PowerShell
    try {
        $sortie = & docker @args 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $ancien
    }
    return [pscustomobject]@{ Code = $code; Lignes = @($sortie | Where-Object { $_ }) }
}

function Verifier-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Erreur "Docker Desktop n'est pas installé : https://www.docker.com/products/docker-desktop/ puis relance ce script."
    }
    if ((Capturer-Docker info).Code -ne 0) {
        Erreur "Docker ne répond pas : lance Docker Desktop, attends qu'il indique « Engine running », puis relance ce script."
    }
    if ((Capturer-Docker compose version).Code -ne 0) {
        Erreur "Docker Compose est introuvable : mets à jour Docker Desktop."
    }
}

function Services-Compose {
    $r = Capturer-Docker compose config --services
    if ($r.Code -ne 0) { $r.Lignes | Out-Host; Erreur 'docker compose config a échoué : vérifie docker-compose.yml.' }
    return @($r.Lignes)
}

# Construit l'image Docker, ou la reconstruit si le code a changé depuis (après une mise à jour).
# Le fichier témoin .image-construite date la dernière construction. Les envois automatiques
# actifs passent ensuite à la nouvelle version.
function Construire-Image {
    $existe = (Capturer-Docker image inspect job-alert).Code -eq 0
    if ($existe -and (Test-Path -LiteralPath '.image-construite')) {
        $construite = (Get-Item -LiteralPath '.image-construite').LastWriteTime
        $modifies = @(Get-ChildItem -LiteralPath 'app', 'Dockerfile', 'requirements.txt' -Recurse -File |
            Where-Object { $_.LastWriteTime -gt $construite })
        if ($modifies.Count -eq 0) { return }
    }
    if ($existe) { Info "Le code a changé : mise à jour de l'image Docker…" }
    else { Info "Construction de l'image Docker (quelques minutes la première fois)…" }
    if (-not (Lancer-Docker compose build)) { Erreur "La construction de l'image Docker a échoué (voir le message ci-dessus)." }
    Ecrire-Texte '.image-construite' ''
    $actifs = @((Capturer-Docker compose ps --status running --services).Lignes)
    if ($actifs.Count -gt 0) {
        # Recrée les conteneurs actifs avec la nouvelle image
        if (Lancer-Docker compose up -d @actifs) { Ok "Envoi automatique relancé avec la nouvelle version : $($actifs -join ' ')" }
    }
}

# Recherche immédiate, sans attendre l'heure prévue → $true si elle a réussi
function Lancer-Recherche([string]$Nom, [switch]$Apercu) {
    Write-Host "Recherche en cours pour « $Nom » (2 à 5 minutes)…"
    $options = if ($Apercu) { @('--dry-run') } else { @() }
    if (Lancer-Docker compose run --rm -T $Nom python -m app run @options) {
        if ($Apercu) {
            Ok "Aucun mail envoyé. Aperçu du mail : data\$Nom\last_email.html"
            Invoke-Item -LiteralPath "data\$Nom\last_email.html" -ErrorAction SilentlyContinue
        } else {
            Ok 'Recherche terminée, mail envoyé.'
        }
        return $true
    }
    Attention "La recherche a échoué (voir le message ci-dessus). Corrige profils\$Nom.env ou le .env, puis relance lancer.bat."
    return $false
}

# ─── installer : configuration du .env ─────────────────────────────────

$script:FichierEnv = '.env'          # fichier modifié par Ecrire-Env
$script:NouvelleInstall = $true      # sinon, Entrée garde la valeur actuelle du .env

# Ecrire-Env CLE valeur : remplace la ligne CLE= du fichier en cours de configuration (ou l'ajoute)
function Ecrire-Env([string]$Cle, [string]$Valeur) { Ecrire-Reglage $script:FichierEnv $Cle $Valeur }

# Demander-Valeur "Question" CLE [-Secret] [-Obligatoire]. Entrée garde la valeur actuelle du .env.
function Demander-Valeur([string]$Question, [string]$Cle, [switch]$Secret, [switch]$Obligatoire) {
    $actuel = if ($script:NouvelleInstall) { '' } else { Lire-Reglage $script:FichierEnv $Cle }
    if ($actuel) { $Question += ' (Entrée = garder la valeur actuelle)' }
    while ($true) {
        $r = if ($Secret) { Lire-Secret $Question } else { Demander $Question }
        if (-not $r) { $r = $actuel }
        if ($r -or -not $Obligatoire) { return $r }
        Write-Host '  → cette valeur est obligatoire.'
    }
}

function Configurer-Claude {
    Write-Host ''
    Info '─── Connexion à Claude ───'
    Write-Host "Claude lit le CV et note chaque offre. Deux façons de s'y connecter :"
    $choix = Choisir 'Laquelle choisis-tu ?' @(
        "Mon abonnement Claude Pro ou Max (inclus dans l'abonnement)",
        "Une clé API Anthropic (facturée à l'usage)")
    if ($choix -eq 1) {
        Write-Host ''
        Write-Host 'Il te faut un jeton lié à ton abonnement. Sur un ordinateur où Claude Code est installé'
        Write-Host '(https://claude.com/claude-code) et connecté à ton compte, tape dans un terminal :'
        Write-Host '    claude setup-token'
        Write-Host 'puis copie le jeton affiché (il commence par sk-ant-oat). Garde-le secret.'
        $jeton = Demander-Valeur 'Colle le jeton ici (clic droit pour coller, la saisie reste invisible)' CLAUDE_CODE_OAUTH_TOKEN -Secret -Obligatoire
        Ecrire-Env CLAUDE_CODE_OAUTH_TOKEN $jeton
        Ecrire-Env ANTHROPIC_API_KEY ''
    } else {
        Write-Host ''
        Write-Host 'Crée une clé sur https://platform.claude.com → API Keys (elle commence par sk-ant-api).'
        $cle = Demander-Valeur 'Colle la clé ici (clic droit pour coller, la saisie reste invisible)' ANTHROPIC_API_KEY -Secret -Obligatoire
        Ecrire-Env ANTHROPIC_API_KEY $cle
        Ecrire-Env CLAUDE_CODE_OAUTH_TOKEN ''
        Write-Host ''
        $modele = Choisir 'Modèle utilisé pour noter les offres :' @(
            'Opus : la meilleure notation (environ 0,50 à 1 $ par jour)',
            'Haiku : notation un peu moins fine (quelques centimes par jour)')
        Ecrire-Env CLAUDE_MODEL $(if ($modele -eq 1) { 'claude-opus-5-5' } else { 'claude-haiku-5-5' })
    }
    Ecrire-Env CLAUDE_BACKEND auto
}

function Configurer-Mail {
    Write-Host ''
    Info '─── Envoi des mails ───'
    Write-Host 'Les offres sont envoyées depuis une adresse mail à toi.'
    $choix = Choisir 'Quelle messagerie utilises-tu pour envoyer ?' @('Gmail', 'OVH', 'Autre (je connais ses paramètres SMTP)')
    switch ($choix) {
        1 { $hote = 'smtp.gmail.com'; $port = '587'; $securite = 'starttls' }
        2 { $hote = 'ssl0.ovh.net'; $port = '465'; $securite = 'ssl' }
        3 {
            $hote = Demander-Valeur 'Serveur SMTP (ex. smtp.exemple.fr)' SMTP_HOST -Obligatoire
            $s = Choisir 'Sécurité de la connexion :' @('STARTTLS (port 587 en général)', 'SSL/TLS (port 465 en général)', 'Aucune')
            $securite = @('starttls', 'ssl', 'none')[$s - 1]
            $port = @('587', '465', '25')[$s - 1]
            do { $port = Demander 'Port' $port } until ($port -match '^[0-9]+$')
        }
    }
    do {
        $adresse = Demander-Valeur "Adresse mail d'envoi" SMTP_USER -Obligatoire
        if ($adresse -notmatch $MailRegex) { Write-Host '  → adresse invalide.' }
    } until ($adresse -match $MailRegex)

    if ($hote -eq 'smtp.gmail.com') {
        Write-Host ''
        Write-Host "Gmail n'accepte pas ton mot de passe habituel : il faut un « mot de passe d'application »."
        Write-Host "  1. Active la validation en deux étapes sur ton compte Google, si ce n'est pas déjà fait."
        Write-Host '  2. Va sur https://myaccount.google.com/apppasswords, crée un mot de passe (nom : « offres »).'
        Write-Host '  3. Copie les 16 lettres affichées.'
    }
    $motDePasse = Demander-Valeur 'Mot de passe (clic droit pour coller, la saisie reste invisible)' SMTP_PASSWORD -Secret -Obligatoire
    if ($hote -eq 'smtp.gmail.com') { $motDePasse = $motDePasse -replace ' ', '' }

    Ecrire-Env SMTP_HOST $hote
    Ecrire-Env SMTP_PORT $port
    Ecrire-Env SMTP_SECURITY $securite
    Ecrire-Env SMTP_USER $adresse
    Ecrire-Env SMTP_PASSWORD $motDePasse
    Ecrire-Env MAIL_FROM $adresse
    # Destinataire par défaut (mail de test, alertes) ; chaque profil indique le sien
    Ecrire-Env MAIL_TO $adresse
}

function Configurer-Sources {
    Write-Host ''
    Info "─── Sources d'offres (facultatif) ───"
    Write-Host "Sans rien configurer, l'appli cherche déjà sur Welcome to the Jungle, Remotive, Remote OK et Jobicy."
    Write-Host 'Les trois sources ci-dessous sont gratuites et apportent beaucoup plus d''offres.'
    Write-Host "Laisse vide pour en ignorer une : tu pourras l'ajouter plus tard en relançant installer.bat."
    Write-Host ''
    Write-Host "• France Travail : https://francetravail.io → « Créer une application » → ajouter l'API « Offres d'emploi v2 »"
    Ecrire-Env FRANCETRAVAIL_CLIENT_ID (Demander-Valeur '  Identifiant client France Travail' FRANCETRAVAIL_CLIENT_ID)
    Ecrire-Env FRANCETRAVAIL_CLIENT_SECRET (Demander-Valeur '  Clé secrète France Travail' FRANCETRAVAIL_CLIENT_SECRET)
    Write-Host '• Adzuna : https://developer.adzuna.com → inscription gratuite'
    Ecrire-Env ADZUNA_APP_ID (Demander-Valeur '  App ID Adzuna' ADZUNA_APP_ID)
    Ecrire-Env ADZUNA_APP_KEY (Demander-Valeur '  App Key Adzuna' ADZUNA_APP_KEY)
    Write-Host '• Google Jobs (LinkedIn, Indeed, APEC, HelloWork…) : https://serpapi.com → inscription gratuite, 250 recherches par mois'
    Ecrire-Env SERPAPI_API_KEY (Demander-Valeur '  Clé SerpApi' SERPAPI_API_KEY)
}

function Installer {
    Write-Host ''
    Info "═══ Installation de la veille d'offres d'emploi ═══"
    Verifier-Docker
    Ok 'Docker est prêt.'

    # 1. Fichier .env
    if (Test-Path -LiteralPath '.env') {
        $script:NouvelleInstall = $false
        Write-Host ''
        Write-Host 'Le fichier .env existe déjà. Réponds « o » pour modifier une partie, Entrée pour la garder.'
        $avant = [IO.File]::ReadAllText('.env', $Utf8)
        if (Confirmer 'Modifier la connexion à Claude ?') { Configurer-Claude }
        if (Confirmer "Modifier l'envoi des mails ?") { Configurer-Mail }
        if (Confirmer "Modifier les sources d'offres ?") { Configurer-Sources }
        if ([IO.File]::ReadAllText('.env', $Utf8) -ne $avant) {
            Ecrire-Texte '.env.bak' $avant
            Ok 'Fichier .env mis à jour (ancienne version : .env.bak).'
        }
    } else {
        # Écrit dans un fichier temporaire : un .env à moitié rempli ne doit pas rester en cas d'abandon
        $script:FichierEnv = '.env.nouveau'
        try {
            Ecrire-Texte $script:FichierEnv ([IO.File]::ReadAllText('.env.example', $Utf8))
            Configurer-Claude
            Configurer-Mail
            Configurer-Sources
            Move-Item -LiteralPath $script:FichierEnv -Destination '.env'
        } finally {
            Remove-Item -LiteralPath '.env.nouveau' -ErrorAction SilentlyContinue
        }
        $script:FichierEnv = '.env'
        $script:NouvelleInstall = $false
        Ok 'Fichier .env créé.'
    }

    # 2. Image Docker et mail de test
    Write-Host ''
    Construire-Image
    New-Item -ItemType Directory -Force -Path 'data\principal' | Out-Null
    $destinataire = Lire-Reglage 'profils\principal.env' MAIL_TO
    if (-not $destinataire) { $destinataire = Lire-Reglage '.env' MAIL_TO }
    Write-Host ''
    if (Confirmer "Envoyer un mail de test à $destinataire pour vérifier l'envoi ?" 'o') {
        while ($true) {
            if (Lancer-Docker compose run --rm -T principal python -m app test-mail) {
                Ok 'Mail de test envoyé : vérifie ta boîte de réception (et les spams).'
                break
            }
            Attention "L'envoi a échoué (voir le message ci-dessus) : souvent un mot de passe incorrect."
            if (-not (Confirmer "Ressaisir les paramètres d'envoi des mails ?" 'o')) { break }
            Configurer-Mail
        }
    }

    # 3. Premier profil
    if (Test-Path -LiteralPath 'data\principal\cv.pdf') {
        Write-Host ''
        Ok 'Le premier profil (« principal ») est déjà configuré.'
        if (Confirmer 'Ajouter une autre personne ?') { Ajouter-Personne }
    } else {
        Ajouter-Personne -Principal
    }

    Write-Host ''
    if (Test-Path -LiteralPath 'data\principal\cv.pdf') { Ok 'Installation terminée.' }
    else { Attention "Le premier profil n'a pas été créé : relance installer.bat quand tu veux." }
    Write-Host ''
    Write-Host 'Pour la suite (double-clic dans le dossier du projet) :'
    Write-Host "  lancer.bat       lancer une recherche quand tu veux, activer ou arrêter l'envoi automatique"
    Write-Host '  ajouter_cv.bat   ajouter une autre personne'
    Write-Host "  installer.bat    modifier la connexion à Claude, l'envoi des mails ou les sources"
}

# ─── ajouter : nouvelle personne ───────────────────────────────────────

# Valeur-Google nom → recherches Google Jobs par jour de cette personne (6 par défaut)
function Valeur-Google([string]$Nom) {
    $valeur = Reglage-De $Nom GOOGLEJOBS_SEARCHES_PER_RUN
    if ($valeur -match '^[0-9]+$') { return [int]$valeur }
    return 6
}

# Utilise-Google nom → $true si cette personne interroge Google Jobs
# (SOURCES de son profil, sinon celui du .env ; vide = toutes les sources)
function Utilise-Google([string]$Nom) {
    $valeur = (Reglage-De $Nom SOURCES) -replace '\s', ''
    return (-not $valeur -or ",$valeur," -like '*,googlejobs,*')
}

function Ajouter-Personne([switch]$Principal, [string]$Modifier = '') {
    if (-not (Test-Path -LiteralPath '.env')) { Erreur "Fichier .env introuvable : lance d'abord installer.bat." }
    $existants = @(Services-Compose)

    Write-Host ''
    if ($Modifier) {
        $nom = $Modifier
        if ($existants -notcontains $nom) { Erreur "Profil « $nom » inconnu. Profils existants : $($existants -join ' ')" }
        if (-not (Test-Path -LiteralPath "data\$nom\cv.pdf")) { Erreur "Pas de CV pour « $nom » : dépose-le dans data\$nom\cv.pdf." }
        Info "═══ Modification du profil « $nom » ═══"
        Write-Host 'Entrée garde la valeur actuelle (entre crochets), « - » la vide.'
    } elseif ($Principal) {
        Info '═══ Création du premier profil ═══'
        $nom = 'principal'
        if (Test-Path -LiteralPath "data\$nom\cv.pdf") {
            Erreur "Le profil « $nom » a déjà un CV. Pour le modifier : lancer.bat $nom. Pour ajouter une personne : ajouter_cv.bat"
        }
        if ((Test-Path -LiteralPath "profils\$nom.env") -and -not (Confirmer "profils\$nom.env existe déjà. Le remplacer ?")) {
            Write-Host "Annulé, rien n'a été modifié."
            return
        }
    } else {
        Info "═══ Ajout d'une nouvelle personne ═══"
        Write-Host "Personnes déjà configurées : $($existants -join ' ')"
        Write-Host ''
        while ($true) {
            $nom = Demander 'Nom court de la personne (minuscules, chiffres, tirets ; ex. alice)'
            if ($nom -cnotmatch '^[a-z0-9][a-z0-9-]*$') {
                Write-Host '  → uniquement des minuscules sans accent, des chiffres et des tirets.'
            } elseif ($nom -eq 'tous') {
                Write-Host '  → « tous » est réservé (lancer.bat tous agit sur tous les profils).'
            } elseif ($existants -contains $nom) {
                Write-Host "  → « $nom » existe déjà."
            } elseif ((Test-Path -LiteralPath "profils\$nom.env") -or (Test-Path -LiteralPath "data\$nom")) {
                Write-Host "  → profils\$nom.env ou data\$nom existe déjà : choisis un autre nom ou supprime-les."
            } else { break }
        }
    }

    # Valeurs proposées : celles du profil pour une modification, sinon les valeurs par défaut
    $d = @{ mail = ''; ville = ''; rayon = ''; teletravail = 'o'; preferences = ''; exclusions = 'stage,alternance'
            entreprises = ''; sources = ''; heure = ''; recherche = ''; score = ''; max = '' }
    if ($Modifier) {
        $d.mail = Reglage-De $nom MAIL_TO
        $d.ville = Reglage-De $nom LOCATION_CITY
        $d.rayon = Reglage-De $nom LOCATION_RADIUS_KM
        # Même lecture que l'appli (app/config.py) : vide = oui, sinon oui seulement pour 1/true/yes/oui/on
        $distance = Reglage-De $nom INCLUDE_REMOTE
        if ($distance -and $distance -notmatch '^(1|true|yes|oui|on)$') { $d.teletravail = 'n' }
        $d.preferences = Reglage-De $nom CANDIDATE_PREFERENCES
        $d.exclusions = Reglage-De $nom EXCLUDE_KEYWORDS
        $d.entreprises = Reglage-De $nom TARGET_COMPANIES
        $d.sources = (Reglage-De $nom SOURCES) -replace '\s', ''
        $d.heure = Reglage-De $nom RUN_AT
        if (-not $d.heure) { $d.heure = '21:00' }  # RUN_AT vide : l'appli envoie à 21:00
        $d.recherche = Reglage-De $nom SEARCH_AT
        $d.score = Reglage-De $nom MIN_SCORE
        $d.max = Reglage-De $nom MAX_RESULTS
    }
    if (-not $d.rayon) { $d.rayon = '30' }
    if (-not $d.heure) { $d.heure = '21:15' }
    if (-not $d.score) { $d.score = '60' }
    if (-not $d.max) { $d.max = '15' }
    # Demander-Texte "Question" [valeur proposée] → réponse ; « - » vide la valeur
    function Demander-Texte([string]$Question, [string]$Defaut = '') {
        $r = Demander $Question $Defaut
        if ($r -eq '-') { return '' }
        return $r
    }

    # CV
    while ($true) {
        if ($Modifier) {
            $cv = (Demander "Nouveau CV (PDF) : glisse le fichier dans cette fenêtre (Entrée = garder l'actuel)").Trim('"', "'")
            if (-not $cv) { break }
        } else {
            $cv = (Demander 'Chemin du CV (PDF) : glisse le fichier dans cette fenêtre puis appuie sur Entrée').Trim('"', "'")
        }
        if (-not $cv -or -not (Test-Path -LiteralPath $cv -PathType Leaf)) { Write-Host "  → fichier introuvable : $cv"; continue }
        $cv = (Resolve-Path -LiteralPath $cv).Path
        $flux = [IO.File]::OpenRead($cv)
        try { $debut = New-Object byte[] 4; $lus = $flux.Read($debut, 0, 4) } finally { $flux.Dispose() }
        if ($lus -eq 4 -and [Text.Encoding]::ASCII.GetString($debut) -eq '%PDF') { break }
        Write-Host "  → ce fichier n'est pas un PDF."
    }

    # Mail
    do {
        $mailTo = Demander 'Adresse mail qui recevra les offres (plusieurs : séparées par des virgules)' $d.mail
        if ($mailTo -notmatch $MailsRegex) { Write-Host '  → adresse invalide.' }
    } until ($mailTo -match $MailsRegex)

    # Recherche
    Write-Host ''
    Info 'Recherche (Entrée = valeur proposée, « - » = vide)'
    $ville = Demander-Texte 'Ville autour de laquelle chercher (vide = toute la France)' $d.ville
    $rayon = $d.rayon
    if ($ville) { do { $rayon = Demander 'Rayon de recherche en km' $d.rayon } until ($rayon -match '^[0-9]+$') }
    $teletravail = if (Confirmer 'Inclure les offres 100 % télétravail ?' $d.teletravail) { 'true' } else { 'false' }
    $preferences = Demander-Texte 'Critères en langage naturel (ex. CDI uniquement, pas de management ; vide = aucun)' $d.preferences
    $exclusions = Demander-Texte 'Mots à exclure des intitulés, séparés par des virgules' $d.exclusions
    $entreprises = Demander-Texte 'Entreprises cibles, séparées par des virgules (vide = aucune)' $d.entreprises

    # Sources à clé : proposées seulement si leur clé est dans le .env. Les autres sources gardent
    # leur état actuel (toutes pour un nouveau profil) : une source sans clé reste dans la liste,
    # ignorée tant que la clé manque, pour s'activer dès qu'on l'ajoute. WTTJ et les sites
    # télétravail sont gratuits ; les sites carrière ne servent que s'il y a des entreprises cibles.
    $questions = @{
        francetravail = @('FRANCETRAVAIL_CLIENT_ID', 'Chercher sur France Travail ?')
        adzuna        = @('ADZUNA_APP_ID', 'Chercher sur Adzuna ?')
        googlejobs    = @('SERPAPI_API_KEY', 'Chercher sur Google Jobs (LinkedIn, Indeed, APEC… ; quota SerpApi partagé entre les personnes) ?')
    }
    $aCle = @($questions.Keys | Where-Object { Lire-Reglage '.env' $questions[$_][0] })
    if ($aCle.Count -gt 0) { Write-Host ''; Info "Sources d'offres utilisant tes clés API" }
    $choisies = @()
    foreach ($source in @('francetravail', 'adzuna', 'wttj', 'googlejobs', 'careersites', 'remotive', 'remoteok', 'jobicy')) {
        $utilisee = (-not $d.sources) -or (",$($d.sources)," -like "*,$source,*")
        if ($aCle -contains $source) {
            if (Confirmer $questions[$source][1] $(if ($utilisee) { 'o' } else { 'n' })) { $choisies += $source }
        } elseif ($utilisee) {
            $choisies += $source
        }
    }
    $sources = $choisies -join ','

    # Envoi
    Write-Host ''
    Info 'Envoi du mail'
    do { $heure = Demander "Heure d'envoi quotidienne (HH:MM, heure de Paris)" $d.heure } until ($heure -match $HeureRegex)
    Write-Host "La recherche peut avoir lieu plus tôt que le mail, par exemple la nuit : les offres notées attendent l'heure du mail."
    while ($true) {
        $heureRecherche = Demander 'Heure de la recherche (HH:MM, ex. 03:00 ; « non » = au moment du mail)' $(if ($d.recherche) { $d.recherche } else { 'non' })
        if ($heureRecherche -eq 'non' -or $heureRecherche -eq '-' -or $heureRecherche -match $HeureRegex) { break }
        Write-Host '  → format attendu : HH:MM (ex. 03:00), ou « non ».'
    }
    if ($heureRecherche -eq 'non' -or $heureRecherche -eq '-' -or $heureRecherche -eq $heure) { $heureRecherche = '' }
    $horaire = if ($heureRecherche) { "recherche à $heureRecherche, mail à $heure" } else { "à $heure" }
    do { $score = Demander "Score minimum (0-100) pour qu'une offre figure dans le mail" $d.score } until ($score -match '^[0-9]+$' -and [int]$score -le 100)
    do { $maxOffres = Demander "Nombre maximum d'offres par mail" $d.max } until ($maxOffres -match '^[1-9][0-9]*$')

    # Quota SerpApi gratuit (250 recherches/mois) partagé entre les personnes qui utilisent Google Jobs.
    # Seuls les profils avec un CV comptent (« principal » peut exister sans être utilisé).
    $quota = 250
    $google = $choisies -contains 'googlejobs'
    $autresGoogle = @($existants | Where-Object { $_ -ne $nom -and (Test-Path -LiteralPath "data\$_\cv.pdf") -and (Utilise-Google $_) })
    $sommeAutres = 0
    foreach ($autre in $autresGoogle) { $sommeAutres += Valeur-Google $autre }
    $nbGoogle = $autresGoogle.Count + 1
    $conseil = [int][Math]::Max(1, [Math]::Min(6, [Math]::Floor($quota / (31 * $nbGoogle))))
    $recherchesGoogle = $conseil
    $reequilibrage = 0   # nouvelle valeur pour les autres personnes, si elles doivent être réduites
    $totalGoogle = 0
    if ($google) {
        Write-Host ''
        Write-Host "Google Jobs : $quota recherches gratuites par mois, partagées entre les $nbGoogle personnes qui l'utilisent."
        Write-Host "Conseillé : $conseil recherches par jour chacune (plus de recherches = plus d'offres)."
        $defaut = if ($Modifier) { Valeur-Google $nom } else { $conseil }
        do { $r = Demander "Recherches Google Jobs par jour pour $nom" "$defaut" } until ($r -match '^[1-9][0-9]*$')
        $recherchesGoogle = [int]$r
        $totalGoogle = ($sommeAutres + $recherchesGoogle) * 31
        if ($totalGoogle -gt $quota -and $autresGoogle.Count -gt 0) {
            $reduit = [int][Math]::Max(1, [Math]::Floor(($quota - $recherchesGoogle * 31) / (31 * $autresGoogle.Count)))
            # Seules les personnes au-dessus de cette valeur sont réduites (jamais augmentées)
            $aReduire = @($autresGoogle | Where-Object { (Valeur-Google $_) -gt $reduit })
            $sommeReduite = 0
            foreach ($autre in $autresGoogle) { $sommeReduite += [Math]::Min($reduit, (Valeur-Google $autre)) }
            Attention "Au total : $totalGoogle recherches par mois pour toutes les personnes, au-delà des $quota gratuites."
            if ($aReduire.Count -gt 0 -and (Confirmer "Ramener $($aReduire -join ' ') à $reduit recherches par jour ?" 'o')) {
                $reequilibrage = $reduit
                $autresGoogle = $aReduire
                $totalGoogle = ($sommeReduite + $recherchesGoogle) * 31
            }
        }
        if ($totalGoogle -gt $quota) { Attention "Le quota sera dépassé : Google Jobs s'arrêtera avant la fin du mois, quand il sera épuisé." }
    }

    # Applique la réduction acceptée aux autres personnes, et relance leur envoi automatique s'il est actif
    function Appliquer-Reequilibrage {
        if ($reequilibrage -eq 0) { return }
        $actifs = @((Capturer-Docker compose ps --status running --services).Lignes)
        foreach ($autre in $autresGoogle) { Ecrire-Reglage "profils\$autre.env" GOOGLEJOBS_SEARCHES_PER_RUN "$reequilibrage" }
        Ok "Google Jobs : $reequilibrage recherches par jour pour $($autresGoogle -join ' ')"
        $relancer = @($autresGoogle | Where-Object { $actifs -contains $_ })
        if ($relancer.Count -gt 0) { Lancer-Docker compose up -d @relancer | Out-Null }
    }

    Write-Host ''
    Info '═══ Récapitulatif ═══'
    Write-Host "  Nom                : $nom"
    Write-Host "  CV                 : $(if ($cv) { "$cv → data\$nom\cv.pdf" } else { 'inchangé' })"
    Write-Host "  Mail               : $mailTo"
    Write-Host "  Ville / rayon      : $(if ($ville) { "$ville / $rayon km" } else { 'toute la France' })"
    Write-Host "  Télétravail        : $teletravail"
    Write-Host "  Critères           : $(if ($preferences) { $preferences } else { 'aucun' })"
    Write-Host "  Mots exclus        : $(if ($exclusions) { $exclusions } else { 'aucun' })"
    Write-Host "  Entreprises cibles : $(if ($entreprises) { $entreprises } else { 'aucune' })"
    Write-Host "  Envoi              : tous les jours $horaire, score ≥ $score, $maxOffres offres max"
    Write-Host "  Sources            : $sources"
    if ($google) {
        Write-Host "  Google Jobs        : $recherchesGoogle recherches par jour"
        if ($reequilibrage) { Write-Host "                       (et $reequilibrage pour $($autresGoogle -join ' ')) : $totalGoogle recherches par mois sur $quota" }
        else { Write-Host "                       (toutes personnes : $totalGoogle recherches par mois sur $quota)" }
    }
    Write-Host ''

    # Modification : mise à jour du profil existant
    if ($Modifier) {
        if (-not (Confirmer 'Enregistrer ces modifications ?' 'o')) { Write-Host "Annulé, rien n'a été modifié."; return }
        if ($cv) {
            Copy-Item -LiteralPath $cv -Destination "data\$nom\cv.pdf" -Force
            Ok 'Nouveau CV copié : il sera analysé à la prochaine recherche.'
        }
        $profil = "profils\$nom.env"
        $valeurs = [ordered]@{
            MAIL_TO = $mailTo; LOCATION_CITY = $ville; LOCATION_RADIUS_KM = $rayon; INCLUDE_REMOTE = $teletravail
            CANDIDATE_PREFERENCES = $preferences; EXCLUDE_KEYWORDS = $exclusions; TARGET_COMPANIES = $entreprises
            RUN_AT = $heure; SEARCH_AT = $heureRecherche; MIN_SCORE = $score; MAX_RESULTS = $maxOffres
            SOURCES = $sources
        }
        if ($google) { $valeurs.GOOGLEJOBS_SEARCHES_PER_RUN = "$recherchesGoogle" }
        foreach ($cle in $valeurs.Keys) { Ecrire-Reglage $profil $cle $valeurs[$cle] }
        Ok "Réglages enregistrés dans $profil"
        if (@((Capturer-Docker compose ps --status running --services).Lignes) -contains $nom) {
            # Recrée le conteneur avec les nouveaux réglages
            if (Lancer-Docker compose up -d $nom) { Ok "Envoi automatique relancé avec les nouveaux réglages (tous les jours, $horaire)." }
        }
        Appliquer-Reequilibrage
        return
    }

    if (-not (Confirmer 'Créer cette personne ?' 'o')) { Write-Host "Annulé, rien n'a été modifié."; return }

    # Création, annulée en cas d'erreur
    $crees = New-Object System.Collections.Generic.List[string]
    $sauvegardeOverride = $null
    try {
        # 1. CV (data\principal peut déjà exister : l'installation le crée pour le mail de test)
        if (Test-Path -LiteralPath "data\$nom") { $crees.Add("data\$nom\cv.pdf") } else { $crees.Add("data\$nom") }
        New-Item -ItemType Directory -Force -Path "data\$nom" | Out-Null
        Copy-Item -LiteralPath $cv -Destination "data\$nom\cv.pdf"
        Ok "CV copié dans data\$nom\cv.pdf"

        # 2. Profil : toutes les valeurs personnelles sont écrites, même vides,
        #    pour ne jamais hériter de celles d'une autre personne via le .env commun.
        New-Item -ItemType Directory -Force -Path 'profils' | Out-Null
        $crees.Add("profils\$nom.env")
        Ecrire-Texte "profils\$nom.env" @"
# Réglages de « $nom », créés par ajouter_cv.bat le $(Get-Date -Format 'dd/MM/yyyy').
# Ils écrasent ceux du .env commun. Après modification : docker compose up -d $nom

MAIL_TO=$mailTo

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
SEARCH_AT=$heureRecherche
MIN_SCORE=$score
MAX_RESULTS=$maxOffres

# Sources interrogées (retirer un nom pour ne plus l'utiliser)
SOURCES=$sources
# Recherches Google Jobs par jour (quota SerpApi gratuit de 250 par mois, partagé entre les personnes)
GOOGLEJOBS_SEARCHES_PER_RUN=$recherchesGoogle

"@
        Ok "Réglages créés dans profils\$nom.env"

        # 3. Conteneur, dans docker-compose.override.yml (« principal » est déjà dans docker-compose.yml)
        if (-not $Principal) {
            if (Test-Path -LiteralPath $Override) {
                $sauvegardeOverride = [IO.File]::ReadAllText($Override, $Utf8)
                $texte = $sauvegardeOverride
            } else {
                $crees.Add($Override)
                $texte = "# Personnes ajoutées avec ajouter_cv. Fichier lu automatiquement par`n# Docker Compose en plus de docker-compose.yml, et ignoré par git.`n`nservices:`n"
            }
            $texte += @"

  ${nom}:
    image: job-alert
    container_name: job-alert-$nom
    restart: unless-stopped
    env_file:
      - path: .env
      - path: profils/$nom.env
    volumes:
      - ./data/${nom}:/data
    logging:
      driver: json-file
      options:
        max-size: "5m"
        max-file: "3"

"@
            Ecrire-Texte $Override $texte
            # Vérifie que Docker Compose accepte la nouvelle configuration (affiche son erreur sinon)
            $r = Capturer-Docker compose config --services
            if ($r.Code -ne 0 -or $r.Lignes -notcontains $nom) {
                $r.Lignes | Out-Host
                throw "Docker Compose refuse la nouvelle configuration."
            }
            Ok "Conteneur « job-alert-$nom » déclaré dans $Override"
        }
    } catch {
        Write-Host "[X] Échec : $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '    Annulation des modifications…' -ForegroundColor Red
        foreach ($f in $crees) { Remove-Item -LiteralPath $f -Recurse -Force -ErrorAction SilentlyContinue }
        if ($null -ne $sauvegardeOverride) { Ecrire-Texte $Override $sauvegardeOverride }
        exit 1
    }
    Appliquer-Reequilibrage

    # Première recherche et envoi automatique
    Write-Host ''
    Construire-Image
    Write-Host ''
    $choix = Choisir 'Lancer une première recherche maintenant (2 à 5 minutes) ?' @(
        'Oui, sans envoyer de mail : juste pour vérifier (aperçu)',
        "Oui, et envoyer le mail à $mailTo",
        'Non, plus tard')
    if ($choix -eq 1) { Lancer-Recherche $nom -Apercu | Out-Null }
    elseif ($choix -eq 2) { Lancer-Recherche $nom | Out-Null }

    Write-Host ''
    Write-Host "Envoi automatique : la recherche peut tourner toute seule tous les jours ($horaire),"
    Write-Host "tant que cet ordinateur et Docker Desktop restent allumés. Sinon, lance-la quand tu veux avec lancer.bat."
    if (Confirmer "Activer l'envoi automatique quotidien pour $nom ?" 'o') {
        if (Lancer-Docker compose up -d $nom) { Ok "« $nom » recevra ses offres tous les jours ($horaire)." }
    } else {
        Write-Host "Pour l'activer plus tard : lancer.bat"
    }
}

# ─── lancer : recherche à la demande ───────────────────────────────────

# Reglage-De nom CLE → valeur du profil, sinon du .env (comme Docker Compose)
function Reglage-De([string]$Nom, [string]$Cle) {
    $profil = "profils\$Nom.env"
    if ((Test-Path -LiteralPath $profil) -and (Select-String -LiteralPath $profil -Pattern "^$Cle=" -Quiet)) {
        return (Lire-Reglage $profil $Cle)
    }
    return (Lire-Reglage '.env' $Cle)
}

# Supprimer-Profil nom : retire son conteneur, son bloc dans docker-compose.override.yml,
# ses réglages, son CV et l'historique de ses offres
function Supprimer-Profil([string]$Nom) {
    Write-Host ''
    Attention "Suppression de « $Nom » : ses réglages, son CV et l'historique de ses offres seront effacés."
    if (-not (Confirmer "Supprimer définitivement « $Nom » ?")) { Write-Host "Annulé, rien n'a été supprimé."; return }
    Capturer-Docker compose rm -sf $Nom | Out-Null  # arrête et retire son conteneur
    if (Test-Path -LiteralPath $Override) {
        $avant = [IO.File]::ReadAllText($Override, $Utf8)
        $lignes = $avant -split "\r?\n"
        if ($lignes -contains "  ${Nom}:") {
            # Retire son bloc, de la ligne « <nom>: » jusqu'au service suivant
            $service = '^  [^ #][^:]*:\s*$'
            $saute = $false
            $gardees = foreach ($ligne in $lignes) {
                if ($ligne -eq "  ${Nom}:") { $saute = $true; continue }
                if ($saute -and $ligne -match $service) { $saute = $false }
                if (-not $saute) { $ligne }
            }
            if (@($gardees | Where-Object { $_ -match $service }).Count -eq 0) {
                Remove-Item -LiteralPath $Override  # plus aucune personne ajoutée
            } else {
                Ecrire-Texte $Override ($gardees -join "`n")
            }
            if ((Capturer-Docker compose config --services).Code -ne 0) {
                Ecrire-Texte $Override $avant
                Erreur "Docker Compose refuse la configuration sans « $Nom » : $Override restauré, rien d'autre n'a été supprimé."
            }
        }
    }
    Remove-Item -LiteralPath "profils\$Nom.env" -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "data\$Nom" -Recurse -Force -ErrorAction SilentlyContinue
    if ($Nom -eq 'principal') {
        Ok "Profil « principal » vidé. Il reste déclaré dans docker-compose.yml, mais sans CV il est ignoré : installer.bat pour le recréer."
    } else {
        Ok "« $Nom » a été supprimé."
    }
}

# Heure-De nom → heure du mail (21:00 par défaut)
function Heure-De([string]$Nom) {
    $heure = Reglage-De $Nom RUN_AT
    if (-not $heure) { $heure = '21:00' }
    return $heure
}

# Recherche-De nom → heure de la recherche si elle a lieu avant le mail, sinon vide
function Recherche-De([string]$Nom) {
    $recherche = Reglage-De $Nom SEARCH_AT
    if ($recherche -eq (Heure-De $Nom)) { return '' }
    return $recherche
}

# Horaire-De nom → « à 21:00 » ou « recherche à 03:00, mail à 21:00 »
function Horaire-De([string]$Nom) {
    $recherche = Recherche-De $Nom
    if ($recherche) { return "recherche à $recherche, mail à $(Heure-De $Nom)" }
    return "à $(Heure-De $Nom)"
}

# Executer nom action → $true si l'action a réussi pour cette personne
function Executer([string]$Nom, [string]$Action, [bool]$Actif) {
    $horaire = Horaire-De $Nom
    switch ($Action) {
        'envoi' { return (Lancer-Recherche $Nom) }
        'apercu' { return (Lancer-Recherche $Nom -Apercu) }
        'test-mail' {
            if (-not (Lancer-Docker compose run --rm -T $Nom python -m app test-mail)) {
                Attention "L'envoi du mail de test a échoué pour « $Nom » (voir le message ci-dessus)."
                return $false
            }
            Ok "Mail de test envoyé pour « $Nom » : vérifie la boîte de réception (et les spams)."
            return $true
        }
        'profil' { return (Lancer-Docker compose run --rm -T $Nom python -m app profile) }
        { $_ -eq 'activer' -or $_ -eq 'heure' } {
            if ($Action -eq 'activer' -or $Actif) {
                # Recrée le conteneur si l'heure a changé
                if (-not (Lancer-Docker compose up -d $Nom)) { return $false }
                Ok "Envoi automatique activé pour « $Nom » : tous les jours, $horaire, tant que Docker Desktop tourne."
            } else {
                Ok "Heures enregistrées ($horaire). L'envoi automatique n'est pas actif : lancer.bat $Nom activer"
            }
            return $true
        }
        'arreter' {
            if (-not (Lancer-Docker compose stop $Nom)) { return $false }
            Ok "Envoi automatique arrêté pour « $Nom ». Tu peux toujours lancer une recherche avec lancer.bat."
            return $true
        }
    }
}

function Lancer([string]$Nom, [string]$Action, [string]$NouvelleHeure, [string]$NouvelleRecherche) {
    if (-not (Test-Path -LiteralPath '.env')) { Erreur "Rien n'est encore installé : lance d'abord installer.bat." }
    $profils = @(Services-Compose)
    $actifs = @((Capturer-Docker compose ps --status running --services).Lignes)

    # Personne
    if (-not $Nom) {
        if ($profils.Count -eq 1) {
            $Nom = $profils[0]
        } else {
            $options = @(foreach ($p in $profils) { if ($actifs -contains $p) { "$p (envoi automatique actif)" } else { $p } })
            Write-Host ''
            $choix = Choisir 'Pour qui ?' ($options + 'Tous les profils')
            $Nom = if ($choix -gt $profils.Count) { 'tous' } else { $profils[$choix - 1] }
        }
    } elseif ($Nom -ne 'tous' -and $profils -notcontains $Nom) {
        Erreur "Profil « $Nom » inconnu. Profils existants : $($profils -join ' ') (ou « tous »)"
    }

    # Action
    if ($Nom -eq 'tous') {
        if (-not $Action) {
            Write-Host ''
            $choix = Choisir "Que veux-tu faire pour tous les profils, l'un après l'autre ?" @(
                'Lancer une recherche et envoyer le mail',
                'Lancer une recherche sans envoyer de mail (aperçu)',
                'Envoyer un mail de test',
                "Activer l'envoi automatique quotidien (chacun à ses heures)",
                "Arrêter l'envoi automatique quotidien")
            $Action = @('envoi', 'apercu', 'test-mail', 'activer', 'arreter')[$choix - 1]
        }
        if ($Action -eq 'heure') { Erreur "Pour changer les heures, choisis un profil : lancer.bat <nom> heure HH:MM [HH:MM]" }
        if (@('envoi', 'apercu', 'test-mail', 'profil', 'activer', 'arreter') -notcontains $Action) {
            Erreur "Action inconnue : $Action (envoi, apercu, test-mail, profil, activer ou arreter)"
        }
        if ($NouvelleHeure) { Erreur "Avec « tous », chacun garde ses heures : lancer.bat <nom> $Action HH:MM pour en changer." }
    } else {
        if (-not (Test-Path -LiteralPath "data\$Nom\cv.pdf")) {
            Erreur "Pas de CV pour « $Nom » : dépose-le dans data\$Nom\cv.pdf, ou lance installer.bat."
        }
        $heure = Heure-De $Nom
        $recherche = Recherche-De $Nom
        if (-not $Action) {
            $options = @(
                'Lancer une recherche et envoyer le mail',
                'Lancer une recherche sans envoyer de mail (aperçu)',
                'Envoyer un mail de test',
                'Voir le profil déduit du CV (métier, mots-clés, requêtes)')
            $actions = @('envoi', 'apercu', 'test-mail', 'profil')
            if ($actifs -contains $Nom) {
                $options += "Changer les heures de l'envoi automatique (actuellement tous les jours, $(Horaire-De $Nom))", "Arrêter l'envoi automatique quotidien"
                $actions += 'heure', 'arreter'
            } else {
                $options += "Activer l'envoi automatique quotidien, aux heures de ton choix"
                $actions += 'activer'
            }
            $options += 'Modifier le profil (CV, mail, ville, critères, sources…)', 'Supprimer ce profil'
            $actions += 'modifier', 'supprimer'
            Write-Host ''
            $Action = $actions[(Choisir "Que veux-tu faire pour « $Nom » ?" $options) - 1]
        }
        if (@('envoi', 'apercu', 'test-mail', 'profil', 'activer', 'heure', 'arreter', 'modifier', 'supprimer') -notcontains $Action) {
            Erreur "Action inconnue : $Action (envoi, apercu, test-mail, profil, activer, heure, arreter, modifier ou supprimer)"
        }

        # Heures de l'envoi automatique : en arguments, sinon demandées (Entrée = heure actuelle).
        # Heure de la recherche : « non » (ou absente en argument) = au moment du mail.
        if ($Action -eq 'activer' -or $Action -eq 'heure') {
            if ($NouvelleHeure -and $NouvelleHeure -notmatch $HeureRegex) {
                Erreur "Heure du mail invalide : $NouvelleHeure (format attendu : HH:MM, ex. 08:30)"
            }
            if ($NouvelleRecherche -and $NouvelleRecherche -ne 'non' -and $NouvelleRecherche -notmatch $HeureRegex) {
                Erreur "Heure de recherche invalide : $NouvelleRecherche (HH:MM, ex. 03:00, ou « non »)"
            }
            if (-not $NouvelleHeure) {
                do { $NouvelleHeure = Demander 'Heure du mail, tous les jours (HH:MM)' $heure } until ($NouvelleHeure -match $HeureRegex)
                Write-Host "La recherche peut avoir lieu plus tôt, par exemple la nuit : les offres notées attendent l'heure du mail."
                $defaut = if ($recherche) { $recherche } else { 'non' }
                while ($true) {
                    $NouvelleRecherche = Demander 'Heure de la recherche (HH:MM, ex. 03:00 ; « non » = au moment du mail)' $defaut
                    if ($NouvelleRecherche -eq 'non' -or $NouvelleRecherche -match $HeureRegex) { break }
                    Write-Host '  → format attendu : HH:MM (ex. 03:00), ou « non ».'
                }
            } elseif (-not $NouvelleRecherche) {
                # Heure du mail seule en argument : la recherche ne change pas
                $NouvelleRecherche = if ($recherche) { $recherche } else { 'non' }
            }
            if ($NouvelleRecherche -eq 'non' -or $NouvelleRecherche -eq $NouvelleHeure) { $NouvelleRecherche = '' }
            if ($NouvelleHeure -ne $heure) { Ecrire-Reglage "profils\$Nom.env" RUN_AT $NouvelleHeure }
            if ($NouvelleRecherche -ne $recherche) { Ecrire-Reglage "profils\$Nom.env" SEARCH_AT $NouvelleRecherche }
        }
    }

    # Modification et suppression d'un profil
    if ($Action -eq 'modifier') { Ajouter-Personne -Modifier $Nom; return }
    if ($Action -eq 'supprimer') { Supprimer-Profil $Nom; return }

    # Exécution
    Write-Host ''
    Construire-Image
    if ($Nom -ne 'tous') {
        if (-not (Executer $Nom $Action ($actifs -contains $Nom))) { exit 1 }
        return
    }

    # Tous les profils, l'un après l'autre : un échec n'arrête pas les suivants
    $bilan = @()
    $echecs = 0
    foreach ($p in $profils) {
        Write-Host ''
        Info "═══ $p ═══"
        if (-not (Test-Path -LiteralPath "data\$p\cv.pdf")) {
            Attention "Pas de CV dans data\$p\cv.pdf : profil ignoré."
            $bilan += "-    $p : ignoré (pas de CV)"
        } elseif (Executer $p $Action ($actifs -contains $p)) {
            $bilan += "[OK] $p"
        } else {
            $bilan += "[X]  $p : échec (voir plus haut)"
            $echecs++
        }
    }
    Write-Host ''
    Info '═══ Récapitulatif ═══'
    foreach ($ligne in $bilan) { Write-Host "  $ligne" }
    if ($echecs -gt 0) { exit 1 }
}

# ─── Point d'entrée ────────────────────────────────────────────────────

switch ($Commande) {
    'installer' { Installer }
    'ajouter' { Verifier-Docker; Ajouter-Personne }
    'lancer' { Verifier-Docker; Lancer $Nom $Action $Heure $Recherche }
}
