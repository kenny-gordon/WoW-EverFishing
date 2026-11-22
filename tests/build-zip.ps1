Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function ExpectFailure([scriptblock] $Action, [string] $Message) {
    try {
        & $Action
    } catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        return
    }
    throw "Expected failure containing: $Message"
}

function GetZipEntries([string] $Path) {
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        return @($archive.Entries | ForEach-Object { $_.FullName })
    } finally {
        $archive.Dispose()
    }
}

function GetZipText([string] $Path, [string] $EntryName) {
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.GetEntry($EntryName)
        if ($null -eq $entry) { throw "Missing ZIP entry: $EntryName" }
        $reader = [System.IO.StreamReader]::new($entry.Open())
        try {
            return $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }
    } finally {
        $archive.Dispose()
    }
}

$repository = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("EverFishing-zip-test-" + [guid]::NewGuid().ToString("N"))
$fixture = Join-Path $testRoot "fixture"
$addon = Join-Path $fixture "EverFishing"
$media = Join-Path $addon "Media"
$output = Join-Path $testRoot "output"

try {
    New-Item -ItemType Directory -Path $media -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repository "build.ps1") -Destination $fixture
    Set-Content -LiteralPath (Join-Path $addon "Core.lua") -Value "original core"
    Set-Content -LiteralPath (Join-Path $addon "Data.lua") -Value "data"
    Set-Content -LiteralPath (Join-Path $media "asset.txt") -Value "tracked asset"
    $unicodeName = "accent $([char]0x00E9).lua"
    Set-Content -LiteralPath (Join-Path $media $unicodeName) -Value "unicode asset"
    foreach ($toc in @("EverFishing.toc", "EverFishing_Forever.toc", "EverFishing_Vanilla.toc")) {
        Set-Content -LiteralPath (Join-Path $addon $toc) -Value @("## Version: 2.3.4", "Data.lua", "Core.lua")
    }
    foreach ($document in @("README.md", "LICENSE.txt", "CHANGELOG.md")) {
        Set-Content -LiteralPath (Join-Path $fixture $document) -Value "fixture $document"
    }

    & git -C $fixture init --quiet
    if ($LASTEXITCODE -ne 0) { throw "Could not initialize test repository." }
    & git -C $fixture -c core.autocrlf=false add -- EverFishing README.md LICENSE.txt
    if ($LASTEXITCODE -ne 0) { throw "Could not stage test files." }
    Set-Content -LiteralPath (Join-Path $addon "untracked.txt") -Value "not for release"
    $metadata = Join-Path $addon ".git"
    New-Item -ItemType Directory -Path $metadata | Out-Null
    Set-Content -LiteralPath (Join-Path $metadata "config") -Value "not for release"

    $builder = Join-Path $fixture "build.ps1"
    Set-Content -LiteralPath (Join-Path $addon "EverFishing_Mainline.toc") -Value @("## Version: 2.3.4", "Data.lua", "Core.lua")
    ExpectFailure { & $builder -OutputDirectory $output } "Required addon TOC is not tracked: EverFishing/EverFishing_Mainline.toc"
    & git -C $fixture -c core.autocrlf=false add -- (Join-Path "EverFishing" "EverFishing_Mainline.toc")
    if ($LASTEXITCODE -ne 0) { throw "Could not stage test TOC." }
    ExpectFailure { & $builder -OutputDirectory $output } "Release document is not tracked: CHANGELOG.md"
    & git -C $fixture -c core.autocrlf=false add -- CHANGELOG.md
    if ($LASTEXITCODE -ne 0) { throw "Could not stage test changelog." }
    $previousEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::ASCII
        $defaultZip = & $builder
        Assert ([Console]::OutputEncoding.CodePage -eq [System.Text.Encoding]::ASCII.CodePage) "Builder must restore the console encoding."
    } finally {
        [Console]::OutputEncoding = $previousEncoding
    }
    Assert ($defaultZip -eq (Join-Path (Join-Path $fixture "dist") "EverFishing-2.3.4.zip")) "Default output must be under the checkout's dist directory."
    $zip = & $builder -OutputDirectory $output
    Assert ((Split-Path -Leaf $zip) -eq "EverFishing-2.3.4.zip") "ZIP filename must use the TOC version."
    $names = @(GetZipEntries $zip)
    $expected = @(
        "EverFishing/",
        "EverFishing/Core.lua",
        "EverFishing/Data.lua",
        "EverFishing/EverFishing.toc",
        "EverFishing/EverFishing_Forever.toc",
        "EverFishing/EverFishing_Mainline.toc",
        "EverFishing/EverFishing_Vanilla.toc",
        "EverFishing/Media/asset.txt",
        "EverFishing/Media/$unicodeName",
        "EverFishing/README.md",
        "EverFishing/LICENSE.txt",
        "EverFishing/CHANGELOG.md"
    )
    foreach ($name in $expected) {
        Assert ($names -contains $name) "Missing ZIP entry: $name"
    }
    Assert ($names.Count -eq $expected.Count) "ZIP contains unexpected or untracked files."
    Assert ((GetZipText $zip "EverFishing/Core.lua").Trim() -eq "original core") "ZIP must use working-tree content."

    $originalHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    ExpectFailure { & $builder -OutputDirectory $output } "ZIP already exists"
    Assert ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -eq $originalHash) "Existing ZIP was changed without -Force."

    Set-Content -LiteralPath (Join-Path $addon "Core.lua") -Value "updated core"
    $rebuilt = & $builder -OutputDirectory $output -Force
    Assert ($rebuilt -eq $zip) "Rebuild must replace the same ZIP."
    Assert ((GetZipText $zip "EverFishing/Core.lua").Trim() -eq "updated core") "Forced rebuild must include current file content."

    $rebuiltHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    Set-Content -LiteralPath (Join-Path $addon "EverFishing_Forever.toc") -Value "## Version: 2.3.5"
    ExpectFailure { & $builder -OutputDirectory $output -Force } "TOC version mismatch"
    Assert ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -eq $rebuiltHash) "Invalid input must not replace the previous ZIP."

    Set-Content -LiteralPath (Join-Path $addon "EverFishing_Forever.toc") -Value @("## Version: 2.3.4", "## Version: 2.3.4")
    ExpectFailure { & $builder -OutputDirectory $output -Force } "Expected one valid Version"
    Assert ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -eq $rebuiltHash) "Invalid TOC must not replace the previous ZIP."

    Set-Content -LiteralPath (Join-Path $addon "Extra.lua") -Value "new addon file"
    Set-Content -LiteralPath (Join-Path $addon "EverFishing_Forever.toc") -Value @("## Version: 2.3.4", ".\Extra.lua")
    ExpectFailure { & $builder -OutputDirectory $output -Force } "references an untracked or missing addon file"
    Assert ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -eq $rebuiltHash) "An untracked TOC dependency must not replace the previous ZIP."
    & git -C $fixture -c core.autocrlf=false add -- (Join-Path "EverFishing" "Extra.lua")
    if ($LASTEXITCODE -ne 0) { throw "Could not stage test addon file." }
    $rebuilt = & $builder -OutputDirectory $output -Force
    Assert (@(GetZipEntries $rebuilt) -contains "EverFishing/Extra.lua") "A newly staged TOC dependency must be packaged."
    $rebuiltHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash

    Remove-Item -LiteralPath (Join-Path $addon "Data.lua")
    ExpectFailure { & $builder -OutputDirectory $output -Force } "Tracked addon file is missing"
    Assert ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -eq $rebuiltHash) "Missing input must not replace the previous ZIP."

    Write-Output "ZIP builder tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
