# ─────────────────────────────────────────────────────────────────────────────
# Stage 1: Build the email-builder sub-frontend
# ─────────────────────────────────────────────────────────────────────────────
FROM node:22-alpine AS email-builder

WORKDIR /app/frontend/email-builder

# Install deps (copy lockfiles first for layer caching)
COPY frontend/email-builder/package.json frontend/email-builder/yarn.lock ./
RUN yarn install --frozen-lockfile

# Copy full email-builder source and build
COPY frontend/email-builder/ ./
ARG LISTMONK_VERSION=v0.0.0
RUN VUE_APP_VERSION=${LISTMONK_VERSION} yarn build

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2: Build the main Vue frontend
# ─────────────────────────────────────────────────────────────────────────────
FROM node:22-alpine AS frontend-builder

WORKDIR /app

# Install deps
# The postinstall script copies altcha.umd.cjs to ../static/public/static/,
# so that directory must exist before yarn install runs.
COPY frontend/package.json frontend/yarn.lock frontend/
RUN mkdir -p static/public/static && cd frontend && yarn install --frozen-lockfile

# Copy the email-builder output into the expected location before the main build
COPY --from=email-builder /app/frontend/email-builder/dist/ frontend/public/static/email-builder/

# Copy the rest of the frontend source
COPY frontend/ frontend/

ARG LISTMONK_VERSION=v0.0.0
# ESLint is configured with --ignore-path .gitignore, but .gitignore is excluded
# by .dockerignore. Create a stub so ESLint doesn't abort.
RUN touch frontend/.gitignore && cd frontend && VUE_APP_VERSION=${LISTMONK_VERSION} yarn build

# ─────────────────────────────────────────────────────────────────────────────
# Stage 3: Build the Go binary + embed all static assets with stuffbin
# ─────────────────────────────────────────────────────────────────────────────
FROM golang:1.26-alpine AS go-builder

RUN apk --no-cache add git

WORKDIR /app

# Download Go module deps first (cache layer)
COPY go.mod go.sum ./
RUN go mod download

# Install stuffbin
RUN go install github.com/knadh/stuffbin/...

# Copy all source files
COPY cmd/ cmd/
COPY internal/ internal/
COPY models/ models/
COPY queries/ queries/

# Copy static assets that get embedded
COPY config.toml.sample ./
COPY schema.sql ./
COPY permissions.json ./
COPY static/ static/
COPY i18n/ i18n/

# Copy built frontend dist from stage 2
COPY --from=frontend-builder /app/frontend/dist/ frontend/dist/

# Build the Go binary
ARG LISTMONK_VERSION=v0.0.0
ARG LAST_COMMIT=unknown
ARG BUILDDATE=unknown
RUN CGO_ENABLED=0 go build \
    -o listmonk \
    -ldflags="-s -w \
      -X 'main.buildString=${LISTMONK_VERSION} (#${LAST_COMMIT} ${BUILDDATE})' \
      -X 'main.versionString=${LISTMONK_VERSION}'" \
    cmd/*.go

# Pack all static assets into the binary using stuffbin
# This mirrors the STATIC variable in the Makefile exactly.
RUN stuffbin -a stuff -in listmonk -out listmonk \
    config.toml.sample \
    schema.sql \
    "queries:/queries" \
    permissions.json \
    "static/public:/public" \
    static/email-templates \
    "frontend/dist:/admin" \
    "i18n:/i18n"

# ─────────────────────────────────────────────────────────────────────────────
# Stage 4: Minimal runtime image
# ─────────────────────────────────────────────────────────────────────────────
FROM alpine:latest

RUN apk --no-cache add ca-certificates tzdata shadow su-exec

WORKDIR /listmonk

# Copy only the self-contained binary and the sample config
COPY --from=go-builder /app/listmonk .
COPY config.toml.sample config.toml

# Copy the entrypoint script
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 9000

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["./listmonk"]
