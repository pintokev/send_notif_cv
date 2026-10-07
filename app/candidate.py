"""Lecture du CV et extraction du profil du candidat par Claude."""

from __future__ import annotations

import base64
import hashlib
import json
import logging
from dataclasses import asdict, dataclass
from io import BytesIO

from pypdf import PdfReader

from .config import Settings
from .llm import structured_call

log = logging.getLogger(__name__)

PROFILE_SCHEMA = {
    "type": "object",
    "properties": {
        "summary": {"type": "string"},
        "job_titles": {"type": "array", "items": {"type": "string"}},
        "search_queries": {"type": "array", "items": {"type": "string"}},
        "keywords": {"type": "array", "items": {"type": "string"}},
        "seniority": {"type": "string"},
        "languages": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["summary", "job_titles", "search_queries", "keywords", "seniority", "languages"],
    "additionalProperties": False,
}

PROFILE_PROMPT = """Analyse ce CV pour alimenter un outil de veille d'offres d'emploi.

Renvoie :
- summary : un résumé factuel du profil en 5 à 10 lignes (postes occupés, années d'expérience, compétences clés, secteurs, diplômes, langues).
- job_titles : les intitulés de postes que ce candidat peut viser de façon réaliste, en français (et en anglais si c'est courant dans son métier).
- search_queries : 3 à 6 requêtes courtes (1 à 3 mots chacune) à taper dans un moteur de recherche d'offres d'emploi pour trouver ces postes. Commence par la plus pertinente.
- keywords : 15 à 40 mots-clés discriminants (technologies, outils, compétences métier, domaines, intitulés) qu'on s'attend à trouver dans une offre qui lui correspond. Un mot-clé = un terme court, pas une phrase.
- seniority : le niveau (junior, confirmé, senior, lead/manager…) avec le nombre d'années d'expérience.
- languages : les langues parlées avec le niveau."""


@dataclass
class Profile:
    summary: str
    job_titles: list[str]
    search_queries: list[str]
    keywords: list[str]
    seniority: str
    languages: list[str]
    cv_text: str = ""
    cv_hash: str = ""


def read_cv_text(pdf_bytes: bytes, path_label: str) -> str:
    reader = PdfReader(BytesIO(pdf_bytes))
    text = "\n".join((page.extract_text() or "") for page in reader.pages).strip()
    if not text:
        log.warning("Aucun texte extrait de %s (PDF scanné ?) : Claude lira directement le PDF", path_label)
    return text


def load_profile(settings: Settings, refresh: bool = False) -> Profile:
    """Renvoie le profil, en le recalculant seulement si le CV ou le modèle a changé."""
    if not settings.cv_path.exists():
        raise FileNotFoundError(f"CV introuvable : {settings.cv_path}")
    pdf_bytes = settings.cv_path.read_bytes()
    cv_hash = hashlib.sha256(pdf_bytes + settings.claude_model.encode()).hexdigest()
    cache_path = settings.data_dir / "profile.json"

    profile: Profile | None = None
    if cache_path.exists() and not refresh:
        cached = json.loads(cache_path.read_text(encoding="utf-8"))
        if cached.get("cv_hash") == cv_hash:
            profile = Profile(**cached)
            log.info("Profil chargé depuis le cache")

    if profile is None:
        log.info("Analyse du CV par Claude (%s)…", settings.claude_model)
        cv_text = read_cv_text(pdf_bytes, str(settings.cv_path))
        data = structured_call(
            model=settings.claude_model,
            system="Tu es un recruteur expérimenté qui analyse des CV avec précision.",
            content=[
                {
                    "type": "document",
                    "source": {
                        "type": "base64",
                        "media_type": "application/pdf",
                        "data": base64.standard_b64encode(pdf_bytes).decode(),
                    },
                },
                {"type": "text", "text": PROFILE_PROMPT},
            ],
            schema=PROFILE_SCHEMA,
            effort="medium",
        )
        # Si le PDF n'a pas de couche texte, le résumé de Claude sert de CV pour la notation.
        profile = Profile(**data, cv_text=cv_text or data["summary"], cv_hash=cv_hash)
        settings.data_dir.mkdir(parents=True, exist_ok=True)
        cache_path.write_text(json.dumps(asdict(profile), ensure_ascii=False, indent=2), encoding="utf-8")

    return _apply_overrides(profile, settings)


def _apply_overrides(profile: Profile, settings: Settings) -> Profile:
    if settings.search_queries:
        profile.search_queries = list(settings.search_queries)
    profile.search_queries = profile.search_queries[: settings.max_queries]
    seen = {k.lower() for k in profile.keywords}
    profile.keywords += [k for k in settings.extra_keywords if k.lower() not in seen]
    return profile
