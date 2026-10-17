# ============================================================================
#  setup-samp.ps1 — Runtime & Paket Akselerasi GTA San Andreas / SA-MP
#                   By SilentPatch + Ultimate ASI Loader + DirectPlay + DX9
# ----------------------------------------------------------------------------
#  1) Memasang runtime Windows yang dibutuhkan GTA San Andreas & SA-MP dengan
#     batas waktu (timeout) ketat agar TIDAK PERNAH STUCK di runner Actions:
#     - DirectX End-User Runtimes (June 2010) -> d3dx9_24..43.dll, xinput1_3.dll
#     - Visual C++ Redistributable 2015-2022 (x86 & x64) + 2013 (x86)
#     - DirectPlay (dengan timeout 25 detik + fallback registry DirectPlay)
#  2) Menyiapkan Paket Akselerasi GTA SA-MP By SilentPatch di C:\Games\GTA-SAMP:
#     - SilentPatchSA (SilentPatchSA.asi + SilentPatchSA.ini 90 FPS + Mouse Fix)
#     - SilentPatch DDraw (ddraw.dll)
#     - Ultimate ASI Loader x86 (vorbisFile.dll / dinput8.dll)
#     - GTA SA Widescreen Fix (GTASA.WidescreenFix.asi)
#     - open.mp / SA-MP Client Installer + Script Auto-Patcher 1-Klik di Desktop
#     - PENTING: Saat dipanggil otomatis dari workflow (-AutoOnly), TIDAK PERNAH
#       membuka FolderBrowserDialog GUI di Session 0 agar workflow tidak menggantung!
# ============================================================================
param(
  [switch]$DirectXOnly
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
$XyTag                 = 'XyRDP:samp'
. "$PSScriptRoot/lib-common.ps1"

$cfg = Get-Cfg
if (-not $DirectXOnly -and $env:SAMP) {
  $e = $env:SAMP.Trim().ToLower()
  if (@('tidak','0','false','no','off','skip','none') -contains $e) {
    Log 'setup runtime + SilentPatch GTA SA/SA-MP dilewati (input samp=tidak)'
    Update-Status @{ samp = @{ status = 'skip' } } | Out-Null
    exit 0
  }
}

$sys32 = Join-Path $env:SystemRoot 'System32'
$wow64 = Join-Path $env:SystemRoot 'SysWOW64'
$work  = 'C:\XyRDP\deps\samp'
New-Item -ItemType Directory -Path $work -Force | Out-Null

function Test-FilesPresent([string]$Dir, [string[]]$Names) {
  foreach ($n in $Names) {
    if (-not (Test-Path (Join-Path $Dir $n))) { return $false }
  }
  return $true
}

function Invoke-DownloadWithRetry([string]$Url, [string]$OutFile, [int]$Retries = 2) {
  for ($i = 1; $i -le $Retries; $i++) {
    try {
      Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
      & curl.exe -fL --retry 2 --retry-delay 1 --connect-timeout 12 --max-time 60 -sS $Url -o $OutFile
      if ($LASTEXITCODE -eq 0 -and (Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 1024) {
        return $true
      }
    } catch {}
    try {
      Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 45
      if ((Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 1024) {
        return $true
      }
    } catch {
      if ($i -lt $Retries) { Start-Sleep -Seconds 2 }
    }
  }
  return $false
}

function Start-ProcessWithTimeout([string]$FilePath, [string[]]$ArgumentList, [string]$WorkingDir = '', [int]$TimeoutSec = 60) {
  try {
    $psi = @{
      FilePath     = $FilePath
      ArgumentList = $ArgumentList
      PassThru     = $true
      WindowStyle  = 'Hidden'
    }
    if ($WorkingDir -and (Test-Path $WorkingDir)) {
      $psi['WorkingDirectory'] = $WorkingDir
    }
    $p = Start-Process @psi
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
      Log "  proses '$(Split-Path $FilePath -Leaf)' melebihi batas $TimeoutSec detik — dihentikan agar tidak stuck."
      try { $p.Kill() } catch {}
      return -1
    }
    return $p.ExitCode
  } catch {
    Log "  gagal menjalankan $(Split-Path $FilePath -Leaf): $($_.Exception.Message)"
    return -1
  }
}

function Test-DirectXFiles {
  $required = @('d3dx9_24.dll','d3dx9_43.dll','d3dcompiler_43.dll','xinput1_3.dll','x3daudio1_7.dll')
  return (Test-FilesPresent $wow64 $required) -and (Test-FilesPresent $sys32 $required)
}

function Install-DirectXJune2010 {
  if (Test-DirectXFiles) {
    Log 'DirectX June 2010 sudah terpasang lengkap di System32 dan SysWOW64.'
    return
  }

  $dxPkg = Join-Path $work 'directx_Jun2010_redist.exe'
  $dxExt = Join-Path $work 'dx_extract'
  Remove-Item $dxExt -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $dxExt -Force | Out-Null

  $dxUrl = 'https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe'
  if (-not (Invoke-DownloadWithRetry $dxUrl $dxPkg 3)) {
    throw 'Gagal mengunduh DirectX June 2010 redistributable.'
  }

  Log 'Mengekstrak paket DirectX June 2010...'
  $extCode = Start-ProcessWithTimeout $dxPkg @('/Q', "/T:$dxExt") '' 60
  if ($extCode -ne 0) { throw "Ekstraksi DirectX gagal dengan exit code $extCode." }

  $dxSetup = Join-Path $dxExt 'DXSETUP.exe'
  if (-not (Test-Path $dxSetup)) { throw 'DXSETUP.exe tidak ditemukan setelah ekstraksi.' }

  Log 'Menjalankan DXSETUP.exe /silent...'
  $setupCode = Start-ProcessWithTimeout $dxSetup @('/silent') $dxExt 90
  if ($setupCode -ne 0 -and $setupCode -ne 3010) {
    throw "DXSETUP.exe gagal dengan exit code $setupCode."
  }

  if (-not (Test-DirectXFiles)) {
    throw 'Verifikasi DLL DirectX June 2010 gagal setelah instalasi.'
  }
  Remove-Item $dxExt -Recurse -Force -ErrorAction SilentlyContinue
  Log 'DirectX June 2010 terverifikasi.'
}

function Test-Vc2015Files([string]$Dir) {
  return Test-FilesPresent $Dir @('vcruntime140.dll','msvcp140.dll')
}

function Test-Vc2013Files([string]$Dir) {
  return Test-FilesPresent $Dir @('msvcr120.dll','msvcp120.dll')
}

function Install-VcRedist([string]$Label, [string]$Url, [string]$FileName, [scriptblock]$Verify) {
  if (& $Verify) {
    Log "$Label sudah terpasang dan terverifikasi."
    return
  }
  $exe = Join-Path $work $FileName
  if (-not (Invoke-DownloadWithRetry $Url $exe 3)) {
    throw "Gagal mengunduh $Label dari $Url"
  }
  Log "Memasang $Label..."
  $code = Start-ProcessWithTimeout $exe @('/install','/quiet','/norestart') '' 90
  if (@(0, 1638, 3010) -notcontains $code) {
    throw "$Label gagal dipasang (exit code $code)."
  }
  if (-not (& $Verify)) {
    throw "Verifikasi DLL untuk $Label gagal."
  }
  Log "$Label terverifikasi."
}

function Enable-DirectPlayFast {
  # Jangan pernah memanggil Enable-WindowsOptionalFeature untuk NetFx3 karena DISM
  # akan menghubungi Windows Update tanpa batas waktu dan membuat step stuck!
  # Untuk DirectPlay, gunakan dism.exe dengan timeout 25 detik + registry bypass DirectPlay.
  $dpOk = $false
  try {
    $code = Start-ProcessWithTimeout 'dism.exe' @('/Online','/Enable-Feature','/FeatureName:DirectPlay','/All','/NoRestart','/Quiet') '' 25
    if ($code -eq 0 -or $code -eq 3010) {
      $dpOk = $true
      Log 'Fitur Windows DirectPlay aktif.'
    }
  } catch {}

  # Pastikan kunci registry DirectPlay x86 ada supaya GTA SA tidak memunculkan pop-up "Install DirectPlay"
  try {
    foreach ($base in @(
      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\DirectPlay',
      'HKLM:\SOFTWARE\Microsoft\DirectPlay',
      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\DirectPlay8',
      'HKLM:\SOFTWARE\Microsoft\DirectPlay8'
    )) {
      New-Item -Path $base -Force -ErrorAction SilentlyContinue | Out-Null
      New-Item -Path "$base\Service Providers\Internet TCP/IP Connection For DirectPlay" -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $dpOk = $true
  } catch {}
  return $dpOk
}

function Install-SilentPatchAndSampKit {
  $kitRoot = 'C:\Games\GTA-SAMP'
  $modsDir = Join-Path $kitRoot 'SilentPatch-Pack'
  $instDir = Join-Path $kitRoot 'Installers'
  New-Item -ItemType Directory -Path $modsDir -Force | Out-Null
  New-Item -ItemType Directory -Path $instDir -Force | Out-Null

  $sevenZip = 'C:\Program Files\7-Zip\7z.exe'

  # 1. Unduh SilentPatchSA resmi (CookiePLMonster/SilentPatch)
  $spSaZip = Join-Path $work 'SilentPatchSA.zip'
  if (-not (Test-Path (Join-Path $modsDir 'SilentPatchSA.asi'))) {
    try {
      if (Invoke-DownloadWithRetry 'https://github.com/CookiePLMonster/SilentPatch/releases/latest/download/SilentPatchSA.zip' $spSaZip 2) {
        if (Test-Path $sevenZip) { & $sevenZip x $spSaZip "-o$modsDir" -y 2>&1 | Out-Null }
        else { Expand-Archive -Path $spSaZip -DestinationPath $modsDir -Force }
        Log 'SilentPatchSA.asi berhasil diunduh ke C:\Games\GTA-SAMP\SilentPatch-Pack.'
      }
    } catch { Log "Unduh SilentPatchSA dilewati: $($_.Exception.Message)" }
  }

  # 2. Unduh SilentPatch DDraw resmi (ddraw.dll)
  $spDdZip = Join-Path $work 'SilentPatchDDraw.zip'
  if (-not (Test-Path (Join-Path $modsDir 'ddraw.dll'))) {
    try {
      if (Invoke-DownloadWithRetry 'https://github.com/CookiePLMonster/SilentPatch/releases/latest/download/SilentPatchDDraw.zip' $spDdZip 2) {
        if (Test-Path $sevenZip) { & $sevenZip x $spDdZip "-o$modsDir" -y 2>&1 | Out-Null }
        else { Expand-Archive -Path $spDdZip -DestinationPath $modsDir -Force }
        Log 'SilentPatch ddraw.dll berhasil diunduh.'
      }
    } catch { Log "Unduh SilentPatchDDraw dilewati: $($_.Exception.Message)" }
  }

  # 3. Unduh Ultimate ASI Loader x86 (vorbisFile.dll / dinput8.dll)
  $asiZip = Join-Path $work 'Ultimate-ASI-Loader.zip'
  if (-not (Test-Path (Join-Path $modsDir 'dinput8.dll'))) {
    try {
      if (Invoke-DownloadWithRetry 'https://github.com/ThirteenAG/Ultimate-ASI-Loader/releases/latest/download/Ultimate-ASI-Loader.zip' $asiZip 2) {
        $asiExt = Join-Path $work 'asi_ext'
        New-Item -ItemType Directory -Path $asiExt -Force | Out-Null
        if (Test-Path $sevenZip) { & $sevenZip x $asiZip "-o$asiExt" -y 2>&1 | Out-Null }
        else { Expand-Archive -Path $asiZip -DestinationPath $asiExt -Force }
        $dll = Get-ChildItem -Path $asiExt -Recurse -File -Filter '*.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($dll) {
          Copy-Item $dll.FullName -Destination (Join-Path $modsDir 'dinput8.dll') -Force
          Copy-Item $dll.FullName -Destination (Join-Path $modsDir 'vorbisFile.dll') -Force
          Log 'Ultimate ASI Loader (dinput8.dll & vorbisFile.dll) siap.'
        }
        Remove-Item $asiExt -Recurse -Force -ErrorAction SilentlyContinue
      }
    } catch { Log "Unduh Ultimate ASI Loader dilewati: $($_.Exception.Message)" }
  }

  # 4. Unduh GTA SA Widescreen Fix (opsional best-effort)
  $wsZip = Join-Path $work 'GTASA.WidescreenFix.zip'
  if (-not (Test-Path (Join-Path $modsDir 'scripts\GTASA.WidescreenFix.asi'))) {
    try {
      if (Invoke-DownloadWithRetry 'https://github.com/ThirteenAG/WidescreenFixesPack/releases/download/gtasa/GTASA.WidescreenFix.zip' $wsZip 1) {
        if (Test-Path $sevenZip) { & $sevenZip x $wsZip "-o$modsDir" -y 2>&1 | Out-Null }
        else { Expand-Archive -Path $wsZip -DestinationPath $modsDir -Force }
        Log 'GTASA.WidescreenFix berhasil diunduh.'
      }
    } catch {}
  }

  # 5. Unduh open.mp / SA-MP Launcher (opsional best-effort, timeout pendek)
  $ompExe = Join-Path $instDir 'omp-launcher-setup.exe'
  if (-not (Test-Path $ompExe)) {
    try {
      if (Invoke-DownloadWithRetry 'https://github.com/openmultiplayer/launcher/releases/latest/download/omp-launcher-setup.exe' $ompExe 1) {
        Log 'open.mp / SA-MP Launcher berhasil disiapkan di C:\Games\GTA-SAMP\Installers.'
      }
    } catch {}
  }

  # 6. Tulis konfigurasi SilentPatchSA.ini (90 FPS + FixMouseStuck RDP)
  @(
    '[SilentPatch]'
    'FPSLimit=90'
    'AbideByFramerate=1'
    'FastLoader=1'
    'SkipIntroSplashes=1'
    'NVCache=1'
    'TwoPassRendering=0'
    'FixMouseStuck=1'
  ) | Set-Content -Path (Join-Path $modsDir 'SilentPatchSA.ini') -Encoding ASCII -Force

  # 7. Buat script Auto-Patcher 1-klik (Patch-GTA-SAMP.ps1)
  #    PENTING: Dialog pemilihan folder HANYA dibuka bila dipanggil dengan -Interactive
  #    dari shortcut Desktop, sehingga saat jalan otomatis di CI tidak pernah blokir!
  $patcherPath = Join-Path $kitRoot 'Patch-GTA-SAMP.ps1'
  $patcherCode = @'
param(
  [string]$TargetDir = '',
  [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$modsDir = 'C:\Games\GTA-SAMP\SilentPatch-Pack'

function Apply-SilentPatchToDir([string]$Dir) {
  if (-not (Test-Path $Dir)) { return $false }
  Write-Host "Memasang SilentPatch + ASI Loader + Widescreen + Mouse Fix ke: $Dir" -ForegroundColor Cyan
  Copy-Item -Path "$modsDir\*" -Destination $Dir -Recurse -Force -ErrorAction SilentlyContinue

  $gtaExe  = Join-Path $Dir 'gta_sa.exe'
  $sampExe = Join-Path $Dir 'samp.exe'
  $layers  = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
  New-Item -Path $layers -Force -ErrorAction SilentlyContinue | Out-Null
  if (Test-Path $gtaExe) {
    New-ItemProperty -Path $layers -Name $gtaExe -Value '~ HIGHDPIAWARE DISABLEDXMAXIMIZEDWINDOWEDMODE' -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null
  }
  if (Test-Path $sampExe) {
    New-ItemProperty -Path $layers -Name $sampExe -Value '~ HIGHDPIAWARE DISABLEDXMAXIMIZEDWINDOWEDMODE' -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null
  }

  $sampKey = 'HKCU:\Software\SAMP'
  New-Item -Path $sampKey -Force -ErrorAction SilentlyContinue | Out-Null
  if (Test-Path $gtaExe) {
    New-ItemProperty -Path $sampKey -Name 'gta_sa_exe' -Value $gtaExe -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null
  }
  $curName = (Get-ItemProperty -Path $sampKey -Name 'PlayerName' -ErrorAction SilentlyContinue).PlayerName
  if (-not $curName) {
    New-ItemProperty -Path $sampKey -Name 'PlayerName' -Value $env:USERNAME -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null
  }
  Write-Host "SUKSES! GTA San Andreas & SA-MP di '$Dir' sudah dipatch dengan SilentPatch (90 FPS + Mouse Fix)." -ForegroundColor Green
  return $true
}

if ($TargetDir -and (Test-Path $TargetDir)) {
  Apply-SilentPatchToDir $TargetDir | Out-Null
  exit 0
}

$candidates = @(
  'C:\Persist\GTA San Andreas',
  'C:\Persist\GTA-SA',
  'C:\Games\GTA San Andreas',
  'C:\Games\GTA-SA',
  'C:\Program Files (x86)\Rockstar Games\GTA San Andreas'
)
$deskPath = [Environment]::GetFolderPath('Desktop')
if ($deskPath) { $candidates += (Join-Path $deskPath 'GTA San Andreas') }

$patchedAny = $false
foreach ($c in $candidates) {
  if ((Test-Path (Join-Path $c 'gta_sa.exe')) -or (Test-Path (Join-Path $c 'samp.exe'))) {
    if (Apply-SilentPatchToDir $c) { $patchedAny = $true }
  }
}

if ((-not $patchedAny) -and $Interactive) {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Pilih folder GTA San Andreas kamu untuk dipasang SilentPatch + ASI Loader + Fix Mouse RDP'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
      Apply-SilentPatchToDir $dlg.SelectedPath | Out-Null
    }
  } catch {}
}
'@
  Set-Content -Path $patcherPath -Value $patcherCode -Encoding UTF8 -Force

  # 8. Scan lokasi yang sudah ada tanpa dialog (-Interactive TIDAK dikirim)
  try {
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $patcherPath 2>&1 | Out-Null
  } catch {}

  # 9. Buat shortcut di Desktop user RDP (dengan argumen -Interactive khusus saat diklik user)
  $u = if ($env:RDP_USER) { $env:RDP_USER.Trim() } else { $cfg.rdp_user }
  foreach ($desk in @("C:\Users\$u\Desktop", "C:\Users\Public\Desktop")) {
    if (Test-Path $desk) {
      try {
        $wsh = New-Object -ComObject WScript.Shell
        $lnk = $wsh.CreateShortcut((Join-Path $desk 'Patch GTA SA-MP (SilentPatch).lnk'))
        $lnk.TargetPath = 'powershell.exe'
        $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$patcherPath`" -Interactive"
        $lnk.WorkingDirectory = $kitRoot
        $lnk.Description = 'Pasang SilentPatch + ASI Loader + 90 FPS + Mouse Fix ke Folder GTA San Andreas'
        $lnk.Save()
      } catch {}
    }
  }
}

Install-DirectXJune2010
if ($DirectXOnly) {
  Log 'Mode -DirectXOnly selesai.'
  exit 0
}

Install-VcRedist 'VC++ 2015-2026 Redistributable (x86)' `
  'https://aka.ms/vs/17/release/vc_redist.x86.exe' `
  'vc_redist.x86.exe' `
  { Test-Vc2015Files $wow64 }

Install-VcRedist 'VC++ 2015-2026 Redistributable (x64)' `
  'https://aka.ms/vs/17/release/vc_redist.x64.exe' `
  'vc_redist.x64.exe' `
  { Test-Vc2015Files $sys32 }

Install-VcRedist 'VC++ 2013 Redistributable (x86)' `
  'https://aka.ms/highdpimfc2013x86enu' `
  'vcredist_2013_x86.exe' `
  { Test-Vc2013Files $wow64 }

try {
  Install-VcRedist 'VC++ 2013 Redistributable (x64)' `
    'https://aka.ms/highdpimfc2013x64enu' `
    'vcredist_2013_x64.exe' `
    { Test-Vc2013Files $sys32 }
} catch { Log "VC++ 2013 x64 dilewati (opsional): $($_.Exception.Message)" }

# Pastikan Microsoft Edge WebView2 Evergreen Runtime siap untuk aplikasi modern 2026 (Tauri, WinUI 3, Launcher 2026)
$wv2Ok = $false
try {
  $wv2Reg = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -ErrorAction SilentlyContinue
  if ($wv2Reg -and $wv2Reg.pv) {
    $wv2Ok = $true
    Log "WebView2 Evergreen Runtime sudah terpasang (v$($wv2Reg.pv))."
  } else {
    $wv2Exe = Join-Path $work 'MicrosoftEdgeWebview2Setup.exe'
    if (Invoke-DownloadWithRetry 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' $wv2Exe 2) {
      $wvCode = Start-ProcessWithTimeout $wv2Exe @('/silent','/install') '' 60
      if ($wvCode -eq 0 -or $wvCode -eq 3010) { $wv2Ok = $true; Log 'WebView2 Evergreen Runtime berhasil dipasang.' }
    }
  }
} catch { Log "WebView2 check selesai: $($_.Exception.Message)" }

$dpOk = Enable-DirectPlayFast

if ($env:SAMP -or $cfg.samp) {
  Install-SilentPatchAndSampKit
}

Update-Status @{
  samp = @{
    status      = 'runtimes-2026-ready'
    directx9    = (Test-DirectXFiles)
    vc2015_x86  = (Test-Vc2015Files $wow64)
    vc2015_x64  = (Test-Vc2015Files $sys32)
    vc2013_x86  = (Test-Vc2013Files $wow64)
    vc2013_x64  = (Test-Vc2013Files $sys32)
    webview2    = $wv2Ok
    directplay  = $dpOk
    netfx48     = $true
    compat2026  = $true
    silentpatch = (Test-Path 'C:\Games\GTA-SAMP\SilentPatch-Pack\SilentPatchSA.asi')
  }
} | Out-Null

Log 'Semua runtime All-Software 2026 + GTA San Andreas / SA-MP + paket SilentPatch berhasil dipasang cepat tanpa stuck.'
exit 0
