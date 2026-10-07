"""Google Jobs via SerpApi (https://serpapi.com, offre gratuite : 250 recherches par mois).

Google Jobs agrège LinkedIn, Indeed, APEC, HelloWork, Cadremploi et les sites
carrière des entreprises. Chaque requête consomme une recherche SerpApi : le
nombre de requêtes par exécution est plafonné et le solde du compte est vérifié
avant de lancer quoi que ce soit.
"""

from __future__ import annotations

import logging
import re
from datetime import datetime, timedelta

import httpx

from ..models import Job
from .base import Source, SourceError

log = logging.getLogger(__name__)

SEARCH_URL = "https://serpapi.com/search.json"
ACCOUNT_URL = "https://serpapi.com/account.json"
SEARCH_TIMEOUT = 90  # SerpApi interroge Google en direct : une recherche peut prendre plus de 30 s

_AGE_RE = re.compile(r"(\d+)\+?\s*(minute|heure|hour|jour|day|semaine|week|mois|month)", re.I)
_UNIT_DAYS = {"minute": 1 / 1440, "heure": 1 / 24, "hour": 1 / 24, "jour": 1, "day": 1,
              "semaine": 7, "week": 7, "mois": 30, "month": 30}


def parse_posted_at(text: str | None, now: datetime) -> datetime | None:
    """« il y a 3 jours » / « 3 days ago » → date approximative."""
    match = _AGE_RE.search(text or "")
    if not match:
        return None
    unit = match.group(2).lower()
    return now - timedelta(days=int(match.group(1)) * _UNIT_DAYS[unit])


class GoogleJobsSource(Source):
    name = "googlejobs"
    label = "Google Jobs"

    def is_configured(self) -> bool:
        return bool(self.ctx.settings.serpapi_api_key)

    @property
    def max_days_old(self) -> int:
        # Google Jobs ne trie pas par date : on élargit la fenêtre, le dédoublonnage évite les répétitions.
        return self.ctx.settings.extended_max_days_old

    def _searches_left(self) -> int | None:
        try:
            resp = self.http.get(ACCOUNT_URL, params={"api_key": self.ctx.settings.serpapi_api_key})
        except Exception as exc:  # le contrôle du solde ne doit pas bloquer la recherche
            log.warning("Solde SerpApi inconnu : %s", exc)
            return None
        if resp.status_code == 401:
            raise SourceError("clé SerpApi invalide")
        try:
            resp.raise_for_status()
            data = resp.json()
        except Exception as exc:
            log.warning("Solde SerpApi inconnu : %s", exc)
            return None
        left = data.get("total_searches_left", data.get("plan_searches_left"))
        return int(left) if left is not None else None

    def _searches(self) -> list[str]:
        s = self.ctx.settings
        queries = self.ctx.profile.search_queries
        local = [f"{q} {s.city}" if s.city else q for q in queries]
        remote = [f"{q} télétravail" for q in queries] if s.include_remote else []
        budget = s.googlejobs_searches_per_run
        left = self._searches_left()
        if left is not None:
            log.info("SerpApi : %d recherches restantes ce mois-ci", left)
            budget = min(budget, left)
        # Recherches locales d'abord, puis télétravail avec le budget restant.
        return (local + remote)[: max(budget, 0)]

    def fetch(self) -> list[Job]:
        searches = self._searches()
        if not searches:
            log.warning("Google Jobs ignoré : quota SerpApi épuisé")
            return []
        jobs: list[Job] = []
        for q in searches:
            try:
                resp = self.http.get(SEARCH_URL, params=self._params(q), timeout=SEARCH_TIMEOUT)
            except httpx.TimeoutException:
                log.warning("Google Jobs « %s » : pas de réponse de SerpApi après %d s", q, SEARCH_TIMEOUT)
                continue
            data = resp.json() if resp.headers.get("content-type", "").startswith("application/json") else {}
            if resp.status_code >= 400 or data.get("error"):
                # « Google hasn't returned any results » n'est pas une vraie erreur
                if "hasn't returned any results" not in str(data.get("error", "")):
                    log.warning("Google Jobs « %s » : HTTP %s %s", q, resp.status_code, data.get("error", resp.text[:200]))
                continue
            for item in data.get("jobs_results", []):
                job = self._to_job(item)
                if self.is_recent(job.published_at):
                    jobs.append(job)
        return jobs

    def _params(self, q: str) -> dict:
        return {
            "engine": "google_jobs",
            "q": q,
            "google_domain": "google.fr",
            "gl": "fr",
            "hl": "fr",
            "api_key": self.ctx.settings.serpapi_api_key,
        }

    def _to_job(self, item: dict) -> Job:
        ext = item.get("detected_extensions") or {}
        apply_options = item.get("apply_options") or []
        highlights = "\n".join(
            f"{h.get('title', '')} : " + " ; ".join(h.get("items") or []) for h in item.get("job_highlights") or []
        )
        via = (item.get("via") or "").strip()
        via = re.sub(r"^(via|par)\s+", "", via, flags=re.I)
        return Job(
            source=self.name,
            source_id=str(item.get("job_id") or item.get("share_link")),
            title=item.get("title", ""),
            company=item.get("company_name", ""),
            location=item.get("location", ""),
            url=apply_options[0]["link"] if apply_options else item.get("share_link", ""),
            description="\n".join(x for x in [item.get("description", ""), highlights] if x),
            published_at=parse_posted_at(ext.get("posted_at"), self.ctx.now),
            remote=bool(ext.get("work_from_home")),
            contract=ext.get("schedule_type", "") or "",
            salary=ext.get("salary", "") or "",
            origin=via,
        )
