from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import httpx

from ..candidate import Profile
from ..config import Settings
from ..models import Job

log = logging.getLogger(__name__)

USER_AGENT = "Mozilla/5.0 (compatible; cv-job-alert/1.0)"


class SourceError(RuntimeError):
    """Erreur explicite d'une source, dont le message peut être affiché dans le mail."""


@dataclass
class SearchContext:
    settings: Settings
    profile: Profile
    now: datetime
    city_code: str | None = None  # code INSEE de la commune
    lat: float | None = None
    lng: float | None = None


class Source:
    name = "base"
    label = "base"
    remote_only = False  # source 100 % télétravail : ignorée si INCLUDE_REMOTE=false

    def __init__(self, ctx: SearchContext):
        self.ctx = ctx
        self.http = httpx.Client(timeout=30, headers={"User-Agent": USER_AGENT}, follow_redirects=True)

    def is_configured(self) -> bool:
        return True

    def fetch(self) -> list[Job]:
        raise NotImplementedError

    @property
    def max_days_old(self) -> int:
        return self.ctx.settings.max_days_old

    @property
    def since(self) -> datetime:
        return self.ctx.now - timedelta(days=self.max_days_old)

    def is_recent(self, published_at: datetime | None) -> bool:
        return published_at is None or published_at >= self.since


def parse_datetime(value: str | int | float | None) -> datetime | None:
    if value in (None, ""):
        return None
    try:
        if isinstance(value, (int, float)) or str(value).isdigit():
            return datetime.fromtimestamp(int(value), tz=timezone.utc)
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    except ValueError:
        log.debug("Date illisible : %r", value)
        return None
