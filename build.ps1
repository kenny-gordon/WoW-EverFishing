[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string] $OutputDirectory,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $PSBoundParameters.ContainsKey("OutputDirectory")) {
    $OutputDirectory = Join-Path $PSScriptRoot "dist"
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git is required to build the release ZIP."
}

$previousEncoding = [Console]::OutputEncoding
try {
    # Git emits paths as UTF-8 even when the Windows console uses a legacy code page.
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $trackedFiles = @(& git -C $PSScriptRoot -c core.quotepath=false ls-files -- EverFishing README.md LICENSE.txt CHANGELOG.md)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not list tracked addon files. Run the builder from a Git checkout."
    }
} finally {
    [Console]::OutputEncoding = $previousEncoding
}
$addonFiles = @($trackedFiles | Where-Object { $_ -match '^EverFishing/' })
if ($addonFiles.Count -eq 0) {
    throw "No tracked addon files were found."
}

$entries = [ordered]@{}
foreach ($file in $addonFiles) {
    $diskPath = Join-Path $PSScriptRoot $file.Replace([char]'/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $diskPath -PathType Leaf)) {
        throw "Tracked addon file is missing: $file"
    }
    if ((Get-Item -LiteralPath $diskPath).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Cannot package a symbolic link: $file"
    }
    $entries[$file] = $diskPath
}

$tocFiles = @($addonFiles | Where-Object { $_ -match '^EverFishing/EverFishing(?:_[^/]+)?\.toc$' })
foreach ($requiredToc in @(
    "EverFishing/EverFishing.toc",
    "EverFishing/EverFishing_Forever.toc",
    "EverFishing/EverFishing_Mainline.toc",
    "EverFishing/EverFishing_Vanilla.toc"
)) {
    if ($tocFiles -notcontains $requiredToc) {
        throw "Required addon TOC is not tracked: $requiredToc"
    }
}

$version = $null
foreach ($toc in $tocFiles) {
    $lines = @(Get-Content -LiteralPath $entries[$toc] -Encoding UTF8)
    $versionLines = @($lines | Where-Object { $_ -match '^\s*##\s*Version\s*:' })
    if ($versionLines.Count -ne 1 -or $versionLines[0] -notmatch '^\s*##\s*Version\s*:\s*([0-9A-Za-z][0-9A-Za-z.+_-]*)\s*$') {
        throw "Expected one valid Version in $toc."
    }
    $tocVersion = $Matches[1]
    if ($null -eq $version) {
        $version = $tocVersion
    } elseif ($tocVersion -cne $version) {
        throw "TOC version mismatch: $toc has $tocVersion; expected $version."
    }
    foreach ($line in $lines) {
        $reference = $line.Trim()
        if (-not $reference -or $reference.StartsWith("#")) { continue }
        $path = $reference.Replace([char]'\', [char]'/')
        $parts = @($path.Split('/'))
        if ($path.StartsWith("/") -or $path.Contains(":") -or $parts -contains "..") {
            throw "Invalid file path in ${toc}: $reference"
        }
        $relativePath = (@($parts | Where-Object { $_ -and $_ -ne "." }) -join "/")
        if (-not $relativePath -or $addonFiles -notcontains "EverFishing/$relativePath") {
            throw "$toc references an untracked or missing addon file: $reference"
        }
    }
}

foreach ($document in @("README.md", "LICENSE.txt", "CHANGELOG.md")) {
    $diskPath = Join-Path $PSScriptRoot $document
    $entryName = "EverFishing/$document"
    if ($trackedFiles -notcontains $document) {
        throw "Release document is not tracked: $document"
    }
    if (-not (Test-Path -LiteralPath $diskPath -PathType Leaf)) {
        throw "Release document is missing: $document"
    }
    if ($addonFiles -contains $entryName) {
        throw "Release document conflicts with tracked addon file: $entryName"
    }
    $entries[$entryName] = $diskPath
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
}
if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    throw "Output directory is not a directory: $OutputDirectory"
}
$outputPath = Join-Path (Get-Item -LiteralPath $OutputDirectory).FullName "EverFishing-$version.zip"
if (Test-Path -LiteralPath $outputPath -PathType Container) {
    throw "ZIP destination is a directory: $outputPath"
}
if ((Test-Path -LiteralPath $outputPath) -and -not $Force) {
    throw "ZIP already exists: $outputPath. Use -Force to replace it."
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$temporaryPath = Join-Path (Get-Item -LiteralPath $OutputDirectory).FullName (".EverFishing-{0}.tmp" -f [guid]::NewGuid().ToString("N"))
$archive = $null
try {
    $archive = [System.IO.Compression.ZipFile]::Open($temporaryPath, [System.IO.Compression.ZipArchiveMode]::Create)
    [void] $archive.CreateEntry("EverFishing/")
    foreach ($entry in $entries.GetEnumerator()) {
        [void] [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive, $entry.Value, $entry.Key, [System.IO.Compression.CompressionLevel]::Optimal)
    }
    $archive.Dispose()
    $archive = $null
    Move-Item -LiteralPath $temporaryPath -Destination $outputPath -Force:$Force
} finally {
    if ($null -ne $archive) {
        $archive.Dispose()
    }
    if (Test-Path -LiteralPath $temporaryPath) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }
}

Write-Output $outputPath
