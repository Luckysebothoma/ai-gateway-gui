#!/usr/bin/env bash
#
# deploy-aio-ai.sh
#
# All-In-One AI GUI -- CHAT edition (game/worker removed).
#
#   app  : single Node.js container -- serves the static chat frontend AND
#          the API from one codebase, on TWO ports:
#            APP_PORT      (default 8090) -- frontend + API, for browsers
#            BACKEND_PORT  (default 4500) -- API only, same process/DB,
#                          for direct/API-only integrations (e.g. n8n)
#          Talks to the AI Gateway exactly the way a real human client
#          does: POST /v1/chat with {message, session_id}. No synthetic
#          capability hints, no quiz/topic machinery -- the gateway's own
#          classifier/router decides how to handle each message (chat,
#          code, summarization, translation, reasoning, vision-flavored,
#          whatever). This mirrors the DAY5 chat-simulation test exactly,
#          so what passes `simulate` here is what a real user experiences.
#
#   postgres : optional, managed via compose profile. Set
#              POSTGRES_MODE=external in .env to point at an existing
#              Postgres instead. Only stores conversation history
#              (conversations/messages) -- nothing else.
#
# No Docker Swarm, no Docker secrets, no game/topic/question/challenge/
# worker services. Everything is driven directly from .env.
#
# Usage:
#   ./deploy-aio-ai.sh <init|build|up|down|restart|logs|ps|test|simulate|heal|help>
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
if [ -f "${ENV_FILE:-.env}" ]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE:-.env}"
  set +a
fi

APP_DIR="${APP_DIR:-app}"
PROJECT_NAME="${PROJECT_NAME:-ai_gui}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"

REGISTRY="${REGISTRY:-local}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
APP_IMAGE="${APP_IMAGE:-ai-gui-app}"

APP_PORT="${APP_PORT:-8090}"
EXPOSE_BACKEND_PORT="${EXPOSE_BACKEND_PORT:-true}"
BACKEND_PORT="${BACKEND_PORT:-4500}"
LOG_LEVEL="${LOG_LEVEL:-info}"
SELF_HEAL_DB="${SELF_HEAL_DB:-true}"

# managed = compose also runs its own postgres service (profile: managed-db)
# external = connect to a postgres you already run elsewhere
POSTGRES_MODE="${POSTGRES_MODE:-managed}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-ai_gui}"
POSTGRES_USER="${POSTGRES_USER:-ai_gui}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-change_me_in_env}"

PGHOST="${PGHOST:-postgres}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:-${POSTGRES_DB}}"
PGUSER="${PGUSER:-${POSTGRES_USER}}"
PGPASSWORD="${PGPASSWORD:-${POSTGRES_PASSWORD}}"

GATEWAY_HOST="${GATEWAY_HOST:-192.168.0.140}"
DAY3_URL="${DAY3_URL:-http://${GATEWAY_HOST}:4405}"
DAY4_URL="${DAY4_URL:-http://${GATEWAY_HOST}:4406}"
DAY5_URL="${DAY5_URL:-http://${GATEWAY_HOST}:4407}"
DAY6_URL="${DAY6_URL:-http://${GATEWAY_HOST}:4408}"

TEST_HOST="${TEST_HOST:-localhost}"
TEST_RETRIES="${TEST_RETRIES:-20}"
TEST_RETRY_DELAY="${TEST_RETRY_DELAY:-3}"

CONVERSATION_CONTEXT_LIMIT="${CONVERSATION_CONTEXT_LIMIT:-20}"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RESET="\033[0m"; C_GREEN="\033[1;32m"; C_RED="\033[1;31m"
  C_YELLOW="\033[1;33m"; C_BLUE="\033[1;34m"; C_BOLD="\033[1m"; C_CYAN="\033[1;36m"
else
  C_RESET=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_CYAN=""
fi

info()   { printf "%b[INFO]%b  %s\n"  "$C_BLUE"   "$C_RESET" "$*"; }
ok()     { printf "%b[ OK ]%b  %s\n"  "$C_GREEN"  "$C_RESET" "$*"; }
warn()   { printf "%b[WARN]%b  %s\n"  "$C_YELLOW" "$C_RESET" "$*"; }
err()    { printf "%b[FAIL]%b  %s\n"  "$C_RED"    "$C_RESET" "$*" >&2; }
header() { printf "%b%s%b\n" "$C_BOLD" "$*" "$C_RESET"; }
die()    { err "$*"; exit 1; }

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH."
  docker info >/dev/null 2>&1 || die "docker daemon is not reachable (permission or service down?)."
}
require_curl() { command -v curl >/dev/null 2>&1 || die "curl is required."; }
require_jq()   { command -v jq   >/dev/null 2>&1 || die "jq is required."; }

DC_BIN=""
resolve_compose_bin() {
  if [ -n "$DC_BIN" ]; then return 0; fi
  if docker compose version >/dev/null 2>&1; then
    DC_BIN="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    DC_BIN="docker-compose"
  else
    die "neither 'docker compose' (plugin) nor 'docker-compose' (binary) is available."
  fi
}

profile_flags() {
  if [ "${POSTGRES_MODE}" = "managed" ]; then
    echo "--profile managed-db"
  else
    echo ""
  fi
}

DC() {
  resolve_compose_bin
  # shellcheck disable=SC2046
  $DC_BIN -p "${PROJECT_NAME}" -f "${COMPOSE_FILE}" $(profile_flags) "$@"
}

# ===========================================================================
# init -- scaffold the project
# ===========================================================================
write_if_missing() {
  local path="$1"
  if [ -f "$path" ]; then
    warn "exists, skipping: ${path}"
    cat >/dev/null
  else
    mkdir -p "$(dirname "$path")"
    cat > "$path"
    ok "created: ${path}"
  fi
}

# Everything that affects behavior always gets regenerated on init,
# INCLUDING the frontend. This is the fix for the drift bug that left a
# stale, mismatched frontend on disk across re-inits: source of truth is
# this script, full stop.
write_always() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path"
  ok "regenerated: ${path}"
}

cmd_init() {
  header "==> Initializing ${APP_DIR}/"
  mkdir -p "${APP_DIR}/lib" "${APP_DIR}/db" "${APP_DIR}/public"
  ok "directory structure ready"

  # ---- .env.example -------------------------------------------------------
  write_if_missing ".env.example" <<EOF
# Copy to .env next to deploy-aio-ai.sh and edit.
APP_DIR=${APP_DIR}
PROJECT_NAME=${PROJECT_NAME}
COMPOSE_FILE=${COMPOSE_FILE}

REGISTRY=local
IMAGE_TAG=latest
APP_IMAGE=ai-gui-app

# Browser-facing port (frontend + API)
APP_PORT=${APP_PORT}
# API-only port on the SAME process/DB -- for direct/API-only integrations
# such as n8n HTTP nodes that should not need to change their URL.
EXPOSE_BACKEND_PORT=true
BACKEND_PORT=${BACKEND_PORT}

LOG_LEVEL=info
SELF_HEAL_DB=true

# managed = compose also runs its own postgres (profile: managed-db)
# external = connect to a postgres you already run elsewhere
POSTGRES_MODE=managed
POSTGRES_PORT=5432
POSTGRES_DB=ai_gui
POSTGRES_USER=ai_gui
POSTGRES_PASSWORD=change_me_in_env

# Connection details the app actually uses. For POSTGRES_MODE=managed
# leave PGHOST=postgres (the compose service name). For
# POSTGRES_MODE=external point these at your existing database, e.g.:
#   PGHOST=192.168.0.140
#   PGPORT=8063
#   PGDATABASE=ai_gui
#   PGUSER=opentts
#   PGPASSWORD=<real password>
PGHOST=postgres
PGPORT=5432
PGDATABASE=ai_gui
PGUSER=ai_gui
PGPASSWORD=change_me_in_env

# AI Gateway. DAY5 is the chat endpoint (POST /v1/chat); DAY3/4/6 are only
# used for health/dependency reporting and session bootstrap (DAY4).
GATEWAY_HOST=192.168.0.140
DAY3_URL=http://192.168.0.140:4405
DAY4_URL=http://192.168.0.140:4406
DAY5_URL=http://192.168.0.140:4407
DAY6_URL=http://192.168.0.140:4408

TEST_HOST=localhost
TEST_RETRIES=20
TEST_RETRY_DELAY=3

# How many prior messages the frontend renders on reload / conversation
# history requests.
CONVERSATION_CONTEXT_LIMIT=20
EOF

  # ---- package.json -------------------------------------------------------
  write_always "${APP_DIR}/package.json" <<'EOF'
{
  "name": "ai-gui-app",
  "version": "3.0.0",
  "private": true,
  "description": "All-in-one AI GUI: unified Node server (frontend + API), dual-port (browser + backend/n8n), self-healing schema, persisted chat history. Talks to the AI Gateway the way a real client does: POST /v1/chat with {message, session_id} only.",
  "main": "index.js",
  "scripts": { "start": "node index.js" },
  "dependencies": {
    "cors": "^2.8.5",
    "express": "^4.19.2",
    "pg": "^8.12.0",
    "prom-client": "^15.1.3",
    "winston": "^3.13.0",
    "axios": "^1.7.4",
    "uuid": "^9.0.1"
  }
}
EOF

  # ---- lib/logger.js --------------------------------------------------------
  write_always "${APP_DIR}/lib/logger.js" <<'EOF'
'use strict';
const winston = require('winston');

const logger = winston.createLogger({
  level: process.env.LOG_LEVEL || 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.errors({ stack: true }),
    winston.format.json()
  ),
  defaultMeta: { service: 'ai-gui-app' },
  transports: [new winston.transports.Console()],
});

module.exports = logger;
EOF

  # ---- lib/db.js (self-healing schema: conversations + messages only) ----
  write_always "${APP_DIR}/lib/db.js" <<'EOF'
'use strict';
const { Pool } = require('pg');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const logger = require('./logger');

const SELF_HEAL_DB = String(process.env.SELF_HEAL_DB || 'true') === 'true';

const MANAGED_TABLES = ['messages', 'conversations', 'schema_meta'];

const pool = new Pool({
  host: process.env.PGHOST || 'postgres',
  port: parseInt(process.env.PGPORT || '5432', 10),
  database: process.env.PGDATABASE || 'ai_gui',
  user: process.env.PGUSER || 'ai_gui',
  password: process.env.PGPASSWORD || '',
  max: 10,
  idleTimeoutMillis: 30000,
});

pool.on('error', (e) => logger.error('unexpected postgres error', { error: e.message }));

async function query(text, params) {
  const start = Date.now();
  const res = await pool.query(text, params);
  logger.debug('db query', { text, ms: Date.now() - start, rows: res.rowCount });
  return res;
}

async function waitForConnection(maxAttempts, delayMs) {
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      await pool.query('SELECT 1');
      logger.info('postgres connection established', { attempt });
      return true;
    } catch (e) {
      logger.warn('postgres not ready yet, retrying', { attempt, maxAttempts, error: e.message });
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
  return false;
}

function checksumOf(text) {
  return crypto.createHash('sha256').update(text, 'utf8').digest('hex');
}

async function dropManagedObjects() {
  logger.warn('self-heal: dropping managed tables for a clean rebuild');
  await pool.query('DROP VIEW IF EXISTS conversation_activity CASCADE');
  for (const t of MANAGED_TABLES) await pool.query(`DROP TABLE IF EXISTS ${t} CASCADE`);
}

async function schemaLooksHealthy() {
  const expectedColumns = {
    conversations: ['id', 'player_id', 'title', 'created_at', 'updated_at'],
    messages: ['id', 'conversation_id', 'role', 'content', 'provider', 'metadata', 'created_at'],
  };
  for (const [table, cols] of Object.entries(expectedColumns)) {
    let r;
    try {
      r = await pool.query(`SELECT column_name FROM information_schema.columns WHERE table_name = $1`, [table]);
    } catch (e) {
      logger.error('self-heal: schema introspection failed', { table, error: e.message });
      return false;
    }
    if (r.rowCount === 0) { logger.warn('self-heal: missing table detected', { table }); return false; }
    const present = new Set(r.rows.map((row) => row.column_name));
    const missing = cols.filter((c) => !present.has(c));
    if (missing.length > 0) { logger.warn('self-heal: missing column(s) detected', { table, missing }); return false; }
  }
  return true;
}

async function ensureSchema(force) {
  const schemaPath = path.join(__dirname, '..', 'db', 'schema.sql');
  const schemaSql = fs.readFileSync(schemaPath, 'utf8');
  const checksum = checksumOf(schemaSql);

  await pool.query(`
    CREATE TABLE IF NOT EXISTS schema_meta (
      id INTEGER PRIMARY KEY DEFAULT 1,
      checksum VARCHAR(64) NOT NULL,
      applied_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      CONSTRAINT schema_meta_singleton CHECK (id = 1)
    );
  `);

  const metaRes = await pool.query('SELECT checksum FROM schema_meta WHERE id = 1');
  const storedChecksum = metaRes.rowCount > 0 ? metaRes.rows[0].checksum : null;
  const healthy = storedChecksum ? await schemaLooksHealthy() : false;

  if (!force && storedChecksum === checksum && healthy) {
    logger.info('schema up to date, no changes needed', { checksum });
    return { healed: false, checksum };
  }

  if (!SELF_HEAL_DB && !force) {
    logger.warn('schema drift detected but SELF_HEAL_DB=false; applying non-destructively', { storedChecksum, checksum, healthy });
    await pool.query(schemaSql);
    await pool.query(
      `INSERT INTO schema_meta (id, checksum, applied_at) VALUES (1, $1, now())
       ON CONFLICT (id) DO UPDATE SET checksum = EXCLUDED.checksum, applied_at = now()`,
      [checksum]
    );
    return { healed: false, checksum };
  }

  logger.warn('self-heal: schema missing, drifted, or forced -- rebuilding managed tables', { storedChecksum, checksum, healthy, forced: !!force });
  await dropManagedObjects();
  await pool.query(schemaSql);
  await pool.query(
    `INSERT INTO schema_meta (id, checksum, applied_at) VALUES (1, $1, now())
     ON CONFLICT (id) DO UPDATE SET checksum = EXCLUDED.checksum, applied_at = now()`,
    [checksum]
  );
  logger.info('self-heal: schema rebuilt successfully', { checksum });
  return { healed: true, checksum };
}

module.exports = { pool, query, waitForConnection, ensureSchema, schemaLooksHealthy };
EOF

  # ---- lib/gateway.js (real-client chat call: message + session_id only) -
  write_always "${APP_DIR}/lib/gateway.js" <<'EOF'
'use strict';
const axios = require('axios');
const logger = require('./logger');

const DAY3_URL = process.env.DAY3_URL || 'http://192.168.0.140:4405';
const DAY4_URL = process.env.DAY4_URL || 'http://192.168.0.140:4406';
const DAY5_URL = process.env.DAY5_URL || 'http://192.168.0.140:4407';
const DAY6_URL = process.env.DAY6_URL || 'http://192.168.0.140:4408';

const client = axios.create({ timeout: 60000 });

async function health() {
  const targets = { day3: `${DAY3_URL}/health`, day4: `${DAY4_URL}/health`, day5: `${DAY5_URL}/health`, day6: `${DAY6_URL}/health` };
  const out = {};
  await Promise.all(Object.entries(targets).map(async ([k, url]) => {
    try {
      const r = await client.get(url, { timeout: 5000 });
      out[k] = { available: r.status === 200, url };
    } catch (e) {
      out[k] = { available: false, url, error: e.message };
    }
  }));
  return out;
}

async function capabilities() {
  const r = await client.get(`${DAY5_URL}/v1/capabilities`, { timeout: 8000 });
  return r.data;
}

async function ensureSession(userId, agentName, metadata) {
  try {
    const r = await client.post(`${DAY4_URL}/v1/session`, { user_id: userId, agent_name: agentName, metadata });
    return r.data.session_id || null;
  } catch (e) {
    logger.warn('day4 session creation failed, continuing without context', { error: e.message });
    return null;
  }
}

// This is the ONLY content-generation call the app makes, and it is
// deliberately shaped exactly like the DAY5 chat-simulation test sends
// it: {message, session_id}. No capability_hint, no quiz/topic params --
// the gateway's own classifier decides how to route it (chat, code,
// summarization, translation, reasoning, vision-flavored, etc).
async function chat({ message, sessionId }) {
  const r = await client.post(`${DAY5_URL}/v1/chat`, {
    message,
    session_id: sessionId,
  });
  return r.data; // expected shape: { success, response, provider, ... }
}

module.exports = { DAY3_URL, DAY4_URL, DAY5_URL, DAY6_URL, health, capabilities, ensureSession, chat };
EOF

  # ---- db/schema.sql (conversations + messages only) ----------------------
  write_always "${APP_DIR}/db/schema.sql" <<'EOF'
-- Chat-only schema. There is no game content here at all -- topics,
-- questions, challenges, scores, and the worker that used to produce them
-- have been removed. Content comes entirely from the AI Gateway's
-- POST /v1/chat, called per-turn exactly the way a real client would.

CREATE TABLE IF NOT EXISTS conversations (
    id            VARCHAR(64) PRIMARY KEY,
    player_id     VARCHAR(64),
    title         VARCHAR(160),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS messages (
    id              SERIAL PRIMARY KEY,
    conversation_id VARCHAR(64) NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    role            VARCHAR(16) NOT NULL,      -- 'user' | 'assistant' | 'system'
    content         TEXT NOT NULL,
    provider        VARCHAR(64),               -- which model/provider answered, if known
    metadata        JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_messages_conversation_id ON messages(conversation_id);
CREATE INDEX IF NOT EXISTS idx_conversations_player_id  ON conversations(player_id);

CREATE OR REPLACE VIEW conversation_activity AS
SELECT c.id, c.player_id, c.title, c.created_at, c.updated_at,
       COUNT(m.id) AS message_count,
       MAX(m.created_at) AS last_message_at
FROM conversations c
LEFT JOIN messages m ON m.conversation_id = c.id
GROUP BY c.id, c.player_id, c.title, c.created_at, c.updated_at
ORDER BY last_message_at DESC NULLS LAST;
EOF

  # ---- index.js (unified server: static chat frontend + chat API) --------
  write_always "${APP_DIR}/index.js" <<'EOF'
'use strict';

const path = require('path');
const fs = require('fs');
const express = require('express');
const cors = require('cors');
const client = require('prom-client');
const { v4: uuidv4 } = require('uuid');

const logger = require('./lib/logger');
const db = require('./lib/db');
const gateway = require('./lib/gateway');

const PORT = process.env.APP_PORT || process.env.PORT || 8090;
const BACKEND_PORT = process.env.EXPOSE_BACKEND_PORT === 'true' ? (process.env.BACKEND_PORT || null) : null;
const CONTEXT_LIMIT = parseInt(process.env.CONVERSATION_CONTEXT_LIMIT || '20', 10);
const PUBLIC_DIR = path.join(__dirname, 'public');

const app = express();
app.use(cors());
app.use(express.json({ limit: '1mb' }));

app.use((req, res, next) => {
  req.request_id = uuidv4();
  const start = Date.now();
  res.on('finish', () => {
    logger.info('request', {
      request_id: req.request_id, method: req.method, path: req.path,
      status: res.statusCode, ms: Date.now() - start,
    });
  });
  next();
});

// ---------------------------------------------------------------------------
// Prometheus metrics
// ---------------------------------------------------------------------------
const register = new client.Registry();
client.collectDefaultMetrics({ register, prefix: 'ai_gui_' });

const httpRequestsTotal = new client.Counter({
  name: 'ai_gui_http_requests_total', help: 'Total HTTP requests',
  labelNames: ['method', 'route', 'status_code'],
});
register.registerMetric(httpRequestsTotal);

const chatTurnsTotal = new client.Counter({
  name: 'ai_gui_chat_turns_total', help: 'Chat turns sent to the gateway',
  labelNames: ['outcome', 'provider'],
});
register.registerMetric(chatTurnsTotal);

const chatLatency = new client.Histogram({
  name: 'ai_gui_chat_latency_ms', help: 'Latency of gateway chat calls in ms',
  buckets: [100, 250, 500, 1000, 2000, 5000, 10000, 20000, 45000],
});
register.registerMetric(chatLatency);

const schemaHealsTotal = new client.Counter({
  name: 'ai_gui_schema_heals_total', help: 'Times self-healing rebuilt managed tables',
});
register.registerMetric(schemaHealsTotal);

app.use((req, res, next) => {
  res.on('finish', () => {
    const route = req.route && req.route.path ? req.route.path : req.path;
    httpRequestsTotal.inc({ method: req.method, route, status_code: res.statusCode });
  });
  next();
});

// ---------------------------------------------------------------------------
// JSON-everywhere guarantee. This is the fix for "Request failed: JSON.parse:
// unexpected character": every /api/* response -- success, 4xx, 5xx, or an
// uncaught throw -- is guaranteed valid JSON. Nothing under /api/ can ever
// hand the frontend an HTML error page or raw text again.
// ---------------------------------------------------------------------------
function fail(res, status, code, message, extra) {
  return res.status(status).json({ success: false, error: { code, message, ...extra } });
}

let dbReady = false;

app.use((req, res, next) => {
  if (!dbReady && req.path.startsWith('/api/') && req.path !== '/api/health') {
    return fail(res, 503, 'DB_NOT_READY', 'Database is still initializing, try again shortly');
  }
  next();
});

// ---------------------------------------------------------------------------
// Meta / capability endpoints
// ---------------------------------------------------------------------------
app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', service: 'ai-gui-app', dbReady, uptimeSeconds: process.uptime() });
});

app.get('/api/ready', async (req, res) => {
  try {
    await db.query('SELECT 1');
    res.json({ ready: true, postgres: true, dbReady });
  } catch (e) {
    res.status(503).json({ ready: false, postgres: false, error: e.message });
  }
});

app.get('/api/dependencies', async (req, res) => {
  const h = await gateway.health();
  res.json({ success: true, ...h });
});

app.get('/api/capabilities', async (req, res) => {
  try {
    const caps = await gateway.capabilities();
    res.json({ success: true, capabilities: caps.capabilities || caps });
  } catch (e) {
    fail(res, 502, 'GATEWAY_UNAVAILABLE', 'Could not reach AI Gateway capabilities', { detail: e.message });
  }
});

// Combined smoke-test endpoint used by `./deploy-aio-ai.sh test`. Includes
// one real end-to-end chat round trip, not just a health ping, so a green
// result actually means "a user can talk to this right now".
app.get('/api/test', async (req, res) => {
  const checks = {};
  let allOk = true;

  try { await db.query('SELECT 1'); checks.database = { ok: true }; }
  catch (e) { checks.database = { ok: false, error: e.message }; allOk = false; }

  try { checks.schema = { ok: await db.schemaLooksHealthy() }; if (!checks.schema.ok) allOk = false; }
  catch (e) { checks.schema = { ok: false, error: e.message }; allOk = false; }

  try {
    const h = await gateway.health();
    checks.gateway = { ok: Object.values(h).some((x) => x.available), detail: h };
  } catch (e) {
    checks.gateway = { ok: false, error: e.message }; allOk = false;
  }

  try {
    const started = Date.now();
    const result = await gateway.chat({ message: 'ping', sessionId: `selftest-${Date.now()}` });
    const ms = Date.now() - started;
    const ok = !!(result && result.success !== false && typeof result.response === 'string' && result.response.length > 0);
    checks.chat_roundtrip = { ok, ms, provider: result && result.provider };
    if (!ok) allOk = false;
  } catch (e) {
    checks.chat_roundtrip = { ok: false, error: e.message }; allOk = false;
  }

  checks.ports = { app: Number(PORT), backend: BACKEND_PORT ? Number(BACKEND_PORT) : null };

  res.status(allOk ? 200 : 503).json({ success: allOk, checks });
});

// ---------------------------------------------------------------------------
// Self-healing DB admin
// ---------------------------------------------------------------------------
app.post('/api/admin/self-heal', async (req, res) => {
  try {
    const force = !!(req.body && req.body.force);
    const result = await db.ensureSchema(force);
    if (result.healed) schemaHealsTotal.inc();
    res.json({ success: true, ...result });
  } catch (e) {
    logger.error('manual self-heal failed', { error: e.message });
    fail(res, 500, 'SELF_HEAL_FAILED', 'Self-heal attempt failed', { detail: e.message });
  }
});

app.get('/api/admin/schema-status', async (req, res) => {
  try { res.json({ success: true, healthy: await db.schemaLooksHealthy() }); }
  catch (e) { fail(res, 500, 'SCHEMA_STATUS_FAILED', e.message); }
});

// ---------------------------------------------------------------------------
// Conversations
// ---------------------------------------------------------------------------
async function ensureConversation(sessionId, playerId) {
  await db.query(
    `INSERT INTO conversations (id, player_id) VALUES ($1,$2) ON CONFLICT (id) DO NOTHING`,
    [sessionId, playerId || null]
  );
}

async function appendMessage(conversationId, role, content, provider, metadata) {
  await db.query(
    `INSERT INTO messages (conversation_id, role, content, provider, metadata) VALUES ($1,$2,$3,$4,$5)`,
    [conversationId, role, content, provider || null, metadata ? JSON.stringify(metadata) : null]
  );
  await db.query(`UPDATE conversations SET updated_at = now() WHERE id = $1`, [conversationId]);
}

app.post('/api/session/start', async (req, res) => {
  const { player_id: playerId, title } = req.body || {};
  const sessionId = uuidv4();

  const day4SessionId = await gateway.ensureSession(String(playerId || 'guest'), 'ai-gui-chat', {});

  await db.query(
    `INSERT INTO conversations (id, player_id, title) VALUES ($1,$2,$3)`,
    [sessionId, playerId || null, title || null]
  );

  res.json({ success: true, session_id: sessionId, day4_session_id: day4SessionId, date: new Date().toISOString() });
});

app.get('/api/conversations', async (req, res) => {
  const r = await db.query('SELECT * FROM conversation_activity LIMIT 100');
  res.json({ success: true, conversations: r.rows });
});

app.get('/api/conversations/:session_id/messages', async (req, res) => {
  const { session_id: sessionId } = req.params;
  const limit = Math.min(500, parseInt(req.query.limit, 10) || CONTEXT_LIMIT * 2);
  const r = await db.query(
    `SELECT id, role, content, provider, metadata, created_at FROM messages
     WHERE conversation_id = $1 ORDER BY created_at ASC LIMIT $2`,
    [sessionId, limit]
  );
  res.json({ success: true, session_id: sessionId, messages: r.rows });
});

// ---------------------------------------------------------------------------
// Chat -- the entire capability surface. One turn in, one turn out, exactly
// the way DAY5's simulation script sends it: {message, session_id}. The
// gateway itself decides intent/routing; this app never guesses.
// ---------------------------------------------------------------------------
app.post('/api/chat', async (req, res) => {
  const { session_id: sessionId, message, player_id: playerId } = req.body || {};

  if (!sessionId || typeof sessionId !== 'string') {
    return fail(res, 400, 'INVALID_REQUEST', 'session_id is required (call POST /api/session/start first)');
  }
  if (!message || typeof message !== 'string' || !message.trim()) {
    return fail(res, 400, 'INVALID_REQUEST', 'message is required and must be non-empty');
  }

  await ensureConversation(sessionId, playerId);
  await appendMessage(sessionId, 'user', message, null, null);

  const endTimer = chatLatency.startTimer();
  try {
    const result = await gateway.chat({ message, sessionId });
    endTimer();

    const ok = !!(result && result.success !== false && typeof result.response === 'string');
    if (!ok) {
      chatTurnsTotal.inc({ outcome: 'gateway_error', provider: (result && result.provider) || 'unknown' });
      return fail(res, 502, 'GATEWAY_ERROR', 'Gateway did not return a usable response', { detail: result });
    }

    await appendMessage(sessionId, 'assistant', result.response, result.provider || null, {
      context_degraded: result.context_degraded || false,
    });

    chatTurnsTotal.inc({ outcome: 'ok', provider: result.provider || 'unknown' });

    res.json({
      success: true,
      session_id: sessionId,
      response: result.response,
      provider: result.provider || null,
      context_degraded: result.context_degraded || false,
    });
  } catch (e) {
    endTimer();
    chatTurnsTotal.inc({ outcome: 'exception', provider: 'unknown' });
    logger.error('chat call failed', { error: e.message, session_id: sessionId });
    fail(res, 502, 'GATEWAY_UNAVAILABLE', 'Could not reach the AI Gateway', { detail: e.message });
  }
});

// ---------------------------------------------------------------------------
// help / metrics
// ---------------------------------------------------------------------------
app.get('/help', (req, res) => {
  res.json({
    service: 'ai-gui-app',
    description: 'All-in-one AI GUI, chat-only: unified Node server, dual-port (browser + backend/n8n), self-healing DB, persisted chat history. One capability surface: POST /api/chat, which forwards {message, session_id} to the AI Gateway exactly like a real client would.',
    ports: { app: Number(PORT), backend: BACKEND_PORT ? Number(BACKEND_PORT) : null },
    endpoints: [
      'GET  /help', 'GET  /metrics', 'GET  /api/health', 'GET  /api/ready', 'GET  /api/test',
      'GET  /api/dependencies', 'GET  /api/capabilities',
      'POST /api/admin/self-heal', 'GET  /api/admin/schema-status',
      'POST /api/session/start', 'GET  /api/conversations', 'GET  /api/conversations/:session_id/messages',
      'POST /api/chat',
    ],
  });
});

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

// ---------------------------------------------------------------------------
// Static frontend
// ---------------------------------------------------------------------------
app.use(express.static(PUBLIC_DIR));
app.get('*', (req, res, next) => {
  if (req.path.startsWith('/api/') || req.path === '/metrics' || req.path === '/help') return next();
  const indexFile = path.join(PUBLIC_DIR, 'index.html');
  if (fs.existsSync(indexFile)) return res.sendFile(indexFile);
  res.status(404).send('Not found');
});

// Any unmatched /api/* route -> JSON 404, never Express's default HTML page.
app.use('/api', (req, res) => fail(res, 404, 'NOT_FOUND', `no such endpoint: ${req.method} ${req.path}`));

// Final safety net: any uncaught error anywhere under /api/* becomes JSON,
// never an HTML stack trace that would break the frontend's JSON.parse.
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  logger.error('unhandled error', { error: err.message, path: req.path });
  if (req.path.startsWith('/api/')) {
    return fail(res, 500, 'INTERNAL_ERROR', 'Unexpected server error');
  }
  res.status(500).send('Internal server error');
});

// ---------------------------------------------------------------------------
// Boot: listen immediately on both ports, self-heal schema afterward.
// ---------------------------------------------------------------------------
async function bootstrap() {
  app.listen(PORT, '0.0.0.0', () => logger.info(`ai-gui-app listening on port ${PORT} (frontend + API)`));

  if (BACKEND_PORT && String(BACKEND_PORT) !== String(PORT)) {
    app.listen(BACKEND_PORT, '0.0.0.0', () => logger.info(`ai-gui-app also listening on port ${BACKEND_PORT} (API only, e.g. n8n)`));
  }

  const connected = await db.waitForConnection(30, 2000);
  if (!connected) logger.error('could not reach postgres after retries; will keep retrying in background');

  while (!dbReady) {
    try {
      const result = await db.ensureSchema(false);
      if (result.healed) logger.warn('schema self-heal performed at boot');
      dbReady = true;
      logger.info('database ready');
    } catch (e) {
      logger.error('schema initialization failed, retrying in 5s', { error: e.message });
      await new Promise((r) => setTimeout(r, 5000));
    }
  }
}

bootstrap();
EOF

  # ---- public/index.html (chat UI -- this is the ONLY frontend now) ------
  write_always "${APP_DIR}/public/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>AI Chat</title>
  <link rel="stylesheet" href="style.css" />
</head>
<body>
  <div class="app" id="app">
    <header class="app__header">
      <div class="app__title">
        <span class="app__wave">💬</span>
        <div>
          <h1 id="greeting">AI Chat</h1>
          <p id="fulldate" class="app__date"></p>
        </div>
      </div>
      <div class="app__badges">
        <span id="statusBadge" class="badge">connecting…</span>
        <button id="newChatBtn" class="badge badge--btn" title="Start a new conversation">new chat</button>
      </div>
    </header>

    <section class="panel panel--chat">
      <div id="messages" class="messages"></div>
      <form id="composer" class="composer">
        <input id="messageInput" placeholder="Type your message…" autocomplete="off" />
        <button type="submit" id="sendBtn" class="btn btn--primary">Send</button>
      </form>
    </section>

    <footer class="app__footer"><a href="/help" target="_blank" rel="noopener">API docs</a></footer>
  </div>
  <script src="app.js"></script>
</body>
</html>
EOF

  # ---- public/style.css ----------------------------------------------------
  write_always "${APP_DIR}/public/style.css" <<'EOF'
:root {
  --bg1:#0b1026; --bg2:#1c2456; --accent:#6ee7ff; --panel:#151b3b;
  --text:#f4f6ff; --bad:#ff6b6b; --muted:#8f97c2;
}
* { box-sizing: border-box; }
body {
  margin:0; min-height:100vh; font-family:'Segoe UI',Roboto,Helvetica,Arial,sans-serif; color:var(--text);
  display:flex; justify-content:center; padding:1.5rem 1rem;
  background:radial-gradient(circle at 20% 20%, var(--bg2) 0%, var(--bg1) 60%);
}
.app { width:100%; max-width:720px; display:flex; flex-direction:column; height:calc(100vh - 3rem); }
.app__header { display:flex; justify-content:space-between; align-items:center; margin-bottom:1rem; }
.app__title { display:flex; gap:.75rem; align-items:center; }
.app__wave { font-size:1.8rem; }
.app__header h1 { margin:0; font-size:1.4rem; }
.app__date { margin:.15rem 0 0; opacity:.75; font-size:.85rem; }
.app__badges { display:flex; gap:.5rem; }
.badge {
  background:rgba(255,255,255,.08); border:1px solid var(--accent); color:var(--accent);
  padding:.25rem .7rem; border-radius:999px; font-size:.75rem; white-space:nowrap;
}
.badge--btn { cursor:pointer; }
.badge--btn:hover { background:rgba(255,255,255,.16); }
.panel { background:var(--panel); border-radius:16px; box-shadow:0 10px 30px rgba(0,0,0,.35); }
.panel--chat { flex:1; display:flex; flex-direction:column; overflow:hidden; padding:1rem; }
.messages { flex:1; overflow-y:auto; display:flex; flex-direction:column; gap:.6rem; padding-right:.25rem; }
.msg { max-width:82%; padding:.6rem .9rem; border-radius:14px; line-height:1.4; white-space:pre-wrap; word-wrap:break-word; }
.msg--user { align-self:flex-end; background:var(--accent); color:#0b1026; border-bottom-right-radius:4px; }
.msg--assistant { align-self:flex-start; background:rgba(255,255,255,.08); border-bottom-left-radius:4px; }
.msg--system { align-self:center; background:transparent; color:var(--muted); font-size:.8rem; font-style:italic; }
.msg--error { align-self:flex-start; background:rgba(255,107,107,.15); border:1px solid var(--bad); color:var(--bad); border-bottom-left-radius:4px; }
.msg__meta { display:block; margin-top:.3rem; font-size:.68rem; opacity:.6; }
.composer { display:flex; gap:.5rem; margin-top:.75rem; }
.composer input {
  flex:1; padding:.7rem .9rem; border-radius:10px; border:none; font-size:1rem;
  background:#0f1533; color:var(--text);
}
.composer input:focus { outline:2px solid var(--accent); }
.btn { cursor:pointer; font-weight:600; border:none; border-radius:10px; padding:.7rem 1.2rem; font-size:1rem; }
.btn--primary { background:var(--accent); color:#0b1026; }
.btn--primary:disabled { opacity:.6; cursor:not-allowed; }
.app__footer { text-align:center; opacity:.6; font-size:.8rem; margin-top:.75rem; }
.app__footer a { color:var(--accent); }
.typing { display:inline-flex; gap:3px; align-items:center; }
.typing span { width:6px; height:6px; border-radius:50%; background:var(--muted); animation:blink 1.2s infinite ease-in-out; }
.typing span:nth-child(2) { animation-delay:.2s; }
.typing span:nth-child(3) { animation-delay:.4s; }
@keyframes blink { 0%,80%,100% { opacity:.2; } 40% { opacity:1; } }
EOF

  # ---- public/app.js (chat only -- every parse is guarded) ---------------
  write_always "${APP_DIR}/public/app.js" <<'EOF'
(() => {
  const fulldate = document.getElementById('fulldate');
  const statusBadge = document.getElementById('statusBadge');
  const newChatBtn = document.getElementById('newChatBtn');
  const messagesEl = document.getElementById('messages');
  const composer = document.getElementById('composer');
  const messageInput = document.getElementById('messageInput');
  const sendBtn = document.getElementById('sendBtn');

  let sessionId = localStorage.getItem('ai_gui_session_id') || null;
  let sending = false;

  function renderFullDate() {
    const now = new Date();
    fulldate.textContent = now.toLocaleDateString(undefined, { weekday:'long', year:'numeric', month:'long', day:'numeric' }) + ' — ' + now.toLocaleTimeString();
  }
  renderFullDate(); setInterval(renderFullDate, 30000);

  // Every fetch response goes through this. Never call res.json() directly
  // on an unchecked response -- if the server (or a proxy in front of it)
  // ever returns HTML or plain text, this throws a clear, handled error
  // instead of a cryptic "unexpected character" crash.
  async function fetchJson(url, options) {
    const res = await fetch(url, options);
    const raw = await res.text();
    let data;
    try {
      data = raw ? JSON.parse(raw) : {};
    } catch (e) {
      throw new Error(`Server returned non-JSON (HTTP ${res.status}): ${raw.slice(0, 120)}`);
    }
    if (!res.ok && data && data.error) {
      throw new Error(data.error.message || `HTTP ${res.status}`);
    }
    if (!res.ok) {
      throw new Error(`HTTP ${res.status}`);
    }
    return data;
  }

  function addMessage(role, content, meta) {
    const el = document.createElement('div');
    el.className = `msg msg--${role}`;
    el.textContent = content;
    if (meta) {
      const metaEl = document.createElement('span');
      metaEl.className = 'msg__meta';
      metaEl.textContent = meta;
      el.appendChild(metaEl);
    }
    messagesEl.appendChild(el);
    messagesEl.scrollTop = messagesEl.scrollHeight;
    return el;
  }

  function addTyping() {
    const el = document.createElement('div');
    el.className = 'msg msg--assistant';
    el.innerHTML = '<span class="typing"><span></span><span></span><span></span></span>';
    messagesEl.appendChild(el);
    messagesEl.scrollTop = messagesEl.scrollHeight;
    return el;
  }

  async function ensureSession() {
    if (sessionId) return sessionId;
    statusBadge.textContent = 'starting…';
    const data = await fetchJson('/api/session/start', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({}),
    });
    sessionId = data.session_id;
    localStorage.setItem('ai_gui_session_id', sessionId);
    return sessionId;
  }

  async function loadHistory() {
    if (!sessionId) return;
    try {
      const data = await fetchJson(`/api/conversations/${encodeURIComponent(sessionId)}/messages`);
      messagesEl.innerHTML = '';
      for (const m of data.messages || []) {
        if (m.role === 'user' || m.role === 'assistant') addMessage(m.role, m.content);
      }
    } catch (e) {
      // Non-fatal -- a fresh session just has no history yet.
    }
  }

  async function checkStatus() {
    try {
      const data = await fetchJson('/api/dependencies');
      const anyUp = Object.values(data).some((d) => d && d.available);
      statusBadge.textContent = anyUp ? 'gateway online' : 'gateway unreachable';
    } catch (e) {
      statusBadge.textContent = 'status unknown';
    }
  }

  async function sendMessage(text) {
    if (sending) return;
    sending = true;
    sendBtn.disabled = true;
    addMessage('user', text);
    const typingEl = addTyping();
    try {
      const sid = await ensureSession();
      const data = await fetchJson('/api/chat', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ session_id: sid, message: text }),
      });
      typingEl.remove();
      addMessage('assistant', data.response, data.provider ? `via ${data.provider}` : null);
      if (data.context_degraded) {
        addMessage('system', 'Note: conversation context may be degraded right now.');
      }
    } catch (e) {
      typingEl.remove();
      addMessage('error', `Something went wrong: ${e.message}`);
    } finally {
      sending = false;
      sendBtn.disabled = false;
      messageInput.focus();
    }
  }

  composer.addEventListener('submit', (e) => {
    e.preventDefault();
    const text = messageInput.value.trim();
    if (!text) return;
    messageInput.value = '';
    sendMessage(text);
  });

  newChatBtn.addEventListener('click', () => {
    sessionId = null;
    localStorage.removeItem('ai_gui_session_id');
    messagesEl.innerHTML = '';
    addMessage('system', 'Started a new conversation.');
  });

  (async () => {
    checkStatus();
    setInterval(checkStatus, 30000);
    if (sessionId) await loadHistory();
    if (!messagesEl.children.length) addMessage('system', 'Say hello to get started.');
    messageInput.focus();
  })();
})();
EOF

  # ---- Dockerfile ------------------------------------------------------
  write_always "${APP_DIR}/Dockerfile" <<'EOF'
FROM node:20-alpine

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund

COPY . .

ENV APP_PORT=8090
EXPOSE 8090 4500

HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=5 \
  CMD wget -qO- http://localhost:8090/api/health || exit 1

USER node
CMD ["node", "index.js"]
EOF

  # ---- docker-compose.yml (static; all values come from .env at runtime) -
  write_always "${COMPOSE_FILE}" <<EOF
# Generated by deploy-aio-ai.sh init.
# This file is intentionally static -- every setting is driven by .env at
# runtime via docker-compose's variable substitution / env_file. Edit .env,
# not this file, for day-to-day configuration changes.
version: "3.9"

services:
  app:
    build:
      context: ./${APP_DIR}
      dockerfile: Dockerfile
    image: \${APP_IMAGE:-ai-gui-app}:\${IMAGE_TAG:-latest}
    env_file:
      - .env
    environment:
      - APP_PORT=\${APP_PORT:-8090}
      - EXPOSE_BACKEND_PORT=\${EXPOSE_BACKEND_PORT:-true}
      - BACKEND_PORT=\${BACKEND_PORT:-4500}
    ports:
      - "\${APP_PORT:-8090}:\${APP_PORT:-8090}"
      - "\${BACKEND_PORT:-4500}:\${BACKEND_PORT:-4500}"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:\${APP_PORT:-8090}/api/health"]
      interval: 15s
      timeout: 3s
      start_period: 20s
      retries: 5

  # Only started when POSTGRES_MODE=managed (deploy-aio-ai.sh passes
  # --profile managed-db automatically). For POSTGRES_MODE=external, set
  # PGHOST/PGPORT/PGUSER/PGPASSWORD in .env and this service is never
  # started.
  postgres:
    image: postgres:16-alpine
    profiles: ["managed-db"]
    env_file:
      - .env
    environment:
      - POSTGRES_DB=\${POSTGRES_DB:-ai_gui}
      - POSTGRES_USER=\${POSTGRES_USER:-ai_gui}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD:-change_me_in_env}
    ports:
      - "\${POSTGRES_PORT:-5432}:5432"
    volumes:
      - ai_gui_pgdata:/var/lib/postgresql/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER:-ai_gui} -d \${POSTGRES_DB:-ai_gui}"]
      interval: 10s
      timeout: 3s
      retries: 5

volumes:
  ai_gui_pgdata:
    driver: local
EOF

  # ---- README --------------------------------------------------------------
  write_if_missing "README.md" <<EOF
# All-In-One AI GUI -- Chat (docker-compose)

One Node.js service:

- **app** -- serves the chat frontend AND the chat API on APP_PORT
  (browsers) and BACKEND_PORT (API-only, e.g. n8n). Its entire capability
  surface is \`POST /api/chat\`, which forwards \`{message, session_id}\` to
  the AI Gateway's \`POST /v1/chat\` -- the exact same shape the DAY5
  chat-simulation test sends, with no synthetic capability/quiz params.
  The gateway's own classifier decides how to route each message (chat,
  code, summarization, translation, reasoning, vision-flavored, etc.).

There is no game content, no topics/questions/challenges, and no worker
service in this build -- those have been removed entirely. Every /api/*
response is guaranteed valid JSON (success, 4xx, 5xx, or an uncaught
error), so the frontend can never crash on a JSON.parse of an HTML error
page again.

Run:
  cp .env.example .env   # then edit .env
  ./deploy-aio-ai.sh init
  ./deploy-aio-ai.sh up
  ./deploy-aio-ai.sh test
  ./deploy-aio-ai.sh simulate     # DAY5-style realistic conversation checks
  ./deploy-aio-ai.sh logs
  ./deploy-aio-ai.sh down

Set POSTGRES_MODE=external in .env plus PGHOST/PGPORT/PGUSER/PGPASSWORD to
point at an already-running Postgres instead of the bundled one.
EOF

  header "==> init complete."
  info "Edit .env (copy from .env.example), then run: ./deploy-aio-ai.sh up"
}

ensure_initialized() {
  if [ ! -f "${APP_DIR}/index.js" ] || [ ! -f "${COMPOSE_FILE}" ]; then
    warn "not initialized yet, running init first"
    cmd_init
  fi
}

# ===========================================================================
# build / up / down / restart / logs / ps
# ===========================================================================
cmd_build() {
  require_docker
  ensure_initialized
  header "==> Building image (docker-compose)"
  DC build
}

cmd_up() {
  require_docker
  ensure_initialized
  [ "${POSTGRES_MODE}" = "external" ] && [ -z "${PGPASSWORD}" ] && warn "PGPASSWORD is empty in .env; app will fail to authenticate against ${PGHOST}."
  header "==> Starting stack (POSTGRES_MODE=${POSTGRES_MODE})"
  DC up -d --build
  ok "stack is up"
  info "App (browser):     http://<host>:${APP_PORT}/  (chat frontend + API)"
  if [ "${EXPOSE_BACKEND_PORT}" = "true" ]; then
    info "API (n8n/direct):  http://<host>:${BACKEND_PORT}/api/...  (same process, same DB)"
  fi
  info "Run './deploy-aio-ai.sh test' once the container reports healthy."
}

cmd_down()    { require_docker; header "==> Stopping stack"; DC down; }
cmd_restart() { require_docker; header "==> Restarting stack"; DC restart; }
cmd_ps()      { require_docker; DC ps; }
cmd_logs()    { require_docker; DC logs -f --tail=200; }

wait_for_http() {
  local url="$1" out="$2" attempt=1 code="000"
  while [ "${attempt}" -le "${TEST_RETRIES}" ]; do
    code="$(curl -s --max-time 8 -o "${out}" -w '%{http_code}' "${url}" || echo 000)"
    if [ "${code}" = "200" ]; then echo "${code}"; return 0; fi
    sleep "${TEST_RETRY_DELAY}"
    attempt=$((attempt + 1))
  done
  echo "${code}"
  return 1
}

cmd_test() {
  require_curl
  require_jq

  header "==> Testing app at http://${TEST_HOST}:${APP_PORT} (up to ${TEST_RETRIES}x${TEST_RETRY_DELAY}s waits per check)"
  local base="http://${TEST_HOST}:${APP_PORT}"
  local failures=0

  info "checking ${base}/ ..."
  local root_code
  root_code="$(wait_for_http "${base}/" /tmp/ai_gui_root.html || true)"
  if [ "${root_code}" = "200" ]; then ok "landing page responded 200"; else err "landing page check failed (HTTP ${root_code})"; failures=$((failures + 1)); fi

  info "checking ${base}/api/health ..."
  local health_code
  health_code="$(wait_for_http "${base}/api/health" /tmp/ai_gui_health.json || true)"
  if [ "${health_code}" = "200" ] && jq -e '.status == "ok"' /tmp/ai_gui_health.json >/dev/null 2>&1; then
    ok "/api/health responded 200 status=ok"
    jq -e '.dbReady == false' /tmp/ai_gui_health.json >/dev/null 2>&1 && warn "database still initializing (self-heal may be running)"
  else
    err "/api/health check failed (HTTP ${health_code})"; failures=$((failures + 1))
  fi

  info "checking ${base}/api/test (includes a real chat round trip) ..."
  local full_code
  full_code="$(wait_for_http "${base}/api/test" /tmp/ai_gui_full.json || true)"
  if [ "${full_code}" = "200" ] && jq -e '.success == true' /tmp/ai_gui_full.json >/dev/null 2>&1; then
    ok "/api/test: db, schema, gateway, and a live chat round trip all passed"
  else
    err "/api/test failed (HTTP ${full_code})"; failures=$((failures + 1))
    jq . /tmp/ai_gui_full.json 2>/dev/null || cat /tmp/ai_gui_full.json 2>/dev/null
  fi

  info "checking ${base}/api/dependencies ..."
  local deps_code
  deps_code="$(curl -s --max-time 8 -o /tmp/ai_gui_deps.json -w '%{http_code}' "${base}/api/dependencies" || echo 000)"
  if [ "${deps_code}" = "200" ]; then
    ok "/api/dependencies responded 200"
    jq -r '. as $r | ["day3","day4","day5","day6"][] as $k | "  \($k): \($r[$k].available // false) (\($r[$k].url // "n/a"))"' /tmp/ai_gui_deps.json 2>/dev/null || true
  else
    warn "/api/dependencies did not pass (HTTP ${deps_code}) -- non-fatal"
  fi

  if [ "${EXPOSE_BACKEND_PORT}" = "true" ]; then
    info "checking direct backend port http://${TEST_HOST}:${BACKEND_PORT}/api/health (n8n path) ..."
    local direct_code
    direct_code="$(wait_for_http "http://${TEST_HOST}:${BACKEND_PORT}/api/health" /tmp/ai_gui_direct.json || true)"
    if [ "${direct_code}" = "200" ]; then
      ok "backend directly reachable on host port ${BACKEND_PORT} (same process/DB, used by n8n)"
    else
      warn "direct backend port check did not pass (HTTP ${direct_code}) -- non-fatal, but n8n calling this port will fail too"
    fi
  fi

  info "checking ${base}/metrics ..."
  local metrics_code
  metrics_code="$(wait_for_http "${base}/metrics" /tmp/ai_gui_metrics.txt || true)"
  if [ "${metrics_code}" = "200" ] && grep -q "^# HELP" /tmp/ai_gui_metrics.txt 2>/dev/null; then
    ok "/metrics responded 200 with Prometheus-format output"
  else
    err "/metrics check failed (HTTP ${metrics_code})"; failures=$((failures + 1))
  fi

  rm -f /tmp/ai_gui_root.html /tmp/ai_gui_health.json /tmp/ai_gui_full.json /tmp/ai_gui_deps.json /tmp/ai_gui_metrics.txt /tmp/ai_gui_direct.json

  if [ "${failures}" -eq 0 ]; then header "==> All critical checks passed ✅"; return 0
  else header "==> ${failures} check(s) failed ❌"; return 1
  fi
}

cmd_heal() {
  require_curl
  require_jq
  local force="${1:-false}"
  local base="http://${TEST_HOST}:${APP_PORT}"
  header "==> Requesting self-heal (force=${force}) at ${base}/api/admin/self-heal"
  local attempt=1
  while [ "${attempt}" -le "${TEST_RETRIES}" ]; do
    if curl -s --max-time 8 -X POST -H 'Content-Type: application/json' -d "{\"force\": ${force}}" \
        -o /tmp/ai_gui_heal.json -w '%{http_code}' "${base}/api/admin/self-heal" | grep -q '^200$'; then
      ok "self-heal request completed"
      jq . /tmp/ai_gui_heal.json 2>/dev/null || cat /tmp/ai_gui_heal.json
      rm -f /tmp/ai_gui_heal.json
      return 0
    fi
    warn "attempt ${attempt}/${TEST_RETRIES} failed, retrying in ${TEST_RETRY_DELAY}s..."
    attempt=$((attempt + 1)); sleep "${TEST_RETRY_DELAY}"
  done
  rm -f /tmp/ai_gui_heal.json
  die "self-heal request failed after ${TEST_RETRIES} attempts"
}

# ===========================================================================
# simulate -- DAY5-style realistic multi-turn scenarios, but run against
# THIS APP's /api/chat (not the gateway directly), so a pass means the
# whole stack -- app, DB persistence, gateway proxy -- works end to end
# exactly the way a real user's browser would exercise it.
# ===========================================================================
cmd_simulate() {
  require_curl
  local base="http://${TEST_HOST}:${APP_PORT}"
  local have_jq=0; command -v jq >/dev/null 2>&1 && have_jq=1
  local total=0 passed=0 failed=0

  _sim_log()  { echo -e "${C_CYAN}[CHAT]${C_RESET} $*"; }
  _sim_pass() { echo -e "${C_GREEN}[PASS]${C_RESET} $*"; }
  _sim_fail() { echo -e "${C_RED}[FAIL]${C_RESET} $*" >&2; }
  _sim_info() { echo -e "\033[1;90m[INFO]${C_RESET} $*"; }

  jget() {
    if [ "$have_jq" -eq 1 ]; then echo "$1" | jq -r ".$2 // empty" 2>/dev/null; return; fi
    local out
    out=$(echo "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -1 | sed -E "s/\"$2\":\"([^\"]*)\"/\1/")
    [ -z "$out" ] && out=$(echo "$1" | grep -o "\"$2\":[a-zA-Z0-9.\-]*" | head -1 | sed -E "s/\"$2\"://")
    echo "$out"
  }

  json_str() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"
    printf '"%s"' "$s"
  }

  new_session() {
    curl -s --max-time 10 -X POST -H 'Content-Type: application/json' -d '{}' "${base}/api/session/start" \
      | { [ "$have_jq" -eq 1 ] && jq -r '.session_id // empty' || sed -E 's/.*"session_id":"([^"]*)".*/\1/'; }
  }

  send_turn() {
    local sid="$1" message="$2" start end ms resp code tmp
    tmp=$(mktemp)
    start=$(date +%s%3N 2>/dev/null || date +%s000)
    code=$(curl -sS -o "$tmp" -w '%{http_code}' --connect-timeout 5 --max-time 60 \
      -X POST "${base}/api/chat" -H "Content-Type: application/json" \
      -d "$(printf '{"session_id":%s,"message":%s}' "$(json_str "$sid")" "$(json_str "$message")")")
    end=$(date +%s%3N 2>/dev/null || date +%s000)
    ms=$((end - start))
    resp=$(cat "$tmp"); rm -f "$tmp"
    _sim_info "  > \"$message\""
    _sim_info "  < HTTP $code (${ms}ms) $(echo "$resp" | cut -c1-220)"
    echo "$resp"
  }

  assert_ok() {
    local resp="$1" success text
    success=$(jget "$resp" success); text=$(jget "$resp" response)
    [ "$success" = "true" ] && [ -n "$text" ]
  }

  scenario() { total=$((total + 1)); echo; _sim_log "=== SCENARIO: $1 ==="; }
  record()   { if [ "$2" = "0" ]; then passed=$((passed + 1)); _sim_pass "$1"; else failed=$((failed + 1)); _sim_fail "$1"; fi; }

  echo "============================================================"
  echo " CHAT SIMULATION (app end-to-end, mirrors DAY5 real-client test)"
  echo "============================================================"
  echo "Target: ${base}/api/chat"

  scenario "Casual small talk"
  SID=$(new_session)
  r=$(send_turn "$SID" "Hey! How's it going?")
  assert_ok "$r"; record "Casual small talk" $?

  scenario "Context recall across turns"
  SID=$(new_session)
  send_turn "$SID" "My name is Mimo." >/dev/null
  send_turn "$SID" "I use n8n for orchestration." >/dev/null
  r=$(send_turn "$SID" "What is my name and what do I use for orchestration?")
  text=$(jget "$r" response); ok=1
  echo "$text" | grep -qi "mimo" && echo "$text" | grep -qi "n8n" && ok=0
  record "Context recall across turns" $ok
  [ "$ok" -ne 0 ] && _sim_info "  (context may be degraded if Day 4 is offline -- check context_degraded flag)"

  scenario "Coding help with follow-up"
  SID=$(new_session)
  r1=$(send_turn "$SID" "Can you write a Python function that reverses a string?"); ok1=1; assert_ok "$r1" && ok1=0
  r2=$(send_turn "$SID" "Nice -- now make it handle unicode/emoji correctly."); ok2=1; assert_ok "$r2" && ok2=0
  ok=$(( ok1 + ok2 > 0 ? 1 : 0 ))
  record "Coding help with follow-up" $ok

  scenario "Summarization"
  SID=$(new_session)
  LONG_TEXT="Our quarterly report shows revenue grew 12 percent year over year, driven mainly by strong demand in the APAC region. Operating costs rose slightly due to increased hiring in engineering. Customer churn dropped to its lowest level in two years."
  r=$(send_turn "$SID" "Summarize this in one sentence: ${LONG_TEXT}")
  assert_ok "$r"; record "Summarization" $?

  scenario "Translation"
  SID=$(new_session)
  r=$(send_turn "$SID" "How do you say 'Where is the nearest train station?' in Spanish?")
  assert_ok "$r"; record "Translation" $?

  scenario "Reasoning"
  SID=$(new_session)
  r=$(send_turn "$SID" "If a train travels at 60 mph for 2.5 hours, how far does it go? Show your reasoning briefly.")
  assert_ok "$r"; record "Reasoning" $?

  scenario "Vision-flavored request"
  SID=$(new_session)
  r=$(send_turn "$SID" "I'm about to upload a photo -- can you identify what's in it?")
  provider=$(jget "$r" provider); ok=1; assert_ok "$r" && ok=0
  record "Vision-flavored request" $ok
  _sim_info "  routed provider: ${provider:-unknown}"

  scenario "Rapid back-and-forth (4 turns)"
  SID=$(new_session)
  ok=0
  for msg in "hi" "what can you do?" "give me one fun fact" "thanks, bye!"; do
    r=$(send_turn "$SID" "$msg")
    assert_ok "$r" || ok=1
  done
  record "Rapid back-and-forth (4 turns)" $ok

  scenario "Low-signal message handled gracefully (no 5xx)"
  SID=$(new_session)
  tmp=$(mktemp)
  code=$(curl -sS -o "$tmp" -w '%{http_code}' --connect-timeout 5 --max-time 30 \
    -X POST "${base}/api/chat" -H "Content-Type: application/json" \
    -d "$(printf '{"session_id":%s,"message":"..."}' "$(json_str "$SID")")")
  resp=$(cat "$tmp"); rm -f "$tmp"
  _sim_info "  > \"...\""
  _sim_info "  < HTTP $code $(echo "$resp" | cut -c1-200)"
  ok=1; [ "$code" -lt 500 ] && ok=0
  record "Low-signal message handled gracefully" $ok

  scenario "Long rambling real-world message"
  SID=$(new_session)
  r=$(send_turn "$SID" "okay so basically I've been trying to figure out for like the past hour why my node server keeps crashing when I deploy it, I think it might be a memory leak but honestly I'm not sure, could you help me think through how I'd even start debugging that in production without just restarting it constantly")
  assert_ok "$r"; record "Long rambling real-world message" $?

  echo
  echo "============================================================"
  echo " CHAT SIMULATION SUMMARY"
  echo "============================================================"
  echo "Total : ${total}"
  echo "Passed: ${passed}"
  echo "Failed: ${failed}"
  echo

  if [ "${failed}" -eq 0 ]; then
    _sim_pass "CHAT SIMULATION PASSED"
    return 0
  else
    _sim_fail "CHAT SIMULATION HAS ${failed} FAILED SCENARIO(S)"
    return 1
  fi
}

# ===========================================================================
# help
# ===========================================================================
cmd_help() {
  cat <<EOF
$(header "deploy-aio-ai.sh -- All-In-One AI GUI: Chat (docker-compose edition)")

Usage:
  ./deploy-aio-ai.sh <command> [options]

Commands:
  init      Scaffold ${APP_DIR}/ (chat frontend + chat API), Dockerfile,
            docker-compose.yml, .env.example. Safe to re-run -- source,
            Dockerfile, compose file, AND the frontend are always
            regenerated, so this script is the single source of truth and
            a stale frontend can never drift from what the API actually
            supports again.

  build     docker compose build (no start).

  up        docker compose up -d --build for app (+ postgres when
            POSTGRES_MODE=managed; skipped entirely when
            POSTGRES_MODE=external -- point PGHOST/PGPORT at your own DB).

  down      docker compose down.

  restart   docker compose restart.

  logs      Follow logs.

  ps        Show container status.

  test      Smoke-test the deployment with retry/backoff: landing page,
            /api/health, /api/test (db + schema + gateway + a real live
            chat round trip), /api/dependencies, direct backend port
            (n8n path), /metrics.

  simulate  Run DAY5-style realistic multi-turn conversation scenarios
            (small talk, context recall, code, summarization, translation,
            reasoning, vision-flavored phrasing, rapid turns, edge cases,
            rambling messages) against THIS APP's /api/chat -- not the
            gateway directly -- so a pass means the whole stack works the
            way a real user's browser would experience it.

  heal [force]
            Trigger the app's self-heal endpoint (POST /api/admin/self-heal).
            Pass 'true' to force a full rebuild of managed tables:
              ./deploy-aio-ai.sh heal true

  help      Show this message.

One service, one capability surface:
  'app' does exactly one thing with the AI Gateway: POST /v1/chat with
  {message, session_id}, the same shape a real client sends -- no
  synthetic capability hints, no quiz/topic params. The gateway's own
  classifier decides how to route each turn. There is no game content and
  no worker service in this build.

JSON-everywhere guarantee:
  Every /api/* response -- success, 4xx, 5xx, or an uncaught exception --
  is guaranteed to be valid JSON. This is what fixes "Request failed:
  JSON.parse: unexpected character" errors: the frontend can never again
  receive an HTML error page or raw file content where it expected JSON.

Dual-port app (frontend + backend, no separate container):
  The SAME Node process, code, and DB pool listens on both APP_PORT (for
  browsers) and BACKEND_PORT (API only). n8n's existing HTTP Request nodes
  pointing at http://<host>:${BACKEND_PORT}/api/... keep working unchanged.
  Set EXPOSE_BACKEND_PORT=false in .env to disable the second listener.

Persisted chat history:
  Every user/assistant turn is written to Postgres under a conversation
  keyed by session_id. GET /api/conversations/:session_id/messages replays
  the full transcript; the frontend uses this to restore history on reload.

Configuration (.env -- no Docker secrets are used):
  APP_DIR, PROJECT_NAME, COMPOSE_FILE
  REGISTRY, IMAGE_TAG, APP_IMAGE
  APP_PORT (default ${APP_PORT}), EXPOSE_BACKEND_PORT, BACKEND_PORT (default ${BACKEND_PORT})
  LOG_LEVEL, SELF_HEAL_DB

  POSTGRES_MODE        managed | external (default: managed)
  POSTGRES_PORT/DB/USER/PASSWORD   used only when POSTGRES_MODE=managed
  PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD   what the app actually
                       connects with -- set these directly for
                       POSTGRES_MODE=external
  GATEWAY_HOST, DAY3_URL, DAY4_URL, DAY5_URL, DAY6_URL
  TEST_HOST, TEST_RETRIES (default ${TEST_RETRIES}), TEST_RETRY_DELAY (default ${TEST_RETRY_DELAY}s)
  CONVERSATION_CONTEXT_LIMIT (default ${CONVERSATION_CONTEXT_LIMIT})

Examples:
  ./deploy-aio-ai.sh init
  ./deploy-aio-ai.sh up
  ./deploy-aio-ai.sh test
  ./deploy-aio-ai.sh simulate
  ./deploy-aio-ai.sh heal
  POSTGRES_MODE=external ./deploy-aio-ai.sh up
  ./deploy-aio-ai.sh logs
  ./deploy-aio-ai.sh down
EOF
}

# ===========================================================================
# Dispatcher
# ===========================================================================
main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    init)     cmd_init "$@" ;;
    build)    cmd_build "$@" ;;
    up)       cmd_up "$@" ;;
    down)     cmd_down "$@" ;;
    restart)  cmd_restart "$@" ;;
    logs)     cmd_logs "$@" ;;
    ps)       cmd_ps "$@" ;;
    test)     cmd_test "$@" ;;
    simulate) cmd_simulate "$@" ;;
    heal)     cmd_heal "$@" ;;
    help|-h|--help) cmd_help "$@" ;;
    *)
      err "unknown command: ${cmd}"
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
