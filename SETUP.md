# Panel-host VPS cheat-sheet

Two machines are involved. Don't mix them up:

| Machine | Role | Gets wiped? |
|---------|------|-------------|
| **Panel host** | small always-on VPS that runs the control panel | ❌ never |
| **Target VPS** | the Linux server you want Windows installed on | ✅ yes, fully |

Set up the **panel host once**. Reuse it for all your target VPSes.

---

## A) Panel host — with HTTPS + a domain (recommended)

You need a domain (or subdomain) you can point at the panel-host VPS.

**1. Point DNS at the panel host.** In your domain's DNS, add an **A record**:
`panel.yourdomain.com  →  <PANEL-HOST-IP>`  (wait a few minutes for it to propagate)

**2. SSH into the panel host and run:**
```bash
# install Docker + git
curl -fsSL https://get.docker.com | sh
apt-get install -y git

# get the panel and start it with automatic HTTPS
git clone https://github.com/mudassirkamal/tiny-installer.git
cd tiny-installer
./deploy.sh --domain panel.yourdomain.com
```

**3. Open the firewall** (only if `ufw` is active — check with `ufw status`):
```bash
ufw allow 80,443/tcp
```
> Also open ports **80** and **443** in your VPS provider's firewall / security group if it has one.

**4. Open** `https://panel.yourdomain.com` → create your account. Done.

---

## B) Panel host — quick HTTP test (no domain)

Faster to try, but the token/command travel unencrypted — fine for a quick test, not for daily use.

```bash
curl -fsSL https://get.docker.com | sh
apt-get install -y git
git clone https://github.com/mudassirkamal/tiny-installer.git
cd tiny-installer
./deploy.sh
```
Open the firewall for the panel port (if `ufw` active) and in your provider firewall:
```bash
ufw allow 8787/tcp
```
Open `http://<PANEL-HOST-IP>:8787` → create your account.

> No Docker? `deploy.sh` falls back to Node automatically. Install Node first if needed:
> `apt-get install -y nodejs` then re-run `./deploy.sh`.

---

## Deploy Windows onto a target VPS

1. In the panel: pick **Windows Server 2022 Datacenter Evaluation**, set a password + RDP port → **Generate command**.
2. SSH into your **target VPS as root** and paste the one-liner it gives you:
   ```bash
   (wget https://panel.yourdomain.com/setup.sh -4O setup.sh || curl https://panel.yourdomain.com/setup.sh -Lo setup.sh) && bash setup.sh <TOKEN>
   ```
3. Type `REINSTALL` to confirm (or tick **Force** in the panel to skip the prompt).
4. It reports the target's public IP, reboots, and installs Windows unattended (~10–25 min).
5. Back in the panel, **Deployment status** turns **Online** when the RDP port opens — it shows the **IP · port · username · password** to connect with Windows Remote Desktop.

---

## Managing the panel

```bash
cd tiny-installer
docker compose logs -f          # watch logs (Docker mode)
git pull && ./deploy.sh         # update to the latest version
docker compose down             # stop the panel
```

## Two things that can trip you up
- **The panel must be reachable from the target VPS** — that's why it lives on a public host, not your laptop.
- **Microsoft eval ISO links rotate.** If a run fails to download the ISO, grab a current Windows ISO link and paste it into the panel's **Image URL** box, then regenerate.
