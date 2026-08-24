<#
  prepare-windows.ps1  -  brand + preconfigure a Windows box before capturing it
  as a golden image, so customers get a ready-to-use server.

  Run INSIDE the freshly installed Windows (over RDP), in an ELEVATED PowerShell:

    Set-ExecutionPolicy -Scope Process Bypass -Force
    .\prepare-windows.ps1 -WallpaperUrl "https://your-host/wallpaper.jpg" -CompanyName "MK Selling Hub"

  Then sysprep/shut down and capture the disk (see BUILD-FAST-IMAGE.md).
#>
param(
  [string]$WallpaperUrl = "",                 # direct link to your JPG/PNG wallpaper
  [string]$CompanyName  = "My Company",
  [string]$TimeZone     = "",                  # leave empty to keep the VPS's own timezone
  [switch]$InstallChrome,                      # optional: bake Google Chrome in
  [switch]$InstallAgent                        # bake the first-boot agent (random pw + report to panel)
)

$ErrorActionPreference = "Continue"
function Step($m){ Write-Host "==> $m" -ForegroundColor Cyan }
function EnsureKey($p){ if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null } }

# ------------------------------------------------------------------ Wallpaper
if ($WallpaperUrl) {
  Step "Setting company wallpaper"
  $dir = "C:\Windows\Web\Wallpaper\Company"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $wp = Join-Path $dir "wallpaper.jpg"
  try {
    Invoke-WebRequest -Uri $WallpaperUrl -OutFile $wp -UseBasicParsing
    # current (admin) account  -  persists because the image keeps this account
    Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name Wallpaper       -Value $wp
    Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle  -Value 10   # 10 = Fill
    Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name TileWallpaper   -Value 0
    # default profile  -  any NEW user created later also gets it
    reg load "HKU\DEF" "C:\Users\Default\NTUSER.DAT" | Out-Null
    reg add "HKU\DEF\Control Panel\Desktop" /v Wallpaper      /t REG_SZ /d $wp /f | Out-Null
    reg add "HKU\DEF\Control Panel\Desktop" /v WallpaperStyle /t REG_SZ /d 10  /f | Out-Null
    reg unload "HKU\DEF" | Out-Null
    rundll32.exe user32.dll,UpdatePerUserSystemParameters 1, True
    Write-Host "   wallpaper set." -ForegroundColor Green
  } catch { Write-Host "   wallpaper failed: $_" -ForegroundColor Yellow }
} else {
  Write-Host "(!) No -WallpaperUrl given; skipping wallpaper." -ForegroundColor Yellow
}

# --------------------------------------------------------- Make RDP bulletproof
Step "Ensuring Remote Desktop is enabled + allowed through the firewall"
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue

# ------------------------------------------------------- Quality-of-life tweaks
Step "Disabling Server Manager auto-open at logon"
EnsureKey 'HKLM:\SOFTWARE\Microsoft\ServerManager'
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name DoNotOpenServerManagerAtLogon -Value 1 -Type DWord

Step "Turning off IE Enhanced Security (so browsing works out of the box)"
$adm = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}'
$usr = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}'
Set-ItemProperty $adm -Name IsInstalled -Value 0 -ErrorAction SilentlyContinue
Set-ItemProperty $usr -Name IsInstalled -Value 0 -ErrorAction SilentlyContinue

if ($TimeZone) {
  Step "Setting time zone to '$TimeZone'"
  try { Set-TimeZone -Id $TimeZone } catch { Write-Host "   bad TimeZone id, left default" -ForegroundColor Yellow }
} else {
  Step "Leaving time zone as-is (matches each VPS's own location)"
}

Step "High performance: never sleep / never turn off display / no hibernation"
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /h off   # disable hibernation -> clean shutdowns, so rescue can mount the disk read-write

Step "Admin password never expires"
try { Set-LocalUser -Name $env:USERNAME -PasswordNeverExpires $true } catch {}

Step "Show file extensions + This PC on desktop"
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name HideFileExt -Value 0
$icon='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'
EnsureKey $icon
Set-ItemProperty $icon -Name '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' -Value 0 -Type DWord

# ---------------------------------------------------------------- Optional apps
if ($InstallChrome) {
  Step "Installing Google Chrome"
  $f = "$env:TEMP\chrome.exe"
  try {
    Invoke-WebRequest "https://dl.google.com/chrome/install/standalonesetup64.exe" -OutFile $f -UseBasicParsing
    Start-Process $f -ArgumentList "/silent","/install" -Wait
  } catch { Write-Host "   chrome install failed: $_" -ForegroundColor Yellow }
}

# ------------------------------------------------------------- First-boot agent
if ($InstallAgent) {
  Step "Baking in the first-boot agent (random password + report to panel)"
  $dir = "C:\ti-agent"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  # The agent runs as SYSTEM at every boot; it does nothing unless setup.sh has
  # written C:\ti-firstboot.json onto the disk (i.e. this is a fresh deploy).
  $agent = @'
$cfgPath = "C:\ti-firstboot.json"
if (-not (Test-Path $cfgPath)) { exit }
try { $c = Get-Content $cfgPath -Raw | ConvertFrom-Json } catch { exit }
$user = if ($c.user) { "$($c.user)" } else { "administrator" }
$port = if ($c.port) { [int]$c.port } else { 22 }
# generate a strong random password
$chars = (48..57)+(65..90)+(97..122)
$pw = -join ($chars | Get-Random -Count 14 | ForEach-Object {[char]$_})
$pw = $pw + "@9"
# ensure the account exists, is enabled, and gets the new password
cmd /c "net user `"$user`" `"$pw`"" | Out-Null
cmd /c "net user `"$user`" /active:yes" | Out-Null
cmd /c "net localgroup administrators `"$user`" /add" | Out-Null
# RDP on + firewall + chosen port
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0 -ErrorAction SilentlyContinue
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name PortNumber -Value $port -ErrorAction SilentlyContinue
cmd /c "netsh advfirewall firewall add rule name=`"TI-RDP-$port`" dir=in action=allow protocol=TCP localport=$port" | Out-Null
# public IP
$ip = ""
foreach ($u in @("https://api.ipify.org","https://ifconfig.me/ip","https://icanhazip.com")) {
  try { $ip = (Invoke-RestMethod -Uri $u -TimeoutSec 8); if ($ip) { $ip = "$ip".Trim(); break } } catch {}
}
# report credentials back to the panel
$body = @{ ip=$ip; username=$user; password=$pw; port=$port; status="online" } | ConvertTo-Json
try { Invoke-RestMethod -Uri "$($c.panel)/api/deploy/$($c.token)/report" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 20 } catch {}
# clean up: remove config, self, and the scheduled task
Remove-Item $cfgPath -Force -ErrorAction SilentlyContinue
schtasks /delete /tn "TIFirstBoot" /f | Out-Null
Start-Sleep -Seconds 2
Remove-Item "C:\ti-agent" -Recurse -Force -ErrorAction SilentlyContinue
# apply the new RDP port without a full reboot
Restart-Service TermService -Force -ErrorAction SilentlyContinue
'@
  Set-Content -Path "$dir\firstboot.ps1" -Value $agent -Encoding ASCII
  # register it to run as SYSTEM at every startup
  schtasks /create /tn "TIFirstBoot" /tr "powershell -NoProfile -ExecutionPolicy Bypass -File C:\ti-agent\firstboot.ps1" /sc onstart /ru SYSTEM /rl HIGHEST /f | Out-Null
  Write-Host "   agent baked in (scheduled task TIFirstBoot)." -ForegroundColor Green
}

# -------------------------------------------------------------- Branding string
Step "Writing company name into system properties"
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name RegisteredOrganization -Value $CompanyName -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "All set. Company: $CompanyName" -ForegroundColor Green
if ($InstallAgent) {
  Write-Host "Agent is baked in - each deployed clone will set its own random password and report to the panel." -ForegroundColor Green
  Write-Host "Next: zero free space (cipher /w:C:), shut down, boot rescue, and capture the disk (BUILD-FAST-IMAGE.md)." -ForegroundColor Green
} else {
  Write-Host "Next: set the admin password you want customers to receive, e.g.:" -ForegroundColor Green
  Write-Host "   net user $env:USERNAME YourFixedPass123!" -ForegroundColor White
}
Write-Host "Then shut down:  shutdown /s /t 0    -  and capture the disk (BUILD-FAST-IMAGE.md)." -ForegroundColor Green
