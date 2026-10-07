"""Collecte des offres sur toutes les sources activées, en parallèle."""

from __future__ import annotations

import logging
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import httpx

from ..candidate import Profile
from ..config import Settings
from ..models import Job
from .adzuna import AdzunaSource
from .base import USER_AGENT, SearchContext, Source, SourceError
from .careersites import CareerSitesSource
from .francetravail import FranceTravailSource
from .googlejobs import GoogleJobsSource
from .remote_boards import JobicySource, RemoteOKSource, RemotiveSource
from .wttj import WelcomeToTheJungleSource

log = logging.getLogger(__name__)

SOURCE_CLASSES: dict[str, type[Source]] = {
    cls.name: cls
    for cls in [
        FranceTravailSource,
        AdzunaSource,
        WelcomeToTheJungleSource,
        GoogleJobsSource,
        CareerSitesSource,
        RemotiveSource,
        RemoteOKSource,
        JobicySource,
    ]
}


def resolve_city(city: str) -> tuple[str | None, float | None, float | None]:
    """Code INSEE et coordonnées d'une commune, via l'API officielle geo.api.gouv.fr."""
    if not city:
        return None, None, None
    try:
        resp = httpx.get(
            "https://geo.api.gouv.fr/communes",
            params={"nom": city, "fields": "code,nom,centre", "boost": "population", "limit": 1},
            headers={"User-Agent": USER_AGENT},
            timeout=15,
        )
        resp.raise_for_status()
        results = resp.json()
    except httpx.HTTPError as exc:
        log.warning("Impossible de localiser « %s » : %s", city, exc)
        return None, None, None
    if not results:
        log.warning("Commune « %s » introuvable : recherche sur toute la France", city)
        return None, None, None
    commune = results[0]
    lng, lat = commune["centre"]["coordinates"]
    log.info("Localisation : %s (INSEE %s)", commune["nom"], commune["code"])
    return commune["code"], lat, lng


def fetch_all(settings: Settings, profile: Profile) -> tuple[list[Job], dict[str, str]]:
    """Renvoie toutes les offres récupérées et un état par source (pour le mail)."""
    code, lat, lng = resolve_city(settings.city)
    ctx = SearchContext(
        settings=settings,
        profile=profile,
        now=datetime.now(timezone.utc),
        city_code=code,
        lat=lat,
        lng=lng,
    )

    status: dict[str, str] = {}
    active: list[Source] = []
    for name in settings.sources:
        cls = SOURCE_CLASSES.get(name)
        if cls is None:
            log.warning("Source inconnue ignorée : %s", name)
            continue
        if cls.remote_only and not settings.include_remote:
            continue
        source = cls(ctx)
        if not source.is_configured():
            source.http.close()
            status[name] = "non configurée"
            log.info("Source %s ignorée : identifiants manquants", name)
            continue
        active.append(source)

    def run(source: Source) -> list[Job]:
        try:
            jobs = source.fetch()
            status[source.name] = f"{len(jobs)} offres"
            log.info("%s : %d offres", source.name, len(jobs))
            return jobs
        except Exception as exc:  # une source en panne ne doit pas bloquer les autres
            # Seuls nos messages sont affichés : ceux de httpx peuvent contenir des clés API.
            detail = str(exc) if isinstance(exc, SourceError) else exc.__class__.__name__
            status[source.name] = f"erreur : {detail}"
            log.exception("Échec de la source %s", source.name)
            return []
        finally:
            source.http.close()

    with ThreadPoolExecutor(max_workers=len(active) or 1) as pool:
        results = list(pool.map(run, active))
    return [job for jobs in results for job in jobs], status
