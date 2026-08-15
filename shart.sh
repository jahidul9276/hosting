#!/usr/bin/env bash
#
# shart.sh — Wolf Host one-command bootstrap & runner
# ============================================================
#  LOCAL (Docker installed):   ./shart.sh          -> docker compose up (full stack)
#  RAILWAY backend service:    ROLE=backend  shart.sh   (auto if service name ~ backend)
#  RAILWAY frontend service:   ROLE=frontend shart.sh   (auto if service name ~ front/web)
#
#  On Railway EVERYTHING is automatic:
#    - PORT is taken from $PORT (Railway injects it)
#    - DATABASE_URL / REDIS_URL are taken from Railway's injected vars
#      and rewritten to the async driver the backend needs
#    - CORS + frontend API url are wired from the public domain
#
#  Flags:  shart.sh --help
#
set -euo pipefail

# ---------- logging ----------
g() { printf '\033[1;32m[shart]\033[0m %s\n' "$*"; }
y() { printf '\033[1;33m[shart]\033[0m %s\n' "$*"; }
r() { printf '\033[1;31m[shart]\033[0m %s\n' "$*"; }

CMD="${1:-}"
ROLE="${ROLE:-}"
FORCE_DOCKER="${FORCE_DOCKER:-0}"

if [ "$CMD" = "--help" ] || [ "$CMD" = "-h" ]; then
  sed -n '3,14p' "$0"
  exit 0
fi

# ---------- Railway detection ----------
if [ -n "${RAILWAY_ENVIRONMENT:-}" ]; then
  IS_RAILWAY=1
  g "Railway environment detected (service: ${RAILWAY_SERVICE_NAME:-unknown})"
else
  IS_RAILWAY=0
fi

# explicit role from CLI
if [ "$CMD" = "backend" ] || [ "$CMD" = "frontend" ]; then
  ROLE="$CMD"
fi

# auto role on Railway from service name
if [ -z "$ROLE" ] && [ "$IS_RAILWAY" = "1" ]; then
  case "${RAILWAY_SERVICE_NAME:-}" in
    *front*|*web*|*client*|*ui*) ROLE=frontend ;;
    *) ROLE=backend ;;
  esac
  g "Auto-selected ROLE=$ROLE from Railway service name"
fi
[ -z "$ROLE" ] && ROLE=backend

# ---------- helpers ----------
rand_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    python3 -c "import secrets;print(secrets.token_hex(32))"
  fi
}

# Railway Postgres URL -> asyncpg driver the backend requires
fix_db_url() {
  local u="${DATABASE_URL:-}"
  [ -z "$u" ] && return
  u="${u/#postgres:/postgresql:}"
  u="${u/#postgresql:/postgresql+asyncpg:}"
  export DATABASE_URL="$u"
}

# ensure redis url carries a db number
fix_redis_url() {
  local u="${REDIS_URL:-}"
  [ -z "$u" ] && return
  if [[ "$u" != */* ]]; then u="${u%/}/0"; fi
  export REDIS_URL="$u"
}

script_dir() { cd "$(dirname "$0")" && pwd; }

# ============================================================
# LOCAL: full stack via docker compose
# ============================================================
run_local_docker() {
  local ROOT; ROOT="$(script_dir)"
  g "Docker detected — launching full Wolf Host stack via docker compose."
  cd "$ROOT"

  if [ ! -f .env ]; then
    if [ -f .env.example ]; then
      cp .env.example .env
    else
      : > .env
    fi
    printf 'SECRET_KEY=%s\n' "$(rand_secret)" >> .env
    y "Created .env (generated SECRET_KEY). Edit it before production use."
  fi

  local DC
  if docker compose version >/dev/null 2>&1; then DC="docker compose"; else DC="docker-compose"; fi

  $DC build
  $DC up -d
  g "Stack is up. Open http://localhost (nginx proxies API + frontend)."
  g "Use: docker compose ps   |   docker compose logs -f backend"
  exit 0
}

# ============================================================
# BACKEND (native / Railway docker image)
# ============================================================
start_backend() {
  g "Starting backend..."
  local SD; SD="$(script_dir)"
  if [ -d "$SD/backend" ]; then cd "$SD/backend"; else cd "$SD"; fi

  fix_db_url
  fix_redis_url
  export PORT="${PORT:-8000}"
  export HOSTNAME="${HOSTNAME:-0.0.0.0}"

  if [ -z "${SECRET_KEY:-}" ]; then
    SECRET_KEY="$(rand_secret)"
    y "SECRET_KEY was empty — generated an ephemeral key."
    y "On Railway, set SECRET_KEY in the service variables so logins survive restarts."
    export SECRET_KEY
  fi
  export CORS_ORIGINS="${CORS_ORIGINS:-*}"

  # install deps only when running outside a built image
  if [ "$IS_RAILWAY" = "0" ] && [ ! -x "$(command -v uvicorn 2>/dev/null || true)" ]; then
    python3 -m venv .venv 2>/dev/null && . .venv/bin/activate || true
    pip install -q -r requirements.txt
  fi

  g "Running DB migrations (alembic)..."
  alembic upgrade head

  g "Seeding database (plans / admin)..."
  python -m app.db.seed || y "seed skipped (already present or DB not ready yet)."

  g "Backend listening on 0.0.0.0:$PORT"
  exec uvicorn app.main:app --host 0.0.0.0 --port "$PORT" --workers "${WEB_CONCURRENCY:-1}"
}

# ============================================================
# FRONTEND (native / Railway docker image)
# ============================================================
start_frontend() {
  g "Starting frontend..."
  local SD; SD="$(script_dir)"

  export PORT="${PORT:-3000}"
  export HOSTNAME="${HOSTNAME:-0.0.0.0}"
  export NEXT_PUBLIC_API_URL="${NEXT_PUBLIC_API_URL:-${BACKEND_URL:-http://localhost:8000}}"

  if [ -f "$SD/server.js" ]; then
    # Railway / docker standalone build: server.js already at image root
    cd "$SD"
    g "Using prebuilt Next.js standalone server."
    exec node server.js
  fi

  # native / not-yet-built
  cd "$SD/frontend"
  if [ -f .next/standalone/server.js ]; then
    cp -r public .next/standalone/ 2>/dev/null || true
    cp -r .next/static .next/standalone/.next/ 2>/dev/null || true
    cd .next/standalone
    g "Using prebuilt standalone server."
    exec node server.js
  fi

  y "No standalone build found — building now (first run only, may take a few minutes)."
  npm install
  npm run build
  exec npm run start -- -p "$PORT"
}

# ============================================================
# dispatch
# ============================================================
if [ "$IS_RAILWAY" = "1" ]; then
  : # never use docker on Railway
elif [ -n "$ROLE" ] && { [ "$ROLE" = "backend" ] || [ "$ROLE" = "frontend" ]; } && [ "$FORCE_DOCKER" != "1" ]; then
  : # explicit native role requested
elif command -v docker >/dev/null 2>&1 && [ "$FORCE_DOCKER" != "0" ]; then
  run_local_docker
else
  y "Docker not found and not on Railway — running native role: $ROLE"
fi

case "$ROLE" in
  frontend) start_frontend ;;
  *)        start_backend  ;;
esac
