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
