# Dockerfile for LibreOffice worker (fixed: includes JRE + java-common)
FROM node:20-bullseye-slim

ENV DEBIAN_FRONTEND=noninteractive

# Add LibreOffice repository for libreoffice-pdfimport
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      wget \
      gnupg \
    && wget -qO - https://deb.libreoffice.org/key.asc | apt-key add - && \
    echo "deb http://deb.libreoffice.org/libreoffice/debian bullseye main" >> /etc/apt/sources.list.d/libreoffice.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      openjdk-11-jre-headless \
      libreoffice-core \
      libreoffice-writer \
      libreoffice-impress \
      libreoffice-common \
      libreoffice-java-common \
      libreoffice-calc \
      libreoffice-draw \
      libreoffice-pdfimport \
      poppler-utils \
      imagemagick \
      qpdf \
      fonts-dejavu-core \
      gzip \
      unzip \
      procps \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash appuser

WORKDIR /home/appuser

COPY package.json pnpm-lock.yaml ./

RUN set -eux; \
    corepack enable; \
    corepack prepare pnpm@latest --activate; \
    pnpm install --prod --frozen-lockfile

COPY . .

RUN mkdir -p /home/appuser/tmp && chmod 700 /home/appuser/tmp && chown -R appuser:appuser /home/appuser

USER appuser

ENV NODE_ENV=production
ENV TMPDIR=/home/appuser/tmp

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD sh -c "command -v soffice > /dev/null && soffice --version | grep -Ei 'libreoffice|soffice' || exit 1"

CMD ["node", "worker.js"]
