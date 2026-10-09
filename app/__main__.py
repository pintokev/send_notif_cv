"""Point d'entrée : python -m app <commande>."""

from __future__ import annotations

import argparse
import json
import logging
import sys
from dataclasses import asdict

from .candidate import load_profile
from .config import load_settings
from .mailer import send_email
from .pipeline import run, run_safely, search, search_safely, send, send_safely


def schedule(settings) -> None:
    from apscheduler.schedulers.blocking import BlockingScheduler
    from apscheduler.triggers.cron import CronTrigger

    scheduler = BlockingScheduler(timezone=settings.timezone)

    def daily(job_id: str, func, hour_minute: tuple[int, int]) -> None:
        hour, minute = hour_minute
        scheduler.add_job(
            func,
            CronTrigger(hour=hour, minute=minute, timezone=settings.timezone),
            args=[settings],
            id=job_id,
            misfire_grace_time=3600,
            coalesce=True,
            max_instances=1,
        )

    search_at = settings.search_hour_minute
    if search_at is None:
        daily("daily", run_safely, settings.run_hour_minute)
        logging.info("Planifié tous les jours à %02d:%02d (%s)", *settings.run_hour_minute, settings.timezone)
    else:
        daily("search", search_safely, search_at)
        daily("send", send_safely, settings.run_hour_minute)
        logging.info(
            "Planifié tous les jours : recherche à %02d:%02d, mail à %02d:%02d (%s)",
            *search_at, *settings.run_hour_minute, settings.timezone,
        )
    if settings.run_on_start:
        run_safely(settings)
    scheduler.start()


def main() -> None:
    parser = argparse.ArgumentParser(prog="python -m app", description="Veille d'offres d'emploi à partir d'un CV")
    sub = parser.add_subparsers(dest="command", required=True)
    run_cmd = sub.add_parser("run", help="Lance une recherche maintenant")
    run_cmd.add_argument("--dry-run", action="store_true", help="N'envoie pas le mail : l'affiche et l'enregistre en HTML")
    sub.add_parser("search", help="Recherche et note les offres sans envoyer de mail (elles attendent le prochain envoi)")
    send_cmd = sub.add_parser("send", help="Envoie les offres déjà notées et pas encore envoyées")
    send_cmd.add_argument("--dry-run", action="store_true", help="N'envoie pas le mail : l'affiche et l'enregistre en HTML")
    sub.add_parser("schedule", help="Tourne en continu : recherche à SEARCH_AT (ou RUN_AT) et mail à RUN_AT, chaque jour")
    profile_cmd = sub.add_parser("profile", help="Affiche le profil et les mots-clés déduits du CV")
    profile_cmd.add_argument("--refresh", action="store_true", help="Force une nouvelle analyse du CV")
    sub.add_parser("test-mail", help="Envoie un mail de test pour vérifier la config SMTP")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s : %(message)s",
        stream=sys.stdout,
    )
    for noisy in ("httpx", "httpx2", "httpcore", "anthropic", "apscheduler.executors"):
        logging.getLogger(noisy).setLevel(logging.WARNING)

    settings = load_settings()
    if args.command == "run":
        run(settings, dry_run=args.dry_run)
    elif args.command == "search":
        search(settings)
    elif args.command == "send":
        send(settings, dry_run=args.dry_run)
    elif args.command == "schedule":
        schedule(settings)
    elif args.command == "profile":
        profile = load_profile(settings, refresh=args.refresh)
        data = asdict(profile)
        data.pop("cv_text")
        data.pop("cv_hash")
        print(json.dumps(data, ensure_ascii=False, indent=2))
    elif args.command == "test-mail":
        send_email(settings, "Test – veille d'offres d'emploi", "La configuration SMTP fonctionne.")


if __name__ == "__main__":
    main()
