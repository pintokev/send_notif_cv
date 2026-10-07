"""Chargement de la configuration depuis les variables d'environnement (.env)."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

from dotenv import load_dotenv

ALL_SOURCES = ["francetravail", "adzuna", "wttj", "googlejobs", "careersites", "remotive", "remoteok", "jobicy"]


def _str(name: str, default: str = "") -> str:
    return os.getenv(name, default).strip()


def _int(name: str, default: int) -> int:
    value = _str(name)
    return int(value) if value else default


def _bool(name: str, default: bool) -> bool:
    value = _str(name).lower()
    if not value:
        return default
    return value in {"1", "true", "yes", "oui", "on"}


def _list(name: str, default: list[str] | None = None) -> list[str]:
    value = _str(name)
    if not value:
        return list(default or [])
    return [item.strip() for item in value.split(",") if item.strip()]


@dataclass
class Settings:
    # Claude
    claude_model: str = "claude-opus-5-5"

    # CV et profil
    cv_path: Path = Path("/data/cv.pdf")
    data_dir: Path = Path("/data")
    search_queries: list[str] = field(default_factory=list)  # surcharge des requêtes déduites du CV
    extra_keywords: list[str] = field(default_factory=list)
    exclude_keywords: list[str] = field(default_factory=list)
    preferences: str = ""
    max_queries: int = 5

    # Localisation
    city: str = ""
    radius_km: int = 30
    include_remote: bool = True

    # Recherche et sélection
    sources: list[str] = field(default_factory=lambda: list(ALL_SOURCES))
    max_days_old: int = 2
    # Sources à faible volume ou aux dates imprécises (télétravail, Google Jobs, sites carrière)
    extended_max_days_old: int = 7
    prefilter_top_k: int = 60
    min_score: int = 60
    max_results: int = 15

    # Identifiants des sources
    francetravail_client_id: str = ""
    francetravail_client_secret: str = ""
    adzuna_app_id: str = ""
    adzuna_app_key: str = ""
    serpapi_api_key: str = ""
    googlejobs_searches_per_run: int = 6

    # Entreprises cibles : recherche sur leur site carrière + mise en avant dans le mail
    target_companies: list[str] = field(default_factory=list)
    career_searches_per_company: int = 3

    # Email
    smtp_host: str = ""
    smtp_port: int = 587
    smtp_user: str = ""
    smtp_password: str = ""
    smtp_security: str = "starttls"  # starttls | ssl | none
    mail_from: str = ""
    mail_to: list[str] = field(default_factory=list)
    send_if_empty: bool = True
    notify_errors: bool = True

    # Planification
    run_at: str = "21:00"
    timezone: str = "Europe/Paris"
    run_on_start: bool = False

    @property
    def db_path(self) -> Path:
        return self.data_dir / "jobs.sqlite3"

    @property
    def run_hour_minute(self) -> tuple[int, int]:
        hour, _, minute = self.run_at.partition(":")
        return int(hour), int(minute or 0)


def load_settings() -> Settings:
    load_dotenv()
    data_dir = Path(_str("DATA_DIR", "/data"))
    smtp_user = _str("SMTP_USER")
    return Settings(
        claude_model=_str("CLAUDE_MODEL", "claude-opus-5-5"),
        cv_path=Path(_str("CV_PATH", str(data_dir / "cv.pdf"))),
        data_dir=data_dir,
        search_queries=_list("SEARCH_QUERIES"),
        extra_keywords=_list("EXTRA_KEYWORDS"),
        exclude_keywords=_list("EXCLUDE_KEYWORDS"),
        preferences=_str("CANDIDATE_PREFERENCES"),
        max_queries=_int("MAX_QUERIES", 5),
        city=_str("LOCATION_CITY"),
        radius_km=_int("LOCATION_RADIUS_KM", 30),
        include_remote=_bool("INCLUDE_REMOTE", True),
        sources=[s.lower() for s in _list("SOURCES", ALL_SOURCES)],
        max_days_old=_int("MAX_DAYS_OLD", 2),
        extended_max_days_old=_int("EXTENDED_MAX_DAYS_OLD", 7),
        prefilter_top_k=_int("PREFILTER_TOP_K", 60),
        min_score=_int("MIN_SCORE", 60),
        max_results=_int("MAX_RESULTS", 15),
        francetravail_client_id=_str("FRANCETRAVAIL_CLIENT_ID"),
        francetravail_client_secret=_str("FRANCETRAVAIL_CLIENT_SECRET"),
        adzuna_app_id=_str("ADZUNA_APP_ID"),
        adzuna_app_key=_str("ADZUNA_APP_KEY"),
        serpapi_api_key=_str("SERPAPI_API_KEY"),
        googlejobs_searches_per_run=_int("GOOGLEJOBS_SEARCHES_PER_RUN", 6),
        target_companies=_list("TARGET_COMPANIES"),
        career_searches_per_company=_int("CAREER_SEARCHES_PER_COMPANY", 3),
        smtp_host=_str("SMTP_HOST"),
        smtp_port=_int("SMTP_PORT", 587),
        smtp_user=smtp_user,
        smtp_password=_str("SMTP_PASSWORD"),
        smtp_security=_str("SMTP_SECURITY", "starttls").lower(),
        mail_from=_str("MAIL_FROM", smtp_user),
        mail_to=_list("MAIL_TO"),
        send_if_empty=_bool("SEND_IF_EMPTY", True),
        notify_errors=_bool("NOTIFY_ERRORS", True),
        run_at=_str("RUN_AT", "21:00"),
        timezone=_str("TZ", "Europe/Paris"),
        run_on_start=_bool("RUN_ON_START", False),
    )
