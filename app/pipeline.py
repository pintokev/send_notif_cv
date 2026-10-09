"""Exécution complète : CV → collecte → préfiltre → notation → mail.

La recherche (collecte, préfiltre, notation) et l'envoi du mail peuvent avoir lieu à des
heures différentes (SEARCH_AT, puis RUN_AT) : les offres notées attendent dans l'historique
SQLite, et le résumé de la recherche (sources, statistiques) dans last_search.json.
"""

from __future__ import annotations

import json
import logging
import time
import traceback
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone

from .candidate import load_profile
from .config import Settings
from .mailer import build_digest, send_email
from .prefilter import prefilter
from .scorer import score_jobs
from .sources import fetch_all
from .storage import Storage

log = logging.getLogger(__name__)

NO_RECENT_SEARCH = (
    "Aucune nouvelle recherche depuis le dernier mail (la machine était peut-être éteinte "
    "à l'heure de la recherche) : offres notées lors des recherches précédentes."
)


@dataclass
class SearchReport:
    """Résumé d'une recherche, affiché en bas du mail."""

    queries: list[str] = field(default_factory=list)
    status: dict[str, str] = field(default_factory=dict)
    stats: str = ""
    searched_at: str = ""
    error: str = ""  # trace de l'erreur si la recherche a échoué
    sent: bool = False  # True une fois le mail correspondant envoyé


def _report_path(settings: Settings):
    return settings.data_dir / "last_search.json"


def _save_report(settings: Settings, report: SearchReport) -> None:
    _report_path(settings).write_text(json.dumps(asdict(report), ensure_ascii=False, indent=2), encoding="utf-8")


def _load_report(settings: Settings) -> SearchReport | None:
    try:
        return SearchReport(**json.loads(_report_path(settings).read_text(encoding="utf-8")))
    except (OSError, ValueError, TypeError):
        return None


def search(settings: Settings) -> SearchReport:
    """Collecte, préfiltre et note les nouvelles offres, qui attendent ensuite l'envoi dans l'historique."""
    started = time.monotonic()
    if settings.claude_backend == "subscription":
        log.info("Claude : via ton abonnement (Claude Code), modèle %s", settings.claude_model)
    else:
        log.info("Claude : via l'API (clé API), modèle %s", settings.claude_model)
    profile = load_profile(settings)
    log.info("Requêtes : %s", ", ".join(profile.search_queries))

    jobs, status = fetch_all(settings, profile)
    storage = Storage(settings.db_path)
    try:
        fresh = storage.filter_new(jobs)
        log.info("%d offres collectées, %d nouvelles", len(jobs), len(fresh))

        candidates = prefilter(
            fresh, profile, settings.prefilter_top_k, settings.exclude_keywords, settings.target_companies
        )
        scored = score_jobs(candidates, profile, settings)
        storage.save_scored(scored)
    finally:
        storage.close()

    stats = (
        f"{len(jobs)} offres collectées, {len(fresh)} nouvelles, {len(candidates)} analysées par Claude, "
        f"{sum(s.score >= settings.min_score for s in scored)} au-dessus du seuil "
        f"(recherche en {time.monotonic() - started:.0f} s)."
    )
    log.info(stats)
    report = SearchReport(
        queries=profile.search_queries,
        status=status,
        stats=stats,
        searched_at=datetime.now(timezone.utc).isoformat(),
    )
    _save_report(settings, report)
    return report


def send(settings: Settings, report: SearchReport | None = None, dry_run: bool = False) -> None:
    """Envoie les meilleures offres notées et pas encore envoyées.

    Sans résumé fourni, reprend celui de la dernière recherche (last_search.json).
    """
    if report is None:
        report = _load_report(settings)
        if report is None or report.sent:
            report = SearchReport(queries=report.queries if report else [], stats=NO_RECENT_SEARCH)

    storage = Storage(settings.db_path)
    try:
        selected = storage.pending(settings.min_score, settings.max_results)
        if not selected and not settings.send_if_empty:
            log.info("Aucune offre à envoyer")
            return

        subject, text, html = build_digest(selected, settings, report.queries, report.status, report.stats)
        if dry_run:
            preview = settings.data_dir / "last_email.html"
            preview.write_text(html, encoding="utf-8")
            print(text)
            log.info("Mode test : mail non envoyé, aperçu HTML dans %s", preview)
            return

        send_email(settings, subject, text, html)
        storage.mark_emailed(selected)
        log.info("Mail envoyé : %d offres", len(selected))
    finally:
        storage.close()

    if report.searched_at:
        report.sent = True
        _save_report(settings, report)


def run(settings: Settings, dry_run: bool = False) -> None:
    """Recherche puis envoi immédiat."""
    send(settings, search(settings), dry_run=dry_run)


def _notify_failure(settings: Settings, details: str) -> None:
    if not settings.notify_errors:
        return
    try:
        send_email(
            settings,
            "⚠️ Échec de la veille d'offres d'emploi",
            "L'exécution quotidienne a échoué :\n\n" + details,
        )
    except Exception:
        log.exception("Impossible d'envoyer le mail d'erreur")


def run_safely(settings: Settings) -> None:
    """Version utilisée par le planificateur : en cas d'erreur, prévient par mail."""
    try:
        run(settings)
    except Exception:
        log.exception("Échec de l'exécution")
        _notify_failure(settings, traceback.format_exc())


def search_safely(settings: Settings) -> None:
    """Recherche planifiée à SEARCH_AT. Une erreur est gardée pour être signalée à l'heure du mail."""
    try:
        search(settings)
    except Exception:
        log.exception("Échec de la recherche")
        _save_report(
            settings,
            SearchReport(searched_at=datetime.now(timezone.utc).isoformat(), error=traceback.format_exc()),
        )


def send_safely(settings: Settings) -> None:
    """Envoi planifié à RUN_AT, après une recherche à SEARCH_AT."""
    try:
        report = _load_report(settings)
        if report is not None and report.error and not report.sent:
            # La recherche a échoué : alerte à la place du mail ; les offres en attente partiront demain
            _notify_failure(settings, f"La recherche de {_local_time(report.searched_at)} a échoué :\n\n{report.error}")
            report.sent = True
            _save_report(settings, report)
            return
        send(settings)
    except Exception:
        log.exception("Échec de l'envoi")
        _notify_failure(settings, traceback.format_exc())


def _local_time(iso: str) -> str:
    try:
        return datetime.fromisoformat(iso).astimezone().strftime("%H:%M")
    except ValueError:
        return "cette nuit"
