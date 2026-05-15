FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

ARG HERMES_REF=db84a78e618bf973ffc403ed2e1f8162f2591daa

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      curl ca-certificates git tini unzip \
      fonts-liberation libasound2 libatk-bridge2.0-0 libatk1.0-0 \
      libcairo2 libcups2 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0 \
      libgtk-3-0 libnspr4 libnss3 libpango-1.0-0 libx11-6 libx11-xcb1 \
      libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxkbcommon0 \
      libxrandr2 libxrender1 libxshmfence1 && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

ENV BUN_INSTALL=/usr/local
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/usr/local/bin:${PATH}"

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
COPY scripts/setup-gstack.sh /usr/local/bin/setup-gstack
RUN chmod +x /app/entrypoint.sh /app/shared_state_sync.py /usr/local/bin/hermes-cloud-auth /usr/local/bin/setup-gstack && mkdir -p /data/.hermes

ENV HOME=/data
ENV HERMES_HOME=/data/.hermes
ENV PORT=8080

ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/app/entrypoint.sh"]
