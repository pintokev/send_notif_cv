"""Notation des offres par Claude au regard du CV."""

from __future__ import annotations

import logging
from concurrent.futures import ThreadPoolExecutor
from datetime import date

from .candidate import Profile
from .config import Settings
from .llm import structured_call
from .models import Job, ScoredJob

log = logging.getLogger(__name__)

BATCH_SIZE = 8
MAX_WORKERS = 4
DESCRIPTION_CHARS = 4000  # largement suffisant pour juger une offre

SCORE_SCHEMA = {
    "type": "object",
    "properties": {
        "evaluations": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "job_id": {"type": "string"},
                    "score": {"type": "integer"},
                    "reason": {"type": "string"},
                },
                "required": ["job_id", "score", "reason"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["evaluations"],
    "additionalProperties": False,
}


def _system_prompt(profile: Profile, settings: Settings) -> str:
    location = settings.city or "France (pas de ville précise)"
    remote = "accepte aussi le 100 % télétravail" if settings.include_remote else "ne cherche pas de télétravail complet"
    preferences = settings.preferences or "aucune précisée"
    return f"""Tu es un recruteur expert qui évalue l'adéquation entre un candidat et des offres d'emploi.

<profil>
{profile.summary}
Niveau : {profile.seniority}
Langues : {", ".join(profile.languages)}
Postes visés : {", ".join(profile.job_titles)}
</profil>

<cv>
{profile.cv_text}
</cv>

<contraintes_du_candidat>
Lieu de vie : {location}, rayon de recherche {settings.radius_km} km ; {remote}.
Préférences : {preferences}
</contraintes_du_candidat>

Pour chaque offre, attribue un score de 0 à 100 :
- 85-100 : correspondance excellente (métier, compétences clés et niveau alignés)
- 70-84 : bonne correspondance, quelques écarts mineurs
- 50-69 : correspondance partielle (compétences transférables, niveau ou domaine différent)
- 0-49 : peu ou pas pertinent

Pénalise fortement : un niveau très éloigné (stage ou alternance pour un profil expérimenté, poste de direction pour un junior), un métier différent malgré des mots-clés communs, une offre en télétravail réservée à des résidents d'un autre pays que la France, une offre qui ne respecte pas les préférences du candidat.

Pour "reason", écris en français une phrase concise (25 mots maximum) qui explique le score : points forts et principal écart éventuel. Renvoie une évaluation par offre avec son job_id exact."""


def _format_job(job_id: str, job: Job) -> str:
    published = job.published_at.date().isoformat() if job.published_at else "inconnue"
    return f"""<offre job_id="{job_id}">
Intitulé : {job.title}
Entreprise : {job.company}
Lieu : {job.location}{" (télétravail)" if job.remote else ""}
Contrat : {job.contract or "non précisé"}
Salaire : {job.salary or "non précisé"}
Publiée le : {published}
Description :
{job.description[:DESCRIPTION_CHARS]}
</offre>"""


def score_jobs(jobs: list[Job], profile: Profile, settings: Settings) -> list[ScoredJob]:
    if not jobs:
        return []
    system = _system_prompt(profile, settings)
    batches = [jobs[i : i + BATCH_SIZE] for i in range(0, len(jobs), BATCH_SIZE)]

    def score_batch(batch: list[Job]) -> list[ScoredJob]:
        by_id = {str(i + 1): job for i, job in enumerate(batch)}
        content = (
            f"Date du jour : {date.today().isoformat()}. Évalue ces {len(batch)} offres :\n\n"
            + "\n\n".join(_format_job(job_id, job) for job_id, job in by_id.items())
        )
        try:
            data = structured_call(
                backend=settings.claude_backend,
                model=settings.claude_model,
                system=system,
                content=content,
                schema=SCORE_SCHEMA,
                effort="low",
            )
        except Exception:
            log.exception("Échec de la notation d'un lot de %d offres", len(batch))
            return []
        results = []
        for ev in data["evaluations"]:
            job = by_id.get(str(ev["job_id"]))
            if job is not None:
                results.append(ScoredJob(job=job, score=max(0, min(100, int(ev["score"]))), reason=ev["reason"]))
        missing = len(batch) - len(results)
        if missing:
            log.warning("%d offres non évaluées dans un lot", missing)
        return results

    log.info("Notation de %d offres par Claude (%d lots)…", len(jobs), len(batches))
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        scored = [s for batch in pool.map(score_batch, batches) for s in batch]
    log.info("Notation terminée : %d offres notées", len(scored))
    return scored

