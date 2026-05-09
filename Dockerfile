FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

ARG HERMES_REF=f1f42a7b9ffa83749f725cfdf76b121779859914

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates git tini && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

RUN git clone --filter=blob:none https://github.com/NousResearch/hermes-agent.git /opt/hermes-agent && \
    cd /opt/hermes-agent && \
    git checkout ${HERMES_REF} && \
    uv pip install --system --no-cache -e ".[all]" && \
    if [ -d web ]; then cd web && npm install --silent && npm run build && cd /opt/hermes-agent; fi && \
    if [ -d ui-tui ]; then cd ui-tui && npm install --silent --no-fund --no-audit --progress=false && npm run build && cd /opt/hermes-agent; fi && \
    rm -rf /opt/hermes-agent/.git /root/.npm

COPY entrypoint.sh /app/entrypoint.sh
COPY health.py /app/health.py
COPY shared_state_sync.py /app/shared_state_sync.py
COPY scripts/hermes-cloud-auth.sh /usr/local/bin/hermes-cloud-auth
RUN chmod +x /app/entrypoint.sh /app/shared_state_sync.py /usr/local/bin/hermes-cloud-auth && mkdir -p /data/.hermes

ENV HOME=/data
ENV HERMES_HOME=/data/.hermes
ENV PORT=8080

ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/app/entrypoint.sh"]
