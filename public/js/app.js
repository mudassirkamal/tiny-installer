// TinyInstaller Panel — front-end
const $ = (s) => document.querySelector(s);
const api = async (path, opts = {}) => {
  const r = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...opts,
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error || "Request failed");
  return data;
};
const toast = (m) => { const t = $("#toast"); t.textContent = m; t.classList.add("show"); clearTimeout(t._t); t._t = setTimeout(() => t.classList.remove("show"), 1800); };

let REF = { nodes: [], osImages: [], getFiles: [] };
let ME = null;
let cmdOS = "linux";
let currentToken = null;
let currentCommand = "";
let TWOFA_ON = false;
const GF_ICONS = { chrome: "🌐", firefox: "🦊", edge: "🌊", brave: "🦁", "7zip": "🗜️" };

// ---------- Auth (single access key) ----------
function showAuth() { $("#auth").classList.remove("hidden"); $("#app").classList.add("hidden"); }
function showApp() { $("#auth").classList.add("hidden"); $("#app").classList.remove("hidden"); }

// ---------- Header navigation (view switching) ----------
const VIEWS = ["home", "profiles", "pricing", "docs"];
function showView(name) {
  if (!VIEWS.includes(name)) name = "home";
  VIEWS.forEach((v) => { const el = document.getElementById("view-" + v); if (el) el.classList.toggle("hidden", v !== name); });
  document.querySelectorAll(".nav-links a").forEach((a) => a.classList.toggle("on", a.dataset.view === name));
  window.scrollTo(0, 0);
}
document.querySelectorAll(".nav-links a").forEach((a) => {
  a.onclick = (e) => { e.preventDefault(); showView(a.dataset.view); };
});

$("#authBtn").onclick = async () => {
  const key = $("#authKey").value.trim();
  const code = ($("#authCode") && $("#authCode").value.trim()) || "";
  $("#authErr").textContent = "";
  try {
    const { user } = await api("/api/login-key", { method: "POST", body: { key, code } });
    ME = user; await boot();
  } catch (e) {
    if (/2fa/i.test(e.message)) { $("#twofaField").style.display = ""; if ($("#authCode")) $("#authCode").focus(); }
    $("#authErr").textContent = e.message;
  }
};
$("#authKey").addEventListener("keydown", (e) => { if (e.key === "Enter") $("#authBtn").click(); });
if ($("#authCode")) $("#authCode").addEventListener("keydown", (e) => { if (e.key === "Enter") $("#authBtn").click(); });

// ---------- Theme (dark / light, persisted) ----------
function applyTheme(t) {
  const light = t === "light";
  document.body.classList.toggle("light", light);
  const lbl = $("#mThemeLabel"); if (lbl) lbl.textContent = light ? "Dark theme" : "Light theme";
}
function toggleTheme() {
  const next = document.body.classList.contains("light") ? "dark" : "light";
  localStorage.setItem("ti-theme", next); applyTheme(next);
}
applyTheme(localStorage.getItem("ti-theme") || "dark");
$("#themeToggle").onclick = toggleTheme;

// ---------- Account dropdown (My Access) ----------
const acctMenu = $("#acctMenu");
$("#acctBtn").onclick = (e) => { e.stopPropagation(); acctMenu.classList.toggle("hidden"); };
document.addEventListener("click", (e) => { if (!e.target.closest(".acct-wrap")) acctMenu.classList.add("hidden"); });
$("#mThemeItem").onclick = toggleTheme;
$("#mLogout").onclick = async () => { await api("/api/logout", { method: "POST" }); location.reload(); };

// ---------- Boot ----------
async function boot() {
  REF = await api("/api/reference");
  renderReference();
  renderAccount();
  await loadProfiles();
  showApp();
  await syncCommand(false);   // command is ready immediately, no button needed
  startPolling();
}
function renderReference() {
  const os = $("#osImage"); os.innerHTML = "";
  REF.osImages.forEach((o) => {
    const opt = document.createElement("option");
    opt.value = o.id;
    const size = o.sizeGb ? `${o.sizeGb} GB · ` : "";
    opt.textContent = `${o.label}  —  ${size}${o.cost} token`;
    os.appendChild(opt);
  });
  const node = $("#node"); node.innerHTML = "";
  REF.nodes.forEach((n) => { const opt = document.createElement("option"); opt.value = n.id; opt.textContent = n.label; node.appendChild(opt); });
  const gf = $("#getFiles"); gf.innerHTML = "";
  const mkChip = (id, label, selected) => {
    const el = document.createElement("button");
    el.type = "button";
    el.className = "browser-chip" + (selected ? " on" : "");
    el.dataset.id = id; el.textContent = label;
    el.onclick = () => {
      gf.querySelectorAll(".browser-chip").forEach((x) => x.classList.remove("on"));
      el.classList.add("on");
      scheduleSync();
    };
    gf.appendChild(el);
  };
  mkChip("", "None", true);                                  // default: install nothing
  REF.getFiles.forEach((f) => mkChip(f.id, f.label, false));
  updateOsHint();
}
function updateOsHint() {
  const meta = REF.osImages.find((o) => o.id === $("#osImage").value) || {};
  const eng = meta.fast ? "⚡ fast image (dd, ~8-12 min)" : (meta.method === "dd" ? "raw image (dd)" : "reinstall engine (~15-20 min)");
  $("#osHint").textContent = `${meta.type} · ${eng}${meta.sizeGb ? " · " + meta.sizeGb + " GB" : ""} · ${meta.cost || 1} token`;
  // Show the Image URL field only when the OS needs one (custom, or Windows without a bundled ISO).
  $("#imageUrlRow").style.display = meta.needsUrl ? "" : "none";
  const inp = $("#imageUrl");
  if (inp) inp.placeholder = meta.type === "windows"
    ? "https://…/windows.iso  (Microsoft ISO direct link)"
    : "https://…/image.img.gz  (raw disk image direct link)";
}
$("#osImage").addEventListener("change", updateOsHint);

function renderAccount() {
  const name = ME.email === "owner" ? "Fomze" : ME.email.split("@")[0].replace(/^./, (c) => c.toUpperCase());
  $("#greetName").textContent = "Hi " + name;
  $("#accountNo").textContent = "# " + ME.accountNo;
  $("#planBadge").firstChild.textContent = ME.plan + " ";
  // account dropdown ("My Access")
  $("#mAcctName").textContent = name;
  $("#mAcctNo").textContent = "# " + ME.accountNo;
  $("#mAvatar").textContent = (name[0] || "F").toUpperCase();
  $("#mPlan").textContent = ME.plan;
  $("#mExpiry").textContent = ME.unlimited ? "No expiry" : new Date(ME.expiresAt).toISOString().slice(0, 10);
  $("#m2fa").textContent = TWOFA_ON ? "On ✓" : "Off";
  if (ME.unlimited) {
    $("#expBar").style.width = "100%";
    $("#expDays").textContent = "No expiry";
    $("#expDate").textContent = "Unlimited";
    $("#useBar").style.width = "100%";
    $("#useLeft").textContent = "Unlimited deployments";
    $("#procBar").style.width = "0%";
    $("#procTxt").textContent = `${ME.activeProcesses} active · no limit`;
    return;
  }
  // expiry
  const now = Date.now();
  const created = new Date(ME.createdAt).getTime();
  const exp = new Date(ME.expiresAt).getTime();
  const totalMs = exp - created;
  const leftMs = Math.max(0, exp - now);
  const days = Math.ceil(leftMs / 86400000);
  $("#expBar").style.width = Math.max(2, Math.min(100, (leftMs / totalMs) * 100)) + "%";
  $("#expDays").textContent = days + " days remaining";
  $("#expDate").textContent = new Date(ME.expiresAt).toISOString().slice(0, 19).replace("T", " ");
  // usage
  $("#useBar").style.width = Math.max(2, (ME.usageLeft / ME.usageTotal) * 100) + "%";
  $("#useLeft").textContent = ME.usageLeft + " remaining";
  // processes
  const pct = Math.round((ME.activeProcesses / ME.maxProcesses) * 100);
  $("#procBar").style.width = pct + "%";
  $("#procTxt").textContent = `${ME.activeProcesses} / ${ME.maxProcesses} (${pct}%)`;
}

// ---------- Config collection ----------
function collectConfig() {
  const selGf = $("#getFiles .browser-chip.on");
  const gfId = selGf ? selGf.dataset.id : "";
  return {
    osImage: $("#osImage").value,
    imageUrl: $("#imageUrl").value.trim(),
    getFile: gfId ? { id: gfId, url: $("#getFileUrl").value.trim() } : null,
    node: $("#node").value,
    remotePort: $("#remotePort").value ? Number($("#remotePort").value) : undefined,
    username: $("#username").value.trim(),
    usernameRandom: $("#userRandom").checked,
    password: $("#password").value,
    privateTracking: $("#privateTracking").checked,
    preConfirmed: $("#preConfirmed").checked,
    advanced: {
      mode: $("#modeSeg .on").dataset.mode,
      force: $("#force").checked,
      installGrub: $("#installGrub").checked,
      rescueEnv: $("#rescueEnv").checked,
      convertGpt: $("#convertGpt").checked,
      randomUrl: $("#randomUrl").checked,
    },
  };
}

// ---------- Command ----------
// The command is always ready (no "Generate" button). It reflects the options
// above and is persisted server-side against a standing token, so you just copy
// and run it. Editing options re-syncs it (debounced) without spawning cards.
let syncTimer = null;
async function syncCommand(showToast) {
  try {
    const res = await api("/api/deploy", { method: "POST", body: collectConfig() });
    currentToken = res.token;
    currentCommand = res.command;
    renderCommand();
    if (res.config) {
      const active = document.activeElement;
      const setIf = (id, val) => { const el = $("#" + id); if (el && el !== active) el.value = val; };
      setIf("remotePort", res.config.remotePort);
      if (!$("#userRandom").checked) setIf("username", res.config.username);
      // password is intentionally NOT pre-filled — the real (random) password
      // appears in the deployment card once the server runs the command.
    }
    if (showToast) toast("Command updated");
    renderDeployments();
  } catch (e) { if (showToast) toast(e.message); }
}
function scheduleSync() { clearTimeout(syncTimer); syncTimer = setTimeout(() => syncCommand(false), 600); }
["osImage", "imageUrl", "remotePort", "username", "userRandom", "password", "node", "privateTracking", "preConfirmed", "getFileUrl"]
  .forEach((id) => {
    const el = $("#" + id);
    if (!el) return;
    el.addEventListener("change", scheduleSync);
    el.addEventListener("input", scheduleSync);   // live: update on every keystroke
  });

function renderCommand() {
  if (!currentCommand) return;
  if (cmdOS === "windows") {
    // Windows uses PowerShell to fetch + run under WSL/bash-equivalent; show a PS wrapper.
    const psUrl = currentCommand.match(/wget (\S+)/)[1];
    $("#cmd").textContent =
      `# Run in an elevated PowerShell on the target Windows host\n` +
      `curl.exe -Lo setup.sh "${psUrl}"; bash setup.sh ${currentToken}`;
  } else {
    $("#cmd").textContent = currentCommand;
  }
}
document.querySelectorAll(".cmd-tabs button").forEach((b) => {
  b.onclick = () => {
    document.querySelectorAll(".cmd-tabs button").forEach((x) => x.classList.remove("on"));
    b.classList.add("on"); cmdOS = b.dataset.os; renderCommand();
  };
});
$("#copyCmd").onclick = async () => {
  const txt = $("#cmd").textContent;
  try { await navigator.clipboard.writeText(txt); toast("Copied"); } catch { toast("Copy failed"); }
};

// ---------- Advanced ----------
$("#advHead").onclick = () => $("#adv").classList.toggle("open");
document.querySelectorAll("#modeSeg button").forEach((b) => {
  b.onclick = () => { document.querySelectorAll("#modeSeg button").forEach((x) => x.classList.remove("on")); b.classList.add("on"); };
});
$("#regenLink").onclick = async () => {
  if (!currentToken) return toast("Generate a command first");
  try {
    const res = await api(`/api/deploy/${currentToken}/regenerate`, { method: "POST" });
    currentToken = res.token; currentCommand = res.command; renderCommand();
    toast("Token regenerated — old command is now invalid");
  } catch (e) { toast(e.message); }
};
// ---------- Profiles ----------
let PROFILES = [];
async function loadProfiles() {
  try { PROFILES = (await api("/api/profiles")).profiles; } catch { PROFILES = []; }
  const sel = $("#profileSelect");
  sel.innerHTML = '<option value="">Pre-select deployment profile…</option>' +
    PROFILES.map((p) => `<option value="${p.id}">${esc(p.name)}</option>`).join("");
}
function applyProfile(cfg) {
  if (!cfg) return;
  if (cfg.osImage) { $("#osImage").value = cfg.osImage; updateOsHint(); }
  $("#imageUrl").value = cfg.imageUrl || "";
  $("#node").value = cfg.node || "EU";
  $("#remotePort").value = cfg.remotePort || "";
  $("#username").value = cfg.username || "";
  $("#userRandom").checked = !!cfg.usernameRandom;
  $("#password").value = cfg.password || "";
  $("#privateTracking").checked = cfg.privateTracking !== false;
  $("#preConfirmed").checked = !!cfg.preConfirmed;
  const a = cfg.advanced || {};
  ["force", "installGrub", "rescueEnv", "convertGpt", "randomUrl"].forEach((k) => { if ($("#" + k)) $("#" + k).checked = !!a[k]; });
  document.querySelectorAll("#modeSeg button").forEach((b) => b.classList.toggle("on", b.dataset.mode === (a.mode || "auto")));
  // browser chip
  const wantGf = (cfg.getFile && cfg.getFile.id) || "";
  document.querySelectorAll("#getFiles .browser-chip").forEach((el) => el.classList.toggle("on", el.dataset.id === wantGf));
  $("#getFileUrl").value = (cfg.getFile && cfg.getFile.url) || "";
  scheduleSync();
}
$("#loadProfile").onclick = () => {
  const p = PROFILES.find((x) => x.id === $("#profileSelect").value);
  if (!p) return toast("Pick a profile first");
  applyProfile(p.config); showView("home"); toast(`Loaded “${p.name}” into Home`);
};
$("#deleteProfile").onclick = async () => {
  const id = $("#profileSelect").value;
  if (!id) return toast("Pick a profile to delete");
  try { await api(`/api/profiles/${id}`, { method: "DELETE" }); await loadProfiles(); toast("Profile deleted"); }
  catch (e) { toast(e.message); }
};
$("#saveProfile").onclick = async () => {
  const name = prompt("Name this deployment profile:");
  if (!name) return;
  try { await api("/api/profiles", { method: "POST", body: { name, config: collectConfig() } }); await loadProfiles(); toast("Profile saved"); }
  catch (e) { toast(e.message); }
};
$("#renewBtn").onclick = async () => {
  try { ME = (await api("/api/renew", { method: "POST" })).user; renderAccount(); toast("Renewed — tokens topped up, expiry extended"); }
  catch (e) { toast(e.message); }
};

// Random remote port (10000–65535)
if ($("#randPort")) $("#randPort").onclick = () => {
  $("#remotePort").value = Math.floor(Math.random() * (65535 - 10000 + 1)) + 10000;
  scheduleSync();
  toast("Random port set");
};

// Strong random password generator (avoids look-alike chars, guarantees each class)
function genPassword() {
  const U = "ABCDEFGHJKLMNPQRSTUVWXYZ", L = "abcdefghijkmnpqrstuvwxyz", N = "23456789", S = "@#%+=!";
  const pick = (s) => s[Math.floor(Math.random() * s.length)];
  const all = U + L + N + S;
  let p = [pick(U), pick(L), pick(N), pick(S)];
  for (let i = 0; i < 10; i++) p.push(pick(all));
  return p.sort(() => Math.random() - 0.5).join("");
}
if ($("#randPass")) $("#randPass").onclick = () => { $("#password").value = genPassword(); scheduleSync(); toast("Random password set"); };
if ($("#randResetPass")) $("#randResetPass").onclick = () => { $("#resetPass").value = genPassword(); renderResetCmd(); toast("Random password set"); };

// ---------- Reset Windows password command (Documents) ----------
function renderResetCmd() {
  const el = document.getElementById("resetCmd"); if (!el) return;
  const url = location.origin + "/reset-windows-password.sh";
  const pass = (document.getElementById("resetPass") || {}).value || "";
  let cmd = `(wget ${url} -O reset.sh || curl ${url} -o reset.sh) && bash reset.sh --user administrator`;
  if (pass.trim()) cmd += ` --password '${pass.trim().replace(/'/g, "'\\''")}'`;
  el.textContent = cmd;
}
if (document.getElementById("resetPass")) document.getElementById("resetPass").addEventListener("input", renderResetCmd);
if (document.getElementById("copyReset")) document.getElementById("copyReset").onclick = async () => {
  try { await navigator.clipboard.writeText(document.getElementById("resetCmd").textContent); toast("Reset command copied"); } catch {}
};
renderResetCmd();

// ---------- Deployment tracking ----------
const STAGES = ["start", "network", "download", "reinstall", "reboot", "done"];
const cp = (val) => `<span class="cp" title="Copy" data-cp="${encodeURIComponent(val)}">
  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/></svg></span>`;
const esc = (s) => String(s == null ? "" : s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

function stageIndex(logs) {
  let idx = 0;
  for (const l of logs) { const i = STAGES.indexOf(l.stage); if (i > idx) idx = i; }
  return idx;
}
function osLabel(id) { const o = REF.osImages.find((x) => x.id === id); return o ? o.label : id; }

async function renderDeployments() {
  let list = [];
  try { list = (await api("/api/deployments")).deployments; } catch { return; }
  // Hide the standing command itself (a "ready" deploy that no server has run yet).
  list = list.filter((d) => !(d.status === "ready" && !d.serverIp && (!d.logs || !d.logs.length)));
  const track = $("#track");
  if (!list.length) { track.innerHTML = `<p class="hint">No deployments yet — copy the command above and run it on your VPS.</p>`; return; }
  track.innerHTML = list.map((d) => {
    const c = d.config;
    const done = d.status === "completed" || d.status === "online";
    const si = d.status === "online" ? STAGES.length - 1 : stageIndex(d.logs);
    const stages = STAGES.map((s, i) =>
      `<span class="stage ${i <= si && d.status !== "ready" ? "done" : ""}">${s}</span>`).join("");
    const logs = d.logs.slice(-12).map((l) =>
      `<div><span class="ts">${(l.at || "").slice(11, 19)}</span> ${esc(l.stage ? "[" + l.stage + "] " : "")}${esc(l.message)}</div>`).join("") || `<div class="hint">Waiting for the server to run the command…</div>`;
    const ip = d.serverIp;
    return `<div class="dep">
      <div class="dep-top">
        <span class="os">${esc(osLabel(c.osImage))}</span>
        <span class="tok">${d.token.slice(0, 8)}…</span>
        <a class="sharelink" href="/d/${d.token}" target="_blank" title="Open shareable live status page">🔗 Live status</a>
        <div class="spacer"></div>
        <span class="st ${d.status}"><span class="dot"></span>${d.status}</span>
        <button class="dep-del" data-del="${d.token}" title="Delete this deployment" style="background:none;border:0;color:var(--faint);cursor:pointer;font-size:16px;padding:2px 6px;margin-left:8px">✕</button>
      </div>
      <div class="conn">
        <div class="kv"><div class="k">Address (IP : Port)</div><div class="v">${ip ? esc(ip + ":" + c.remotePort) + cp(ip + ":" + c.remotePort) : '<span class="hint" style="margin:0">pending…</span>'}</div></div>
        <div class="kv"><div class="k">Username</div><div class="v">${esc(c.username)}${cp(c.username)}</div></div>
        <div class="kv"><div class="k">Password</div><div class="v">${c.password ? esc(c.password) + cp(c.password) : '<span class="hint" style="margin:0">pending…</span>'}</div></div>
      </div>
      <div class="stages">${stages}</div>
      ${done && ip ? `<div class="rdp-note">✓ Ready. Connect via ${/^(win|ws)/.test(c.osImage) ? "Remote Desktop (RDP)" : "SSH"} to <b>${esc(ip)}:${esc(c.remotePort)}</b> as <b>${esc(c.username)}</b>.</div>` : ""}
      ${d.postInstall ? `<div class="post"><div class="post-h">Post-install · ${esc(d.postInstall.label)} <span class="hint" style="margin:0">— run this once the server is online</span></div>
        <div class="cmdbox" style="margin-top:8px"><code>${esc(d.postInstall.command)}</code>
          <button class="copy pi-copy" data-cmd="${encodeURIComponent(d.postInstall.command)}" title="Copy"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="16" height="16"><rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/></svg></button></div></div>` : ""}
      <div class="log">${logs}</div>
    </div>`;
  }).join("");
  track.querySelectorAll(".cp").forEach((el) => {
    el.onclick = async () => { try { await navigator.clipboard.writeText(decodeURIComponent(el.dataset.cp)); toast("Copied"); } catch {} };
  });
  track.querySelectorAll(".pi-copy").forEach((el) => {
    el.onclick = async () => { try { await navigator.clipboard.writeText(decodeURIComponent(el.dataset.cmd)); toast("Post-install command copied"); } catch {} };
  });
  track.querySelectorAll(".dep-del").forEach((el) => {
    el.onclick = async () => {
      if (!confirm("Delete this deployment card? (It does not touch the server.)")) return;
      try { await api(`/api/deployments/${el.dataset.del}`, { method: "DELETE" }); toast("Deployment deleted"); renderDeployments(); }
      catch (e) { toast(e.message); }
    };
  });
}
let pollTimer = null;
function startPolling() { renderDeployments(); clearInterval(pollTimer); pollTimer = setInterval(renderDeployments, 4000); }

// ---------- Init ----------
(async () => {
  // Is 2FA enabled? If so, reveal the code field on the login page up-front.
  try {
    const info = await api("/api/auth-info");
    TWOFA_ON = !!info.twofa;
    if (TWOFA_ON && $("#twofaField")) $("#twofaField").style.display = "";
  } catch {}
  try { const { user } = await api("/api/me"); ME = user; await boot(); }
  catch { showAuth(); }
})();
