# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------------------
# Production image for the Notes API.
#
# Two stages are used for one concrete reason: production dependencies are
# installed in a throw-away stage, so npm's cache, the install logs and any
# build-time tooling never reach the final image. The runtime stage receives
# only node_modules + source.
#
# Deliberate decisions:
#  - npm ci (not install)  -> reproducible install from package-lock.json
#  - --omit=dev            -> no Jest/ESLint/Supertest in the shipped image
#  - --ignore-scripts      -> no arbitrary postinstall scripts at build time
#  - USER node (uid 1000)  -> the process cannot write to /app or escalate
#  - code owned by root    -> a compromised process cannot patch its own source
#  - exec-form CMD         -> node is PID 1 and receives SIGTERM directly
# ---------------------------------------------------------------------------

ARG NODE_VERSION=22.22.2

# ---------- Stage 1: production dependencies only ----------
FROM node:${NODE_VERSION}-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund \
    && npm cache clean --force

# ---------- Stage 2: minimal runtime ----------
FROM node:${NODE_VERSION}-alpine AS runtime

# Injected by CI so /health can prove which artefact is live.
ARG APP_VERSION=1.0.0
ARG GIT_SHA=unknown

ENV NODE_ENV=production \
    PORT=3000 \
    HOST=0.0.0.0 \
    APP_VERSION=${APP_VERSION} \
    GIT_SHA=${GIT_SHA} \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NODE_OPTIONS=--enable-source-maps

WORKDIR /app

# Two hardening steps that remove real, scanner-visible attack surface:
#
# 1. `apk upgrade` pulls patched OS packages (notably OpenSSL) that were
#    published after the base image tag was cut. Without it the image ships
#    known-vulnerable libssl3/libcrypto3 even though a fix exists.
# 2. The package managers are deleted from the runtime image. Nothing at
#    runtime installs packages, and npm's bundled dependency tree (tar, pacote,
#    sigstore, brace-expansion, picomatch, ip-address) accounted for the
#    majority of HIGH/CRITICAL findings in a stock node:alpine image. Removing
#    them is strictly better than suppressing those findings in .trivyignore.
RUN apk upgrade --no-cache \
    && rm -rf /usr/local/lib/node_modules/npm \
              /usr/local/lib/node_modules/corepack \
              /opt/yarn-* \
              /usr/local/bin/npm \
              /usr/local/bin/npx \
              /usr/local/bin/corepack \
              /usr/local/bin/yarn \
              /usr/local/bin/yarnpkg \
    && rm -rf /var/cache/apk/*

COPY --from=deps --chown=root:root /app/node_modules ./node_modules
COPY --chown=root:root package.json ./
COPY --chown=root:root src ./src

USER node
EXPOSE 3000
STOPSIGNAL SIGTERM

# Uses the runtime's own fetch - no curl/wget needed in the image.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "src/server.js"]
