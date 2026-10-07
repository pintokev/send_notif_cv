"""API Offres d'emploi v2 de France Travail (identifiants sur https://francetravail.io)."""

from __future__ import annotations

import logging

from ..models import Job
from .base import Source, SourceError, parse_datetime

log = logging.getLogger(__name__)

TOKEN_URL = "https://entreprise.francetravail.fr/connexion/oauth2/access_token?realm=%2Fpartenaire"
SEARCH_URL = "https://api.francetravail.io/partenaire/offresdemploi/v2/offres/search"
SCOPE = "api_offresdemploiv2 o2dsoffre"
# Valeurs acceptées par le paramètre publieeDepuis
PUBLISHED_SINCE_DAYS = (1, 3, 7, 14, 31)


class FranceTravailSource(Source):
    name = "francetravail"
    label = "France Travail"

    def is_configured(self) -> bool:
        s = self.ctx.settings
        return bool(s.francetravail_client_id and s.francetravail_client_secret)

    def _token(self) -> str:
        s = self.ctx.settings
        resp = self.http.post(
            TOKEN_URL,
            data={
                "grant_type": "client_credentials",
                "client_id": s.francetravail_client_id,
                "client_secret": s.francetravail_client_secret,
                "scope": SCOPE,
            },
        )
        if resp.status_code >= 400:
            try:
                error = resp.json().get("error", "")
            except ValueError:
                error = ""
            hint = " : vérifie FRANCETRAVAIL_CLIENT_ID / SECRET" if error == "invalid_client" else ""
            raise SourceError(f"authentification refusée (HTTP {resp.status_code} {error}){hint}")
        return resp.json()["access_token"]

    def fetch(self) -> list[Job]:
        s = self.ctx.settings
        headers = {"Authorization": f"Bearer {self._token()}", "Accept": "application/json"}
        days = next((d for d in PUBLISHED_SINCE_DAYS if d >= s.max_days_old), 31)
        jobs: list[Job] = []
        for query in self.ctx.profile.search_queries:
            params = {"motsCles": query, "publieeDepuis": days, "sort": 1, "range": "0-149"}
            if self.ctx.city_code:
                params.update(commune=self.ctx.city_code, distance=s.radius_km)
            resp = self.http.get(SEARCH_URL, params=params, headers=headers)
            if resp.status_code == 204:  # aucun résultat
                continue
            if resp.status_code >= 400:
                log.warning("France Travail « %s » : HTTP %s %s", query, resp.status_code, resp.text[:200])
                continue
            for item in resp.json().get("resultats", []):
                jobs.append(self._to_job(item))
        return jobs

    @staticmethod
    def _to_job(item: dict) -> Job:
        offer_id = item["id"]
        salary = (item.get("salaire") or {}).get("libelle", "")
        return Job(
            source="francetravail",
            source_id=offer_id,
            title=item.get("intitule", ""),
            company=(item.get("entreprise") or {}).get("nom", "") or "Entreprise non communiquée",
            location=(item.get("lieuTravail") or {}).get("libelle", ""),
            url=f"https://candidat.francetravail.fr/offres/recherche/detail/{offer_id}",
            description=item.get("description", ""),
            published_at=parse_datetime(item.get("dateCreation")),
            contract=item.get("typeContratLibelle", "") or item.get("typeContrat", ""),
            salary=salary,
        )
