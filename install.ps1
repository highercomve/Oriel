# Install the oriel CLI from GitHub Releases on Windows.
#
#   irm https://raw.githubusercontent.com/highercomve/Oriel/main/install.ps1 | iex
#
# Downloads oriel-<arch>-windows.exe (x86_64 or aarch64), verifies it against
# the release's SHA256SUMS and installs it as oriel.exe. Per user: no
# administrator rights. Adds to User PATH unless ORIEL_NO_MODIFY_PATH=1.
#
# Environment:
#   ORIEL_VERSION         release tag to install, e.g. v0.1.0 (default: latest)
#   ORIEL_INSTALL_DIR     where to put oriel.exe (default: %LOCALAPPDATA%\Programs\oriel)
#   ORIEL_NO_MODIFY_PATH  set to 1 to skip adding to User PATH
#   ORIEL_RELEASES_URL    releases base URL (default: the GitHub releases of
#                         highercomve/Oriel); files are fetched from
#                         <url>/latest/download/<file> or <url>/download/<tag>/<file>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # Invoke-WebRequest is much faster without it

# `throw`, not `exit`: under `irm ... | iex`, exit would close the user's shell.
function Fail([string]$message) {
    throw "install.ps1: error: $message"
}

$githubReleases = 'https://github.com/highercomve/Oriel/releases'
$releasesUrl = if ($env:ORIEL_RELEASES_URL) { $env:ORIEL_RELEASES_URL } else { $githubReleases }
$version = if ($env:ORIEL_VERSION) { $env:ORIEL_VERSION } else { 'latest' }
$installDir = if ($env:ORIEL_INSTALL_DIR) { $env:ORIEL_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs\oriel' }

# PROCESSOR_ARCHITEW6432 is set when a 32-bit PowerShell runs on 64-bit Windows.
$cpu = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
switch ($cpu) {
    'AMD64' { $arch = 'x86_64' }
    'ARM64' { $arch = 'aarch64' }
    default { Fail "unsupported architecture '$cpu' (x86_64 and aarch64 are available)" }
}
$asset = "oriel-$arch-windows.exe"

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("oriel-install-" + [System.Guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    if ($version -eq 'latest' -and $releasesUrl -eq $githubReleases) {
        # GitHub's releases/latest skips pre-releases (every 0.x release is
        # one), so ask the API for the newest release of any kind.
        try {
            $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/highercomve/Oriel/releases?per_page=1' -Headers @{ 'User-Agent' = 'oriel-install' }
        } catch {
            Fail 'could not look up the latest release'
        }
        if (-not $releases -or -not $releases[0].tag_name) { Fail "no releases found at $githubReleases" }
        $version = $releases[0].tag_name
    }

    $base = if ($version -eq 'latest') { "$($releasesUrl.TrimEnd('/'))/latest/download" } else { "$($releasesUrl.TrimEnd('/'))/download/$version" }

    Write-Host "Downloading $asset ($version)..."
    $exe = Join-Path $tmp $asset
    $sums = Join-Path $tmp 'SHA256SUMS'
    try { Invoke-WebRequest -Uri "$base/$asset" -OutFile $exe -UseBasicParsing } catch { Fail "download failed: $base/$asset" }
    try { Invoke-WebRequest -Uri "$base/SHA256SUMS" -OutFile $sums -UseBasicParsing } catch { Fail "download failed: $base/SHA256SUMS" }

    # The line for our file: "<sha256>  <name>" (sha256sum format, '*' for binary mode).
    $expected = $null
    foreach ($line in Get-Content $sums) {
        $fields = $line -split '\s+', 2
        if ($fields.Count -eq 2 -and ($fields[1] -eq $asset -or $fields[1] -eq "*$asset")) {
            $expected = $fields[0].ToLowerInvariant()
            break
        }
    }
    if (-not $expected) { Fail "SHA256SUMS has no entry for $asset" }
    $actual = (Get-FileHash -Algorithm SHA256 -Path $exe).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { Fail "checksum mismatch for ${asset}: expected $expected, got $actual" }

    try { New-Item -ItemType Directory -Force -Path $installDir | Out-Null } catch { Fail "cannot create $installDir (set ORIEL_INSTALL_DIR to a writable directory)" }
    $target = Join-Path $installDir 'oriel.exe'
    # A running exe can't be overwritten on Windows, but it can be renamed:
    # move the old one aside first (removed on the next install).
    $old = "$target.old"
    if (Test-Path $old) { Remove-Item -Force $old -ErrorAction SilentlyContinue }
    if (Test-Path $target) { Move-Item -Force $target $old }
    try { Copy-Item -Force $exe $target } catch {
        if (Test-Path $old) { Move-Item -Force $old $target } # put the old one back
        Fail "cannot write to $installDir (set ORIEL_INSTALL_DIR)"
    }

    $installed = (& $target --version | Select-Object -First 1)
    Write-Host "Installed $installed to $target"
    $modifyPath = $env:ORIEL_NO_MODIFY_PATH -ne '1'
    # The raw value: GetEnvironmentVariable expands %VARS%, and writing that
    # back would turn the user's REG_EXPAND_SZ Path into fixed strings.
    $envKey = Get-Item -Path 'HKCU:\Environment'
    $userPath = $envKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $normalized = $installDir.TrimEnd('\')
    $pathEntries = if ($userPath) { $userPath -split ';' | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') } } else { @() }
    $alreadyInUserPath = $pathEntries -contains $normalized

    if ($modifyPath) {
        if (-not $alreadyInUserPath) {
            $newUserPath = if ([string]::IsNullOrEmpty($userPath)) {
                $installDir
            } else {
                $userPath.TrimEnd(';') + ';' + $installDir
            }
            Set-ItemProperty -Path 'HKCU:\Environment' -Name 'Path' -Value $newUserPath -Type ExpandString
            # Tell running programs (Explorer, new terminals) that the environment changed.
            [Environment]::SetEnvironmentVariable('ORIEL_PATH_REFRESH', '1', 'User')
            [Environment]::SetEnvironmentVariable('ORIEL_PATH_REFRESH', $null, 'User')
            Write-Host "Added $installDir to User PATH."
        } else {
            Write-Host "$installDir is already in User PATH."
        }
        $envEntries = if ($env:Path) { $env:Path -split ';' } else { @() }
        if (-not ($envEntries -contains $installDir)) {
            $env:Path = if ([string]::IsNullOrEmpty($env:Path)) {
                $installDir
            } else {
                $env:Path.TrimEnd(';') + ';' + $installDir
            }
            Write-Host "Updated PATH for current session."
        }
    } else {
        Write-Host "ORIEL_NO_MODIFY_PATH=1: skipped modifying PATH."
        if (-not $alreadyInUserPath) {
            Write-Host "Note: $installDir is not on your PATH. Run it by its full path, re-run this installer without ORIEL_NO_MODIFY_PATH, or add it in Settings > System > About > Advanced system settings > Environment Variables."
        }
    }
    Write-Host 'Next: oriel doctor, then oriel init my-app'
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
