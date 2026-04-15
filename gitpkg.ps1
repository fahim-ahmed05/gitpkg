param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('clone', 'pull', 'fetch', 'list', 'rm', 'export', 'import', 'freeze', 'unfreeze', 'deep', 'shallow')]
    [string]$Command,
    [Parameter(Position = 1)]
    [string]$Target,
    [Parameter(Position = 2)]
    [string]$Branch,
    [string]$Name
)

if (-not (Get-Command "git" -ErrorAction SilentlyContinue)) {
    Write-Host "Error: 'git' command not found. Please install Git and ensure it is in your system PATH." -ForegroundColor Red
    exit 1
}

$ConfigDir = Join-Path $env:USERPROFILE ".config\gitpkg"
$ConfigFile = Join-Path $ConfigDir "repos.json"
$InstallDir = Join-Path $env:USERPROFILE "gitpkg"

if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir | Out-Null }
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir | Out-Null }
if (-not (Test-Path $ConfigFile)) { Set-Content -Path $ConfigFile -Value "[]" }

function Get-Packages {
    $content = Get-Content $ConfigFile -Raw
    if ([string]::IsNullOrWhiteSpace($content) -or $content -eq '[]') { return @() }
    return @($content | ConvertFrom-Json)
}

function Save-Packages {
    param([array]$Packages)
    if ($Packages.Count -eq 0) {
        Set-Content -Path $ConfigFile -Value "[]"
    }
    else {
        $Packages | ConvertTo-Json -Depth 2 | Set-Content -Path $ConfigFile
    }
}

function Get-ShortHash {
    param([string]$InputString)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
    $hash = [System.Security.Cryptography.MD5]::Create().ComputeHash($bytes)
    $hex = [System.BitConverter]::ToString($hash) -replace '-'
    return $hex.Substring(0, 8).ToLower()
}

function Get-RemoteDefaultBranch {
    param([string]$Url)
    try {
        $output = & git ls-remote --symref $Url HEAD
        $outputString = $output -join "`n"
        if ($outputString -match 'ref: refs/heads/([^\s]+)\s+HEAD') { return $matches[1] }
    }
    catch {}
    return "master"
}

function Resolve-AmbiguousPackage {
    param(
        [array]$Candidates,
        [string]$TargetName,
        [string]$ActionName
    )
    Write-Host "`nMultiple repositories match '$TargetName'. Which one would you like to $ActionName?" -ForegroundColor Yellow
    for ($i = 0; $i -lt $Candidates.Count; $i++) { Write-Host " [$($i + 1)] $($Candidates[$i].Id)" }
    Write-Host " [0] Cancel`n"
    $choice = Read-Host "Enter number"
    if ($choice -eq '0') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }
    elseif ($choice -match '^\d+$' -and [int]$choice -gt 0 -and [int]$choice -le $Candidates.Count) {
        return @($Candidates[[int]$choice - 1])
    }
    else {
        Write-Host "Invalid choice. Exiting." -ForegroundColor Red
        exit 1
    }
}

switch ($Command) {
    'clone' {
        if (-not $Target) {
            Write-Host "Error: URL required for clone. Usage: gitpkg clone <url> [branch]" -ForegroundColor Red
            exit 1
        }
        $CleanTarget = $Target.TrimEnd('/')
        if (-not $Name) { $Name = ($CleanTarget -split '[:/]')[-1] -replace '\.git$', '' }

        if ([string]::IsNullOrWhiteSpace($Branch)) {
            Write-Host "Detecting default branch for $Name... " -ForegroundColor DarkGray -NoNewline
            $Branch = Get-RemoteDefaultBranch -Url $CleanTarget
            Write-Host "Detected default branch: $Branch" -ForegroundColor Yellow
        }

        if ($CleanTarget -match '^(?:https?://|ssh://)?(?:git@)?([^/:]+)[/:](.+?)(?:\.git)?$') {
            $Domain = $matches[1]
            $RepoPath = $matches[2]
        }
        else {
            Write-Host "Error: Could not parse URL properly." -ForegroundColor Red
            exit 1
        }

        $FormattedId = "{0}:{1}@{2}" -f $Domain, $RepoPath, $Branch
        $ShortHash = Get-ShortHash -InputString $FormattedId
        $DirName = "{0}@{1}-{2}" -f $Name, $Branch, $ShortHash

        [array]$Packages = Get-Packages
        if ($Packages.Id -contains $FormattedId) { 
            Write-Host "Repository '$FormattedId' is already cloned and tracked." -ForegroundColor Yellow
            exit 0 
        }

        $TargetPath = Join-Path $InstallDir $DirName
        if (Test-Path $TargetPath) {
            Write-Host "Error: Directory '$DirName' exists but is untracked." -ForegroundColor Red
            Write-Host "Clean it up: Remove-Item -Recurse -Force `"$TargetPath`"" -ForegroundColor Yellow
            exit 1
        }

        $gitArgs = @("clone", "--depth", "1", $CleanTarget, $TargetPath, "--branch", $Branch)
        Write-Host "== > Cloning $FormattedId... " -ForegroundColor Cyan
        & git @gitArgs

        if ($LASTEXITCODE -eq 0) {
            $newPkg = [PSCustomObject]@{
                Id     = $FormattedId
                Name   = $Name
                Hash   = $ShortHash
                Url    = $CleanTarget
                Branch = $Branch
                Path   = $TargetPath
                Frozen = $false
                Depth  = 1
            }
            $Packages += $newPkg
            Save-Packages $Packages
            Write-Host "Successfully cloned to '$DirName'." -ForegroundColor Green
        }
        else {
            Write-Host "Failed to clone '$Name'. Check network or SSH keys." -ForegroundColor Red
        }
    }

    'fetch' {
        [array]$Packages = Get-Packages
        if ($Packages.Count -eq 0) { Write-Host "No repositories tracked." -ForegroundColor Yellow; exit 0 }

        [array]$TargetPackages = @()
        if (-not $Target) {
            $TargetPackages = $Packages
        }
        else {
            $TargetPackages = $Packages | Where-Object { $_.Name -eq $Target -or $_.Id -eq $Target -or $_.Hash -eq $Target }
            if ($TargetPackages.Count -eq 0) { Write-Host "Repository '$Target' not found." -ForegroundColor Yellow; exit 1 }
            if ($TargetPackages.Count -gt 1 -and $Target -eq $TargetPackages[0].Name) {
                $TargetPackages = Resolve-AmbiguousPackage -Candidates $TargetPackages -TargetName $Target -ActionName "fetch status for"
            }
        }

        Write-Host "Checking remote servers for changes... " -ForegroundColor Cyan
        $StatusList = @()
        foreach ($pkg in $TargetPackages) {
            $skipMsg = if ($pkg.Frozen) { " (Frozen)" } else { "" }
            if (Test-Path $pkg.Path) {
                Push-Location $pkg.Path
                $isBehind = $false
                $statusMsg = "Up to date$skipMsg"
                try {
                    if ($pkg.Frozen) {
                        $statusMsg = "Frozen$skipMsg"
                    }
                    else {
                        # Git output is now visible
                        $localHash = & git rev-parse HEAD
                        $remoteOutput = & git ls-remote $pkg.Url "refs/heads/$($pkg.Branch)"
                        if ($remoteOutput) {
                            $remoteHash = ($remoteOutput -split '\s+')[0]
                            if ($localHash -and $remoteHash -and ($localHash -ne $remoteHash)) {
                                $isBehind = $true
                                $statusMsg = "Update available$skipMsg"
                            }
                        }
                        else { $statusMsg = "Error reaching remote$skipMsg" }
                    }
                }
                catch { $statusMsg = "Error checking status$skipMsg" }

                $StatusList += [PSCustomObject]@{
                    Name        = $pkg.Name
                    Status      = $statusMsg
                    Id          = $pkg.Id
                    NeedsAction = $isBehind -and (-not $pkg.Frozen)
                }
                Pop-Location
            }
            else {
                $StatusList += [PSCustomObject]@{
                    Name        = $pkg.Name
                    Status      = "Missing (Will restore)$skipMsg"
                    Id          = $pkg.Id
                    NeedsAction = $true -and (-not $pkg.Frozen)
                }
            }
        }

        Write-Host "`nRepository Status: "
        $StatusList | Format-Table Name, Status, Id -AutoSize

        $actionsAvailable = $StatusList | Where-Object { $_.NeedsAction -eq $true }
        if ($actionsAvailable.Count -gt 0) {
            Write-Host "$($actionsAvailable.Count) repositories need updates or restoration." -ForegroundColor Green
            Write-Host "Run 'gitpkg pull' to apply them, or 'gitpkg pull <name>' for a specific one.`n"
        }
        else {
            Write-Host "All repositories are up to date and present.`n" -ForegroundColor Green
        }
    }

    'pull' {
        [array]$Packages = Get-Packages
        if ($Packages.Count -eq 0) { Write-Host "No repositories tracked." -ForegroundColor Yellow; exit 0 }

        if (-not $Target) { $Target = "all" }

        [array]$MatchedPackages = @()
        if ($Target -eq "all") { $MatchedPackages = $Packages }
        else {
            $MatchedPackages = $Packages | Where-Object { $_.Name -eq $Target -or $_.Id -eq $Target -or $_.Hash -eq $Target }
            if ($MatchedPackages.Count -eq 0) { Write-Host "Repository '$Target' not found." -ForegroundColor Yellow; exit 1 }
            if ($MatchedPackages.Count -gt 1 -and $Target -eq $MatchedPackages[0].Name) {
                $MatchedPackages = Resolve-AmbiguousPackage -Candidates $MatchedPackages -TargetName $Target -ActionName "pull"
            }
        }

        foreach ($pkg in $MatchedPackages) {
            if ($pkg.Frozen) { Write-Host "==> Skipping frozen repository $($pkg.Id)..." -ForegroundColor Yellow; continue }

            if (Test-Path $pkg.Path) {
                Write-Host "== > Pulling $($pkg.Id)... " -ForegroundColor Cyan
                Push-Location $pkg.Path
                $hashBefore = & git rev-parse HEAD

                if ($pkg.Depth -eq 1) { & git fetch origin $pkg.Branch --depth 1 }
                else { & git fetch --unshallow; & git fetch origin $pkg.Branch }
                & git reset --hard origin/$($pkg.Branch)

                $hashAfter = & git rev-parse HEAD
                if ($hashBefore -and $hashAfter -and ($hashBefore -ne $hashAfter)) { Write-Host "    -> Updated!" -ForegroundColor Green }
                else { Write-Host "    -> Already up to date." -ForegroundColor DarkGray }
                Pop-Location
            }
            else {
                Write-Host "== > Restoring missing repository $($pkg.Id)... " -ForegroundColor Magenta
                $gitArgs = if ($pkg.Depth -eq 1) { @("clone", "--depth", "1", $pkg.Url, $pkg.Path, "--branch", $pkg.Branch) }
                else { @("clone", $pkg.Url, $pkg.Path, "--branch", $pkg.Branch) }
                & git @gitArgs
            }
        }
        if ($Target -eq "all") { Write-Host "All repositories processed." -ForegroundColor Green }
        else { Write-Host "Successfully processed." -ForegroundColor Green }
    }

    'list' {
        [array]$Packages = Get-Packages
        if ($Packages.Count -gt 0) { $Packages | Format-Table Name, Branch, Hash, Id, Frozen, Depth -AutoSize }
        else { Write-Host "No repositories tracked." -ForegroundColor Yellow }
    }

    'rm' {
        if (-not $Target) { Write-Host "Error: Target required. Usage: gitpkg rm <name|id|hash>" -ForegroundColor Red; exit 1 }
        [array]$Packages = Get-Packages
        [array]$MatchedPackages = $Packages | Where-Object { $_.Name -eq $Target -or $_.Id -eq $Target -or $_.Hash -eq $Target }
        if ($MatchedPackages.Count -eq 0) { Write-Host "Repository '$Target' not found." -ForegroundColor Yellow; exit 1 }
        if ($MatchedPackages.Count -gt 1 -and $Target -eq $MatchedPackages[0].Name) {
            $MatchedPackages = Resolve-AmbiguousPackage -Candidates $MatchedPackages -TargetName $Target -ActionName "remove"
        }
        $TargetPkg = $MatchedPackages[0]
        Write-Host "==> Removing $($TargetPkg.Id)..." -ForegroundColor Cyan
        if (Test-Path $TargetPkg.Path) { Remove-Item -Path $TargetPkg.Path -Recurse -Force }
        $Packages = $Packages | Where-Object { $_.Id -ne $TargetPkg.Id }
        Save-Packages $Packages
        Write-Host "Successfully removed." -ForegroundColor Green
    }

    'export' {
        $exportPath = if ($Target) { $Target } else { Join-Path (Get-Location) "gitpkg-export.json" }
        Copy-Item -Path $ConfigFile -Destination $exportPath -Force
        Write-Host "Successfully exported tracked repositories to:" -ForegroundColor Green
        Write-Host $exportPath -ForegroundColor Cyan
    }

    'import' {
        if (-not $Target -or -not (Test-Path $Target)) { Write-Host "Error: Please provide a valid path to a JSON file. Usage: gitpkg import <file.json>" -ForegroundColor Red; exit 1 }
        $importedData = Get-Content $Target -Raw | ConvertFrom-Json
        [array]$currentPackages = Get-Packages
        $addedCount = 0
        $existingIds = $currentPackages.Id
        foreach ($pkg in $importedData) {
            if (-not $existingIds -or $existingIds -notcontains $pkg.Id) {
                if ($null -eq $pkg.Frozen) { $pkg | Add-Member -NotePropertyName Frozen -NotePropertyValue $false -Force }
                if ($null -eq $pkg.Depth) { $pkg | Add-Member -NotePropertyName Depth   -NotePropertyValue 1 -Force }
                $currentPackages += $pkg; $addedCount++
            }
        }
        Save-Packages $currentPackages
        Write-Host "Imported $addedCount new repositories from $Target." -ForegroundColor Green
        if ($addedCount -gt 0) { Write-Host "Run 'gitpkg pull' to physically download the missing directories." -ForegroundColor Yellow }
    }

    'freeze' {
        if (-not $Target) { Write-Host "Error: Target required. Usage: gitpkg freeze <name|id|hash>" -ForegroundColor Red; exit 1 }
        [array]$Packages = Get-Packages
        [array]$Matched = $Packages | Where-Object { $_.Name -eq $Target -or $_.Id -eq $Target -or $_.Hash -eq $Target }
        if ($Matched.Count -eq 0) { Write-Host "Repository '$Target' not found." -ForegroundColor Yellow; exit 1 }
        if ($Matched.Count -gt 1 -and $Target -eq $Matched[0].Name) { $Matched = Resolve-AmbiguousPackage -Candidates $Matched -TargetName $Target -ActionName "freeze" }
        $idx = [array]::IndexOf($Packages, $Matched[0])
        $Packages[$idx].Frozen = $true
        Save-Packages $Packages
        Write-Host "==> Frozen $($Matched[0].Id). It will be skipped during pulls." -ForegroundColor Green
    }

    'unfreeze' {
        if (-not $Target) { Write-Host "Error: Target required. Usage: gitpkg unfreeze <name|id|hash>" -ForegroundColor Red; exit 1 }
        [array]$Packages = Get-Packages
        [array]$Matched = $Packages | Where-Object { $_.Name -eq $Target -or $_.Id -eq $Target -or $_.Hash -eq $Target }
        if ($Matched.Count -eq 0) { Write-Host "Repository '$Target' not found." -ForegroundColor Yellow; exit 1 }
        if ($Matched.Count -gt 1 -and $Target -eq $Matched[0].Name) { $Matched = Resolve-AmbiguousPackage -Candidates $Matched -TargetName $Target -ActionName "unfreeze" }
        $idx = [array]::IndexOf($Packages, $Matched[0])
        $Packages[$idx].Frozen = $false
        Save-Packages $Packages
        Write-Host "==> Unfrozen $($Matched[0].Id). It will now update normally." -ForegroundColor Green
    }

    'deep' {
        if (-not $Target) { Write-Host "Error: Target required. Usage: gitpkg deep <name|id|hash>" -ForegroundColor Red; exit 1 }
        [array]$Packages = Get-Packages
        [array]$Matched = $Packages | Where-Object { $_.Name -eq $Target -or $_.Id -eq $Target -or $_.Hash -eq $Target }
        if ($Matched.Count -eq 0) { Write-Host "Repository '$Target' not found." -ForegroundColor Yellow; exit 1 }
        if ($Matched.Count -gt 1 -and $Target -eq $Matched[0].Name) { $Matched = Resolve-AmbiguousPackage -Candidates $Matched -TargetName $Target -ActionName "set deep fetch" }
        $idx = [array]::IndexOf($Packages, $Matched[0])
        $Packages[$idx].Depth = 0
        Save-Packages $Packages
        Write-Host "==> Set $($Matched[0].Id) to deep mode. Next pull will fetch full history." -ForegroundColor Green
    }

    'shallow' {
        if (-not $Target) { Write-Host "Error: Target required. Usage: gitpkg shallow <name|id|hash>" -ForegroundColor Red; exit 1 }
        [array]$Packages = Get-Packages
        [array]$Matched = $Packages | Where-Object { $_.Name -eq $Target -or $_.Id -eq $Target -or $_.Hash -eq $Target }
        if ($Matched.Count -eq 0) { Write-Host "Repository '$Target' not found." -ForegroundColor Yellow; exit 1 }
        if ($Matched.Count -gt 1 -and $Target -eq $Matched[0].Name) { $Matched = Resolve-AmbiguousPackage -Candidates $Matched -TargetName $Target -ActionName "set shallow fetch" }
        $idx = [array]::IndexOf($Packages, $Matched[0])
        $Packages[$idx].Depth = 1
        Save-Packages $Packages
        Write-Host "==> Set $($Matched[0].Id) to shallow mode. Next pull will use --depth 1." -ForegroundColor Green
    }
}