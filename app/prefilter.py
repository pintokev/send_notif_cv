"""Préfiltre gratuit par mots-clés : ne garde que les offres les plus prometteuses
avant de les faire noter par Claude."""

from __future__ import annotations

import logging
import re

from .candidate import Profile
from .models import Job, is_target_company, normalize

log = logging.getLogger(__name__)

TITLE_WEIGHT = 3
DESCRIPTION_WEIGHT = 1
JOB_TITLE_BONUS = 10
TARGET_COMPANY_BONUS = 10


def _pattern(term: str) -> re.Pattern[str] | None:
    term = normalize(term)
    if len(term) < 2:
        return None
    # Bornes de mot « souples » pour gérer des termes comme c++, c# ou node.js
    return re.compile(rf"(?<![a-z0-9]){re.escape(term)}(?![a-z0-9])")


def keyword_score(job: Job, keywords: list[re.Pattern], titles: list[re.Pattern]) -> int:
    title = normalize(job.title)
    text = normalize(job.description)
    score = 0
    for pattern in keywords:
        if pattern.search(title):
            score += TITLE_WEIGHT
        elif pattern.search(text):
            score += DESCRIPTION_WEIGHT
    if any(p.search(title) for p in titles):
        score += JOB_TITLE_BONUS
    return score


def prefilter(
    jobs: list[Job], profile: Profile, top_k: int, exclude: list[str], target_companies: list[str]
) -> list[Job]:
    terms = profile.keywords + profile.search_queries
    keywords = [p for p in map(_pattern, dict.fromkeys(terms)) if p]
    titles = [p for p in map(_pattern, profile.job_titles + profile.search_queries) if p]
    excluded = [p for p in map(_pattern, exclude) if p]

    scored: list[tuple[int, Job]] = []
    for job in jobs:
        if any(p.search(normalize(job.title)) for p in excluded):
            continue
        score = keyword_score(job, keywords, titles)
        if is_target_company(job.company, target_companies):
            # Offres des entreprises cibles : prioritaires pour la notation par Claude
            score += TARGET_COMPANY_BONUS
        if score > 0:
            scored.append((score, job))

    scored.sort(key=lambda item: (item[0], item[1].published_at is not None, item[1].published_at), reverse=True)
    kept = [job for _, job in scored[:top_k]]
    log.info("Préfiltre : %d offres pertinentes sur %d, %d gardées pour Claude", len(scored), len(jobs), len(kept))
    return kept
