"""Welcome to the Jungle, via l'index Algolia public utilisé par leur site.

Ce n'est pas une API officielle : si le site change, cette source peut cesser de
fonctionner (les autres sources continuent). Les identifiants Algolia publics
peuvent être mis à jour via WTTJ_ALGOLIA_APP_ID / WTTJ_ALGOLIA_API_KEY.
"""

from __future__ import annotations

import logging
import os

from ..models import Job, html_to_text
from .base import Source, parse_datetime

log = logging.getLogger(__name__)

INDEX = "wttj_jobs_production_fr_published_at_desc"
REMOTE_LABELS = {"fulltime": "Télétravail total", "partial": "Télétravail partiel", "punctual": "Télétravail ponctuel"}


class WelcomeToTheJungleSource(Source):
    name = "wttj"
    label = "Welcome to the Jungle"

    def fetch(self) -> list[Job]:
        app_id = os.getenv("WTTJ_ALGOLIA_APP_ID", "CSEKHVMS53")
        api_key = os.getenv("WTTJ_ALGOLIA_API_KEY", "4bd8f6215d0cc52b26430765769e65a0")
        url = f"https://{app_id.lower()}-dsn.algolia.net/1/indexes/{INDEX}/query"
        headers = {
            "X-Algolia-Application-Id": app_id,
            "X-Algolia-API-Key": api_key,
            "Referer": "https://www.welcometothejungle.com/",
            "Origin": "https://www.welcometothejungle.com",
        }
        since_ts = int(self.since.timestamp())

        searches: list[dict] = []
        if self.ctx.lat is not None and self.ctx.lng is not None:
            searches.append(
                {
                    "aroundLatLng": f"{self.ctx.lat},{self.ctx.lng}",
                    "aroundRadius": self.ctx.settings.radius_km * 1000,
                }
            )
        else:  # pas de ville configurée : toute la France
            searches.append({"facetFilters": [["offices.country_code:FR"]]})
        if self.ctx.settings.include_remote:
            searches.append({"filters": "remote:fulltime", "facetFilters": [["offices.country_code:FR"]]})

        jobs: list[Job] = []
        for query in self.ctx.profile.search_queries:
            for extra in searches:
                body = {
                    "query": query,
                    "hitsPerPage": 100,
                    "numericFilters": [f"published_at_timestamp>={since_ts}"],
                    **extra,
                }
                resp = self.http.post(url, json=body, headers=headers)
                if resp.status_code >= 400:
                    log.warning("WTTJ « %s » : HTTP %s %s", query, resp.status_code, resp.text[:200])
                    continue
                jobs.extend(self._to_job(hit) for hit in resp.json().get("hits", []))
        return jobs

    @staticmethod
    def _to_job(hit: dict) -> Job:
        org = hit.get("organization") or {}
        offices = hit.get("offices") or []
        location = ", ".join(dict.fromkeys(o.get("city", "") for o in offices if o.get("city")))
        missions = hit.get("key_missions") or []
        description = "\n".join(
            part
            for part in [
                hit.get("summary") or "",
                "Missions : " + " ; ".join(missions) if missions else "",
                html_to_text(hit.get("profile") or ""),
            ]
            if part
        )
        salary = ""
        if hit.get("salary_minimum"):
            salary = f"{hit['salary_minimum']} - {hit.get('salary_maximum') or hit['salary_minimum']} {hit.get('salary_currency') or ''} / {hit.get('salary_period') or ''}"
        remote = hit.get("remote") or ""
        return Job(
            source="wttj",
            source_id=str(hit.get("objectID") or hit.get("reference")),
            title=hit.get("name", ""),
            company=org.get("name", ""),
            location=location,
            url=f"https://www.welcometothejungle.com/fr/companies/{org.get('slug', '')}/jobs/{hit.get('slug', '')}",
            description=description,
            published_at=parse_datetime(hit.get("published_at")),
            remote=remote == "fulltime",
            contract=" · ".join(x for x in [hit.get("contract_type") or "", REMOTE_LABELS.get(remote, "")] if x),
            salary=salary.strip(" /"),
        )
