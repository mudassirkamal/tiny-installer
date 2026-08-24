# Build a FAST Windows image (~8–12 min deploys)

The default Windows deploys install from a Microsoft ISO (~15–20 min — most of it is
Windows' own first-boot setup). To make deploys **fast and consistent**, install Windows
**once**, capture it as a ready image, and then every future deploy just **writes that image
to disk** (`dd`) — Windows is already installed, so it only needs a quick first boot.

```
ISO install (default)   →  ~15–20 min   (installs Windows every time)
Fast dd image (this)    →  ~8–12 min    (writes a ready image, boots)
```

## One-time: build the image

**1. Deploy Windows normally** onto a VPS using the panel (ISO method). Connect via RDP.

**2. Customize it** however you want every future server to look:
   - Confirm **RDP is enabled** and working on your chosen port.
   - (Optional) install your standard apps, set the timezone, tweak settings.
   - (Optional) enable auto-login / firewall rules you want baked in.

**3. Sysprep (generalize)** so the image is reusable on other machines — run in an admin
   Command Prompt **inside Windows**:
   ```cmd
   C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
   ```
   The VPS powers off when done. **Do not boot Windows again** before capturing.

**4. Boot the VPS into a rescue / live Linux** (most providers have a "Rescue Mode" in
   their panel). Then capture the disk to a compressed image with the included script:
   ```bash
   wget https://YOUR-PANEL/setup-notused -O /dev/null 2>/dev/null   # ignore
   # copy capture-image.sh onto the box (scp, curl from your repo, or paste it), then:
   bash capture-image.sh --disk /dev/sda --out ws2022.img.gz
   ```
   Tip: install `pigz` first (`apt-get install -y pigz`) for much faster multi-core
   compression. An 11 GB Windows disk usually compresses to ~5–7 GB.

**5. Host the image** with a **direct download link** — e.g. Cloudflare R2, Backblaze B2,
   an S3 bucket, or any web server. You can also upload straight from the capture script:
   ```bash
   bash capture-image.sh --disk /dev/sda --out ws2022.img.gz \
        --upload "https://user:pass@files.example.com/ws2022.img.gz"
   ```

## One-time: register it in the panel

On your **panel host**, create `data/images.json` (copy `data/images.example.json`):
```json
[
  {
    "id": "ws2022-fast",
    "type": "windows",
    "label": "Windows Server 2022 (Fast ⚡)",
    "imageUrl": "https://files.example.com/ws2022.img.gz",
    "sizeGb": 11,
    "cost": 1
  }
]
```
Restart the panel (`git pull` not needed; just `docker compose restart` or re-run
`./deploy.sh`). The new **"Fast ⚡"** option now appears at the top of the OS dropdown.

## From then on

Pick the **Fast** image → Generate command → run on any VPS. It streams the image straight
to disk with `dd` and boots — no Windows setup wait. The live-status page shows progress and
flips to **Online** when RDP opens, same as before.

### Notes
- The target VPS disk must be **≥ the image's uncompressed size**. Keep source disks small
  (e.g. a 20–25 GB Windows install) so the image fits the smallest VPS you sell.
- Rebuild the image occasionally to fold in Windows updates.
- `.img.gz`, `.img.xz`, `.raw`, and `.zip` images are all supported by `setup.sh`.
