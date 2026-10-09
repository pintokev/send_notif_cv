# Version Windows de installer.sh, ajouter_cv.sh et lancer.sh, appelée par installer.bat,
# ajouter_cv.bat et lancer.bat :
#   installer  crée le .env, envoie un mail de test et crée le premier profil ;
#   ajouter    ajoute une personne (CV + adresse mail) ;
#   lancer     lance une recherche à la demande, active ou arrête l'envoi automatique.
# Fichier enregistré en UTF-8 avec BOM : sans BOM, Windows PowerShell 5.1 lit mal les accents.

param(
    [Parameter(Mandatory = $true)][ValidateSet('installer', 'ajouter', 'lancer')][string]$Commande,
    [string]$Nom = '',
    [string]$Action = '',
    [string]$Heure = ''
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

function Construire-Image {
    if ((Capturer-Docker image inspect job-alert).Code -ne 0) {
        Info "Construction de l'image Docker (quelques minutes la première fois)…"
        if (-not (Lancer-Docker compose build)) { Erreur "La construction de l'image Docker a échoué (voir le message ci-dessus)." }
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

# Utilise-Google nom → $true si cette personne interroge Google Jobs
# (SOURCES de son profil, sinon celui du .env ; vide = toutes les sources)
function Utilise-Google([string]$Nom) {
    $fichier = "profils\$Nom.env"
    if (-not ((Test-Path -LiteralPath $fichier) -and (Select-String -LiteralPath $fichier -Pattern '^SOURCES=' -Quiet))) { $fichier = '.env' }
    $valeur = (Lire-Reglage $fichier SOURCES) -replace '\s', ''
    return (-not $valeur -or ",$valeur," -like '*,googlejobs,*')
}

function Ajouter-Personne([switch]$Principal) {
    if (-not (Test-Path -LiteralPath '.env')) { Erreur "Fichier .env introuvable : lance d'abord installer.bat." }
    $existants = @(Services-Compose)

    Write-Host ''
    if ($Principal) {
        Info '═══ Création du premier profil ═══'
        $nom = 'principal'
        if (Test-Path -LiteralPath "data\$nom\cv.pdf") {
            Erreur "Le profil « $nom » a déjà un CV. Pour le modifier : profils\$nom.env. Pour ajouter une personne : ajouter_cv.bat"
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
            } elseif ($existants -contains $nom) {
                Write-Host "  → « $nom » existe déjà."
            } elseif ((Test-Path -LiteralPath "profils\$nom.env") -or (Test-Path -LiteralPath "data\$nom")) {
                Write-Host "  → profils\$nom.env ou data\$nom existe déjà : choisis un autre nom ou supprime-les."
            } else { break }
        }
    }

    # CV
    while ($true) {
        $cv = (Demander 'Chemin du CV (PDF) : glisse le fichier dans cette fenêtre puis appuie sur Entrée').Trim('"', "'")
        if (-not $cv -or -not (Test-Path -LiteralPath $cv -PathType Leaf)) { Write-Host "  → fichier introuvable : $cv"; continue }
        $cv = (Resolve-Path -LiteralPath $cv).Path
        $flux = [IO.File]::OpenRead($cv)
        try { $debut = New-Object byte[] 4; $lus = $flux.Read($debut, 0, 4) } finally { $flux.Dispose() }
        if ($lus -eq 4 -and [Text.Encoding]::ASCII.GetString($debut) -eq '%PDF') { break }
        Write-Host "  → ce fichier n'est pas un PDF."
    }

    # Mail
    do {
        $mailTo = Demander 'Adresse mail qui recevra les offres (plusieurs : séparées par des virgules)'
        if ($mailTo -notmatch $MailsRegex) { Write-Host '  → adresse invalide.' }
    } until ($mailTo -match $MailsRegex)

    # Recherche
    Write-Host ''
    Info 'Recherche (Entrée pour accepter la valeur proposée)'
    $ville = Demander 'Ville autour de laquelle chercher (vide = toute la France)'
    $rayon = '30'
    if ($ville) { do { $rayon = Demander 'Rayon de recherche en km' '30' } until ($rayon -match '^[0-9]+$') }
    $teletravail = if (Confirmer 'Inclure les offres 100 % télétravail ?' 'o') { 'true' } else { 'false' }
    $preferences = Demander 'Critères en langage naturel (ex. CDI uniquement, pas de management ; vide = aucun)'
    $exclusions = Demander 'Mots à exclure des intitulés, séparés par des virgules' 'stage,alternance'
    $entreprises = Demander 'Entreprises cibles, séparées par des virgules (vide = aucune)'

    # Sources à clé : proposées seulement si leur clé est dans le .env. Une source sans clé reste
    # dans la liste (elle est ignorée tant que la clé manque), pour s'activer dès qu'on l'ajoute.
    # WTTJ et les sites télétravail sont gratuits et toujours interrogés ; les sites carrière
    # le sont dès que la personne a des entreprises cibles.
    $exclues = @()
    $aCle = @{
        francetravail = [bool](Lire-Reglage '.env' FRANCETRAVAIL_CLIENT_ID)
        adzuna        = [bool](Lire-Reglage '.env' ADZUNA_APP_ID)
        googlejobs    = [bool](Lire-Reglage '.env' SERPAPI_API_KEY)
    }
    if ($aCle.Values -contains $true) { Write-Host ''; Info "Sources d'offres utilisant tes clés API" }
    if ($aCle.francetravail -and -not (Confirmer 'Chercher sur France Travail ?' 'o')) { $exclues += 'francetravail' }
    if ($aCle.adzuna -and -not (Confirmer 'Chercher sur Adzuna ?' 'o')) { $exclues += 'adzuna' }
    if ($aCle.googlejobs -and -not (Confirmer 'Chercher sur Google Jobs (LinkedIn, Indeed, APEC… ; quota SerpApi partagé entre les personnes) ?' 'o')) { $exclues += 'googlejobs' }
    $sources = (@('francetravail', 'adzuna', 'wttj', 'googlejobs', 'careersites', 'remotive', 'remoteok', 'jobicy') |
        Where-Object { $exclues -notcontains $_ }) -join ','

    # Envoi
    Write-Host ''
    Info 'Envoi du mail'
    do { $heure = Demander "Heure d'envoi quotidienne (HH:MM, heure de Paris)" '21:15' } until ($heure -match '^([01][0-9]|2[0-3]):[0-5][0-9]$')
    do { $score = Demander "Score minimum (0-100) pour qu'une offre figure dans le mail" '60' } until ($score -match '^[0-9]+$' -and [int]$score -le 100)
    do { $maxOffres = Demander "Nombre maximum d'offres par mail" '15' } until ($maxOffres -match '^[1-9][0-9]*$')

    # Quota SerpApi gratuit (250 recherches/mois) partagé entre les personnes qui utilisent Google Jobs
    $google = $exclues -notcontains 'googlejobs'
    $nbGoogle = @($existants | Where-Object { $_ -ne $nom -and (Utilise-Google $_) }).Count + $(if ($google) { 1 } else { 0 })
    $recherchesGoogle = [Math]::Max(1, [Math]::Min(6, [Math]::Floor(250 / (31 * [Math]::Max(1, $nbGoogle)))))

    Write-Host ''
    Info '═══ Récapitulatif ═══'
    Write-Host "  Nom                : $nom"
    Write-Host "  CV                 : $cv → data\$nom\cv.pdf"
    Write-Host "  Mail               : $mailTo"
    Write-Host "  Ville / rayon      : $(if ($ville) { "$ville / $rayon km" } else { 'toute la France' })"
    Write-Host "  Télétravail        : $teletravail"
    Write-Host "  Critères           : $(if ($preferences) { $preferences } else { 'aucun' })"
    Write-Host "  Mots exclus        : $(if ($exclusions) { $exclusions } else { 'aucun' })"
    Write-Host "  Entreprises cibles : $(if ($entreprises) { $entreprises } else { 'aucune' })"
    Write-Host "  Envoi              : tous les jours à $heure, score ≥ $score, $maxOffres offres max"
    Write-Host "  Sources            : $sources"
    if ($google) { Write-Host "  Google Jobs        : $recherchesGoogle recherches par jour (quota SerpApi partagé entre $nbGoogle personnes)" }
    Write-Host ''
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

RUN_AT=$heure
MIN_SCORE=$score
MAX_RESULTS=$maxOffres

# Sources interrogées (retirer un nom pour ne plus l'utiliser)
SOURCES=$sources
# Quota SerpApi gratuit (250 recherches/mois) partagé entre les personnes qui utilisent Google Jobs
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
    Write-Host "Envoi automatique : la recherche peut tourner toute seule tous les jours à $heure,"
    Write-Host "tant que cet ordinateur et Docker Desktop restent allumés. Sinon, lance-la quand tu veux avec lancer.bat."
    if (Confirmer "Activer l'envoi automatique quotidien pour $nom ?" 'o') {
        if (Lancer-Docker compose up -d $nom) { Ok "« $nom » recevra ses offres tous les jours à $heure." }
    } else {
        Write-Host "Pour l'activer plus tard : lancer.bat"
    }

    if ($google -and $nbGoogle -gt 1) {
        Write-Host ''
        Info "Pense au quota Google Jobs : mets GOOGLEJOBS_SEARCHES_PER_RUN=$recherchesGoogle dans le profil de chaque personne qui l'utilise"
        Info "(et dans le .env pour « principal » s'il n'a pas de profils\principal.env), puis : docker compose up -d"
    }
}

# ─── lancer : recherche à la demande ───────────────────────────────────

function Lancer([string]$Nom, [string]$Action, [string]$NouvelleHeure) {
    if (-not (Test-Path -LiteralPath '.env')) { Erreur "Rien n'est encore installé : lance d'abord installer.bat." }
    $profils = @(Services-Compose)
    $actifs = @((Capturer-Docker compose ps --status running --services).Lignes)

    if (-not $Nom) {
        if ($profils.Count -eq 1) {
            $Nom = $profils[0]
        } else {
            $options = foreach ($p in $profils) { if ($actifs -contains $p) { "$p (envoi automatique actif)" } else { $p } }
            Write-Host ''
            $Nom = $profils[(Choisir 'Pour qui ?' @($options)) - 1]
        }
    } elseif ($profils -notcontains $Nom) {
        Erreur "Profil « $Nom » inconnu. Profils existants : $($profils -join ' ')"
    }
    if (-not (Test-Path -LiteralPath "data\$Nom\cv.pdf")) {
        Erreur "Pas de CV pour « $Nom » : dépose-le dans data\$Nom\cv.pdf, ou lance installer.bat."
    }

    $heure = Lire-Reglage "profils\$Nom.env" RUN_AT
    if (-not $heure) { $heure = Lire-Reglage '.env' RUN_AT }
    if (-not $heure) { $heure = '21:00' }

    $actif = $actifs -contains $Nom
    if (-not $Action) {
        $options = @(
            'Lancer une recherche et envoyer le mail',
            'Lancer une recherche sans envoyer de mail (aperçu)',
            'Envoyer un mail de test',
            'Voir le profil déduit du CV (métier, mots-clés, requêtes)')
        $actions = @('envoi', 'apercu', 'test-mail', 'profil')
        if ($actif) {
            $options += "Changer l'heure de l'envoi automatique (actuellement tous les jours à $heure)", "Arrêter l'envoi automatique quotidien"
            $actions += 'heure', 'arreter'
        } else {
            $options += "Activer l'envoi automatique quotidien, à l'heure de ton choix"
            $actions += 'activer'
        }
        Write-Host ''
        $Action = $actions[(Choisir "Que veux-tu faire pour « $Nom » ?" $options) - 1]
    }

    # Nouvelle heure de l'envoi automatique : en argument, sinon demandée (Entrée = heure actuelle)
    if ($Action -eq 'activer' -or $Action -eq 'heure') {
        if ($NouvelleHeure -and $NouvelleHeure -notmatch $HeureRegex) {
            Erreur "Heure invalide : $NouvelleHeure (format attendu : HH:MM, ex. 08:30)"
        }
        while ($NouvelleHeure -notmatch $HeureRegex) {
            if ($NouvelleHeure) { Write-Host '  → format attendu : HH:MM (ex. 08:30).' }
            $NouvelleHeure = Demander "Heure de l'envoi automatique, tous les jours (HH:MM)" $heure
        }
        if ($NouvelleHeure -ne $heure) {
            Ecrire-Reglage "profils\$Nom.env" RUN_AT $NouvelleHeure
            $heure = $NouvelleHeure
        }
    }

    Write-Host ''
    Construire-Image
    switch ($Action) {
        'envoi' { if (-not (Lancer-Recherche $Nom)) { exit 1 } }
        'apercu' { if (-not (Lancer-Recherche $Nom -Apercu)) { exit 1 } }
        'test-mail' {
            if (-not (Lancer-Docker compose run --rm -T $Nom python -m app test-mail)) { Erreur "L'envoi a échoué (voir le message ci-dessus)." }
            Ok 'Mail de test envoyé : vérifie la boîte de réception (et les spams).'
        }
        'profil' { if (-not (Lancer-Docker compose run --rm -T $Nom python -m app profile)) { exit 1 } }
        { $_ -eq 'activer' -or $_ -eq 'heure' } {
            if ($Action -eq 'activer' -or $actif) {
                # Recrée le conteneur si l'heure a changé
                if (-not (Lancer-Docker compose up -d $Nom)) { exit 1 }
                Ok "Envoi automatique activé : « $Nom » recevra ses offres tous les jours à $heure, tant que Docker Desktop tourne."
            } else {
                Ok "Heure enregistrée ($heure). L'envoi automatique n'est pas actif : lancer.bat $Nom activer"
            }
        }
        'arreter' {
            if (-not (Lancer-Docker compose stop $Nom)) { exit 1 }
            Ok "Envoi automatique arrêté pour « $Nom ». Tu peux toujours lancer une recherche avec lancer.bat."
        }
        default { Erreur "Action inconnue : $Action (envoi, apercu, test-mail, profil, activer, heure ou arreter)" }
    }
}

# ─── Point d'entrée ────────────────────────────────────────────────────

switch ($Commande) {
    'installer' { Installer }
    'ajouter' { Verifier-Docker; Ajouter-Personne }
    'lancer' { Verifier-Docker; Lancer $Nom $Action $Heure }
}
