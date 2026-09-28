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
