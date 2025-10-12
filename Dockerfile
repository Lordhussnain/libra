# Dockerfile for LibreOffice worker (fixed: includes JRE + java-common)
FROM node:20-bullseye-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install LibreOffice, Java (headless) and utilities required by conversions
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      wget \
      gnupg \
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

# Create non-root user for running the worker
RUN useradd -m -s /bin/bash appuser

WORKDIR /home/appuser

# Copy dependency manifests first to maximize build cache
COPY package.json pnpm-lock.yaml ./

# Prepare pnpm and install production deps
RUN set -eux; \
    corepack enable; \
    corepack prepare pnpm@latest --activate; \
    pnpm install --prod --frozen-lockfile

# Copy application code
COPY . .

# Ensure tmp dir exists and set ownership
RUN mkdir -p /home/appuser/tmp && chmod 700 /home/appuser/tmp && chown -R appuser:appuser /home/appuser

# Switch to non-root user
USER appuser

# runtime env
ENV NODE_ENV=production
ENV TMPDIR=/home/appuser/tmp

# healthcheck: ensure soffice is available and responds
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD sh -c "command -v soffice > /dev/null && soffice --version | grep -Ei 'libreoffice|soffice' || exit 1"

# Run the worker
CMD ["node", "worker.js"]

