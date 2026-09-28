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
