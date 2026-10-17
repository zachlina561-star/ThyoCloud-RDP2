# ============================================================================
#  persist-state.ps1 — Simpan state sesi RDP lintas sesi (Anti-Reset v2)
# ----------------------------------------------------------------------------
#  Menyimpan:
#    1) Profil user RDP ($env:RDP_USER):
#       - Desktop, Documents (termasuk GTA San Andreas User Files / SAMP),
#         Downloads, Pictures, Music, Videos
#       - AppData\Roaming\.minecraft (world saves, options.txt, servers.dat,
#         mods, resourcepacks), AppData\Roaming\PrismLauncher, .tlauncher
#    2) Folder Permanen lintas sesi:
#       - C:\Persist (shortcut "Folder Permanen (Anti-Reset)" di Desktop)
#       - C:\Games (instalasi GTA SA-MP, SilentPatch, launcher portable)
#    3) Registry Game & Sesi:
#       - HKCU\Software\SAMP (PlayerName, gta_sa_exe)
#    4) Identitas Node Tailscale (C:\ProgramData\Tailscale):
#       - Agar sesi berikutnya tetap mendapatkan IP Tailscale 100.x yang sama
#
#  Penyimpanan Ganda (Dual-Storage):
#    - Arsip lokal C:\XyRDP\persist\xyrdp-state.zip (untuk upload-artifact@v4)
#    - GitHub Release tag 'xyrdp-state-latest' (tahan terhadap cleanup run lama
#      dan mendukung checkpoint berkala setiap 15 menit dari keepalive.ps1)
# ============================================================================
param(
  [switch]$Checkpoint
)

$XyTag = if ($Checkpoint) { 'XyRDP:checkpoint' } else { 'XyRDP:persist' }
. "$PSScriptRoot/lib-common.ps1"

$u = if ($env:RDP_USER) { $env:RDP_USER.Trim() } else { (Get-Cfg).rdp_user }
$prof = "C:\Users\$u"
$outDir = 'C:\XyRDP\persist'
$stage  = Join-Path $outDir 'stage'
$zip    = Join-Path $outDir 'xyrdp-state.zip'
$maxBytes = 1900L * 1024 * 1024  # batas aman ~1.9 GB

New-Item -ItemType Directory -Path $outDir -Force | Out-Null
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
if (-not $Checkpoint) {
  Remove-Item $zip -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $stage -Force | Out-Null

# Pastikan C:\Persist selalu ada
New-Item -ItemType Directory -Path 'C:\Persist' -Force -ErrorAction SilentlyContinue | Out-Null

$skipExts = @('.iso','.wim','.vhd','.vhdx','.vmdk','.dmp','.tmp','.part','.crdownload')
$skipDirs = @('cache','caches','code cache','gpucache','shadercache','crashpad','logs','temp','tmp','webcache','blob_storage','crash-reports')

$script:totalBytes = 0L
$script:totalFiles = 0

function Copy-FilteredTree([string]$SrcRoot, [string]$DstRoot, [string]$Label) {
  if (-not (Test-Path $SrcRoot)) { return }
  $rootPath = (Get-Item $SrcRoot -Force).FullName.TrimEnd('\')
  Get-ChildItem -Path $rootPath -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
    try {
      if ($_.Name -eq 'desktop.ini' -or $_.Name -eq 'thumbs.db') { return }
      $ext = $_.Extension.ToLower()
      if ($skipExts -contains $ext) { return }
      if ($_.Length -gt 700MB) {
        if (-not $Checkpoint) { Log "  skip >700MB: $($_.FullName) ($([math]::Round($_.Length/1MB,1)) MB)" }
        return
      }
      if (($script:totalBytes + $_.Length) -gt $maxBytes) { return }

      $rel = $_.FullName.Substring($rootPath.Length).TrimStart('\')
      $parts = $rel -split '[\\/]'
      foreach ($p in $parts) {
        if ($skipDirs -contains $p.ToLower()) { return }
      }

      $dest = Join-Path $DstRoot $rel
      $destParent = Split-Path $dest -Parent
      if (-not (Test-Path $destParent)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
      }
      Copy-Item $_.FullName -Destination $dest -Force -ErrorAction Stop
      $script:totalBytes += $_.Length
      $script:totalFiles++
    } catch {}
  }
}

# 1. Folder profil utama user RDP
if (Test-Path $prof) {
  foreach ($d in @('Desktop','Documents','Downloads','Pictures','Music','Videos')) {
    Copy-FilteredTree (Join-Path $prof $d) (Join-Path $stage $d) $d
  }

  # 2. Minecraft & Launcher data di AppData\Roaming
  $roaming = Join-Path $prof 'AppData\Roaming'
  foreach ($appDir in @('.minecraft','PrismLauncher','.tlauncher')) {
    $srcApp = Join-Path $roaming $appDir
    if (Test-Path $srcApp) {
      Copy-FilteredTree $srcApp (Join-Path $stage "_appdata_roaming\$appDir") "Roaming\$appDir"
    }
  }
}

# 3. Folder Permanen C:\Persist & C:\Games
if (Test-Path 'C:\Persist') {
  Copy-FilteredTree 'C:\Persist' (Join-Path $stage '_persist') 'C:\Persist'
}
if (Test-Path 'C:\Games') {
  Copy-FilteredTree 'C:\Games' (Join-Path $stage '_games') 'C:\Games'
}

# 4. Ekspor Registry HKCU\Software\SAMP (dan hive user RDP bila sedang login di sesi lain)
try {
  $regDir = Join-Path $stage '_registry'
  New-Item -ItemType Directory -Path $regDir -Force | Out-Null
  $sampRegOut = Join-Path $regDir 'samp-hkcu.reg'
  & reg.exe export 'HKCU\Software\SAMP' $sampRegOut /y 2>&1 | Out-Null

  # Cari SID user RDP di HKU kalau proses Actions jalan sebagai runneradmin
  try {
    $ntAccount = New-Object System.Security.Principal.NTAccount($u)
    $sid = $ntAccount.Translate([System.Security.Principal.SecurityIdentifier]).Value
    if ($sid -and (Test-Path "Registry::HKEY_USERS\$sid\Software\SAMP")) {
      $sampSidOut = Join-Path $regDir 'samp-user.reg'
      & reg.exe export "HKU\$sid\Software\SAMP" $sampSidOut /y 2>&1 | Out-Null
      if (Test-Path $sampSidOut) {
        $rawReg = Get-Content $sampSidOut -Raw -ErrorAction SilentlyContinue
        if ($rawReg) {
          ($rawReg -replace [regex]::Escape("HKEY_USERS\$sid"), 'HKEY_CURRENT_USER') | Set-Content -Path $sampRegOut -Encoding Unicode -Force
          Remove-Item $sampSidOut -Force -ErrorAction SilentlyContinue
        }
      }
      $script:totalFiles++
    }
  } catch {}
} catch {}

# 5. Simpan state Tailscale (server-state.conf) agar IP Tailscale 100.x tidak berubah antar sesi
try {
  $tsData = 'C:\ProgramData\Tailscale'
  if (Test-Path $tsData) {
    $tsDst = Join-Path $stage '_tailscale'
    New-Item -ItemType Directory -Path $tsDst -Force | Out-Null
    Get-ChildItem -Path $tsData -File -Force -ErrorAction SilentlyContinue | Where-Object {
      $_.Name -match '\.(conf|json|key|state)$' -and $_.Length -lt 5MB
    } | ForEach-Object {
      Copy-Item $_.FullName -Destination (Join-Path $tsDst $_.Name) -Force -ErrorAction SilentlyContinue
      $script:totalFiles++
    }
  }
} catch {}

if ($script:totalFiles -eq 0) {
  if (-not $Checkpoint) { Log 'Tidak ada file baru untuk disimpan.' }
  Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
  exit 0
}

# Tulis metadata sesi
@{
  user       = $u
  saved_at   = [DateTime]::UtcNow.ToString('o')
  run_id     = $env:GITHUB_RUN_ID
  checkpoint = [bool]$Checkpoint
  files      = $script:totalFiles
  bytes      = $script:totalBytes
} | ConvertTo-Json | Set-Content (Join-Path $stage '_meta.json') -Encoding UTF8

# Kompresi super cepat dengan 7-Zip multi-thread (-mx=1 -mmt=on -ssw), fallback ke Compress-Archive
$sevenZip = 'C:\Program Files\7-Zip\7z.exe'
$tmpZip = Join-Path $outDir 'xyrdp-state-tmp.zip'
Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue

try {
  if (Test-Path $sevenZip) {
    & $sevenZip a -tzip -mx=1 -mmt=on -ssw $tmpZip "$stage\*" 2>&1 | Out-Null
  } else {
    Compress-Archive -Path "$stage\*" -DestinationPath $tmpZip -CompressionLevel Fastest -Force
  }
  if (Test-Path $tmpZip) {
    Move-Item -Path $tmpZip -Destination $zip -Force
    $szMb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
    Log "State berhasil dikemas: $($script:totalFiles) file ($([math]::Round($script:totalBytes/1MB,1)) MB -> zip $szMb MB)"
  }
} catch {
  Log "Kompresi state gagal: $($_.Exception.Message)"
}
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

# Upload ke GitHub Release Tag 'xyrdp-state-latest' agar tahan terhadap cleanup-actions.ps1
if ((Test-Path $zip) -and $env:GITHUB_TOKEN -and $env:GITHUB_REPOSITORY) {
  try {
    $apiBase = "https://api.github.com/repos/$($env:GITHUB_REPOSITORY)"
    $hdr = @{
      Authorization          = "Bearer $($env:GITHUB_TOKEN)"
      Accept                 = 'application/vnd.github+json'
      'X-GitHub-Api-Version' = '2022-11-28'
      'User-Agent'           = 'XyRDP-Persist'
    }
    $tagName = 'xyrdp-state-latest'
    $rel = $null
    try {
      $rel = Invoke-RestMethod -Uri "$apiBase/releases/tags/$tagName" -Headers $hdr -Method Get -TimeoutSec 20 -ErrorAction Stop
    } catch {}

    if (-not $rel) {
      $body = @{
        tag_name   = $tagName
        name       = 'XyRDP Persistent Session State (Auto-Save)'
        body       = 'Arsip otomatis penyimpanan data sesi XyRDP lintas sesi (jangan dihapus bila ingin file tetap tersimpan).'
        draft      = $false
        prerelease = $true
      } | ConvertTo-Json
      $rel = Invoke-RestMethod -Uri "$apiBase/releases" -Headers $hdr -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 25 -ErrorAction Stop
    }

    if ($rel -and $rel.id) {
      # Hapus asset lama bila ada
      foreach ($asset in @($rel.assets)) {
        if ($asset -and $asset.name -eq 'xyrdp-state.zip') {
          try {
            Invoke-RestMethod -Uri "$apiBase/releases/assets/$($asset.id)" -Headers $hdr -Method Delete -TimeoutSec 15 -ErrorAction SilentlyContinue | Out-Null
          } catch {}
        }
      }
      $uploadUrl = ($rel.upload_url -replace '\{\?name,label\}$', '') + '?name=xyrdp-state.zip'
      $upHdr = @{
        Authorization          = "Bearer $($env:GITHUB_TOKEN)"
        Accept                 = 'application/vnd.github+json'
        'Content-Type'         = 'application/zip'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'XyRDP-Persist'
      }
      Invoke-RestMethod -Uri $uploadUrl -Headers $upHdr -Method Post -InFile $zip -TimeoutSec 180 -ErrorAction Stop | Out-Null
      Log "State berhasil di-backup ke Release '$tagName' (anti-reset lintas sesi aktif)."
    }
  } catch {
    Log "Backup ke Release '$tagName' dilewati: $($_.Exception.Message)"
  }
}
exit 0
