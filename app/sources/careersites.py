"""Sites carrière des entreprises cibles, explorés par Claude avec la recherche web.

Pour chaque entreprise de TARGET_COMPANIES, Claude cherche les offres ouvertes
correspondant au profil (site carrière officiel en priorité). Une offre n'est
gardée que si son lien apparaît réellement dans les pages trouvées par la
recherche : aucun lien inventé ou reconstruit ne peut arriver dans le mail.
"""

from __future__ import annotations

import hashlib
import html
import logging
from concurrent.futures import ThreadPoolExecutor

from ..llm import extract_json, web_research
from ..models import Job
from .base import Source, parse_datetime

log = logging.getLogger(__name__)

MAX_PARALLEL = 3

SYSTEM = """Tu es un assistant de veille emploi. Tu cherches des offres d'emploi réelles et actuellement ouvertes sur le web, en priorité sur le site carrière officiel de l'entreprise demandée.

Règles strictes :
- Chaque URL doit être recopiée exactement telle qu'elle apparaît dans un résultat de recherche ou une page consultée. N'invente, ne devine et ne reconstruis jamais une URL.
- Préfère l'URL de la page de l'offre elle-même ; à défaut, celle de la page qui la liste.
- N'inclus que des offres de l'entreprise demandée (ou de ses filiales), qui semblent encore ouvertes.
- Si tu ne trouves rien de pertinent, renvoie une liste vide : c'est une réponse normale."""

PROMPT = """Entreprise : {company}

Trouve les offres d'emploi actuellement ouvertes chez {company} qui pourraient correspondre à ce candidat.
- Postes visés : {titles}
- Compétences clés : {keywords}
- Niveau : {seniority}
- Localisation : {location}
- Offres récentes de préférence (publiées depuis moins de {days} jours quand la date est visible ; garde l'offre si la date n'est pas indiquée).

Réponds uniquement avec un objet JSON de cette forme, sans texte autour :
{{"offers": [{{"title": "...", "location": "...", "url": "...", "published": "AAAA-MM-JJ ou vide", "contract": "CDI, CDD, stage… ou vide", "summary": "3 à 5 phrases sur les missions et le profil recherché"}}]}}"""


OFFER_FIELDS = ["title", "location", "url", "published", "contract", "summary"]
OFFERS_SCHEMA = {
    "type": "object",
    "properties": {
        "offers": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {field: {"type": "string"} for field in OFFER_FIELDS},
                "required": OFFER_FIELDS,
                "additionalProperties": False,
            },
        }
    },
    "required": ["offers"],
    "additionalProperties": False,
}


def _url_found(url: str, sources_text: str) -> bool:
    if not url.startswith("http"):
        return False
    variants = {url, url.rstrip("/"), html.escape(url)}
    return any(v and v in sources_text for v in variants)


class CareerSitesSource(Source):
    name = "careersites"
    label = "Site carrière"

    def is_configured(self) -> bool:
        return bool(self.ctx.settings.target_companies)

    @property
    def max_days_old(self) -> int:
        return self.ctx.settings.extended_max_days_old

    def fetch(self) -> list[Job]:
        companies = self.ctx.settings.target_companies
        self._costs: list[float] = []
        with ThreadPoolExecutor(max_workers=min(MAX_PARALLEL, len(companies))) as pool:
            results = list(pool.map(self._search_company, companies))
        if self._costs:
            log.info(
                "Sites carrière : coût estimé %.2f $ pour %d entreprises (≈ %.0f $ par mois à ce rythme)",
                sum(self._costs),
                len(companies),
                sum(self._costs) * 30,
            )
        return [job for jobs in results for job in jobs]

    def _location(self) -> str:
        s = self.ctx.settings
        parts = []
        if s.city:
            parts.append(f"{s.city} et alentours (rayon {s.radius_km} km)")
        if s.include_remote or not s.city:
            parts.append("ou en télétravail depuis la France" if s.city else "France ou télétravail")
        return " ".join(parts)

    def _search_company(self, company: str) -> list[Job]:
        s = self.ctx.settings
        profile = self.ctx.profile
        prompt = PROMPT.format(
            company=company,
            titles=", ".join(profile.job_titles),
            keywords=", ".join(profile.keywords[:20]),
            seniority=profile.seniority,
            location=self._location(),
            days=self.max_days_old,
        )
        location = {"country": "FR", "timezone": "Europe/Paris"}
        if s.city:
            location["city"] = s.city
        try:
            research = web_research(
                backend=s.claude_backend,
                model=s.claude_model,
                system=SYSTEM,
                prompt=prompt,
                max_searches=s.career_searches_per_company,
                max_fetches=s.career_searches_per_company + 1,
                user_location=location,
                schema=OFFERS_SCHEMA,
            )
            offers = extract_json(research.text).get("offers", [])
        except Exception:
            log.exception("Recherche sur le site carrière de %s impossible", company)
            return []

        jobs, rejected = [], 0
        for offer in offers:
            url = (offer.get("url") or "").strip()
            if not _url_found(url, research.sources_text):
                rejected += 1
                continue
            job = Job(
                source=self.name,
                source_id=hashlib.sha1(url.encode()).hexdigest()[:16],
                title=offer.get("title", ""),
                company=company,
                location=offer.get("location", ""),
                url=url,
                description=offer.get("summary", ""),
                published_at=parse_datetime(offer.get("published")),
                contract=offer.get("contract", ""),
            )
            if self.is_recent(job.published_at):
                jobs.append(job)
        cost = research.cost_usd
        if cost is not None:
            self._costs.append(cost)
            usage = f"{research.input_tokens // 1000}k tokens lus, ≈ {cost:.2f} $"
        elif s.claude_backend == "subscription":
            usage = "inclus dans l'abonnement"
        else:
            usage = f"{research.input_tokens // 1000}k tokens lus"
        log.info(
            "%s : %d offres trouvées (%d recherches web, %s%s)",
            company,
            len(jobs),
            research.searches,
            usage,
            f", {rejected} écartées car lien non vérifiable" if rejected else "",
        )
        return jobs
