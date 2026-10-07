"""API Adzuna, agrégateur multi-sites (clé gratuite sur https://developer.adzuna.com)."""

from __future__ import annotations

import logging

from ..models import Job, html_to_text
from .base import Source, parse_datetime

log = logging.getLogger(__name__)

SEARCH_URL = "https://api.adzuna.com/v1/api/jobs/fr/search/1"


class AdzunaSource(Source):
    name = "adzuna"
    label = "Adzuna"

    def is_configured(self) -> bool:
        s = self.ctx.settings
        return bool(s.adzuna_app_id and s.adzuna_app_key)

    def fetch(self) -> list[Job]:
        s = self.ctx.settings
        jobs: list[Job] = []
        for query in self.ctx.profile.search_queries:
            params = {
                "app_id": s.adzuna_app_id,
                "app_key": s.adzuna_app_key,
                "what": query,
                "max_days_old": max(1, s.max_days_old),
                "results_per_page": 50,
                "sort_by": "date",
                "content-type": "application/json",
            }
            if s.city:
                params.update(where=s.city, distance=s.radius_km)
            resp = self.http.get(SEARCH_URL, params=params)
            if resp.status_code >= 400:
                log.warning("Adzuna « %s » : HTTP %s %s", query, resp.status_code, resp.text[:200])
                continue
            for item in resp.json().get("results", []):
                job = self._to_job(item)
                if self.is_recent(job.published_at):
                    jobs.append(job)
        return jobs

    @staticmethod
    def _to_job(item: dict) -> Job:
        salary = ""
        if item.get("salary_min") and item.get("salary_is_predicted") != "1":
            salary = f"{int(item['salary_min'])} - {int(item.get('salary_max') or item['salary_min'])} €"
        return Job(
            source="adzuna",
            source_id=str(item["id"]),
            title=html_to_text(item.get("title", "")),
            company=(item.get("company") or {}).get("display_name", ""),
            location=(item.get("location") or {}).get("display_name", ""),
            url=item.get("redirect_url", ""),
            description=html_to_text(item.get("description", "")),
            published_at=parse_datetime(item.get("created")),
            contract=item.get("contract_type", "") or "",
            salary=salary,
        )
