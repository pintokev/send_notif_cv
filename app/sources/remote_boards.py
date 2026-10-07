"""Sites d'offres 100 % télétravail : Remotive, RemoteOK, Jobicy.

Leurs conditions d'utilisation demandent de renvoyer vers l'offre d'origine :
c'est le cas, chaque lien du mail pointe vers leur page.
"""

from __future__ import annotations

import logging

from ..models import Job, html_to_text, normalize
from .base import Source, parse_datetime

log = logging.getLogger(__name__)

# Zones compatibles avec un candidat résidant en France
_ALLOWED_ZONES = {"worldwide", "anywhere", "global", "europe", "european", "eu", "emea", "france", "cet", "cest"}
_NEUTRAL_WORDS = {"remote", "remoto", "only", "timezones", "timezone"}


class RemoteBoardSource(Source):
    """Sites 100 % télétravail : peu d'offres par jour, publiées avec retard."""

    remote_only = True

    @property
    def max_days_old(self) -> int:
        return self.ctx.settings.extended_max_days_old


def location_allowed(location: str) -> bool:
    """Écarte les offres réservées aux résidents d'autres pays (ex. « USA only »)."""
    words = set(normalize(location).replace(".", " ").split())
    if not words - _NEUTRAL_WORDS:  # vide ou juste « Remote » : on laisse Claude juger
        return True
    return bool(words & _ALLOWED_ZONES)


class RemotiveSource(RemoteBoardSource):
    name = "remotive"
    label = "Remotive"

    def fetch(self) -> list[Job]:
        # Un seul appel pour tout le flux (Remotive demande de limiter le nombre d'appels) :
        # le préfiltre par mots-clés fait le tri ensuite.
        resp = self.http.get("https://remotive.com/api/remote-jobs")
        resp.raise_for_status()
        jobs = []
        for item in resp.json().get("jobs", []):
            published = parse_datetime(item.get("publication_date"))
            if not self.is_recent(published) or not location_allowed(item.get("candidate_required_location", "")):
                continue
            jobs.append(
                Job(
                    source=self.name,
                    source_id=str(item["id"]),
                    title=item.get("title", ""),
                    company=item.get("company_name", ""),
                    location=f"Remote ({item.get('candidate_required_location') or 'non précisé'})",
                    url=item.get("url", ""),
                    description=html_to_text(item.get("description", "")),
                    published_at=published,
                    remote=True,
                    contract=item.get("job_type", "") or "",
                    salary=item.get("salary", "") or "",
                )
            )
        return jobs


class RemoteOKSource(RemoteBoardSource):
    name = "remoteok"
    label = "Remote OK"

    def fetch(self) -> list[Job]:
        resp = self.http.get("https://remoteok.com/api")
        resp.raise_for_status()
        jobs = []
        for item in resp.json():
            if "id" not in item:  # le premier élément est la mention légale
                continue
            published = parse_datetime(item.get("date"))
            if not self.is_recent(published) or not location_allowed(item.get("location", "")):
                continue
            salary = ""
            if item.get("salary_min"):
                salary = f"${item['salary_min']} - ${item.get('salary_max') or item['salary_min']}"
            tags = ", ".join(item.get("tags") or [])
            jobs.append(
                Job(
                    source=self.name,
                    source_id=str(item["id"]),
                    title=item.get("position", ""),
                    company=item.get("company", ""),
                    location=f"Remote ({item.get('location') or 'non précisé'})",
                    url=item.get("url", ""),
                    description=html_to_text(item.get("description", "")) + (f"\nTags : {tags}" if tags else ""),
                    published_at=published,
                    remote=True,
                    salary=salary,
                )
            )
        return jobs


class JobicySource(RemoteBoardSource):
    """Le filtre geo=france inclut aussi les offres ouvertes à l'Europe ou au monde entier."""

    name = "jobicy"
    label = "Jobicy"

    def fetch(self) -> list[Job]:
        jobs = []
        for query in self.ctx.profile.search_queries:
            resp = self.http.get("https://jobicy.com/api/v2/remote-jobs", params={"count": 50, "tag": query, "geo": "france"})
            if resp.status_code >= 400:
                log.warning("Jobicy « %s » : HTTP %s", query, resp.status_code)
                continue
            for item in resp.json().get("jobs", []):
                published = parse_datetime(item.get("pubDate"))
                if not self.is_recent(published):
                    continue
                salary = ""
                if item.get("salaryMin"):
                    salary = f"{item['salaryMin']} - {item.get('salaryMax') or item['salaryMin']} {item.get('salaryCurrency') or ''}"
                jobs.append(
                    Job(
                        source=self.name,
                        source_id=str(item["id"]),
                        title=item.get("jobTitle", ""),
                        company=item.get("companyName", ""),
                        location=f"Remote ({item.get('jobGeo') or 'non précisé'})",
                        url=item.get("url", ""),
                        description=html_to_text(item.get("jobDescription", "")),
                        published_at=published,
                        remote=True,
                        contract=", ".join(item.get("jobType") or []),
                        salary=salary.strip(),
                    )
                )
        return jobs
