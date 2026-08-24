# TinyInstaller Panel — zero-dependency Node app
FROM node:20-alpine

WORKDIR /app
COPY package.json ./
COPY server ./server
COPY public ./public
COPY scripts ./scripts

# Persistent data (users, deployments, profiles) lives in /app/data
RUN mkdir -p /app/data
VOLUME ["/app/data"]

ENV PORT=8787
EXPOSE 8787

# Basic healthcheck against the reference endpoint
HEALTHCHECK --interval=30s --timeout=4s --start-period=5s \
  CMD wget -qO- http://127.0.0.1:8787/api/reference >/dev/null 2>&1 || exit 1

CMD ["node", "server/index.js"]
