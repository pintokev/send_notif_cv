FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TZ=Europe/Paris \
    DATA_DIR=/data \
    # Claude Code (mode abonnement) : pas de mise à jour automatique dans le conteneur,
    # la version est figée à la construction de l'image.
    DISABLE_AUTOUPDATER=1 \
    PATH="/home/appuser/.local/bin:${PATH}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1000 appuser \
    && mkdir -p /data && chown appuser:appuser /data

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Claude Code, utilisé uniquement en mode abonnement (sans clé API)
USER appuser
RUN curl -fsSL https://claude.ai/install.sh | bash && claude --version

COPY app ./app
VOLUME ["/data"]

CMD ["python", "-m", "app", "schedule"]
