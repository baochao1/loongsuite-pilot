# package-offline-win.ps1 — Build a fully-offline Windows installer bundle for loongsuite-pilot.
#
# The produced bundle (loongsuite-pilot-offline-win-x64\...) contains everything needed to
# install on a machine WITHOUT network access:
#   * compiled app payload (dist/assets/scripts/agents.d)
#   * node_modules (prebuilt for win32-x64, including sqlite3/zstd-napi native binaries)
#   * a Node.js runtime (node.exe + npm), so the target machine needs no Node installed
#   * installer-opensource.ps1 + install-offline.ps1 one-click entry
#
# Requirements (on the packaging machine):
#   * Node.js >= 18 and npm (used to build + assemble dependencies)
#   * git (for commit stamp; optional, degrades to "unknown")
#   * network access is only needed on THIS machine (npm registry / nodejs.org),
#     the target machine stays fully offline.
#
# Usage (Windows PowerShell):
#   powershell -NoProfile -ExecutionPolicy Bypass -File deploy/package-offline-win.ps1
#
# Options:
#   -OutDir <path>       output directory (default: <repo>\out\offline)
#   -NodeVersion <ver>   Node.js runtime version to bundle (default: 22.22.2)
#   -NodeUrl <url>       override Node.js download URL (zip)
#   -UseSystemNode       bundle the local installed Node instead of downloading
#   -SkipBuild           skip `npm run build` (requires existing dist/)
#   -SkipDeps            skip `npm ci` (requires existing node_modules/)
#   -SkipZip             keep only the extracted bundle directory

[CmdletBinding()]
param(
    [string]$OutDir,
    [string]$NodeVersion = "22.22.2",
    [string]$NodeUrl,
    [switch]$UseSystemNode,
    [switch]$SkipBuild,
    [switch]$SkipDeps,
    [switch]$SkipZip
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $repoRoot "out\offline" }
$stageName = "loongsuite-pilot-offline-win-x64"
$stage = Join-Path $OutDir $stageName

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok { param([string]$m) Write-Host "    OK $m" -ForegroundColor Green }

Set-Location $repoRoot

# ------------------------------------------------------------
# 0. Sanity checks
# ------------------------------------------------------------
if (-not (Get-Command node.exe -ErrorAction SilentlyContinue)) { throw "node.exe not found in PATH" }
if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue) -and -not (Get-Command npm -ErrorAction SilentlyContinue)) { throw "npm not found in PATH" }

# ------------------------------------------------------------
# 1. Dependencies (full install first: build tooling + win32-x64 native binaries)
# ------------------------------------------------------------
if (-not $SkipDeps) {
    Write-Step "Installing dependencies (npm ci, full)"
    if (Test-Path node_modules) { Remove-Item node_modules -Recurse -Force }
    # Redirect postinstall side-effects (hook deployment) away from the real data dir.
    $isoDir = Join-Path $env:TEMP ("pilot-pkg-isolation-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $isoDir -Force | Out-Null
    $env:LOONGSUITE_PILOT_DATA_DIR = $isoDir
    try {
        & npm.cmd ci --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) {
            throw "npm ci failed (exit=$LASTEXITCODE). If package-lock.json is out of sync, delete it and run 'npm install' once, then retry."
        }
    } finally {
        Remove-Item Env:LOONGSUITE_PILOT_DATA_DIR -ErrorAction SilentlyContinue
        Remove-Item $isoDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Ok "dependencies installed"
} else {
    if (-not (Test-Path node_modules)) { throw "node_modules/ not found, remove -SkipDeps or install deps first" }
}

# ------------------------------------------------------------
# 2. Build dist/
# ------------------------------------------------------------
if (-not $SkipBuild) {
    Write-Step "Building dist/ (npm run build)"
    if (Test-Path dist) { Remove-Item dist -Recurse -Force }
    & npm.cmd run build
    if ($LASTEXITCODE -ne 0) { throw "npm run build failed (exit=$LASTEXITCODE)" }
    Write-Ok "dist/ built"
} else {
    if (-not (Test-Path dist)) { throw "dist/ not found, remove -SkipBuild or run build first" }
}

# ------------------------------------------------------------
# 2b. Native modules (win32-x64 prebuilds) + smoke test
# ------------------------------------------------------------
Write-Step "Ensuring native modules (sqlite3, zstd-napi)"
& npm.cmd rebuild sqlite3 zstd-napi --foreground-scripts --no-audit --no-fund
if ($LASTEXITCODE -ne 0) { throw "npm rebuild (native modules) failed (exit=$LASTEXITCODE)" }
& node.exe -e "require('sqlite3'); try{require('zstd-napi')}catch(e){console.error('zstd-napi:',e.message)}; console.log('native modules OK')"
if ($LASTEXITCODE -ne 0) { throw "native module smoke test failed" }
Write-Ok "node_modules ready (win32-x64)"

# ------------------------------------------------------------
# 3. Node.js runtime to bundle
# ------------------------------------------------------------
$nodeSrcDir = ""
if ($UseSystemNode) {
    Write-Step "Bundling local Node.js runtime"
    $sysNode = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $sysNode) { throw "system node.exe not found, cannot use -UseSystemNode" }
    $nodeSrcDir = Split-Path $sysNode.Source -Parent
    Write-Ok "node runtime source: $nodeSrcDir"
} else {
    Write-Step "Fetching Node.js v$NodeVersion (win-x64)"
    $zipName = "node-v$NodeVersion-win-x64.zip"
    $dlDir = Join-Path $env:TEMP "loongsuite-pilot-node-dl"
    New-Item -ItemType Directory -Path $dlDir -Force | Out-Null
    $zipPath = Join-Path $dlDir $zipName
    $needDownload = $true
    if (Test-Path $zipPath) {
        try {
            if ((Get-Item $zipPath).Length -gt 10MB) { $needDownload = $false }
        } catch { }
    }
    if ($needDownload) {
        $urls = @()
        if ($NodeUrl) { $urls += $NodeUrl }
        $urls += "https://npmmirror.com/mirrors/node/v$NodeVersion/$zipName"
        $urls += "https://nodejs.org/dist/v$NodeVersion/$zipName"
        $downloaded = $false
        foreach ($u in $urls) {
            try {
                Write-Host "    downloading $u"
                Invoke-WebRequest -Uri $u -OutFile $zipPath -UseBasicParsing
                if ((Get-Item $zipPath).Length -gt 10MB) { $downloaded = $true; break }
            } catch {
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not $downloaded) {
            throw "Node.js zip download failed. Check network, or re-run with -UseSystemNode to bundle the local Node."
        }
    } else {
        Write-Ok "using cached $zipName"
    }
    $extractDir = Join-Path $dlDir "extract"
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
    $nodeSrcDir = Join-Path $extractDir "node-v$NodeVersion-win-x64"
    if (-not (Test-Path (Join-Path $nodeSrcDir "node.exe"))) { throw "node.exe not found after extraction: $nodeSrcDir" }
    Write-Ok "node runtime extracted: $nodeSrcDir"
}

# ------------------------------------------------------------
# 4. VERSION stamp
# ------------------------------------------------------------
Write-Step "Generating VERSION stamp"
$version = (& node.exe -e "process.stdout.write(require('./package.json').version)")
if (-not $version) { throw "failed to read package version" }
$commit = (& git rev-parse --short HEAD 2>$null); if (-not $commit) { $commit = "unknown" }
$branch = (& git rev-parse --abbrev-ref HEAD 2>$null); if (-not $branch) { $branch = "unknown" }
$buildTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$versionText = @"
version=$version
git_commit=$commit
git_branch=$branch
build_time=$buildTime
"@
Write-Ok "v${version} (${commit})"

# ------------------------------------------------------------
# 5. Assemble offline bundle
# ------------------------------------------------------------
Write-Step "Assembling offline bundle: $stage"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$pkg = Join-Path $stage "package"
New-Item -ItemType Directory -Path $pkg -Force | Out-Null

# --- 5.1 app payload ---
Copy-Item dist    $pkg\dist    -Recurse
Copy-Item assets  $pkg\assets  -Recurse
Copy-Item scripts $pkg\scripts -Recurse
if (Test-Path agents.d) { Copy-Item agents.d $pkg\agents.d -Recurse }
if (Test-Path plugins)  { Copy-Item plugins  $pkg\plugins  -Recurse }
Copy-Item package.json $pkg\package.json
if (Test-Path package-lock.json) { Copy-Item package-lock.json $pkg\package-lock.json }
if (Test-Path .npmrc) { Copy-Item .npmrc $pkg\.npmrc }
if (Test-Path README.md) { Copy-Item README.md $pkg\README.md }
$versionText | Set-Content -Path (Join-Path $pkg "VERSION") -Encoding UTF8

# Strip internal-only files (mirror package-opensource.sh)
Remove-Item $pkg\scripts\migrate-internal-config.js -Force -ErrorAction SilentlyContinue
Remove-Item $pkg\scripts\updater-daemon.js -Force -ErrorAction SilentlyContinue
# macOS status bar app is irrelevant on Windows
if (Test-Path $pkg\app) { Remove-Item $pkg\app -Recurse -Force }

# --- 5.2 bundled node_modules + marker ---
Write-Host "    copying node_modules (this may take a while)..."
Copy-Item node_modules $pkg\node_modules -Recurse
$marker = "${version} win x64"
Set-Content -Path (Join-Path $pkg "node_modules\.pilot-modules-version") -Value $marker -Encoding UTF8
Write-Ok "bundled node_modules + marker ($marker)"

# --- 5.3 node runtime ---
Write-Host "    copying node runtime..."
Copy-Item $nodeSrcDir $stage\node -Recurse
Write-Ok "bundled node runtime"

# --- 5.4 installer + entry scripts ---
Copy-Item (Join-Path $PSScriptRoot "installer-opensource.ps1") $stage\installer-opensource.ps1
Copy-Item (Join-Path $PSScriptRoot "package-offline-win.ps1") $stage\package-offline-win.ps1 -ErrorAction SilentlyContinue

# extract.cmd + extract.ps1 (cmd is the double-click entry, it calls ps1 with -ExecutionPolicy Bypass)
$extractPs1 = @"
# extract.ps1 - Reliable extractor for the offline bundle (Windows)
#
# Windows Explorer's built-in "Extract All" / Shell.Application silently DROPS
# zero-byte files and can stall on large node_modules trees (thousands of files),
# leaving you with an incomplete bundle. This script uses .NET's ZipFile API,
# which preserves every entry (including 0-byte files) and handles long paths.
#
# Usage:
#   extract.ps1                 (extract the sibling zip next to this file)
#   extract.ps1 -Destination D:\loongsuite-pilot
param([string]`$Destination)
`$ErrorActionPreference = "Stop"
`$scriptDir = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$zipName = "loongsuite-pilot-offline-win-x64-v$version.zip"
`$zip = Join-Path `$scriptDir `$zipName
if (-not (Test-Path `$zip)) {
    `$found = Get-ChildItem `$scriptDir -Filter "loongsuite-pilot-offline-win-x64*.zip" -File | Select-Object -First 1
    if (-not `$found) {
        Write-Host "[ERROR] offline zip not found next to extract.ps1." -ForegroundColor Red
        exit 1
    }
    `$zip = `$found.FullName
}
if (-not `$Destination) {
    `$leaf = [System.IO.Path]::GetFileNameWithoutExtension(`$zip) -replace '\.zip$', ''
    `$Destination = Join-Path `$scriptDir `$leaf
}
if (Test-Path `$Destination) {
    Write-Host "[WARN] Destination already exists: `$Destination" -ForegroundColor Yellow
    `$resp = Read-Host "Overwrite and re-extract? (y/N)"
    if (`$resp -notmatch '^[yY]') { Write-Host "Aborted."; exit 0 }
    Remove-Item `$Destination -Recurse -Force
}
New-Item -ItemType Directory -Path `$Destination -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
Write-Host "==> Extracting (this may take a minute)..." -ForegroundColor Cyan
[System.IO.Compression.ZipFile]::ExtractToDirectory(`$zip, `$Destination)
Write-Host "==> Done. Bundle extracted to: `$Destination" -ForegroundColor Green
if (Test-Path (Join-Path `$Destination "install-offline.cmd")) {
    Write-Host "    Next: run install-offline.cmd in that folder." -ForegroundColor Gray
}
"@
Set-Content -Path (Join-Path $OutDir "extract.ps1") -Value $extractPs1 -Encoding UTF8

# extract.cmd is fully self-contained: it embeds the extractor as a base64
# UTF-16LE PowerShell script (via -EncodedCommand), so there is NO external .ps1
# file, NO '$' quoting/escaping through cmd.exe, and thus no corruption risk.
# (A standalone extract.ps1 is also written next to it for manual use.)
$bytes = [System.Text.Encoding]::Unicode.GetBytes($extractPs1)
$extractCmdB64 = [Convert]::ToBase64String($bytes)
$extractCmd = @"
@echo off
rem extract.cmd - Reliable extractor for the offline bundle (Windows)
rem Double-click this file; it runs an embedded PowerShell extractor.
rem Usage: extract.cmd  or  extract.cmd -Destination D:\loongsuite-pilot
powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $extractCmdB64
"@
Set-Content -Path (Join-Path $OutDir "extract.cmd") -Value $extractCmd -Encoding ASCII
Write-Ok "added extract.cmd (self-contained) + extract.ps1 (double-click extract.cmd to extract)"

@'
@echo off
rem install-offline.cmd - One-click OFFLINE install of loongsuite-pilot (Windows)
rem
rem Double-click this file, or run from a command prompt:
rem   install-offline.cmd
rem       -> interactive wizard: choose output target (Langfuse / SLS / none), agents, etc.
rem   install-offline.cmd -LangfuseEndpoint "http://localhost:3000" -LangfusePublicKey "pk-..." -LangfuseSecretKey "sk-..." -LangfuseServiceName "loongsuite-pilot"
rem   install-offline.cmd -SlsEndpoint "https://cn-hangzhou.log.aliyuncs.com" -SlsProject "my-project" -SlsLogstore "my-logstore" -SlsAkId "LTAI..." -SlsAkSecret "...."
rem   install-offline.cmd -SlsEndpoint "..." -SlsProject "..." -SlsLogstore "..." -SlsApiKey "...."
rem
rem This installs WITHOUT any network access. All payloads (app + dependencies +
rem Node.js runtime) are contained in this bundle.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer-opensource.ps1" install -PackageUrl "file://%~dp0package" -NodeRuntimeDir "%~dp0node" %*
'@ | Set-Content -Path $stage\install-offline.cmd -Encoding ASCII

@'
@echo off
rem uninstall-offline.cmd - Uninstall loongsuite-pilot
rem   uninstall-offline.cmd            (keep config & data)
rem   uninstall-offline.cmd -Purge     (remove config & data too)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer-opensource.ps1" uninstall %*
'@ | Set-Content -Path $stage\uninstall-offline.cmd -Encoding ASCII

@"
==========================================================
 loongsuite-pilot 离线安装包 (Windows x64)  v$version
==========================================================

一、说明
  本安装包为"完全离线"安装包：应用代码、全部依赖（node_modules）、
  Node.js 运行时均已内置，目标机器不需要联网，也不需要预装 Node.js。

二、解压（重要）
  ⚠️ 不要用 Windows 资源管理器右键“全部解压 / Extract All”来解压本 zip。
     内置的 node_modules 含大量小文件与部分 0 字节文件，系统自带解压会
     静默丢文件 / 卡死，导致安装时缺少依赖。
  ✅ 正确做法：zip 旁边已附带 extract.ps1（基于 .NET ZipFile，保留所有
     文件、支持长路径）。直接双击它即可把 zip 完整解压到同级目录。
       方式 A：双击 zip 旁边的 extract.ps1
       方式 B：在命令行指定解压目标
         .\extract.ps1 -Destination "D:\loongsuite-pilot"
     解压后得到 loongsuite-pilot-offline-win-x64\ 目录，再进入该目录安装。

三、安装
  1. 进入解压出的 loongsuite-pilot-offline-win-x64\ 目录。
  2. 双击 install-offline.cmd（无需右键/PowerShell，直接跑）。
     不传任何参数时进入交互向导，依次引导：
       - 选择数据输出目标（默认 Langfuse，通过 OTLP Trace 对接；可选阿里云 SLS / 暂不配置）
       - 输入 Langfuse 接入地址、Public Key、Secret Key、Service Name
       - 选择要采集的 AI Agent
     全部过程无需联网。
  3. 如需静默/脚本化安装，追加参数（任选一种输出目标）：
       Langfuse（推荐）:
         install-offline.cmd -LangfuseEndpoint "http://localhost:3000" ^
                               -LangfusePublicKey "pk-..." ^
                               -LangfuseSecretKey "sk-..." ^
                               -LangfuseServiceName "loongsuite-pilot"
       阿里云 SLS:
         install-offline.cmd -SlsEndpoint "https://cn-hangzhou.log.aliyuncs.com" ^
                               -SlsProject "my-project" ^
                               -SlsLogstore "my-logstore" ^
                               -SlsAkId "LTAI..." ^
                               -SlsAkSecret "...."
         或
         install-offline.cmd -SlsEndpoint "..." -SlsProject "..." -SlsLogstore "..." -SlsApiKey "...."
  4. 安装完成后服务自动启动，数据写入 ~/.loongsuite-pilot。

三、常用命令（安装完成后）
  loongsuite-pilot status         查看服务状态
  loongsuite-pilot logs           查看运行日志
  loongsuite-pilot start/stop     启动/停止
  loongsuite-pilot uninstall      卸载

四、卸载
  运行解压目录下的 uninstall-offline.cmd：
    uninstall-offline.cmd            保留配置与数据
    uninstall-offline.cmd -Purge     连同配置与数据一起删除

五、解压后目录结构（loongsuite-pilot-offline-win-x64\）
  package\   应用包（含 node_modules，安装时无需联网下载依赖）
  node\      Node.js 运行时（安装时复制到 ~/.loongsuite-pilot/runtime/）
  installer-opensource.ps1   安装器核心
  install-offline.cmd        一键离线安装入口（双击运行）
  uninstall-offline.cmd      卸载入口（双击运行）
  README-离线安装.txt        本说明

  （注：extract.cmd 在 zip 旁边，解压后无需保留）

六、升级
  下载新版 zip，双击旁边的 extract.cmd 解压后，在旧版本目录上运行新的
  install-offline.cmd 即可升级，配置与数据会被保留，失败自动回滚。

==========================================================
"@ | Set-Content -Path $stage\README-离线安装.txt -Encoding UTF8
Write-Ok "bundle directory ready"

# ------------------------------------------------------------
# 6. Zip archive
# ------------------------------------------------------------
if (-not $SkipZip) {
    Write-Step "Creating zip archive"
    $zipPath = Join-Path $OutDir "loongsuite-pilot-offline-win-x64-v${version}.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    # Zip the CONTENTS of $stage (not the folder itself), so extracting the zip
    # yields the bundle directory directly at the destination instead of nesting
    # an extra loongsuite-pilot-offline-win-x64\ level.
    Compress-Archive -Path "$stage\*" -DestinationPath $zipPath -CompressionLevel Optimal
    $sizeMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
    Write-Ok "zip created: $zipPath (${sizeMB} MB)"
}

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------
Write-Host ""
Write-Host "===================  DONE  ===================" -ForegroundColor Green
Write-Host "Version   : v$version ($commit / $branch)"
Write-Host "Bundle    : $stage"
if (-not $SkipZip) { Write-Host "Zip       : $(Join-Path $OutDir "loongsuite-pilot-offline-win-x64-v${version}.zip")" }
Write-Host "Target    : Windows x64, fully offline"
Write-Host "Next step : copy the bundle to the target machine and run install-offline.ps1"
Write-Host "==============================================" -ForegroundColor Green
