// Tiny JSON-file data store (zero dependencies).
// Not for high concurrency — fine for a small self-hosted panel.
const fs = require("fs");
const path = require("path");

const DB_PATH = path.join(__dirname, "..", "data", "db.json");

const DEFAULTS = {
  users: [],       // {id, email, passHash, salt, plan, createdAt, expiresAt, usageTotal, usageLeft, maxProcesses}
  sessions: [],    // {token, userId, createdAt}
  deployments: [], // {token, userId, config, status, createdAt, updatedAt, logs:[]}
  profiles: [],    // {id, userId, name, config}
};

let cache = null;

function load() {
  if (cache) return cache;
  try {
    cache = JSON.parse(fs.readFileSync(DB_PATH, "utf8"));
    for (const k of Object.keys(DEFAULTS)) if (!cache[k]) cache[k] = [];
  } catch {
    cache = JSON.parse(JSON.stringify(DEFAULTS));
    save();
  }
  return cache;
}

function save() {
  const tmp = DB_PATH + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(cache, null, 2));
  fs.renameSync(tmp, DB_PATH);
}

module.exports = { load, save, get db() { return load(); } };
