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
