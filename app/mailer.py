"""Composition et envoi du mail récapitulatif."""

from __future__ import annotations

import logging
import smtplib
import ssl
from datetime import date
from email.message import EmailMessage
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, select_autoescape

from .config import Settings
from .models import ScoredJob, is_target_company
from .sources import SOURCE_CLASSES

log = logging.getLogger(__name__)

SOURCE_LABELS = {name: cls.label for name, cls in SOURCE_CLASSES.items()}

_env = Environment(
    loader=FileSystemLoader(Path(__file__).parent / "templates"),
    autoescape=select_autoescape(["html"]),
)


def score_color(score: int) -> str:
    if score >= 85:
        return "#0e9f6e"
    if score >= 70:
        return "#3f83f8"
    return "#c27803"


def build_digest(
    jobs: list[ScoredJob], settings: Settings, queries: list[str], status: dict[str, str], stats: str
) -> tuple[str, str, str]:
    """Renvoie (sujet, texte brut, HTML)."""
    today = date.today().strftime("%d/%m/%Y")
    if jobs:
        subject = f"{len(jobs)} nouvelle{'s' if len(jobs) > 1 else ''} offre{'s' if len(jobs) > 1 else ''} pour ton CV – {today}"
    else:
        subject = f"Aucune nouvelle offre pertinente – {today}"
    subtitle = f"Offres notées par Claude au regard de ton CV (score minimum {settings.min_score}/100)"

    html = _env.get_template("email.html").render(
        title=f"Tes offres du {today}",
        subtitle=subtitle,
        jobs=jobs,
        min_score=settings.min_score,
        queries=queries,
        status=status,
        stats=stats,
        source_labels=SOURCE_LABELS,
        score_color=score_color,
        is_target=lambda job: is_target_company(job.company, settings.target_companies),
    )

    lines = [subject, subtitle, ""]
    for item in jobs:
        job = item.job
        star = "⭐ " if is_target_company(job.company, settings.target_companies) else ""
        lines += [
            f"[{item.score}] {star}{job.title} – {job.company} ({job.location})",
            f"    {item.reason}",
            f"    {job.url}",
            "",
        ]
    if not jobs:
        lines.append(f"Aucune nouvelle offre ne dépasse le score minimum de {settings.min_score}.")
    lines += ["", stats]
    return subject, "\n".join(lines), html


def send_email(settings: Settings, subject: str, text: str, html: str | None = None) -> None:
    if not (settings.smtp_host and settings.mail_to and settings.mail_from):
        raise RuntimeError("Configuration SMTP incomplète (SMTP_HOST, MAIL_FROM, MAIL_TO)")

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = settings.mail_from
    msg["To"] = ", ".join(settings.mail_to)
    msg.set_content(text)
    if html:
        msg.add_alternative(html, subtype="html")

    context = ssl.create_default_context()
    if settings.smtp_security == "ssl":
        server: smtplib.SMTP = smtplib.SMTP_SSL(settings.smtp_host, settings.smtp_port, context=context, timeout=30)
    else:
        server = smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=30)
    with server:
        if settings.smtp_security == "starttls":
            server.starttls(context=context)
        if settings.smtp_user:
            server.login(settings.smtp_user, settings.smtp_password)
        server.send_message(msg)
    log.info("Mail envoyé à %s : %s", msg["To"], subject)
