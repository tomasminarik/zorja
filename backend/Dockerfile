# Build from repository root: docker build -f backend/Dockerfile -t aurora-offline .
FROM python:3.13.16-slim-bookworm@sha256:a1165e272e578941b84abc79e4ab38a0305cd12803a5c4247979ac7655f4d641
WORKDIR /app
COPY backend/requirements.lock /app/requirements.lock
RUN python -m pip install --no-cache-dir --require-hashes -r /app/requirements.lock \
    && useradd --system --uid 10001 --create-home aurora
COPY backend/src /app/backend/src
COPY api/examples /app/api/examples
COPY api/openapi.json /app/api/openapi.json
ENV PYTHONPATH=/app/backend/src \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    AURORA_PROFILE=mvp \
    AURORA_MODE=offline \
    AURORA_FIXTURE_DIR=/app/api/examples \
    AURORA_HOST=0.0.0.0 \
    AURORA_ALLOW_NETWORK=true \
    AURORA_PORT=8000
USER aurora
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health/live', timeout=2)"]
CMD ["python", "-m", "aurora_backend.cli", "serve"]
