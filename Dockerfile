# ===========================
# Libra Worker Docker Image
# ===========================
FROM node:20-bullseye-slim

# Install LibreOffice and utilities
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      libreoffice-core \
      libreoffice-writer \
      libreoffice-impress \
      libreoffice-common \
      libreoffice-java-common \
      libreoffice-calc \
      libreoffice-draw \
      poppler-utils \
      imagemagick \
      qpdf \
      ca-certificates \
      wget \
      fonts-dejavu-core \
      gzip \
      unzip \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd -m -s /bin/bash appuser

WORKDIR /home/appuser

# Copy dependency manifests first
COPY package.json pnpm-lock.yaml ./

# Enable corepack & install pnpm
RUN set -eux; \
    corepack enable; \
    corepack prepare pnpm@latest --activate; \
    pnpm install --prod --frozen-lockfile

# Copy the rest of the app
COPY . .

# Make sure tmp dir exists
RUN mkdir -p /home/appuser/tmp && chmod 700 /home/appuser/tmp && chown -R appuser:appuser /home/appuser

# Switch to non-root
USER appuser

# Environment setup
ENV NODE_ENV=production
ENV TMPDIR=/home/appuser/tmp

# Healthcheck to verify LibreOffice
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD soffice --version | grep "LibreOffice" || exit 1

# Start worker
CMD ["node", "worker.js"]


