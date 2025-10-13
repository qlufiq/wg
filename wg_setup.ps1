#requires -version 5.1
param(
  [string]$ConfName = "client-5.conf",     # bisa: client-4.conf / client-6.conf
  [string]$DlDir    = "C:\ProgramData\vh-wg-setup",
  [switch]$NoVirtualHere,                  # jika tidak ingin jalankan VirtualHere
  [switch]$NoFirewall,                     # jika tidak ingin buat firewall rule
  [int]$ServiceStartTimeoutSec = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string]$msg){ Write-Host "[*] $msg" -ForegroundColor Cyan }
function Write-Info([string]$msg){ Write-Host "    $msg" -ForegroundColor Gray }
function Write-OK([string]$msg){ Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn([string]$msg){ Write-Host "    $msg" -ForegroundColor Yellow }
function Write-Err([string]$msg){ Write-Host "    $msg" -ForegroundColor Red }

function Ensure-Dir([string]$path){
  if(-not (Test-Path -LiteralPath $path)){
    $null = New-Item -ItemType Directory -Path $path
  }
}

function Download-IfNeeded {
  param(
    [Parameter(Mandatory=$true)][string]$Url,
    [Parameter(Mandatory=$true)][string]$OutPath,
    [int64]$MinBytes = 1,
    [string]$Sha256 = $null,
    [int]$Retries = 3,
    [int]$TimeoutSec = 120,
    [switch]$CacheBust                 # tambahkan ?t=<epoch> untuk raw github
  )
  Ensure-Dir ([System.IO.Path]::GetDirectoryName($OutPath))

  $srcUrl = $Url
  if($CacheBust){
    $tick = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $sep = ($Url -match '\?') ? '&' : '?'
    $srcUrl = "$Url${sep}t=$tick"
  }

  $exists = Test-Path -LiteralPath $OutPath
  if($exists){
    try { $len = (Get-Item -LiteralPath $OutPath).Length } catch { $len = 0 }
    if($len -ge $MinBytes){
      if($Sha256){
        try{
          $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutPath).Hash.ToLower()
          if($h -eq $Sha256.ToLower()){
            Write-Info "Skip download: $OutPath (OK, size=$len, sha256 match)"
            return $true
          } else { Write-Warn "Hash mismatch, re-download: $OutPath" }
        } catch { Write-Warn "Gagal hitung hash, re-download: $OutPath" }
      } else {
        Write-Info "Skip download: $OutPath (OK, size=$len)"
        return $true
      }
    } else {
      Write-Warn "File 0-byte/terlalu kecil, re-download: $OutPath"
    }
  }

  $tmp = "$OutPath.partial"
  if(Test-Path -LiteralPath $tmp){ Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }

  for($i=1; $i -le $Retries; $i++){
    try{
      Write-Info "Download [$i/$Retries]: $srcUrl → $tmp"
      $wc = New-Object System.Net.WebClient
      $wc.Headers.Add("User-Agent","PowerShell/SkipIfExists")
      $task = $wc.DownloadFileTaskAsync($srcUrl, $tmp)
      if(-not $task.Wait([TimeSpan]::FromSeconds($TimeoutSec))){ throw "Timeout $TimeoutSec s" }
      $wc.Dispose()

      $len = (Get-Item -LiteralPath $tmp).Length
      if($len -lt $MinBytes){ throw "Hasil download terlalu kecil ($len B)" }

      if($Sha256){
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $tmp).Hash.ToLower()
        if($hash -ne $Sha256.ToLower()){ throw "SHA256 mismatch ($hash)" }
      }

      Move-Item -Force -LiteralPath $tmp -Destination $OutPath
      Write-OK "OK: $OutPath (size=$len)"
      return $true
    } catch {
      Write-Warn "Retry karena: $($_.Exception.Message)"
      Start-Sleep -Seconds ([Math]::Min(5*$i, 15))
      if(Test-Path -LiteralPath $tmp){ Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
  }
  Write-Err "Gagal download setelah $Retries kali: $Url"
  return $false
}

function Get-WireGuardAdapters {
  try { Get-NetAdapter -InterfaceDescription "*WireGuard*" } catch { @() }
}

function Wait-ServiceRunning {
  param([Parameter(Mandatory=$true)][string]$ServiceName, [int]$TimeoutSec = 20)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    $s = sc.exe query $ServiceName | Out-String
    if ($s -match "STATE\s*:\s*4\s*RUNNING") { return $true }
    Start-Sleep -Milliseconds 500
  }
  return $false
}

# ====== KONFIG KONTEN (boleh edit sesuai repositori kamu) ======
$VH_Url      = 'https://virtualhere.com/sites/default/files/usbserver/v3/vhusbdwin64.exe'
$WG_Url      = 'https://download.wireguard.com/windows-client/wireguard-installer.exe'
$ConfBaseUrl = 'https://raw.githubusercontent.com/qlufiq/wg/refs/heads/main'  # ganti jika perlu

# ====== Main Flow ======
Ensure-Dir $DlDir

# (1) VirtualHere
Write-Step "[1/9] VirtualHere EXE..."
$VH_Path = Join-Path $DlDir 'vhusbdwin64.exe'
if(Download-IfNeeded -Url $VH_Url -OutPath $VH_Path -MinBytes 1024){
  Ensure-Dir 'C:\Program Files\VirtualHere'
  Copy-Item -Force $VH_Path 'C:\Program Files\VirtualHere\vhusbdwin64.exe'
  Write-Info 'Copied to: "C:\Program Files\VirtualHere\vhusbdwin64.exe"'
} else { exit 1 }

# (FW) Firewall
if(-not $NoFirewall){
  Write-Step "[FW] Buka firewall Private TCP 7575..."
  $fw = $null
  try { $fw = Get-NetFirewallRule -DisplayName "VH TCP 7575" -ErrorAction Stop } catch { }
  if($fw -eq $null){
    $null = New-NetFirewallRule -DisplayName "VH TCP 7575" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 7575 -Profile Private
  } else {
    Write-Info "Rule sudah ada"
  }
} else {
  Write-Warn "Lewati pembuatan firewall rule (permintaan pengguna)"
}

# (2) WireGuard installer
Write-Step "[2/9] WireGuard installer..."
$WG_Path = Join-Path $DlDir 'wireguard-installer.exe'
$null = Download-IfNeeded -Url $WG_Url -OutPath $WG_Path -MinBytes 1024

# (3) Install WireGuard (silent)
Write-Step "[3/9] Install WireGuard (silent)..."
$proc = Start-Process -FilePath $WG_Path -ArgumentList "/S" -Wait -PassThru -WindowStyle Hidden
Write-Info ("Installer exit code: {0}" -f $proc.ExitCode)
$wgExe = Join-Path $env:ProgramFiles 'WireGuard\wireguard.exe'
if(Test-Path $wgExe){ Write-OK "wireguard.exe OK" } else { Write-Err "wireguard.exe tidak ditemukan"; exit 1 }

# (4) Ambil config
Write-Step "[4/9] Config $ConfName..."
$ConfUrl  = "$ConfBaseUrl/$ConfName"
$ConfPath = Join-Path $DlDir $ConfName

# Jika config lama < 10 byte → hapus agar re-download bersih
if (Test-Path -LiteralPath $ConfPath) {
  try { $existLen = (Get-Item -LiteralPath $ConfPath).Length } catch { $existLen = 0 }
  if ($existLen -lt 10) {
    Write-Warn "Config lama 0-byte/invalid, hapus & re-download: $ConfPath"
    Remove-Item -LiteralPath $ConfPath -Force -ErrorAction SilentlyContinue
  }
}

if (Download-IfNeeded -Url $ConfUrl -OutPath $ConfPath -MinBytes 64 -CacheBust) {
  $len = (Get-Item -LiteralPath $ConfPath).Length
  Write-Info "Conf Path : $ConfPath"
  Write-Info "Conf Size : $len bytes"
  if ($len -lt 10) { Write-Err "Config tampak kosong/invalid"; exit 1 }
} else { exit 1 }

# (5) Validasi conf
Write-Step "[5/9] Validasi conf..."
$confText = Get-Content -Raw -LiteralPath $ConfPath
$valid = ($confText -match '\[Interface\]' -and $confText -match '\[Peer\]')
Write-Info "Valid=$valid"
if(-not $valid){ Write-Err "Config tidak valid"; exit 1 }

# (6) Bersihkan service lama
Write-Step "[6/9] Bersihkan service lama..."
$svcName = 'WireGuardTunnel$' + [System.IO.Path]::GetFileNameWithoutExtension($ConfName)
$null = sc.exe stop $svcName

# (7) Install service
Write-Step "[7/9] Install service..."
$null = & $wgExe /installtunnelservice $ConfPath
Write-Info "installtunnelservice code: $LASTEXITCODE"

# (8) Start service
Write-Step "[8/9] Start service via SCM..."
$null = sc.exe start $svcName
Write-Info ("sc start code: {0}" -f $LASTEXITCODE)
if (Wait-ServiceRunning -ServiceName $svcName -TimeoutSec $ServiceStartTimeoutSec) {
  Write-OK "Service RUNNING"
} else {
  Write-Warn "Masih START_PENDING/STOPPED setelah timeout"
}
# Tampilkan adapter WireGuard
$wgAdapters = Get-WireGuardAdapters
if ($wgAdapters -ne $null -and $wgAdapters.Count -gt 0) {
  $names = @(); foreach($a in $wgAdapters){ $names += $a.Name }
  $namesStr = [string]::Join(", ", $names)
  Write-OK ("WireGuard adapters: " + $namesStr)
} else {
  Write-Warn "Tidak menemukan adapter WireGuard."
}

# (9) Jalankan VirtualHere
if(-not $NoVirtualHere){
  Write-Step "[9/9] Jalankan VirtualHere (fallback)..."
  Start-Process -FilePath 'C:\Program Files\VirtualHere\vhusbdwin64.exe' -ArgumentList "-p 7575" -WindowStyle Hidden
} else {
  Write-Warn "Lewati menjalankan VirtualHere (permintaan pengguna)"
}
