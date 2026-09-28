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
