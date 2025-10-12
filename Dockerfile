# Dockerfile.libreoffice — focused PDF -> DOCX worker image (works headless)
FROM node:20-bullseye-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/home/appuser
WORKDIR /home/appuser

# Install Java (headless) + LibreOffice (meta-package) + PDF import filter + helpers
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      openjdk-11-jre-headless \
      libreoffice \
      libreoffice-java-common \
      libreoffice-pdfimport \
      ghostscript \
      poppler-utils \
      qpdf \
      fonts-dejavu-core \
      wget \
      gzip \
      unzip \
      procps \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user for runtime
RUN useradd -m -s /bin/bash appuser

# Copy node manifests (optional — keep if your worker uses node packages)
COPY package.json pnpm-lock.yaml* ./

# Install production deps (if you use node worker.js); keep || true to avoid CI break if no lockfile
RUN set -eux; corepack enable; corepack prepare pnpm@latest --activate; pnpm install --prod --frozen-lockfile || true

# Copy app code
COPY . .

# Ensure LibreOffice has a config dir and tmp dir that appuser owns
RUN mkdir -p $HOME/tmp $HOME/.config/libreoffice/4/user && \
    chmod 700 $HOME/tmp && chown -R appuser:appuser $HOME

USER appuser
ENV NODE_ENV=production
ENV TMPDIR=$HOME/tmp
WORKDIR $HOME

# Lightweight healthcheck for soffice presence
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD sh -c "command -v soffice >/dev/null && soffice --version >/dev/null || exit 1"

# Default command — run your worker (adjust if needed)
CMD ["node", "worker.js"]
# Dockerfile.libreoffice — focused PDF -> DOCX worker image (works headless)
FROM node:20-bullseye-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/home/appuser
WORKDIR /home/appuser

# Install Java (headless) + LibreOffice (meta-package) + PDF import filter + helpers
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      openjdk-11-jre-headless \
      libreoffice \
      libreoffice-java-common \
      libreoffice-pdfimport \
      ghostscript \
      poppler-utils \
      qpdf \
      fonts-dejavu-core \
      wget \
      gzip \
      unzip \
      procps \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user for runtime
RUN useradd -m -s /bin/bash appuser

# Copy node manifests (optional — keep if your worker uses node packages)
COPY package.json pnpm-lock.yaml* ./

# Install production deps (if you use node worker.js); keep || true to avoid CI break if no lockfile
RUN set -eux; corepack enable; corepack prepare pnpm@latest --activate; pnpm install --prod --frozen-lockfile || true

# Copy app code
COPY . .

# Ensure LibreOffice has a config dir and tmp dir that appuser owns
RUN mkdir -p $HOME/tmp $HOME/.config/libreoffice/4/user && \
    chmod 700 $HOME/tmp && chown -R appuser:appuser $HOME

USER appuser
ENV NODE_ENV=production
ENV TMPDIR=$HOME/tmp
WORKDIR $HOME

# Lightweight healthcheck for soffice presence
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD sh -c "command -v soffice >/dev/null && soffice --version >/dev/null || exit 1"

# Default command — run your worker (adjust if needed)
CMD ["node", "worker.js"]
