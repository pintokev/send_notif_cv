from __future__ import annotations

import html
import re
import unicodedata
from dataclasses import asdict, dataclass
from datetime import datetime


def normalize(text: str) -> str:
    """Minuscules, sans accents ni ponctuation : sert aux comparaisons."""
    text = unicodedata.normalize("NFKD", text or "")
    text = "".join(c for c in text if not unicodedata.combining(c)).lower()
    return re.sub(r"[^a-z0-9+#.]+", " ", text).strip()


def is_target_company(company: str, targets: list[str]) -> bool:
    """Vrai si le nom de l'entreprise contient l'une des entreprises cibles (mot entier)."""
    name = normalize(company)
    return any(
        t and re.search(rf"(?<![a-z0-9]){re.escape(t)}(?![a-z0-9])", name) for t in map(normalize, targets)
    )


_TAG_RE = re.compile(r"<[^>]+>")
_BLOCK_TAG_RE = re.compile(r"</?(p|div|br|li|ul|ol|h[1-6])[^>]*>", re.I)


def html_to_text(raw: str) -> str:
    text = _BLOCK_TAG_RE.sub("\n", raw or "")
    text = html.unescape(_TAG_RE.sub("", text))
    text = re.sub(r"[ \t\xa0]+", " ", text)
    return re.sub(r"\n\s*\n+", "\n", text).strip()


@dataclass
class Job:
    source: str
    source_id: str
    title: str
    company: str
    location: str
    url: str
    description: str
    published_at: datetime | None = None
    remote: bool = False
    contract: str = ""
    salary: str = ""
    origin: str = ""  # site d'origine quand la source est un agrégateur (ex. « LinkedIn » via Google Jobs)

    @property
    def key(self) -> str:
        return f"{self.source}:{self.source_id}"

    @property
    def fingerprint(self) -> str:
        """Identifie la même offre publiée sur plusieurs sites."""
        return f"{normalize(self.title)}|{normalize(self.company)}"

    def to_dict(self) -> dict:
        data = asdict(self)
        data["published_at"] = self.published_at.isoformat() if self.published_at else None
        return data

    @classmethod
    def from_dict(cls, data: dict) -> "Job":
        data = dict(data)
        if data.get("published_at"):
            data["published_at"] = datetime.fromisoformat(data["published_at"])
        return cls(**data)


@dataclass
class ScoredJob:
    job: Job
    score: int
    reason: str
