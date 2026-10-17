# ============================================================================
#  restore-state.ps1 — Pulihkan state sesi RDP dari sesi sebelumnya (Anti-Reset v2)
# ----------------------------------------------------------------------------
#  Mencari sumber state terbaru dari:
#    1) GitHub Release tag 'xyrdp-state-latest' (tahan terhadap cleanup run)
#    2) GitHub Actions Artifact 'xyrdp-state' (fallback)
#
#  Memulihkan:
#    - Desktop, Documents (GTA San Andreas User Files / SAMP), Downloads,
#      Pictures, Music, Videos
#    - %APPDATA%\.minecraft, PrismLauncher, .tlauncher
#    - C:\Persist (beserta shortcut Desktop "Folder Permanen (Anti-Reset)")
#    - C:\Games (instalasi GTA SA-MP, SilentPatch, launcher)
#    - Registry HKCU\Software\SAMP (PlayerName & gta_sa_exe)
#    - Identitas Tailscale C:\ProgramData\Tailscale (agar IP 100.x tetap sama)
# ============================================================================

$XyTag = 'XyRDP:restore'
. "$PSScriptRoot/lib-common.ps1"

$u = if ($env:RDP_USER) { $env:RDP_USER.Trim() } else { (Get-Cfg).rdp_user }
$prof = "C:\Users\$u"

# Pastikan folder C:\Persist dan C:\Games selalu siap beserta shortcut Desktop
New-Item -ItemType Directory -Path 'C:\Persist' -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path 'C:\Games'   -Force -ErrorAction SilentlyContinue | Out-Null

function Ensure-PersistShortcut([string]$UserDesktop) {
  if (-not (Test-Path $UserDesktop)) {
    New-Item -ItemType Directory -Path $UserDesktop -Force -ErrorAction SilentlyContinue | Out-Null
  }
  try {
    $readme = 'C:\Persist\BACA-SAYA-ANTI-RESET.txt'
    if (-not (Test-Path $readme)) {
      @(
        '===================================================================='
        ' FOLDER PERMANEN XyRDP (ANTI-RESET LINTAS SESI)'
        '===================================================================='
        'Semua file yang kamu taruh di dalam:'
        '  1. C:\Persist (Folder ini)'
        '  2. C:\Games'
        '  3. Desktop, Documents, Downloads'
        '  4. %APPDATA%\.minecraft & Documents\GTA San Andreas User Files'
        ''
        'Akan OTOMATIS DISIMPAN setiap 15 menit dan saat sesi berakhir,'
        'lalu DIPULIHKAN OTOMATIS pada sesi RDP berikutnya!'
        '===================================================================='
      ) | Set-Content -Path $readme -Encoding UTF8 -Force
    }
    $wsh = New-Object -ComObject WScript.Shell
    $lnk = $wsh.CreateShortcut((Join-Path $UserDesktop 'Folder Permanen (Anti-Reset).lnk'))
    $lnk.TargetPath = 'C:\Persist'
    $lnk.Description = 'Folder Permanen Anti-Reset Lintas Sesi XyRDP'
    $lnk.IconLocation = 'shell32.dll,43'
    $lnk.Save()
  } catch {}
}

if (-not $env:GITHUB_TOKEN -or -not $env:GITHUB_REPOSITORY) {
  Log 'GITHUB_TOKEN tidak tersedia — lewati restore.'
  exit 0
}

$hdr = @{
  Authorization          = "Bearer $($env:GITHUB_TOKEN)"
  Accept                 = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2022-11-28'
  'User-Agent'           = 'XyRDP-Restore'
}
$apiBase = "https://api.github.com/repos/$($env:GITHUB_REPOSITORY)"

$tmp = 'C:\XyRDP\restore'
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$zip = Join-Path $tmp 'state.zip'
$ext = Join-Path $tmp 'ext'
Remove-Item $zip -Force -ErrorAction SilentlyContinue
Remove-Item $ext -Recurse -Force -ErrorAction SilentlyContinue

# Cari kandidat dari Release 'xyrdp-state-latest' dan Artifact 'xyrdp-state', pilih yang paling baru
$releaseAssetUrl = $null
$releaseUpdated  = [DateTime]::MinValue
$releaseSizeMb   = 0

try {
  $rel = Invoke-RestMethod -Uri "$apiBase/releases/tags/xyrdp-state-latest" -Headers $hdr -Method Get -TimeoutSec 20 -ErrorAction Stop
  foreach ($a in @($rel.assets)) {
    if ($a -and $a.name -eq 'xyrdp-state.zip') {
      $releaseAssetUrl = "$apiBase/releases/assets/$($a.id)"
      $releaseUpdated  = [DateTime]::Parse("$($a.updated_at)").ToUniversalTime()
      $releaseSizeMb   = [math]::Round($a.size / 1MB, 1)
      break
    }
  }
} catch {}

$artifactUrl     = $null
$artifactUpdated = [DateTime]::MinValue
$artifactSizeMb  = 0

try {
  $resp = Invoke-RestMethod -Uri "$apiBase/actions/artifacts?name=xyrdp-state&per_page=5" -Headers $hdr -Method Get -TimeoutSec 20 -ErrorAction Stop
  $art = $resp.artifacts | Where-Object { -not $_.expired } | Sort-Object created_at -Descending | Select-Object -First 1
  if ($art) {
    $artifactUrl     = $art.archive_download_url
    $artifactUpdated = [DateTime]::Parse("$($art.created_at)").ToUniversalTime()
    $artifactSizeMb  = [math]::Round($art.size_in_bytes / 1MB, 1)
  }
} catch {}

$downloaded = $false

if ($releaseAssetUrl -and ($releaseUpdated -ge $artifactUpdated)) {
  try {
    Log "Mengunduh state terbaru dari Release 'xyrdp-state-latest' ($releaseSizeMb MB, $($releaseUpdated.ToString('yyyy-MM-dd HH:mm:ss')) UTC)..."
    $dlHdr = @{
      Authorization          = "Bearer $($env:GITHUB_TOKEN)"
      Accept                 = 'application/octet-stream'
      'X-GitHub-Api-Version' = '2022-11-28'
      'User-Agent'           = 'XyRDP-Restore'
    }
    Invoke-WebRequest -Uri $releaseAssetUrl -Headers $dlHdr -OutFile $zip -UseBasicParsing -TimeoutSec 180 -ErrorAction Stop
    if ((Test-Path $zip) -and (Get-Item $zip).Length -gt 100) { $downloaded = $true }
  } catch {
    Log "Unduh dari Release gagal ($($_.Exception.Message)), mencoba fallback Artifact..."
  }
}

if ((-not $downloaded) -and $artifactUrl) {
  try {
    Log "Mengunduh state dari Artifact 'xyrdp-state' ($artifactSizeMb MB, $($artifactUpdated.ToString('yyyy-MM-dd HH:mm:ss')) UTC)..."
    Invoke-WebRequest -Uri $artifactUrl -Headers $hdr -OutFile $zip -UseBasicParsing -TimeoutSec 180 -ErrorAction Stop
    if ((Test-Path $zip) -and (Get-Item $zip).Length -gt 100) { $downloaded = $true }
  } catch {
    Log "Unduh dari Artifact gagal: $($_.Exception.Message)"
  }
}

if ((-not $downloaded) -and $releaseAssetUrl) {
  try {
    $dlHdr = @{
      Authorization          = "Bearer $($env:GITHUB_TOKEN)"
      Accept                 = 'application/octet-stream'
      'X-GitHub-Api-Version' = '2022-11-28'
      'User-Agent'           = 'XyRDP-Restore'
    }
    Invoke-WebRequest -Uri $releaseAssetUrl -Headers $dlHdr -OutFile $zip -UseBasicParsing -TimeoutSec 180 -ErrorAction Stop
    if ((Test-Path $zip) -and (Get-Item $zip).Length -gt 100) { $downloaded = $true }
  } catch {}
}

if (-not $downloaded) {
  Log 'Belum ada simpanan sesi sebelumnya — sesi pertama (folder C:\Persist telah disiapkan).'
  Ensure-PersistShortcut (Join-Path $prof 'Desktop')
  exit 0
}

try {
  $sevenZip = 'C:\Program Files\7-Zip\7z.exe'
  New-Item -ItemType Directory -Path $ext -Force | Out-Null
  if (Test-Path $sevenZip) {
    & $sevenZip x $zip "-o$ext" -y 2>&1 | Out-Null
  } else {
    Expand-Archive -Path $zip -DestinationPath $ext -Force
  }

  # Jika artifact GitHub membungkus xyrdp-state.zip di dalam zip luar, ekstrak lapis kedua
  $innerZip = Join-Path $ext 'xyrdp-state.zip'
  if (Test-Path $innerZip) {
    $innerExt = Join-Path $tmp 'ext_inner'
    New-Item -ItemType Directory -Path $innerExt -Force | Out-Null
    if (Test-Path $sevenZip) {
      & $sevenZip x $innerZip "-o$innerExt" -y 2>&1 | Out-Null
    } else {
      Expand-Archive -Path $innerZip -DestinationPath $innerExt -Force
    }
    Remove-Item $ext -Recurse -Force -ErrorAction SilentlyContinue
    Rename-Item -Path $innerExt -NewName 'ext' -Force
  }

  # Pastikan profil user sudah terbentuk
  if (-not (Test-Path $prof)) {
    New-Item -ItemType Directory -Path $prof -Force | Out-Null
  }

  $restoredDirs = 0

  # 1. Pulihkan folder profil (Desktop, Documents, Downloads, Pictures, Music, Videos)
  foreach ($d in @('Desktop','Documents','Downloads','Pictures','Music','Videos')) {
    $src = Join-Path $ext $d
    if (Test-Path $src) {
      $dst = Join-Path $prof $d
      New-Item -ItemType Directory -Path $dst -Force | Out-Null
      Copy-Item -Path "$src\*" -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
      $restoredDirs++
    }
  }

  # 2. Pulihkan %APPDATA%\.minecraft, PrismLauncher, .tlauncher
  $roamingSrc = Join-Path $ext '_appdata_roaming'
  if (Test-Path $roamingSrc) {
    $roamingDst = Join-Path $prof 'AppData\Roaming'
    New-Item -ItemType Directory -Path $roamingDst -Force | Out-Null
    Copy-Item -Path "$roamingSrc\*" -Destination $roamingDst -Recurse -Force -ErrorAction SilentlyContinue
    $restoredDirs++
  }

  # 3. Pulihkan C:\Persist dan C:\Games
  $persistSrc = Join-Path $ext '_persist'
  if (Test-Path $persistSrc) {
    New-Item -ItemType Directory -Path 'C:\Persist' -Force | Out-Null
    Copy-Item -Path "$persistSrc\*" -Destination 'C:\Persist' -Recurse -Force -ErrorAction SilentlyContinue
    $restoredDirs++
  }
  $gamesSrc = Join-Path $ext '_games'
  if (Test-Path $gamesSrc) {
    New-Item -ItemType Directory -Path 'C:\Games' -Force | Out-Null
    Copy-Item -Path "$gamesSrc\*" -Destination 'C:\Games' -Recurse -Force -ErrorAction SilentlyContinue
    $restoredDirs++
  }

  # 4. Pulihkan Registry HKCU\Software\SAMP
  $sampReg = Join-Path $ext '_registry\samp-hkcu.reg'
  if (Test-Path $sampReg) {
    try {
      & reg.exe import $sampReg 2>&1 | Out-Null
      $ntAccount = New-Object System.Security.Principal.NTAccount($u)
      $sid = $ntAccount.Translate([System.Security.Principal.SecurityIdentifier]).Value
      if ($sid -and (Test-Path "Registry::HKEY_USERS\$sid")) {
        $rawReg = Get-Content $sampReg -Raw -ErrorAction SilentlyContinue
        if ($rawReg) {
          $sidReg = Join-Path $tmp 'samp-sid.reg'
          ($rawReg -replace 'HKEY_CURRENT_USER', "HKEY_USERS\$sid") | Set-Content -Path $sidReg -Encoding Unicode -Force
          & reg.exe import $sidReg 2>&1 | Out-Null
          Remove-Item $sidReg -Force -ErrorAction SilentlyContinue
        }
      }
      Log '  Registry HKCU\Software\SAMP berhasil dipulihkan.'
    } catch {}
  }

  # 5. Pulihkan identitas Tailscale C:\ProgramData\Tailscale
  $tsSrc = Join-Path $ext '_tailscale'
  if (Test-Path $tsSrc) {
    try {
      $tsDst = 'C:\ProgramData\Tailscale'
      New-Item -ItemType Directory -Path $tsDst -Force | Out-Null
      Copy-Item -Path "$tsSrc\*" -Destination $tsDst -Force -ErrorAction SilentlyContinue
      Log '  State identitas Tailscale berhasil dipulihkan (IP 100.x tetap konsisten).'
    } catch {}
  }

  # Berikan hak akses penuh ke user RDP atas seluruh file yang dipulihkan
  & icacls $prof /grant "${u}:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
  & icacls 'C:\Persist' /grant "${u}:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
  & icacls 'C:\Games'   /grant "${u}:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null

  Ensure-PersistShortcut (Join-Path $prof 'Desktop')
  Log "Restore selesai ($restoredDirs kelompok direktori berhasil dipulihkan ke $prof & C:\Persist)."
} catch {
  Log "Restore gagal sebagian: $($_.Exception.Message)"
} finally {
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
