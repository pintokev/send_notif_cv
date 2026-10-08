"""Exécution complète : CV → collecte → préfiltre → notation → mail."""

from __future__ import annotations

import logging
import time
import traceback

from .candidate import load_profile
from .config import Settings
from .mailer import build_digest, send_email
from .prefilter import prefilter
from .scorer import score_jobs
from .sources import fetch_all
from .storage import Storage

log = logging.getLogger(__name__)


def run(settings: Settings, dry_run: bool = False) -> None:
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

        selected = storage.pending(settings.min_score, settings.max_results)
        stats = (
            f"{len(jobs)} offres collectées, {len(fresh)} nouvelles, {len(candidates)} analysées par Claude, "
            f"{sum(s.score >= settings.min_score for s in scored)} au-dessus du seuil "
            f"(exécution en {time.monotonic() - started:.0f} s)."
        )
        log.info(stats)

        if not selected and not settings.send_if_empty:
            log.info("Aucune offre à envoyer")
            return

        subject, text, html = build_digest(selected, settings, profile.search_queries, status, stats)
        if dry_run:
            preview = settings.data_dir / "last_email.html"
            preview.write_text(html, encoding="utf-8")
            print(text)
            log.info("Mode test : mail non envoyé, aperçu HTML dans %s", preview)
            return

        send_email(settings, subject, text, html)
        storage.mark_emailed(selected)
    finally:
        storage.close()


def run_safely(settings: Settings) -> None:
    """Version utilisée par le planificateur : en cas d'erreur, prévient par mail."""
    try:
        run(settings)
    except Exception:
        log.exception("Échec de l'exécution")
        if settings.notify_errors:
            try:
                send_email(
                    settings,
                    "⚠️ Échec de la veille d'offres d'emploi",
                    "L'exécution quotidienne a échoué :\n\n" + traceback.format_exc(),
                )
            except Exception:
                log.exception("Impossible d'envoyer le mail d'erreur")
