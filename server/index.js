// TinyInstaller Panel — zero-dependency Node backend
// Serves the dashboard, the account/deployment API, and the setup.sh reinstaller.
const http = require("http");
const net = require("net");
const fs = require("fs");
const path = require("path");
const url = require("url");
const { db, save } = require("./db");
const U = require("./util");

const PORT = process.env.PORT || 8787;
const PUB = path.join(__dirname, "..", "public");
const SETUP_SH = path.join(__dirname, "..", "scripts", "setup.sh");

// ---- Reference data -------------------------------------------------------
const NODES = [
  { id: "EU", label: "EU — Frankfurt" },
  { id: "US", label: "US — New York" },
  { id: "ASIA", label: "Asia — Singapore" },
];

// OS catalog — mirrors TinyInstaller's dropdown.
//  method "reinstall"  → installed by the bin456789/reinstall engine (real, on a running VPS)
//    - linux distros:   { distro, version }
//    - windows:         { imageName (WIM edition), iso (Microsoft ISO URL) }
//  method "dd"          → a pre-built raw disk image is streamed onto the disk
//  method "custom"      → user supplies the image/ISO URL at deploy time
// sizeGb / cost are shown in the UI (cost = usage tokens consumed), matching TinyInstaller.
const OS_IMAGES = [
  // Only three Windows Server versions — this is all Fomze Installer deploys.
  { id: "ws2022-datacenter-eval", type: "windows", label: "Windows Server 2022", method: "reinstall",
    imageName: "Windows Server 2022 SERVERDATACENTER", iso: "https://go.microsoft.com/fwlink/p/?LinkID=2195280", sizeGb: 11, cost: 1 },
  { id: "ws2019-datacenter-eval", type: "windows", label: "Windows Server 2019", method: "reinstall",
    imageName: "Windows Server 2019 SERVERDATACENTER", iso: "https://go.microsoft.com/fwlink/p/?LinkID=2195167", sizeGb: 11, cost: 1 },
  { id: "ws2016-datacenter-eval", type: "windows", label: "Windows Server 2016", method: "reinstall",
    imageName: "Windows Server 2016 SERVERDATACENTER", iso: "https://go.microsoft.com/fwlink/p/?LinkID=2195174", sizeGb: 12, cost: 1 },
];

// "Get File" quick-picks — a browser/tool to install once the box is online.
// `win`/`nix` are direct installer URLs; `winArgs` runs it silently on Windows.
const GET_FILES = [
  { id: "chrome",  label: "Google Chrome", win: "https://dl.google.com/chrome/install/standalonesetup64.exe", winArgs: "/silent /install" },
  { id: "firefox", label: "Firefox",       win: "https://download.mozilla.org/?product=firefox-latest&os=win64&lang=en-US", winArgs: "/S" },
  { id: "brave",   label: "Brave",         win: "https://laptop-updates.brave.com/latest/winx64", winArgs: "/silent /install" },
  { id: "edge",    label: "Microsoft Edge",win: "https://go.microsoft.com/fwlink/?linkid=2109047&Channel=Stable&language=en", winArgs: "/silent /install" },
  { id: "7zip",    label: "7-Zip",         win: "https://www.7-zip.org/a/7z2408-x64.exe", winArgs: "/S" },
];
function getFileMeta(id) { return GET_FILES.find((g) => g.id === id) || null; }

// Merge operator-defined FAST images (pre-built raw disk images) from
// data/images.json into the catalog. Each entry deploys by `dd` (~8-12 min).
// See data/images.example.json for the format.
try {
  const custom = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "data", "images.json"), "utf8"));
  if (Array.isArray(custom) && custom.length) {
    OS_IMAGES.unshift(...custom.map((o) => ({ method: "dd", cost: 1, ...o })));
    console.log(`  Loaded ${custom.length} custom fast image(s) from data/images.json`);
  }
} catch { /* no custom images configured — fine */ }

// ---- Helpers --------------------------------------------------------------
function send(res, code, body, headers = {}) {
  const h = { "Content-Type": "application/json", ...headers };
  res.writeHead(code, h);
  if (Buffer.isBuffer(body) || typeof body === "string") res.end(body);
  else res.end(JSON.stringify(body));
}
function readBody(req) {
  return new Promise((resolve) => {
    let d = "";
    req.on("data", (c) => (d += c));
    req.on("end", () => {
      try { resolve(d ? JSON.parse(d) : {}); } catch { resolve({}); }
    });
  });
}
function parseCookies(req) {
  const out = {};
  (req.headers.cookie || "").split(";").forEach((p) => {
    const i = p.indexOf("=");
    if (i > -1) out[p.slice(0, i).trim()] = decodeURIComponent(p.slice(i + 1).trim());
  });
  return out;
}
function currentUser(req) {
  const token = parseCookies(req).ti_session;
  if (!token) return null;
  const s = db.sessions.find((x) => x.token === token);
  if (!s) return null;
  return db.users.find((u) => u.id === s.userId) || null;
}
function publicUser(u) {
  return {
    id: u.id, email: u.email, plan: u.plan,
    accountNo: u.accountNo, unlimited: !!u.unlimited,
    expiresAt: u.expiresAt, createdAt: u.createdAt,
    usageTotal: u.usageTotal, usageLeft: u.usageLeft,
    maxProcesses: u.maxProcesses,
    activeProcesses: db.deployments.filter(
      (d) => d.userId === u.id && d.status === "running"
    ).length,
  };
}
function apiBase(req) {
  const proto = (req.headers["x-forwarded-proto"] || "http").split(",")[0];
  const host = req.headers.host;
  return `${proto}://${host}`;
}
function daysFromNow(n) {
  return new Date(Date.now() + n * 86400000).toISOString();
}

// ---- Static files ---------------------------------------------------------
const MIME = {
  ".html": "text/html", ".css": "text/css", ".js": "text/javascript",
  ".svg": "image/svg+xml", ".ico": "image/x-icon", ".json": "application/json",
};
function serveStatic(req, res, pathname) {
  let rel = pathname === "/" ? "/index.html" : pathname;
  const file = path.join(PUB, path.normalize(rel).replace(/^(\.\.[/\\])+/, ""));
  if (!file.startsWith(PUB)) return send(res, 403, { error: "forbidden" });
  fs.readFile(file, (err, data) => {
    if (err) {
      // SPA-ish fallback to index for unknown non-API paths
      return fs.readFile(path.join(PUB, "index.html"), (e2, idx) =>
        e2 ? send(res, 404, { error: "not found" }) :
             send(res, 200, idx, { "Content-Type": "text/html" }));
    }
    send(res, 200, data, { "Content-Type": MIME[path.extname(file)] || "application/octet-stream" });
  });
}

// ---- API ------------------------------------------------------------------
async function handleApi(req, res, pathname) {
  const method = req.method;

  // Public: serve setup.sh with API base injected
  if (pathname === "/setup.sh" && method === "GET") {
    let sh = fs.readFileSync(SETUP_SH, "utf8").replace(/__API_BASE__/g, apiBase(req));
    return send(res, 200, sh, { "Content-Type": "text/x-shellscript; charset=utf-8" });
  }

  // Public reference data (trimmed — no internal ISO defaults)
  if (pathname === "/api/reference" && method === "GET") {
    const osImages = OS_IMAGES.map((o) => ({
      id: o.id, type: o.type, label: o.label, method: o.method,
      sizeGb: o.sizeGb || 0, cost: o.cost || 1,
      needsUrl: o.id === "custom-image" || (!o.iso && !o.imageUrl && o.type === "windows"),
      fast: o.method === "dd" && !!o.imageUrl,
    }));
    return send(res, 200, { nodes: NODES, osImages, getFiles: GET_FILES });
  }

  // ---- Auth ----
  if (pathname === "/api/register" && method === "POST") {
    const { email, password } = await readBody(req);
    if (!email || !password || password.length < 6)
      return send(res, 400, { error: "Email and a 6+ char password are required." });
    if (db.users.find((u) => u.email.toLowerCase() === String(email).toLowerCase()))
      return send(res, 409, { error: "An account with that email already exists." });
    const { salt, hash } = U.hashPassword(password);
    const user = {
      id: U.uuid(),
      accountNo: 10000 + db.users.length + 1,
      email, passHash: hash, salt,
      plan: "Personal",
      createdAt: new Date().toISOString(),
      expiresAt: daysFromNow(30),
      usageTotal: 10, usageLeft: 10,
      maxProcesses: 2,
    };
    db.users.push(user);
    save();
    return login(res, user);
  }

  if (pathname === "/api/login" && method === "POST") {
    const { email, password } = await readBody(req);
    const user = db.users.find((u) => u.email.toLowerCase() === String(email || "").toLowerCase());
    if (!user || !U.verifyPassword(password || "", user.salt, user.passHash))
      return send(res, 401, { error: "Invalid email or password." });
    return login(res, user);
  }

  // Access-key login: one secret key = your unlimited owner account.
  // Set TI_ACCESS_KEY in the host environment; this is the only credential.
  if (pathname === "/api/login-key" && method === "POST") {
    const { key } = await readBody(req);
    const want = process.env.TI_ACCESS_KEY || "fomze-owner-change-me";
    if (!key || String(key) !== want)
      return send(res, 401, { error: "Invalid access key." });
    let user = db.users.find((u) => u.owner);
    if (!user) {
      user = {
        id: U.uuid(), owner: true, unlimited: true,
        accountNo: 10001, email: "owner",
        plan: "Owner", createdAt: new Date().toISOString(),
        expiresAt: daysFromNow(3650),
        usageTotal: 999999, usageLeft: 999999, maxProcesses: 999,
      };
      db.users.push(user);
      save();
    } else {
      user.unlimited = true; user.plan = "Owner";
      user.expiresAt = daysFromNow(3650); user.maxProcesses = 999;
      save();
    }
    return login(res, user);
  }

  if (pathname === "/api/logout" && method === "POST") {
    const token = parseCookies(req).ti_session;
    db.sessions = db.sessions.filter((s) => s.token !== token);
    save();
    return send(res, 200, { ok: true }, {
      "Set-Cookie": "ti_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax",
    });
  }

  // ---- Token-authed endpoints (called by setup.sh, no cookie) ----
  // The deployment token in the path IS the credential.
  const mDeploy = pathname.match(/^\/api\/deploy\/([\w-]+)$/);
  if (mDeploy && method === "GET") {
    const d = db.deployments.find((x) => x.token === mDeploy[1]);
    if (!d) return send(res, 404, { error: "Unknown deployment token." });
    return send(res, 200, buildRunnerConfig(d));
  }
  const mLog = pathname.match(/^\/api\/deploy\/([\w-]+)\/log$/);
  if (mLog && method === "POST") {
    const d = db.deployments.find((x) => x.token === mLog[1]);
    if (!d) return send(res, 404, { error: "Unknown token." });
    const { stage, message, status, ip } = await readBody(req);
    if (ip) d.serverIp = String(ip).slice(0, 64);
    if (stage || message) d.logs.push({ at: new Date().toISOString(), stage: stage || "", message: message || "" });
    if (status) d.status = status;
    d.updatedAt = new Date().toISOString();
    save();
    return send(res, 200, { ok: true });
  }

  // Golden-image first-boot agent reports IN by IP (no token — matched to the
  // most recent in-progress deployment on that public IP). This is how a fast
  // deploy flips to "online" on shared hosting that blocks the panel's outbound
  // RDP probe: the report comes INBOUND over a web port, which is allowed.
  if (pathname === "/api/report-by-ip" && method === "POST") {
    const { ip, username, password, port } = await readBody(req);
    if (!ip) return send(res, 400, { error: "ip required" });
    const d = db.deployments
      .filter((x) => x.serverIp === ip && ["running", "installing", "rebooting"].includes(x.status))
      .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))[0];
    if (!d) return send(res, 404, { error: "no matching in-progress deployment for that IP" });
    if (username) d.config.username = String(username).slice(0, 64);
    if (password) d.config.password = String(password).slice(0, 128);
    if (port) d.config.remotePort = Number(port) || d.config.remotePort;
    d.status = "online";
    d.logs.push({ at: new Date().toISOString(), stage: "done", message: "First-boot agent reported in — server online." });
    d.updatedAt = new Date().toISOString();
    save();
    return send(res, 200, { ok: true, token: d.token });
  }

  // First-boot agent (on a fast/golden-image deploy) reports the credentials it
  // generated on the machine itself. Token in the path is the credential.
  const mReport = pathname.match(/^\/api\/deploy\/([\w-]+)\/report$/);
  if (mReport && method === "POST") {
    const d = db.deployments.find((x) => x.token === mReport[1]);
    if (!d) return send(res, 404, { error: "Unknown token." });
    const { ip, username, password, port, status } = await readBody(req);
    if (ip) d.serverIp = String(ip).slice(0, 64);
    if (username) d.config.username = String(username).slice(0, 64);
    if (password) d.config.password = String(password).slice(0, 128);
    if (port) d.config.remotePort = Number(port) || d.config.remotePort;
    d.status = status || "online";
    d.logs.push({ at: new Date().toISOString(), stage: "done", message: "First-boot agent set the password and reported in — server online." });
    d.updatedAt = new Date().toISOString();
    save();
    return send(res, 200, { ok: true });
  }

  // Public live-status feed for the shareable /d/<token> page (token = credential).
  const mStatus = pathname.match(/^\/api\/status\/([\w-]+)$/);
  if (mStatus && method === "GET") {
    const d = db.deployments.find((x) => x.token === mStatus[1]);
    if (!d) return send(res, 404, { error: "Unknown token." });
    // Refresh live status on-demand (works even where background jobs are frozen).
    await probeOne(d, { fast: true }).catch(() => {});
    const meta = OS_IMAGES.find((o) => o.id === d.config.osImage) || {};
    return send(res, 200, {
      token: d.token,
      status: d.status,
      osLabel: meta.label || d.config.osImage,
      osType: meta.type || "linux",
      serverIp: d.serverIp || null,
      port: d.config.remotePort,
      username: d.config.username,
      password: d.config.password,
      logs: d.logs,
      installLog: d.installLog || "",
      postInstall: buildPostInstall(d),
      createdAt: d.createdAt,
      updatedAt: d.updatedAt,
    });
  }

  // ---- Everything below requires a signed-in user ----
  const user = currentUser(req);
  if (pathname.startsWith("/api/") && !user)
    return send(res, 401, { error: "Not signed in." });

  if (pathname === "/api/me" && method === "GET")
    return send(res, 200, { user: publicUser(user) });

  // Renew: top up usage tokens and extend expiry (operator self-service).
  if (pathname === "/api/renew" && method === "POST") {
    user.usageLeft = user.usageTotal;
    user.expiresAt = daysFromNow(30);
    save();
    return send(res, 200, { user: publicUser(user) });
  }

  if (pathname === "/api/deploy" && method === "POST") {
    const cfg = await readBody(req);
    return createDeployment(req, res, user, cfg);
  }

  // Regenerate token (security notice in the UI)
  const mReg = pathname.match(/^\/api\/deploy\/([\w-]+)\/regenerate$/);
  if (mReg && method === "POST") {
    const d = db.deployments.find((x) => x.token === mReg[1] && x.userId === user.id);
    if (!d) return send(res, 404, { error: "Not found." });
    d.token = U.uuid();
    d.updatedAt = new Date().toISOString();
    save();
    return send(res, 200, { token: d.token, command: buildCommand(req, d) });
  }

  if (pathname === "/api/deployments" && method === "GET") {
    return send(res, 200, {
      deployments: db.deployments
        .filter((d) => d.userId === user.id)
        .map((d) => ({
          token: d.token, status: d.status, config: d.config,
          serverIp: d.serverIp || null, updatedAt: d.updatedAt,
          createdAt: d.createdAt, logs: d.logs,
          postInstall: buildPostInstall(d),
        }))
        .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt)),
    });
  }

  // ---- Profiles ----
  if (pathname === "/api/profiles" && method === "GET")
    return send(res, 200, { profiles: db.profiles.filter((p) => p.userId === user.id) });

  if (pathname === "/api/profiles" && method === "POST") {
    const { name, config } = await readBody(req);
    if (!name) return send(res, 400, { error: "Profile name required." });
    const p = { id: U.uuid(), userId: user.id, name, config: config || {} };
    db.profiles.push(p);
    save();
    return send(res, 200, { profile: p });
  }

  const mProf = pathname.match(/^\/api\/profiles\/([\w-]+)$/);
  if (mProf && method === "DELETE") {
    const before = db.profiles.length;
    db.profiles = db.profiles.filter((p) => !(p.id === mProf[1] && p.userId === user.id));
    if (db.profiles.length === before) return send(res, 404, { error: "Profile not found." });
    save();
    return send(res, 200, { ok: true });
  }

  return send(res, 404, { error: "No such endpoint." });
}

function login(res, user) {
  const token = U.signSession(user.id);
  db.sessions.push({ token, userId: user.id, createdAt: new Date().toISOString() });
  save();
  return send(res, 200, { user: publicUser(user) }, {
    "Set-Cookie": `ti_session=${token}; Path=/; Max-Age=604800; HttpOnly; SameSite=Lax`,
  });
}

function createDeployment(req, res, user, cfg) {
  const config = normalizeConfig(cfg);
  const meta = OS_IMAGES.find((o) => o.id === config.osImage) || {};
  const cost = meta.cost || 1;

  if (!user.unlimited && user.usageLeft < cost)
    return send(res, 402, { error: `Not enough usage tokens (need ${cost}, have ${user.usageLeft}). Renew to top up.` });

  if (!user.unlimited) {
    const active = db.deployments.filter((x) => x.userId === user.id && ["running", "rebooting"].includes(x.status)).length;
    if (active >= user.maxProcesses)
      return send(res, 429, { error: `Concurrent deployment limit reached (${user.maxProcesses}). Wait for one to finish.` });
  }

  const d = {
    token: U.uuid(),
    userId: user.id,
    config,
    cost,
    status: "ready",
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    logs: [],
  };
  // Charge tokens on creation (owner account is unlimited — never charged).
  if (!user.unlimited) user.usageLeft -= cost;
  db.deployments.push(d);
  save();
  return send(res, 200, {
    token: d.token,
    command: buildCommand(req, d),
    config,
    usageLeft: user.usageLeft,
  });
}

function normalizeConfig(cfg) {
  const adv = cfg.advanced || {};
  return {
    osImage: cfg.osImage || "debian-12",
    imageUrl: (cfg.imageUrl || "").trim(),
    getFile: cfg.getFile || null,      // {id, url}
    node: cfg.node || "EU",
    remotePort: cfg.remotePort || 22,                       // default access/RDP port
    username: cfg.usernameRandom ? U.randomUsername() : (cfg.username || "administrator"),
    password: (cfg.password && cfg.password.length) ? cfg.password : U.randomPassword(),
    privateTracking: !!cfg.privateTracking,
    preConfirmed: !!cfg.preConfirmed,
    initScript: cfg.initScript || "",
    advanced: {
      mode: adv.mode || "auto",       // auto | direct | compatibility
      force: !!adv.force,
      installGrub: !!adv.installGrub,
      rescueEnv: !!adv.rescueEnv,
      convertGpt: !!adv.convertGpt,
      randomUrl: !!adv.randomUrl,
    },
  };
}

// Config the setup.sh actually consumes.
function buildRunnerConfig(d) {
  const c = d.config;
  const meta = OS_IMAGES.find((o) => o.id === c.osImage) || {};
  // For Windows, a per-deploy Image URL overrides the catalog's default ISO.
  const iso = c.imageUrl || meta.iso || "";
  // For dd/fast images, use the per-deploy URL or the catalog's preset image URL.
  const rawImageUrl = c.imageUrl || meta.imageUrl || "";
  return {
    token: d.token,
    os_type: meta.type || "linux",
    os_image: c.osImage,
    method: meta.method || "reinstall",
    // reinstall — linux
    distro: meta.distro || "",
    distro_version: meta.version || "",
    desktop: meta.desktop || "",
    // reinstall — windows
    image_name: meta.imageName || "",
    iso_url: iso,
    // dd / custom / fast pre-built image
    image_url: rawImageUrl,
    get_file: c.getFile,
    remote_port: c.remotePort,
    username: c.username,
    password: c.password,
    mode: c.advanced.mode,
    force: c.advanced.force,
    install_grub: c.advanced.installGrub,
    rescue_env: c.advanced.rescueEnv,
    convert_gpt: c.advanced.convertGpt,
    init_script: c.initScript,
  };
}

// Post-install command for the selected "Get File" app, to run once online.
function buildPostInstall(d) {
  const gf = d.config.getFile;
  if (!gf || !gf.id) return null;
  const meta = getFileMeta(gf.id);
  const isWin = (OS_IMAGES.find((o) => o.id === d.config.osImage) || {}).type === "windows";
  const url = gf.url || (meta && (isWin ? meta.win : meta.win)) || "";
  if (!url) return null;
  const label = (meta && meta.label) || gf.id;
  if (isWin) {
    const args = (meta && meta.winArgs) || "/silent";
    return {
      label, os: "windows",
      command: `powershell -Command "$f=\\"$env:TEMP\\app.exe\\"; Invoke-WebRequest '${url}' -OutFile $f; Start-Process $f -ArgumentList '${args}' -Wait"`,
    };
  }
  return { label, os: "linux", command: `curl -fL '${url}' -o /tmp/app && chmod +x /tmp/app && /tmp/app || true` };
}

function buildCommand(req, d) {
  const base = apiBase(req);
  const suffix = d.config.advanced.randomUrl ? `?r=${U.randHex(4)}` : "";
  const scriptUrl = `${base}/setup.sh${suffix}`;
  return `(wget ${scriptUrl} -4O setup.sh || curl ${scriptUrl} -Lo setup.sh) && bash setup.sh ${d.token}`;
}

// ---- Server ---------------------------------------------------------------
const server = http.createServer(async (req, res) => {
  // Behind IIS/iisnode the rewrite can hide the real path; recover it from the
  // headers IIS provides, falling back to req.url for normal/reverse-proxy hosts.
  const rawUrl = req.headers["x-original-url"] || req.headers["x-rewrite-url"] ||
    (req.headers["x-original-uri"]) || req.url;
  const { pathname } = url.parse(rawUrl);
  try {
    if (pathname === "/setup.sh" || pathname.startsWith("/api/"))
      return await handleApi(req, res, pathname);
    // Serve helper scripts from the panel (so a private repo still works).
    if (pathname === "/prepare-windows.ps1" || pathname === "/capture-image.sh" || pathname === "/reset-windows-password.sh") {
      const f = path.join(__dirname, "..", "scripts", pathname.slice(1));
      return fs.readFile(f, (e, buf) =>
        e ? send(res, 404, { error: "not found" })
          : send(res, 200, buf, { "Content-Type": "text/plain; charset=utf-8" }));
    }
    // Shareable public live-status page: /d/<token>
    if (/^\/d\/[\w-]+$/.test(pathname)) {
      return fs.readFile(path.join(PUB, "status.html"), (e, buf) =>
        e ? send(res, 404, { error: "not found" }) : send(res, 200, buf, { "Content-Type": "text/html" }));
    }
    return serveStatic(req, res, pathname);
  } catch (e) {
    console.error(e);
    return send(res, 500, { error: "Server error." });
  }
});

// ---- Live reachability prober --------------------------------------------
// For deployments that have rebooted into install, TCP-probe IP:remotePort.
// When the port answers, the OS is really up → mark "online".
function tcpOpen(host, port, timeout = 4000) {
  return new Promise((resolve) => {
    const sock = new net.Socket();
    let done = false;
    const finish = (ok) => { if (done) return; done = true; sock.destroy(); resolve(ok); };
    sock.setTimeout(timeout);
    sock.once("connect", () => finish(true));
    sock.once("timeout", () => finish(false));
    sock.once("error", () => finish(false));
    sock.connect(port, host);
  });
}
// Fetch the reinstall engine's live install-log web page (served on port 80
// of the target while it is installing). Returns cleaned text, or null.
function httpGetText(host, port, path = "/", timeout = 6000) {
  return new Promise((resolve) => {
    let data = "";
    const req = http.get({ host, port, path, timeout }, (res) => {
      res.setEncoding("utf8");
      res.on("data", (c) => { data += c; if (data.length > 60000) req.destroy(); });
      res.on("end", () => resolve(data));
    });
    req.on("timeout", () => { req.destroy(); resolve(null); });
    req.on("error", () => resolve(null));
  });
}
// Probe ONE deployment: mark online if its port is open, else relay the live
// install-log page (port 80). Runs both from the background loop (on a VPS) AND
// on-demand from /api/status (so it also works on shared hosting that freezes
// background jobs, as long as it allows the panel to make outbound calls).
async function probeOne(d, { fast = false } = {}) {
  if (!d || !d.serverIp || !["running", "rebooting", "installing"].includes(d.status)) return;
  const t1 = fast ? 2500 : 4000, t2 = fast ? 3000 : 6000;
  const port = d.config && d.config.remotePort;
  if (port && (await tcpOpen(d.serverIp, port, t1))) {
    d.status = "online";
    d.updatedAt = new Date().toISOString();
    d.logs.push({ at: new Date().toISOString(), stage: "done", message: `Port ${port} is open — the server is online.` });
    save();
    return;
  }
  const page = await httpGetText(d.serverIp, 80, "/", t2);
  if (page) {
    const text = page
      .replace(/<script[\s\S]*?<\/script>/gi, " ")   // drop the page's own JS
      .replace(/<style[\s\S]*?<\/style>/gi, " ")
      .replace(/<[^>]+>/g, " ")
      .replace(/[ \t]+/g, " ").replace(/\n{2,}/g, "\n").trim();
    const tail = text.slice(-6000);
    // Ignore pages that are just the log viewer's boilerplate (no real log lines yet).
    if (tail && tail.length > 20 && tail !== d.installLog) {
      d.installLog = tail;
      if (d.status !== "installing") {
        d.status = "installing";
        d.logs.push({ at: new Date().toISOString(), stage: "reinstall", message: "Installing OS — live logs streaming from the target." });
      }
      d.updatedAt = new Date().toISOString();
      save();
    }
  }
}
async function probeDeployments() {
  for (const d of db.deployments.filter((x) => x.serverIp && ["running", "rebooting", "installing"].includes(x.status)))
    await probeOne(d);
}
setInterval(() => { probeDeployments().catch(() => {}); }, 15000);

server.listen(PORT, () => {
  console.log(`\n  Fomze Installer running →  http://localhost:${PORT}\n`);
});
