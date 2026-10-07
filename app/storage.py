"""Historique SQLite : évite de renoter ou de renvoyer une offre déjà vue."""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .models import Job, ScoredJob

SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
    key TEXT PRIMARY KEY,
    fingerprint TEXT NOT NULL,
    data TEXT NOT NULL,
    score INTEGER NOT NULL,
    reason TEXT NOT NULL,
    scored_at TEXT NOT NULL,
    emailed_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_jobs_fingerprint ON jobs(fingerprint);
CREATE INDEX IF NOT EXISTS idx_jobs_pending ON jobs(emailed_at, score);
"""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


class Storage:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(path)
        self.conn.executescript(SCHEMA)

    def close(self) -> None:
        self.conn.close()

    def filter_new(self, jobs: list[Job]) -> list[Job]:
        """Retire les doublons du lot et les offres déjà notées lors d'un passage précédent."""
        known_keys = {row[0] for row in self.conn.execute("SELECT key FROM jobs")}
        known_fps = {row[0] for row in self.conn.execute("SELECT fingerprint FROM jobs")}
        fresh: list[Job] = []
        for job in jobs:
            if job.key in known_keys or job.fingerprint in known_fps:
                continue
            known_keys.add(job.key)
            known_fps.add(job.fingerprint)
            fresh.append(job)
        return fresh

    def save_scored(self, scored: list[ScoredJob]) -> None:
        now = _now()
        with self.conn:
            self.conn.executemany(
                "INSERT OR IGNORE INTO jobs (key, fingerprint, data, score, reason, scored_at) VALUES (?, ?, ?, ?, ?, ?)",
                [
                    (s.job.key, s.job.fingerprint, json.dumps(s.job.to_dict(), ensure_ascii=False), s.score, s.reason, now)
                    for s in scored
                ],
            )

    def pending(self, min_score: int, limit: int, max_age_days: int = 7) -> list[ScoredJob]:
        """Meilleures offres notées récemment et jamais envoyées par mail."""
        since = (datetime.now(timezone.utc) - timedelta(days=max_age_days)).isoformat()
        rows = self.conn.execute(
            """SELECT data, score, reason FROM jobs
               WHERE emailed_at IS NULL AND score >= ? AND scored_at >= ?
               ORDER BY score DESC, scored_at DESC LIMIT ?""",
            (min_score, since, limit),
        ).fetchall()
        return [ScoredJob(job=Job.from_dict(json.loads(data)), score=score, reason=reason) for data, score, reason in rows]

    def mark_emailed(self, scored: list[ScoredJob]) -> None:
        now = _now()
        with self.conn:
            self.conn.executemany("UPDATE jobs SET emailed_at = ? WHERE key = ?", [(now, s.job.key) for s in scored])
