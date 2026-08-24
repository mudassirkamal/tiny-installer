# TinyInstaller Panel

A self-hosted **OS deployment / VPS re-installation panel**, modeled on `tinyinstaller.top`.
Pick an OS image and options in the web dashboard, get a one-line deployment command,
run it on your target Linux server, and it reinstalls the OS unattended and sets up
remote access.

> ⚠️ **This wipes disks.** The `setup.sh` runner reinstalls the operating system on the
> machine it runs on — the target disk is erased with no undo. **Only run it on servers you
> own or are explicitly authorized to manage.** You are responsible for OS licensing and
> for lawful use.

---

## One-command deploy

On the box that will host the panel (a small always-on VPS you control):

```bash
git clone <your-repo-url> tinyinstaller-panel
cd tinyinstaller-panel
./deploy.sh
```

`deploy.sh` auto-generates a secret, then starts the panel with **Docker** if present, otherwise
via **systemd** (or `nohup node`). It prints the URL (`http://SERVER_IP:8787`).

**With automatic HTTPS** (recommended — point a domain's DNS A record at the server first):

```bash
./deploy.sh --domain panel.yourdomain.com
```

That's it — open the URL, create an account, and configure a deployment. To update later:
`git pull && ./deploy.sh`.

---

## What's inside

```
tinyinstaller-panel/
├── server/           Zero-dependency Node backend (http + crypto + JSON store)
│   ├── index.js      HTTP server, API, static hosting, serves setup.sh
│   ├── db.js         JSON-file data store
│   └── util.js       hashing, tokens, random port/user/password
├── public/           Dashboard front-end (the panel UI)
│   ├── index.html
│   ├── css/style.css
│   └── js/app.js
├── scripts/
│   └── setup.sh      The real reinstall runner fetched by the one-liner
├── data/db.json      Created on first run (users, deployments, profiles)
└── package.json
```

## Run it

Requires Node.js 18+ (no `npm install` needed — zero dependencies).

```bash
cd tinyinstaller-panel
node server/index.js
# → http://localhost:8787
```

Open the URL, create an account, and you're in the panel.
To change the port or session secret:

```bash
PORT=9000 TI_SECRET="a-long-random-string" node server/index.js
```

## How it works

1. **Configure** a deployment in the dashboard: OS image, image URL (for Windows/custom
   `.iso`/`.zip`/`.img`/`.gz`), remote port, username/password, node, and advanced disk
   options (GRUB, GPT, rescue, force, deployment mode).
2. **Generate command** creates a deployment record with a unique token and returns:
   ```
   (wget http://YOUR_HOST/setup.sh -4O setup.sh || curl http://YOUR_HOST/setup.sh -Lo setup.sh) && bash setup.sh <TOKEN>
   ```
3. **Run it** as root on the target server. `setup.sh`:
   - fetches the deployment config for `<TOKEN>` from the panel,
   - shows the plan and asks you to type `REINSTALL` to confirm (skipped with **Force**),
   - detects the boot disk, then either
     - **Linux** → hands off to the open-source [`bin456789/reinstall`](https://github.com/bin456789/reinstall) netboot engine, or
     - **Windows / custom** → streams the image straight to the disk with `dd`, optionally installs GRUB / converts to GPT,
   - reports progress back to the panel and reboots.

## Accounts, tokens & profiles

- **Usage tokens** — each deployment costs the OS's `cost` (1 by default), decremented from
  `usageLeft`. When it hits zero, new deployments are refused until you **Renew**.
- **Renew** — `POST /api/renew` tops `usageLeft` back to `usageTotal` and extends expiry 30 days
  (operator self-service; wire it to a real billing flow if you resell).
- **Concurrency** — capped at `maxProcesses` simultaneous running deployments.
- **Deployment profiles** — save the current form as a named profile and reload it later from the
  "Pre-select deployment profile" dropdown (create/list/delete via `/api/profiles`).

## Get File (post-install app)

Pick a browser/tool under **Get File** (or paste a direct URL). Once the server is **Online**, the
tracker shows a ready **post-install command** for that app — a silent PowerShell installer on
Windows, or a fetch+run on Linux — with a copy button. (reinstall's unattended Windows setup
doesn't expose custom first-logon commands via CLI, so this is delivered as a reliable one-click
command rather than fragile auto-injection.)

## Deployment tracking

The dashboard has a live **Deployment status** panel (polls every 4s). For each deployment
it shows the status (`ready → running → completed`/`failed`), a stage timeline
(start → network → download → reinstall → reboot → done), a streaming log, and a
**connection card** with the **server IP, port, username and password** (each copyable).
`setup.sh` reports its public IP and each stage back to `POST /api/deploy/:token/log`.

## Does it really install Windows on a Linux VPS?

**Yes — Windows *and* Linux, for real.** The `setup.sh` runner drives the open-source
[`bin456789/reinstall`](https://github.com/bin456789/reinstall) engine, which reinstalls the OS
on a *running* server. This is the same class of engine paid panels like `tinyinstaller.top`
wrap.

- **Linux** (Debian/Ubuntu/Alpine/Rocky…): `reinstall.sh debian 12 --password … --ssh-port …`
- **Windows** (Server 2016–2022, Win10 LTSC, Win11): it installs straight from a **Microsoft
  ISO** with **VirtIO drivers auto-injected** and an **unattended** setup that sets the admin
  password and **enables RDP** on your chosen port:
  ```
  reinstall.sh windows --image-name "Windows Server 2022 SERVERDATACENTER" \
       --iso "<ISO URL>" --username admin --password "***" --rdp-port <PORT>
  ```

You do **not** need to host giant pre-built images. Each catalog entry in `server/index.js`
(`OS_IMAGES`) maps to the right engine parameters — Windows entries carry an `imageName`
(WIM edition) and a default Microsoft `iso` URL; the operator can override the ISO per deploy
via the **Image URL** field. (A `dd` path for your own pre-baked `.img`/`.gz` raw images is
still available via the "Custom image" catalog entry.)

> ISO links rotate. If a bundled Microsoft eval link 404s, paste a current ISO URL in the
> **Image URL** box, or update the `iso:` value in `OS_IMAGES`.

## End-to-end: deploy Windows on one of your VPSes

1. Host this panel somewhere with a public URL (see below) and sign in.
2. Pick e.g. **Windows Server 2022 Datacenter Evaluation**, set a password (or leave blank for a
   random one), pick an RDP port, **Generate command**.
3. SSH into your fresh Linux VPS as root and paste the one-liner:
   ```
   (wget https://panel.example.com/setup.sh -4O setup.sh || curl https://panel.example.com/setup.sh -Lo setup.sh) && bash setup.sh <TOKEN>
   ```
4. Type `REINSTALL` to confirm (or enable **Force** to skip). The VPS reports its public IP,
   reboots, and installs Windows unattended (~10–25 min).
5. Watch **Deployment status** in the panel. When the panel's prober sees the RDP port open, the
   card turns **Online** and shows the **IP · port · username · password** to RDP in with.

## Hosting the panel (so it works from any VPS)

`setup.sh` is fetched over the network and carries a token, so run the panel behind HTTPS:

```bash
# on a small always-on box / VPS you control
git clone <this> && cd tinyinstaller-panel
PORT=8787 TI_SECRET="$(openssl rand -hex 32)" node server/index.js
```
Then put a reverse proxy in front (Caddy makes TLS automatic):
```
panel.example.com {
    reverse_proxy localhost:8787
}
```
Now your one-liner points at `https://panel.example.com/setup.sh` and works from any VPS.

## API (for reference)

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| POST | `/api/register` `/api/login` `/api/logout` | cookie | account/session |
| GET  | `/api/me` | cookie | account status |
| POST | `/api/renew` | cookie | top up usage tokens + extend expiry |
| GET  | `/api/reference` | — | OS images, nodes, get-file list |
| POST | `/api/deploy` | cookie | create deployment → token + command |
| GET  | `/api/deploy/:token` | **token** | runner config (called by `setup.sh`) |
| POST | `/api/deploy/:token/log` | **token** | progress reporting |
| POST | `/api/deploy/:token/regenerate` | cookie | rotate a leaked token |
| GET/POST | `/api/profiles` | cookie | list / save deployment profiles |
| DELETE | `/api/profiles/:id` | cookie | delete a saved profile |
| GET | `/setup.sh` | — | the runner, with the panel URL injected |

## Production notes

- Put it behind HTTPS (a reverse proxy such as Caddy/nginx). The one-liner and token
  travel over the network; without TLS they're exposed.
- The JSON store is fine for a small panel; swap `db.js` for SQLite/Postgres if you grow.
- `setup.sh` is intentionally conservative (root check + typed confirmation). The **Force**
  option removes those guards — treat it accordingly.
- Rotate `TI_SECRET` and never commit `data/db.json` (it holds password hashes).

## Safety & scope

This is legitimate sysadmin tooling, in the same family as `reinstall.sh`, `InstallNET`,
and `netboot.xyz`. It is **not** built to hide itself from a server's owner and must not be
used to reinstall, wipe, or take over machines you don't control.
