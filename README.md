# All-In-One AI GUI -- Chat (docker-compose)

One Node.js service:

- **app** -- serves the chat frontend AND the chat API on APP_PORT
  (browsers) and BACKEND_PORT (API-only, e.g. n8n). Its entire capability
  surface is `POST /api/chat`, which forwards `{message, session_id}` to
  the AI Gateway's `POST /v1/chat` -- the exact same shape the DAY5
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
# ai-gateway-gui
