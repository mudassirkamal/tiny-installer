const crypto = require("crypto");

const SECRET = process.env.TI_SECRET || "change-me-in-production-please";

function uuid() {
  return crypto.randomUUID();
}

function randHex(n = 16) {
  return crypto.randomBytes(n).toString("hex");
}

// Password hashing with scrypt
function hashPassword(password, salt = randHex(16)) {
  const hash = crypto.scryptSync(password, salt, 32).toString("hex");
  return { salt, hash };
}
function verifyPassword(password, salt, expected) {
  const { hash } = hashPassword(password, salt);
  return crypto.timingSafeEqual(Buffer.from(hash), Buffer.from(expected));
}

// Signed session tokens (HMAC) — stored server-side too, this just adds tamper-evidence
function signSession(userId) {
  const raw = `${userId}.${Date.now()}.${randHex(8)}`;
  const sig = crypto.createHmac("sha256", SECRET).update(raw).digest("hex").slice(0, 24);
  return `${raw}.${sig}`;
}

// Random remote port in a safe high range
function randomPort() {
  return 20000 + Math.floor(Math.random() * 40000);
}

// Random strong password for remote access
function randomPassword(len = 16) {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789@#%+=";
  let out = "";
  const bytes = crypto.randomBytes(len);
  for (let i = 0; i < len; i++) out += chars[bytes[i] % chars.length];
  return out;
}

function randomUsername() {
  return "admin" + (100 + Math.floor(Math.random() * 900));
}

module.exports = {
  SECRET, uuid, randHex, hashPassword, verifyPassword,
  signSession, randomPort, randomPassword, randomUsername,
};
