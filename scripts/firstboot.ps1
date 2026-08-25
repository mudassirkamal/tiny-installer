# firstboot.ps1 - the complete first-boot routine for a Fomze golden image.
# The image bakes only a thin bootstrapper (see prepare-windows.ps1) that fetches
# THIS file from the panel and runs it once per clone. Keeping the logic here
# means you can change branding/optimization ANY TIME by editing this file on the
# panel - no need to rebuild the image.
#
# Runs once, as SYSTEM, at first boot of a freshly dd'd clone. It:
#   - extends C: to the full disk
#   - sets a fresh random administrator password + enables RDP on port 22
#   - reports the credentials back to the panel BY IP (so the panel shows them)
#   - applies FOMZE wallpaper + Chrome + performance policies
#   - streams a staged live feed, then marks the server online
#
# __API_BASE__ is replaced by the panel when it serves this file.

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"
# Older Windows (2016/2019) default to TLS 1.0 which the panel's HTTPS rejects.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
$panel   = "__API_BASE__"
$company = "Fomze"
$wallUrl = "https://res.cloudinary.com/dikxngewb/image/upload/v1787536969/fomze_vps_twsw6y.png"
$user    = "administrator"
$port    = 22   # default; overridden below by the operator's chosen port

function EnsureKey($p){ if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null } }

# wait for network (up to ~90s)
for ($i=0; $i -lt 45; $i++) { if (Test-Connection -Count 1 -Quiet -ComputerName 8.8.8.8) { break }; Start-Sleep 2 }

# public IP (to match this clone to its deployment on the panel)
$ip = ""
foreach ($u in @("https://api.ipify.org","https://ifconfig.me/ip","https://icanhazip.com")) {
  try { $ip = ("$((Invoke-RestMethod -Uri $u -TimeoutSec 8))").Trim(); if ($ip) { break } } catch {}
}
# post a live-feed line to the panel BY IP (best-effort)
function Report($stage, $msg, $status, $extra) {
  if (-not $ip) { return }
  $b = @{ ip=$ip; stage=$stage; message=$msg }
  if ($status) { $b.status = $status }
  if ($extra)  { foreach ($k in $extra.Keys) { $b[$k] = $extra[$k] } }
  try { Invoke-RestMethod -Uri "$panel/api/report-by-ip" -Method Post -Body ($b | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 15 | Out-Null } catch {}
}

# fetch the operator's chosen port / username / browser for this deployment by IP,
# so a generic golden image still honours what was picked in the panel
$browser = ""
if ($ip) {
  try {
    $cfg = Invoke-RestMethod -Uri "$panel/api/deploy-config-by-ip?ip=$ip" -TimeoutSec 15
    if ($cfg.port)     { $port = [int]$cfg.port }
    if ($cfg.username) { $user = "$($cfg.username)" }
    if ($cfg.browser)  { $browser = "$($cfg.browser)" }
  } catch {}
}

Report "boot" "Windows booted - configuring your server"

# ------------------------------------------------------ extend C: to full disk
try { $m = (Get-PartitionSupportedSize -DriveLetter C).SizeMax; Resize-Partition -DriveLetter C -Size $m -ErrorAction SilentlyContinue } catch {}
try { "select volume C`r`nextend" | diskpart | Out-Null } catch {}
Report "disk" "Expanded system disk to full size"

# ------------------------------------------- fresh random admin password + RDP
$chars = (48..57)+(65..90)+(97..122)
$pw = (-join ($chars | Get-Random -Count 14 | ForEach-Object {[char]$_})) + "@9"
# ensure the account exists (the image ships with "administrator"; if the operator
# chose a different username, create it and make it an admin)
net user "$user" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  cmd /c "net user `"$user`" `"$pw`" /add" | Out-Null
  cmd /c "net localgroup administrators `"$user`" /add" | Out-Null
} else {
  cmd /c "net user `"$user`" `"$pw`"" | Out-Null
}
cmd /c "net user `"$user`" /active:yes" | Out-Null
try { Set-LocalUser -Name $user -PasswordNeverExpires $true -ErrorAction SilentlyContinue } catch {}
# RDP on + set the chosen port + firewall (both the built-in group and our rule)
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0 -ErrorAction SilentlyContinue
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name PortNumber -Value $port -ErrorAction SilentlyContinue
cmd /c "netsh advfirewall firewall add rule name=`"TI-RDP`" dir=in action=allow protocol=TCP localport=$port" | Out-Null
Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
Restart-Service TermService -Force -ErrorAction SilentlyContinue
# tell the panel the real credentials right away (so it shows the correct password + port)
Report "account" "Created $user account and enabled Remote Desktop on port $port" "installing" @{ username=$user; password=$pw; port=$port }

# ------------------------------------------------- bake a password-reset watcher
# A boot task that applies C:\ti-reset\newpass.txt if present, so the password can
# be reset later just by dropping that file from the provider's Rescue System
# (reliable - it runs inside Windows via net user, no offline SAM editing).
New-Item -ItemType Directory -Force -Path "C:\ti-agent" | Out-Null
$watch = @"
`$acct = "$user"
`$f = "C:\ti-reset\newpass.txt"
if (Test-Path `$f) {
  `$p = [IO.File]::ReadAllText(`$f) -replace "(\r|\n)+`$",""
  "[`$(Get-Date)] TIResetWatch acct=`$acct len=`$(`$p.Length)" | Out-File -Append "C:\resetpw.log"
  if (`$p) {
    try { Set-LocalUser -Name `$acct -Password (ConvertTo-SecureString `$p -AsPlainText -Force); Enable-LocalUser -Name `$acct; "watch Set-LocalUser OK" | Out-File -Append "C:\resetpw.log" }
    catch { cmd /c "net user `"`$acct`" `"`$p`"" | Out-Null; "watch fallback" | Out-File -Append "C:\resetpw.log" }
  }
  Remove-Item `$f -Force -ErrorAction SilentlyContinue
  Remove-Item "C:\ti-reset" -Force -Recurse -ErrorAction SilentlyContinue
}
"@
Set-Content -Path "C:\ti-agent\reset-watch.ps1" -Value $watch -Encoding ASCII
schtasks /create /tn "TIResetWatch" /tr "powershell -NoProfile -ExecutionPolicy Bypass -File C:\ti-agent\reset-watch.ps1" /sc onstart /ru SYSTEM /rl HIGHEST /f | Out-Null

# ------------------------------------------------- performance policies + tweaks
# never lock the account from failed logins (internet brute-force bots would
# otherwise lock the administrator out of an internet-facing VPS)
cmd /c "net accounts /lockoutthreshold:0" | Out-Null
try { powercfg /setactive SCHEME_MIN } catch {}
powercfg /change standby-timeout-ac 0 2>$null
powercfg /change monitor-timeout-ac 0 2>$null
powercfg /h off 2>$null
EnsureKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name VisualFXSetting -Value 2 -Type DWord -ErrorAction SilentlyContinue
EnsureKey 'HKLM:\SOFTWARE\Microsoft\ServerManager'
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name DoNotOpenServerManagerAtLogon -Value 1 -Type DWord -ErrorAction SilentlyContinue
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}' -Name IsInstalled -Value 0 -ErrorAction SilentlyContinue
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}' -Name IsInstalled -Value 0 -ErrorAction SilentlyContinue
EnsureKey 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name AllowTelemetry -Value 0 -Type DWord -ErrorAction SilentlyContinue
try { Set-Service DiagTrack -StartupType Disabled -ErrorAction SilentlyContinue; Stop-Service DiagTrack -Force -ErrorAction SilentlyContinue } catch {}
EnsureKey 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name NetworkThrottlingIndex -Value 0xffffffff -Type DWord -ErrorAction SilentlyContinue
# 1) no Shutdown Event Tracker ("why did you shut down" dialog)
EnsureKey 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability'
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability' -Name ShutdownReasonOn -Value 0 -Type DWord -ErrorAction SilentlyContinue
# 2) no "set network location" prompt + make networks Private
EnsureKey 'HKLM:\SYSTEM\CurrentControlSet\Control\Network\NewNetworkWindowOff'
try { Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue } catch {}
# 4) SysMain/Superfetch off (unneeded on SSD, saves I/O)
try { Set-Service SysMain -StartupType Disabled -ErrorAction SilentlyContinue; Stop-Service SysMain -Force -ErrorAction SilentlyContinue } catch {}
# 5) Print Spooler off (perf + PrintNightmare security; no printing on a VPS)
try { Set-Service Spooler -StartupType Disabled -ErrorAction SilentlyContinue; Stop-Service Spooler -Force -ErrorAction SilentlyContinue } catch {}
# 6) RDP keep-alive so idle sessions don't drop
EnsureKey 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name KeepAliveEnable   -Value 1 -Type DWord -ErrorAction SilentlyContinue
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name KeepAliveInterval -Value 1 -Type DWord -ErrorAction SilentlyContinue
# 7) no first-logon animation + no consumer features/tips/ads
EnsureKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableFirstLogonAnimation -Value 0 -Type DWord -ErrorAction SilentlyContinue
EnsureKey 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name DisableWindowsConsumerFeatures -Value 1 -Type DWord -ErrorAction SilentlyContinue
# 9) IE + Edge first-run experience off
EnsureKey 'HKLM:\SOFTWARE\Policies\Microsoft\Internet Explorer\Main'
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Internet Explorer\Main' -Name DisableFirstRunCustomize -Value 1 -Type DWord -ErrorAction SilentlyContinue
EnsureKey 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name HideFirstRunExperience -Value 1 -Type DWord -ErrorAction SilentlyContinue
Report "optimize" "Applied performance settings and policies"

# --------------------------------------- wallpaper + per-user desktop preferences
$wp = ""
try {
  $dir = "C:\Windows\Web\Wallpaper\Fomze"; New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $wp = Join-Path $dir "wallpaper.jpg"
  if (Get-Command curl.exe -ErrorAction SilentlyContinue) { curl.exe -s -L -o $wp $wallUrl } else { Invoke-WebRequest $wallUrl -OutFile $wp -UseBasicParsing }
  if (-not (Test-Path $wp)) { $wp = "" }
} catch { $wp = "" }
# We run as SYSTEM before the admin logs in, so apply per-user settings into EACH
# user hive (offline) + the Default profile: wallpaper (3=This PC/User Files icons,
# 8=show file extensions + hidden files). Shows the moment the customer connects.
function SetUserPrefs($h) {
  if ($wp) {
    reg add "$h\Control Panel\Desktop" /v Wallpaper      /t REG_SZ /d "$wp" /f | Out-Null
    reg add "$h\Control Panel\Desktop" /v WallpaperStyle /t REG_SZ /d 10   /f | Out-Null
    reg add "$h\Control Panel\Desktop" /v TileWallpaper  /t REG_SZ /d 0    /f | Out-Null
  }
  $ns = "$h\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
  reg add "$ns" /v "{20D04FE0-3AEA-1069-A2D8-08002B30309D}" /t REG_DWORD /d 0 /f | Out-Null
  reg add "$ns" /v "{59031a47-3f72-44a7-89c5-5595fe6b30ee}" /t REG_DWORD /d 0 /f | Out-Null
  $adv = "$h\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
  reg add "$adv" /v HideFileExt /t REG_DWORD /d 0 /f | Out-Null
  reg add "$adv" /v Hidden      /t REG_DWORD /d 1 /f | Out-Null
}
Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
  $dat = Join-Path $_.FullName "NTUSER.DAT"
  if (Test-Path $dat) {
    $tag = "TIW_" + $_.Name
    reg load "HKU\$tag" "$dat" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { SetUserPrefs "HKU\$tag"; reg unload "HKU\$tag" 2>$null | Out-Null }
  }
}
reg load "HKU\DEF" "C:\Users\Default\NTUSER.DAT" 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { SetUserPrefs "HKU\DEF"; reg unload "HKU\DEF" 2>$null | Out-Null }
# Robust fallback: also force the wallpaper live at the next user logon (covers
# profiles whose hive couldn't be edited offline - e.g. an already-active session
# baked into the image). Re-applies each logon; harmless + keeps branding.
try {
  $setwp = @'
Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public class TIW { [DllImport("user32.dll",CharSet=CharSet.Auto)] public static extern int SystemParametersInfo(int a,int b,string c,int d); }'
[TIW]::SystemParametersInfo(20,0,"C:\Windows\Web\Wallpaper\Fomze\wallpaper.jpg",3) | Out-Null
'@
  Set-Content -Path "C:\ti-agent\setwp.ps1" -Value $setwp -Encoding ASCII
  schtasks /create /tn "TIWallpaper" /tr "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\ti-agent\setwp.ps1" /sc onlogon /rl LIMITED /f | Out-Null
} catch {}
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name RegisteredOrganization -Value $company -ErrorAction SilentlyContinue
Report "brand" "Applied $company wallpaper and branding"

# ------------------------------------------------------- optional browser install
# Only installs the browser the operator picked in the panel (empty = none).
function Get-File($url, $out) {
  try {
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) { curl.exe -s -L -o $out $url } else { Invoke-WebRequest $url -OutFile $out -UseBasicParsing }
    return (Test-Path $out)
  } catch { return $false }
}
if ($browser) {
  $b = $browser.ToLower()
  try {
    if ($b -eq "chrome") {
      # Enterprise MSI installs silently + reliably as SYSTEM
      $msi = "$env:TEMP\chrome.msi"
      if (Get-File "https://dl.google.com/tag/s/dl/chrome/install/googlechromestandaloneenterprise64.msi" $msi) {
        Start-Process msiexec.exe -ArgumentList "/i","`"$msi`"","/qn","/norestart" -Wait
      }
    } elseif ($b -eq "firefox") {
      $f = "$env:TEMP\ff.exe"
      if (Get-File "https://download.mozilla.org/?product=firefox-latest&os=win64&lang=en-US" $f) { Start-Process $f -ArgumentList "/S" -Wait }
    } elseif ($b -eq "brave") {
      $f = "$env:TEMP\brave.exe"
      if (Get-File "https://laptop-updates.brave.com/latest/winx64" $f) { Start-Process $f -ArgumentList "/silent","/install" -Wait }
    } elseif ($b -eq "edge") {
      $f = "$env:TEMP\edge.msi"
      if (Get-File "https://go.microsoft.com/fwlink/?linkid=2093437" $f) { Start-Process msiexec.exe -ArgumentList "/i","`"$f`"","/qn","/norestart" -Wait }
    }
    Report "apps" "Installed $browser"
  } catch {}
}

# ------------------------------------------------------------------------ done
Report "done" "Setup complete - your server is ready" "online" @{ username=$user; password=$pw; port=$port }
