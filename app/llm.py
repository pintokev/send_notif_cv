"""Appels à Claude avec sortie JSON structurée.

Deux modes (réglage CLAUDE_BACKEND) : « api » passe par l'API Anthropic avec une clé
API ; « subscription » passe par Claude Code et un abonnement Claude (voir claude_code.py).
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass
from functools import lru_cache
from typing import Any

import anthropic

from . import claude_code

log = logging.getLogger(__name__)

# Modèles qui acceptent le repli automatique côté serveur en cas de refus.
_FALLBACK_MODELS = {"claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"}
_FALLBACK_BETA = "server-side-fallback-2026-07-01"


class LLMError(RuntimeError):
    pass


@lru_cache(maxsize=1)
def _client() -> anthropic.Anthropic:
    return anthropic.Anthropic(max_retries=4)


def structured_call(
    *,
    backend: str,
    model: str,
    system: str,
    content: list[dict] | str,
    schema: dict,
    effort: str = "low",
    max_tokens: int = 16000,
) -> Any:
    """Envoie une requête et renvoie le JSON validé par le schéma."""
    if backend == "subscription":
        try:
            return claude_code.structured_call(model=model, system=system, content=content, schema=schema, effort=effort)
        except claude_code.ClaudeCodeError as exc:
            raise LLMError(str(exc)) from exc

    kwargs: dict[str, Any] = {}
    if model in _FALLBACK_MODELS:
        kwargs = {"betas": [_FALLBACK_BETA], "fallbacks": "default"}

    response = _client().beta.messages.create(
        model=model,
        max_tokens=max_tokens,
        # Le système (profil + CV) est identique pour tous les lots : on le met en cache.
        system=[{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
        messages=[{"role": "user", "content": content}],
        output_config={"effort": effort, "format": {"type": "json_schema", "schema": schema}},
        **kwargs,
    )

    if response.stop_reason == "refusal":
        category = response.stop_details.category if response.stop_details else None
        raise LLMError(f"Requête refusée par le modèle (catégorie : {category})")
    if response.stop_reason == "max_tokens":
        raise LLMError("Réponse tronquée (max_tokens atteint)")

    text = next((b.text for b in response.content if b.type == "text"), None)
    if text is None:
        raise LLMError(f"Aucune réponse texte (request_id={response._request_id})")
    usage = response.usage
    log.debug(
        "Claude : %s tokens en entrée (%s lus en cache), %s en sortie",
        usage.input_tokens,
        usage.cache_read_input_tokens,
        usage.output_tokens,
    )
    return json.loads(text)


# Modèles qui supportent le filtrage dynamique des résultats web (moins de tokens consommés).
_DYNAMIC_FILTERING_PREFIXES = ("claude-opus-", "claude-sonnet-", "claude-fable-", "claude-mythos-")
_MAX_CONTINUATIONS = 4


# Tarifs publics en $ par million de tokens (entrée, sortie), octobre 2026 : sert uniquement aux logs.
_PRICES = {"claude-opus-5-5": (4.0, 20.0), "claude-sonnet-5-5": (2.0, 10.0), "claude-haiku-5-5": (0.10, 0.50)}
_SEARCH_PRICE = 0.01  # $ par recherche web


@dataclass
class WebResearch:
    text: str  # réponse finale de Claude
    sources_text: str  # contenu brut des résultats de recherche et des pages lues
    searches: int
    input_tokens: int = 0
    cost_usd: float | None = None  # None : tarif inconnu, ou inclus dans l'abonnement


def _estimated_cost(model: str, input_tokens: int, output_tokens: int, searches: int) -> float | None:
    """Coût approximatif en $ d'une recherche via l'API (None si le tarif du modèle est inconnu)."""
    if model not in _PRICES:
        return None
    price_in, price_out = _PRICES[model]
    return (input_tokens * price_in + output_tokens * price_out) / 1e6 + searches * _SEARCH_PRICE


def web_research(
    *,
    backend: str,
    model: str,
    system: str,
    prompt: str,
    max_searches: int,
    max_fetches: int,
    user_location: dict | None = None,
    schema: dict | None = None,
) -> WebResearch:
    """Laisse Claude chercher sur le web (recherche + lecture de pages) et renvoie sa réponse.

    `schema` n'est utilisé qu'en mode abonnement : via l'API, les citations automatiques
    de la recherche web sont incompatibles avec la sortie structurée.
    """
    if backend == "subscription":
        try:
            text, sources_text, searches = claude_code.web_research(
                model=model, system=system, prompt=prompt, max_searches=max_searches,
                max_fetches=max_fetches, schema=schema,
            )
        except claude_code.ClaudeCodeError as exc:
            raise LLMError(str(exc)) from exc
        return WebResearch(text=text, sources_text=sources_text, searches=searches)

    dynamic = model.startswith(_DYNAMIC_FILTERING_PREFIXES)
    search_tool: dict[str, Any] = {
        "type": "web_search_20260209" if dynamic else "web_search_20250305",
        "name": "web_search",
        "max_uses": max_searches,
    }
    if user_location:
        search_tool["user_location"] = {"type": "approximate", **user_location}
    fetch_tool = {
        "type": "web_fetch_20260209" if dynamic else "web_fetch_20250910",
        "name": "web_fetch",
        "max_uses": max_fetches,
        "max_content_tokens": 20000,
    }
    kwargs: dict[str, Any] = {}
    if model in _FALLBACK_MODELS:
        kwargs = {"betas": [_FALLBACK_BETA], "fallbacks": "default"}

    messages: list[dict] = [{"role": "user", "content": prompt}]
    content: list = []
    searches = input_tokens = output_tokens = 0
    for _ in range(_MAX_CONTINUATIONS + 1):
        response = _client().beta.messages.create(
            model=model,
            max_tokens=16000,
            system=system,
            messages=messages,
            tools=[search_tool, fetch_tool],
            output_config={"effort": "medium"},
            **kwargs,
        )
        content.extend(response.content)
        usage = response.usage
        # Les tokens lus depuis le cache sont facturés ~10 fois moins cher : on les compte à 10 %.
        input_tokens += (
            usage.input_tokens + (usage.cache_creation_input_tokens or 0) + (usage.cache_read_input_tokens or 0) // 10
        )
        output_tokens += usage.output_tokens
        server_usage = usage.server_tool_use
        searches += (server_usage.web_search_requests or 0) if server_usage else 0
        if response.stop_reason != "pause_turn":
            break
        # Tour mis en pause par l'API : on renvoie le message tel quel pour qu'elle reprenne.
        messages = [messages[0], {"role": "assistant", "content": content}]

    if response.stop_reason == "refusal":
        raise LLMError("Recherche refusée par le modèle")

    text_parts, source_parts = [], []
    for block in content:
        if block.type == "text":
            text_parts.append(block.text)
        elif block.type not in ("thinking", "redacted_thinking", "server_tool_use"):
            # Résultats de recherche, pages lues, sorties du code de filtrage
            source_parts.append(json.dumps(block.to_dict(), ensure_ascii=False))
    return WebResearch(
        text="".join(text_parts),
        sources_text="\n".join(source_parts),
        searches=searches,
        input_tokens=input_tokens,
        cost_usd=_estimated_cost(model, input_tokens, output_tokens, searches),
    )


def extract_json(text: str) -> Any:
    """Récupère le JSON d'une réponse texte (bloc ```json ou premier objet trouvé)."""
    fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.S)
    candidate = fenced.group(1) if fenced else text[text.find("{") : text.rfind("}") + 1]
    return json.loads(candidate)
