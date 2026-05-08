FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

ARG HERMES_REF=v2026.5.7

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates git tini && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch ${HERMES_REF} https://github.com/NousResearch/hermes-agent.git /opt/hermes-agent && \
    cd /opt/hermes-agent && \
    uv pip install --system --no-cache -e ".[all]" && \
    if [ -d web ]; then cd web && npm install --silent && npm run build && cd /opt/hermes-agent; fi && \
    if [ -d ui-tui ]; then cd ui-tui && npm install --silent --no-fund --no-audit --progress=false && npm run build && cd /opt/hermes-agent; fi && \
    rm -rf /opt/hermes-agent/.git /root/.npm

COPY entrypoint.sh /app/entrypoint.sh
COPY health.py /app/health.py
RUN chmod +x /app/entrypoint.sh && mkdir -p /data/.hermes

ENV HOME=/data
ENV HERMES_HOME=/data/.hermes
ENV PORT=8080

ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/app/entrypoint.sh"]
