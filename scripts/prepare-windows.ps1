<#
  prepare-windows.ps1 — brand + preconfigure a Windows box before capturing it
  as a golden image, so customers get a ready-to-use server.

  Run INSIDE the freshly installed Windows (over RDP), in an ELEVATED PowerShell:

    Set-ExecutionPolicy -Scope Process Bypass -Force
    .\prepare-windows.ps1 -WallpaperUrl "https://your-host/wallpaper.jpg" -CompanyName "MK Selling Hub"

  Then sysprep/shut down and capture the disk (see BUILD-FAST-IMAGE.md).
#>
param(
  [string]$WallpaperUrl = "",                 # direct link to your JPG/PNG wallpaper
  [string]$CompanyName  = "My Company",
  [string]$TimeZone     = "UTC",              # e.g. "Pakistan Standard Time"
  [switch]$InstallChrome                       # optional: bake Google Chrome in
)

$ErrorActionPreference = "Continue"
function Step($m){ Write-Host "==> $m" -ForegroundColor Cyan }

# ------------------------------------------------------------------ Wallpaper
if ($WallpaperUrl) {
  Step "Setting company wallpaper"
  $dir = "C:\Windows\Web\Wallpaper\Company"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $wp = Join-Path $dir "wallpaper.jpg"
  try {
    Invoke-WebRequest -Uri $WallpaperUrl -OutFile $wp -UseBasicParsing
    # current (admin) account — persists because the image keeps this account
    Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name Wallpaper       -Value $wp
    Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle  -Value 10   # 10 = Fill
    Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name TileWallpaper   -Value 0
    # default profile — any NEW user created later also gets it
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
New-Item -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name DoNotOpenServerManagerAtLogon -Value 1 -Type DWord

Step "Turning off IE Enhanced Security (so browsing works out of the box)"
$adm = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}'
$usr = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}'
Set-ItemProperty $adm -Name IsInstalled -Value 0 -ErrorAction SilentlyContinue
Set-ItemProperty $usr -Name IsInstalled -Value 0 -ErrorAction SilentlyContinue

Step "Setting time zone to '$TimeZone'"
try { Set-TimeZone -Id $TimeZone } catch { Write-Host "   bad TimeZone id, left default" -ForegroundColor Yellow }

Step "High performance: never sleep / never turn off display"
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0

Step "Admin password never expires"
try { Set-LocalUser -Name $env:USERNAME -PasswordNeverExpires $true } catch {}

Step "Show file extensions + This PC on desktop"
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name HideFileExt -Value 0
$icon='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'
New-Item -Path $icon -Force | Out-Null
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

# -------------------------------------------------------------- Branding string
Step "Writing company name into system properties"
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name RegisteredOrganization -Value $CompanyName -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "All set. Company: $CompanyName" -ForegroundColor Green
Write-Host "Next: set the admin password you want customers to receive, e.g.:" -ForegroundColor Green
Write-Host "   net user $env:USERNAME YourFixedPass123!" -ForegroundColor White
Write-Host "Then shut down:  shutdown /s /t 0   — and capture the disk (BUILD-FAST-IMAGE.md)." -ForegroundColor Green
