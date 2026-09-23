<#
make-kiosk-usb.ps1 — make a USB stick that turns an S101AYCR110 tablet into
the kiosk with no typing on the tablet.

Boot the tablet from the stick and it: checks it's an S101AYCR110 (refuses
anything else), ERASES the internal drive, installs Ubuntu 24.04 with the
"operator" account, powers off. Pull the stick, power on, pick the Wi-Fi on
the login screen (network icon, top right; Ethernet needs nothing): the first
boot then runs the normal tablet setup from GitHub (latest code) and
reboots into the kiosk (~30-40 min, no one needs to log in).

Run in PowerShell AS ADMINISTRATOR (it wipes the stick you choose):
  powershell -ExecutionPolicy Bypass -File make-kiosk-usb.ps1 -ApplianceUrl 'https://DASHBOARD_HOST/'

It asks for the tablet's operator password, lists the USB drives and asks
which one to erase. Passwords are only written to the stick (operator password hashed; -WifiSsid/-WifiPassword put a Wi-Fi
network on it in plain text instead of picking it on the tablet).

Needs: the Ubuntu ISO (downloaded if missing), a USB stick of 8 GB or more,
and openssl (comes with Git for Windows) to hash the password.
#>
param(
  [Parameter(Mandatory = $true)][string]$ApplianceUrl,
  [string]$IsoPath = "$env:USERPROFILE\Downloads\ubuntu-24.04.5.1-desktop-amd64.iso",
  [string]$TimeZone = 'America/New_York',
  [string]$Hostname = 's101-kiosk',
  [string]$Username = 'operator',
  [string]$Model = 'S101AYCR110',   # '' = no model check (erases ANY computer booted from it)
  [string]$RustDeskPassword = '',
  [int]$DiskNumber = -1,
  [switch]$AllowLargeDisk,          # skip the 300 GB "not a USB stick" guard (e.g. fake-capacity sticks)
  # Build into a folder instead of a stick (testing, or to copy onto a stick formatted by hand)
  [string]$TargetFolder = '',
  [string]$WifiSsid = $null, [string]$WifiPassword = '', [string]$OperatorPassword = ''
)
$ErrorActionPreference = 'Stop'
$IsoUrl = 'https://releases.ubuntu.com/24.04/ubuntu-24.04.5.1-desktop-amd64.iso'
$IsoSha256 = '4da4a0c9035da8e68a59a838674f403f0a54472c78a83b4fb7f78d03588f85a7'
$RawBase = 'https://raw.githubusercontent.com/CleanEconomics/ubuntuscript2/main/usb'

function Write-Lf([string]$Path, [string]$Text) {
  # Linux files: LF endings, UTF-8 without BOM.
  [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
}
function Get-UsbFile([string]$Name) {
  $local = Join-Path $PSScriptRoot $Name
  if ($PSScriptRoot -and (Test-Path $local)) { return [IO.File]::ReadAllText($local) }
  return (Invoke-WebRequest -UseBasicParsing "$RawBase/$Name").Content
}
function ConvertTo-Plain([Security.SecureString]$s) {
  $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}
function Quote-Yaml([string]$s) { return "'" + $s.Replace("'", "''") + "'" }
function Quote-Sh([string]$s) { return "'" + $s.Replace("'", "'\''") + "'" }

if (-not $TargetFolder -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Run this in PowerShell as Administrator (right-click PowerShell > Run as administrator).'
}

# --- openssl for the password hash --------------------------------------------
$openssl = (Get-Command openssl -ErrorAction SilentlyContinue).Source
if (-not $openssl) {
  foreach ($p in 'C:\Program Files\Git\usr\bin\openssl.exe', 'C:\Program Files\Git\mingw64\bin\openssl.exe') { if (Test-Path $p) { $openssl = $p; break } }
}
if (-not $openssl) { throw 'openssl not found. Install Git for Windows (https://git-scm.com) and run again.' }

# --- Ubuntu ISO ------------------------------------------------------------------
if (-not (Test-Path $IsoPath)) {
  Write-Host "Downloading Ubuntu (6.2 GB) to $IsoPath ..."
  & curl.exe -L -C - -o $IsoPath $IsoUrl
}
Write-Host 'Checking the Ubuntu ISO...'
if ((Get-FileHash $IsoPath -Algorithm SHA256).Hash -ne $IsoSha256) { throw "ISO checksum mismatch: $IsoPath is damaged or the wrong file. Delete it and run again." }

# --- Settings ------------------------------------------------------------------------
Write-Host ''
# Wi-Fi is normally picked on the tablet's login screen at first boot; pass
# -WifiSsid (and -WifiPassword) only to put a network on the stick instead.
$ssid = $WifiSsid; $wifiPass = $WifiPassword
if ($OperatorPassword) { $p1 = $OperatorPassword }
else {
  do {
    $p1 = ConvertTo-Plain (Read-Host "Password for the tablet's '$Username' account" -AsSecureString)
    $p2 = ConvertTo-Plain (Read-Host 'Type it again' -AsSecureString)
    if ($p1 -ne $p2) { Write-Host 'Passwords do not match - try again.' -ForegroundColor Yellow }
    elseif ($p1.Length -lt 4) { Write-Host 'Use at least 4 characters.' -ForegroundColor Yellow; $p1 = $null; $p2 = 'x' }
  } while ($p1 -ne $p2)
}
# Via a temp file, not a pipe: PowerShell 5.1 re-encodes piped text, which
# silently hashes a different password.
$pwFile = [IO.Path]::GetTempFileName()
try {
  [IO.File]::WriteAllText($pwFile, "$p1`n", (New-Object Text.UTF8Encoding($false)))
  $hash = (& $openssl passwd -6 -in $pwFile | Select-Object -First 1).Trim()
} finally { Remove-Item $pwFile -Force -ErrorAction SilentlyContinue }
if ($hash -notmatch '^\$6\$') { throw 'Could not hash the password with openssl.' }

if ($TargetFolder) {
  New-Item -ItemType Directory -Force $TargetFolder | Out-Null
  $usbRoot = (Resolve-Path $TargetFolder).Path.TrimEnd('\') + '\'
} else {
# --- Pick the stick ------------------------------------------------------------------
$usb = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' -and -not $_.IsBoot -and -not $_.IsSystem })
if ($usb.Count -eq 0) { throw 'No USB drive found. Plug in the stick and run again.' }
Write-Host ''
Write-Host 'USB drives:'
$usb | ForEach-Object { Write-Host ("  Disk {0}: {1}  {2:N1} GB" -f $_.Number, $_.FriendlyName, ($_.Size / 1GB)) }
if ($DiskNumber -lt 0) { $DiskNumber = [int](Read-Host 'Disk number of the stick to ERASE') }
$disk = $usb | Where-Object { $_.Number -eq $DiskNumber }
if (-not $disk) { throw "Disk $DiskNumber is not one of the USB drives listed." }
if ($disk.Size -lt 7GB) { throw 'That stick is too small - it needs 8 GB or more.' }
if ($disk.Size -gt 300GB -and -not $AllowLargeDisk) { throw 'That drive is over 300 GB - refusing, it is probably not a USB stick (-AllowLargeDisk overrides).' }
$confirm = Read-Host ("Everything on Disk {0} ({1}) will be erased. Type ERASE to continue" -f $disk.Number, $disk.FriendlyName)
if ($confirm -cne 'ERASE') { throw 'Cancelled - nothing was changed.' }

# --- Format: one FAT32 partition (UEFI boots it directly) -------------------------------
Write-Host 'Formatting the stick...'
$disk | Clear-Disk -RemoveData -RemoveOEM -Confirm:$false
Initialize-Disk -Number $disk.Number -PartitionStyle MBR -ErrorAction SilentlyContinue
# 16 GB is plenty (Ubuntu needs ~6 GB) and stays near the start of the stick,
# inside the real capacity of fake "1 TB" sticks.
$size = [Math]::Min($disk.Size - 16MB, 16GB)
$part = New-Partition -DiskNumber $disk.Number -Size $size -IsActive -AssignDriveLetter
Start-Sleep 2
$vol = Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel 'KIOSKUSB' -Confirm:$false -Force
$usbRoot = "$($part.DriveLetter):\"
}

# --- Copy Ubuntu onto it --------------------------------------------------------------
Write-Host 'Copying Ubuntu to the stick (about 10 minutes)...'
$img = Mount-DiskImage -ImagePath $IsoPath -PassThru
try {
  $isoRoot = "$(($img | Get-Volume).DriveLetter):\"
  & robocopy.exe $isoRoot $usbRoot /E /R:2 /W:2 /NFL /NDL /NJH /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "Copy to the stick failed (robocopy $LASTEXITCODE)." }
} finally { Dismount-DiskImage -ImagePath $IsoPath | Out-Null }
Get-ChildItem $usbRoot -Recurse -Force | Where-Object { -not $_.PSIsContainer } | ForEach-Object { $_.IsReadOnly = $false }

# --- Kiosk files -------------------------------------------------------------------------
$kdir = Join-Path $usbRoot 'kiosk'
New-Item -ItemType Directory -Force $kdir | Out-Null
Write-Lf (Join-Path $kdir 'firstboot.sh') (Get-UsbFile 'firstboot.sh')
Write-Lf (Join-Path $kdir 'kiosk-firstboot.service') (Get-UsbFile 'kiosk-firstboot.service')
$envText = "APPLIANCE_URL=$(Quote-Sh $ApplianceUrl)`nKIOSK_USER=$(Quote-Sh $Username)`n"
if ($RustDeskPassword) { $envText += "RUSTDESK_PW=$(Quote-Sh $RustDeskPassword)`n" }
Write-Lf (Join-Path $kdir 'kiosk-firstboot.env') $envText
if ($ssid) {
  Write-Lf (Join-Path $kdir 'wifi.nmconnection') @"
[connection]
id=kiosk-wifi
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=$ssid

[wifi-security]
key-mgmt=wpa-psk
psk=$wifiPass

[ipv4]
method=auto

[ipv6]
method=auto
"@
}

$guard = ''
if ($Model) {
  $guard = @"
  early-commands:
    - sh -c 'grep -qs "$Model" /sys/class/dmi/id/product_name /sys/class/dmi/id/board_name || { echo "This is not an $Model tablet - refusing to erase it."; exit 1; }'
"@
}
Write-Lf (Join-Path $usbRoot 'autoinstall.yaml') @"
# Written by make-kiosk-usb.ps1 - unattended Ubuntu install for the kiosk tablet.
autoinstall:
  version: 1
$guard
  source:
    id: ubuntu-desktop-minimal
  locale: en_US.UTF-8
  keyboard:
    layout: us
  timezone: $TimeZone
  identity:
    realname: Operator
    hostname: $Hostname
    username: $Username
    password: $(Quote-Yaml $hash)
  storage:
    layout:
      name: direct
  codecs:
    install: false
  drivers:
    install: false
  late-commands:
    - install -m 755 /cdrom/kiosk/firstboot.sh /target/usr/local/sbin/kiosk-firstboot.sh
    - install -m 644 /cdrom/kiosk/kiosk-firstboot.service /target/etc/systemd/system/kiosk-firstboot.service
    - install -m 600 /cdrom/kiosk/kiosk-firstboot.env /target/etc/kiosk-firstboot.env
    - mkdir -p /target/etc/systemd/system/multi-user.target.wants
    - ln -sf /etc/systemd/system/kiosk-firstboot.service /target/etc/systemd/system/multi-user.target.wants/kiosk-firstboot.service
    - sh -c 'if [ -f /cdrom/kiosk/wifi.nmconnection ]; then install -D -m 600 /cdrom/kiosk/wifi.nmconnection /target/etc/NetworkManager/system-connections/kiosk-wifi.nmconnection; fi'
  shutdown: poweroff
"@

# --- Boot menu: automatic kiosk install first, 10 s timeout -------------------------------
$grubCfg = Join-Path $usbRoot 'boot\grub\grub.cfg'
$grub = [IO.File]::ReadAllText($grubCfg) -replace "`r`n", "`n"
$entry = @"
menuentry "S101 KIOSK - ERASE THIS TABLET AND INSTALL (automatic)" {
	set gfxpayload=keep
	linux	/casper/vmlinuz autoinstall  --- quiet splash
	initrd	/casper/initrd
}
"@
$grub = $grub -replace 'set timeout=\d+', "set default=0`nset timeout=10"
$grub = $grub -replace '(?m)^menuentry "Try or Install Ubuntu"', ($entry.Replace("`r`n", "`n") + "`nmenuentry `"Try or Install Ubuntu`"")
Write-Lf $grubCfg $grub
if ($grub -notmatch 'autoinstall') { throw 'Could not add the automatic install entry to the boot menu.' }

Write-Host ''
Write-Host "Done - $usbRoot is ready." -ForegroundColor Green
Write-Host '  1. Plug it into the tablet, power on tapping F7, pick the "UEFI:" USB entry.'
Write-Host '     The menu on the stick starts the kiosk install by itself after 10 seconds.'
Write-Host '  2. It erases the tablet, installs Ubuntu and powers OFF (about 15 min).'
Write-Host '  3. Pull the stick out, power on. On the login screen tap the network icon (top'
Write-Host '     right) and pick the Wi-Fi - or plug in Ethernet. Do not log in.'
Write-Host '  4. The kiosk setup then runs by itself (~30-40 min) and reboots into the kiosk.'
Write-Host '  Setup log on the tablet: /var/log/kiosk-firstboot.log'
exit 0
