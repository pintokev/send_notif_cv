"""Appels à Claude via Claude Code (mode non interactif), avec un abonnement Claude.

Utilisé quand aucune clé API n'est configurée. Claude Code s'authentifie avec le
jeton créé par `claude setup-token` (variable CLAUDE_CODE_OAUTH_TOKEN) ou avec la
session déjà ouverte sur la machine. Chaque appel lance `claude -p` sans outils
(ou seulement la recherche web), sans réglages utilisateur ni plugins.
"""

from __future__ import annotations

import base64
import json
import logging
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

CALL_TIMEOUT = 600  # secondes : une recherche web complète peut prendre plusieurs minutes


class ClaudeCodeError(RuntimeError):
    pass


def _base_command(model: str, system: str, effort: str, schema: dict | None, tools: str) -> list[str]:
    binary = shutil.which("claude")
    if binary is None:
        raise ClaudeCodeError(
            "Claude Code n'est pas installé : impossible d'utiliser l'abonnement "
            "(ou renseigne ANTHROPIC_API_KEY pour passer par l'API)"
        )
    command = [
        binary,
        "-p",
        "--model", model,
        "--effort", effort,
        "--system-prompt", system,
        "--tools", tools,
        "--no-session-persistence",
        # Ni réglages utilisateur, ni plugins, ni serveurs MCP : un appel isolé et reproductible.
        "--setting-sources", "",
        "--strict-mcp-config",
        "--disable-slash-commands",
        "--permission-prompts", "none",
    ]
    if tools:
        command += ["--allowedTools", tools.replace(",", " ")]
    if schema is not None:
        command += ["--json-schema", json.dumps(schema)]
    return command


def _env() -> dict[str, str]:
    env = dict(os.environ)
    # Une clé API (même vide) prendrait le pas sur l'abonnement.
    env.pop("ANTHROPIC_API_KEY", None)
    return env


def _run(command: list[str], prompt: str, cwd: str | None = None) -> list[dict]:
    """Lance Claude Code et renvoie les événements JSON de sa sortie."""
    try:
        proc = subprocess.run(
            command + ["--output-format", "stream-json", "--verbose", prompt],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=CALL_TIMEOUT,
            env=_env(),
            cwd=cwd,
        )
    except subprocess.TimeoutExpired as exc:
        raise ClaudeCodeError(f"Claude Code n'a pas répondu en {CALL_TIMEOUT} s") from exc

    events = []
    for line in proc.stdout.splitlines():
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    result = next((e for e in reversed(events) if e.get("type") == "result"), None)
    if result is None or result.get("is_error") or result.get("subtype") != "success":
        detail = (result or {}).get("result") or proc.stderr.strip()[-500:] or f"code de sortie {proc.returncode}"
        if "not logged in" in detail.lower() or "/login" in detail:
            detail += (
                " → génère un jeton avec `claude setup-token` sur une machine connectée à ton abonnement,"
                " puis mets-le dans CLAUDE_CODE_OAUTH_TOKEN (.env)"
            )
        raise ClaudeCodeError(f"Échec de Claude Code (abonnement) : {detail}")
    return events


def _result(events: list[dict]) -> dict:
    return next(e for e in reversed(events) if e.get("type") == "result")


def structured_call(*, model: str, system: str, content: list[dict] | str, schema: dict, effort: str) -> Any:
    """Équivalent de llm.structured_call : renvoie le JSON validé par le schéma."""
    if isinstance(content, str):
        return _structured(model, system, content, schema, effort)

    # Contenu multi-blocs : le texte est envoyé tel quel, un PDF joint est lu par l'outil Read.
    texts = [block["text"] for block in content if block.get("type") == "text"]
    documents = [block for block in content if block.get("type") == "document"]
    if not documents:
        return _structured(model, system, "\n\n".join(texts), schema, effort)

    with tempfile.TemporaryDirectory() as tmp:
        paths = []
        for i, doc in enumerate(documents):
            path = Path(tmp) / f"document_{i + 1}.pdf"
            path.write_bytes(base64.b64decode(doc["source"]["data"]))
            paths.append(str(path))
        prompt = f"Lis d'abord avec l'outil Read : {', '.join(paths)}.\n\n" + "\n\n".join(texts)
        return _structured(model, system, prompt, schema, effort, tools="Read", cwd=tmp)


def _structured(
    model: str, system: str, prompt: str, schema: dict, effort: str, tools: str = "", cwd: str | None = None
) -> Any:
    events = _run(_base_command(model, system, effort, schema, tools), prompt, cwd=cwd)
    output = _result(events).get("structured_output")
    if output is None:
        raise ClaudeCodeError("Claude Code n'a pas renvoyé de résultat structuré")
    return output


def web_research(
    *, model: str, system: str, prompt: str, max_searches: int, max_fetches: int, schema: dict | None
) -> tuple[str, str, int]:
    """Recherche web via Claude Code. Renvoie (réponse, contenu brut des résultats, nombre de recherches)."""
    # Claude Code n'a pas de plafond de recherches par appel : la limite passe par la consigne.
    prompt += (
        f"\n\nLimites : {max_searches} recherche(s) web et {max_fetches} lecture(s) de page au maximum."
    )
    events = _run(_base_command(model, system, "medium", schema, "WebSearch,WebFetch"), prompt)

    sources, searches = [], 0
    for event in events:
        blocks = (event.get("message") or {}).get("content")
        if not isinstance(blocks, list):
            continue
        for block in blocks:
            if block.get("type") == "tool_use" and block.get("name") == "WebSearch":
                searches += 1
            elif block.get("type") == "tool_result":
                # Résultats de recherche et pages lues : servent à vérifier les liens proposés.
                content = block.get("content")
                sources.append(content if isinstance(content, str) else json.dumps(content, ensure_ascii=False))

    result = _result(events)
    if schema is not None and result.get("structured_output") is not None:
        text = json.dumps(result["structured_output"], ensure_ascii=False)
    else:
        text = result.get("result") or ""
    return text, "\n".join(sources), searches
