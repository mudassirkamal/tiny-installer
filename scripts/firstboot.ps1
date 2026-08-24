# firstboot.ps1 — Fomze first-boot setup, run ONCE as SYSTEM on a freshly
# installed Windows (triggered by our windows-resize.bat via the reinstall
# engine's SetupComplete/GPO). No golden image, no manual step: every ISO deploy
# runs this automatically. Branding + performance tuning + live progress feed.
#
# __API_BASE__ is replaced by the panel when it serves this file.

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"   # fast Invoke-WebRequest on big files
$panel   = "__API_BASE__"
$company = "Fomze"
$wallUrl = "https://res.cloudinary.com/dikxngewb/image/upload/v1787536969/fomze_vps_twsw6y.png"

# public IP (to match this server to its deployment on the panel)
$ip = ""
foreach ($u in @("https://api.ipify.org","https://ifconfig.me/ip","https://icanhazip.com")) {
  try { $ip = ("$((Invoke-RestMethod -Uri $u -TimeoutSec 8))").Trim(); if ($ip) { break } } catch {}
}
# report a live-feed line to the panel BY IP (best-effort). No status on
# intermediate lines so it never downgrades an already-online deploy.
function Report($stage, $msg, $status) {
  if (-not $ip) { return }
  $b = @{ ip=$ip; stage=$stage; message=$msg }
  if ($status) { $b.status = $status }
  try { Invoke-RestMethod -Uri "$panel/api/report-by-ip" -Method Post -Body ($b | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 15 | Out-Null } catch {}
}
function EnsureKey($p){ if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null } }

Report "boot" "First boot - configuring your server"

# ---------------------------------------------------------------- Performance
Report "optimize" "Applying performance settings and policies"
# high performance power plan + never sleep/display-off + no hibernation
try { powercfg /setactive SCHEME_MIN } catch {}
powercfg /change standby-timeout-ac 0 2>$null
powercfg /change monitor-timeout-ac 0 2>$null
powercfg /h off 2>$null
# visual effects -> best performance
EnsureKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name VisualFXSetting -Value 2 -Type DWord -ErrorAction SilentlyContinue
# don't auto-open Server Manager at logon
EnsureKey 'HKLM:\SOFTWARE\Microsoft\ServerManager'
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name DoNotOpenServerManagerAtLogon -Value 1 -Type DWord -ErrorAction SilentlyContinue
# turn off IE Enhanced Security (so browsing works out of the box)
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}' -Name IsInstalled -Value 0 -ErrorAction SilentlyContinue
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}' -Name IsInstalled -Value 0 -ErrorAction SilentlyContinue
# reduce telemetry
EnsureKey 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name AllowTelemetry -Value 0 -Type DWord -ErrorAction SilentlyContinue
try { Set-Service DiagTrack -StartupType Disabled -ErrorAction SilentlyContinue; Stop-Service DiagTrack -Force -ErrorAction SilentlyContinue } catch {}
# no network throttling
EnsureKey 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name NetworkThrottlingIndex -Value 0xffffffff -Type DWord -ErrorAction SilentlyContinue
# show file extensions for the default profile (new users)
try {
  reg load "HKU\DEF" "C:\Users\Default\NTUSER.DAT" | Out-Null
  reg add "HKU\DEF\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v HideFileExt /t REG_DWORD /d 0 /f | Out-Null
} catch {}

# ---------------------------------------------------------------- Ensure RDP
# (the unattend already enables RDP + the chosen port; this is belt-and-suspenders)
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0 -ErrorAction SilentlyContinue
Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue

# ------------------------------------------------------------------ Wallpaper
Report "brand" "Applying $company wallpaper and branding"
try {
  $dir = "C:\Windows\Web\Wallpaper\Fomze"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $wp = Join-Path $dir "wallpaper.jpg"
  if (Get-Command curl.exe -ErrorAction SilentlyContinue) { curl.exe -s -L -o $wp $wallUrl } else { Invoke-WebRequest $wallUrl -OutFile $wp -UseBasicParsing }
  if (Test-Path $wp) {
    # default profile -> every user created later (incl. the admin's first logon) gets it
    reg add "HKU\DEF\Control Panel\Desktop" /v Wallpaper      /t REG_SZ /d "$wp" /f | Out-Null
    reg add "HKU\DEF\Control Panel\Desktop" /v WallpaperStyle /t REG_SZ /d 10   /f | Out-Null
    reg add "HKU\DEF\Control Panel\Desktop" /v TileWallpaper  /t REG_SZ /d 0    /f | Out-Null
  }
} catch {}
try { reg unload "HKU\DEF" | Out-Null } catch {}

# company name in system properties
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name RegisteredOrganization -Value $company -ErrorAction SilentlyContinue

# -------------------------------------------------------------------- Chrome
Report "apps" "Installing Google Chrome"
try {
  $f = "$env:TEMP\chrome.exe"
  if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
    curl.exe -s -L -o $f "https://dl.google.com/chrome/install/standalonesetup64.exe"
  } else {
    Invoke-WebRequest "https://dl.google.com/chrome/install/standalonesetup64.exe" -OutFile $f -UseBasicParsing
  }
  if (Test-Path $f) { Start-Process $f -ArgumentList "/silent","/install" -Wait }
} catch {}

# --------------------------------------------------------------------- Done
Report "done" "Setup complete - your server is ready" "online"
