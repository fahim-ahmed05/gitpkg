param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('clone', 'pull', 'fetch', 'list', 'rm', 'export', 'import', 'freeze', 'unfreeze', 'deep', 'shallow')]
    [string]$Command,
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Targets,
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

# --- HELPER FUNCTIONS ---

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

function Invoke-GitQuiet {
    param([string[]]$ArgsList)
    $result = & git @ArgsList 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n[Git Error] Failed: git $($ArgsList -join ' ')" -ForegroundColor Red
        $result | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    }
    return $result
}

function Get-RemoteDefaultBranch {
    param([string]$Url)
    try {
        $output = Invoke-GitQuiet @("ls-remote", "--symref", $Url, "HEAD")
        if ($LASTEXITCODE -eq 0) {
            $outputString = $output -join "`n"
            if ($outputString -match 'ref: refs/heads/([^\s]+)\s+HEAD') { return $matches[1] }
        }
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

# --- MAIN LOGIC ---

switch ($Command) {
    'clone' {
        if (-not $Targets) {
            Write-Host "Error: URL required for clone. Usage: gitpkg clone <url> [branch] [name] OR gitpkg clone <url1> <url2> ..." -ForegroundColor Red
            exit 1
        }

        # Determine if we're doing a single clone with potential positional branch/name
        # or multiple clones.
        $urlsToClone = @()
        if ($Targets.Count -eq 1) {
            $urlsToClone += , @($Targets[0], $Branch, $Name)
        }
        else {
            # Check if it looks like positional: clone <url> <branch> <name>
            # If there are 2 or 3 args, and the 2nd one doesn't look like a URL, it might be a branch.
            $isPositional = $false
            if ($Targets.Count -le 3) {
                $secondArg = $Targets[1]
                if ($secondArg -notmatch '^(https?://|ssh://|git@|.*\.git$)') {
                    $isPositional = $true
                }
            }

            if ($isPositional) {
                $urlsToClone += , @($Targets[0], $Targets[1], (if ($Targets.Count -gt 2) { $Targets[2] } else { $null }))
            }
            else {
                foreach ($t in $Targets) { $urlsToClone += , @($t, $null, $null) }
            }
        }

        [array]$Packages = Get-Packages
        foreach ($item in $urlsToClone) {
            $tUrl = $item[0]
            $tBranch = $item[1]
            $tName = $item[2]

            $CleanTarget = $tUrl.TrimEnd('/')
            if (-not $tName) { $tName = ($CleanTarget -split '[:/]')[-1] -replace '\.git$', '' }

            if ([string]::IsNullOrWhiteSpace($tBranch)) {
                Write-Host "Detecting default branch for $tName... " -ForegroundColor DarkGray -NoNewline
                $tBranch = Get-RemoteDefaultBranch -Url $CleanTarget
                Write-Host "Detected default branch: $tBranch" -ForegroundColor Yellow
            }

            if ($CleanTarget -match '^(?:https?://|ssh://)?(?:git@)?([^/:]+)[/:](.+?)(?:\.git)?$') {
                $Domain = $matches[1]
                $RepoPath = $matches[2]
            }
            else {
                Write-Host "Error: Could not parse URL properly: $CleanTarget" -ForegroundColor Red
                continue
            }

            $FormattedId = "{0}:{1}@{2}" -f $Domain, $RepoPath, $tBranch
            $ShortHash = Get-ShortHash -InputString $FormattedId
            $DirName = "{0}@{1}-{2}" -f $tName, $tBranch, $ShortHash

            if ($Packages.Id -contains $FormattedId) { 
                Write-Host "Repository '$FormattedId' is already cloned and tracked." -ForegroundColor Yellow
                continue 
            }

            $TargetPath = Join-Path $InstallDir $DirName
            if (Test-Path $TargetPath) {
                Write-Host "Error: Directory '$DirName' exists but is untracked." -ForegroundColor Red
                Write-Host "Clean it up: Remove-Item -Recurse -Force `"$TargetPath`"" -ForegroundColor Yellow
                continue
            }

            $gitArgs = @("clone", "--depth", "1", $CleanTarget, $TargetPath, "--branch", $tBranch)
            Write-Host "== > Cloning $FormattedId... " -ForegroundColor Cyan
            Invoke-GitQuiet $gitArgs | Out-Null

            if ($LASTEXITCODE -eq 0) {
                $newPkg = [PSCustomObject]@{
                    Id     = $FormattedId
                    Name   = $tName
                    Hash   = $ShortHash
                    Url    = $CleanTarget
                    Branch = $tBranch
                    Path   = $TargetPath
                    Frozen = $false
                    Depth  = 1
                }
                $Packages += $newPkg
                Write-Host "Successfully cloned to '$DirName'." -ForegroundColor Green
            }
            else {
                Write-Host "Failed to clone '$tName'. Check network or SSH keys." -ForegroundColor Red
            }
        }
        Save-Packages $Packages
    }

    'fetch' {
        [array]$Packages = Get-Packages
        if ($Packages.Count -eq 0) { Write-Host "No repositories tracked." -ForegroundColor Yellow; exit 0 }

        [array]$TargetPackages = @()
        if (-not $Targets) {
            $TargetPackages = $Packages
        }
        else {
            foreach ($t in $Targets) {
                $pkgMatches = $Packages | Where-Object { $_.Name -eq $t -or $_.Id -eq $t -or $_.Hash -eq $t }
                if ($pkgMatches.Count -eq 0) { Write-Host "Repository '$t' not found." -ForegroundColor Yellow; continue }
                if ($pkgMatches.Count -gt 1 -and $t -eq $pkgMatches[0].Name) {
                    $pkgMatches = Resolve-AmbiguousPackage -Candidates $pkgMatches -TargetName $t -ActionName "fetch status for"
                }
                $TargetPackages += $pkgMatches
            }
            if ($TargetPackages.Count -eq 0) { exit 1 }
        }

        Write-Host "Checking remote servers for updates... " -ForegroundColor Cyan
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
                        $localHash = Invoke-GitQuiet @("rev-parse", "HEAD")
                        if ($LASTEXITCODE -ne 0) { $statusMsg = "Git error checking status$skipMsg" }
                        else {
                            $remoteOutput = Invoke-GitQuiet @("ls-remote", $pkg.Url, "refs/heads/$($pkg.Branch)")
                            if ($LASTEXITCODE -eq 0 -and $remoteOutput) {
                                $remoteHash = ($remoteOutput -split '\s+')[0]
                                if ($localHash -and $remoteHash -and ($localHash -ne $remoteHash)) {
                                    $isBehind = $true
                                    $statusMsg = "Update available$skipMsg"
                                }
                            }
                            else { $statusMsg = "Error reaching remote$skipMsg" }
                        }
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

        [array]$MatchedPackages = @()
        if (-not $Targets -or ($Targets.Count -eq 1 -and $Targets[0] -eq "all")) { 
            $MatchedPackages = $Packages 
        }
        else {
            foreach ($t in $Targets) {
                $pkgMatches = $Packages | Where-Object { $_.Name -eq $t -or $_.Id -eq $t -or $_.Hash -eq $t }
                if ($pkgMatches.Count -eq 0) { Write-Host "Repository '$t' not found." -ForegroundColor Yellow; continue }
                if ($pkgMatches.Count -gt 1 -and $t -eq $pkgMatches[0].Name) {
                    $pkgMatches = Resolve-AmbiguousPackage -Candidates $pkgMatches -TargetName $t -ActionName "pull"
                }
                $MatchedPackages += $pkgMatches
            }
        }

        foreach ($pkg in $MatchedPackages) {
            if ($pkg.Frozen) { Write-Host "==> Skipping frozen repository $($pkg.Id)..." -ForegroundColor Yellow; continue }

            if (Test-Path $pkg.Path) {
                Write-Host "== > Pulling $($pkg.Id)... " -ForegroundColor Cyan
                Push-Location $pkg.Path
                $hashBefore = Invoke-GitQuiet @("rev-parse", "HEAD")
                $pullFailed = $false

                if ($LASTEXITCODE -eq 0) {
                    if ($pkg.Depth -eq 1) { 
                        Invoke-GitQuiet @("fetch", "origin", $pkg.Branch, "--depth", "1") | Out-Null
                    }
                    else {
                        # Only unshallow if actually shallow
                        $isShallow = Invoke-GitQuiet @("rev-parse", "--is-shallow-repository")
                        if ($LASTEXITCODE -eq 0 -and $isShallow -eq 'true') {
                            Invoke-GitQuiet @("fetch", "--unshallow") | Out-Null
                        }
                        Invoke-GitQuiet @("fetch", "origin", $pkg.Branch) | Out-Null
                    }
                    Invoke-GitQuiet @("reset", "--hard", "origin/$($pkg.Branch)") | Out-Null
                }
                else { $pullFailed = $true }

                if ($pullFailed -or $LASTEXITCODE -ne 0) {
                    Write-Host "    -> Pull failed for $($pkg.Id)." -ForegroundColor Red
                }
                else {
                    $hashAfter = Invoke-GitQuiet @("rev-parse", "HEAD")
                    if ($LASTEXITCODE -eq 0 -and $hashBefore -and $hashAfter -and ($hashBefore -ne $hashAfter)) { 
                        Write-Host "    -> Updated!" -ForegroundColor Green 
                    }
                    else { Write-Host "    -> Already up to date." -ForegroundColor DarkGray }
                }
                Pop-Location
            }
            else {
                Write-Host "== > Restoring missing repository $($pkg.Id)... " -ForegroundColor Magenta
                $gitArgs = if ($pkg.Depth -eq 1) { @("clone", "--depth", "1", $pkg.Url, $pkg.Path, "--branch", $pkg.Branch) }
                else { @("clone", $pkg.Url, $pkg.Path, "--branch", $pkg.Branch) }
                Invoke-GitQuiet $gitArgs | Out-Null
                if ($LASTEXITCODE -ne 0) { Write-Host "    -> Restore failed." -ForegroundColor Red }
                else { Write-Host "    -> Restored successfully." -ForegroundColor Green }
            }
        }
        if (-not $Targets -or ($Targets.Count -eq 1 -and $Targets[0] -eq "all")) { Write-Host "All repositories processed." -ForegroundColor Green }
        else { Write-Host "Successfully processed." -ForegroundColor Green }
    }

    'list' {
        [array]$Packages = Get-Packages
        if ($Packages.Count -gt 0) { $Packages | Format-Table Name, Branch, Hash, Id, Frozen, Depth -AutoSize }
        else { Write-Host "No repositories tracked." -ForegroundColor Yellow }
    }

    'rm' {
        if (-not $Targets) { Write-Host "Error: Target required. Usage: gitpkg rm <name|id|hash> ..." -ForegroundColor Red; exit 1 }
        [array]$Packages = Get-Packages
        $removedAny = $false
        foreach ($t in $Targets) {
            [array]$MatchedPackages = $Packages | Where-Object { $_.Name -eq $t -or $_.Id -eq $t -or $_.Hash -eq $t }
            if ($MatchedPackages.Count -eq 0) { Write-Host "Repository '$t' not found." -ForegroundColor Yellow; continue }
            if ($MatchedPackages.Count -gt 1 -and $t -eq $MatchedPackages[0].Name) {
                $MatchedPackages = Resolve-AmbiguousPackage -Candidates $MatchedPackages -TargetName $t -ActionName "remove"
            }
            foreach ($pkg in $MatchedPackages) {
                Write-Host "==> Removing $($pkg.Id)..." -ForegroundColor Cyan
                if (Test-Path $pkg.Path) { Remove-Item -Path $pkg.Path -Recurse -Force }
                $Packages = $Packages | Where-Object { $_.Id -ne $pkg.Id }
                $removedAny = $true
            }
        }
        if ($removedAny) {
            Save-Packages $Packages
            Write-Host "Successfully removed." -ForegroundColor Green
        }
    }

    'export' {
        $exportPath = if ($Targets -and $Targets.Count -gt 0) { $Targets[0] } else { Join-Path (Get-Location) "gitpkg-export.json" }
        Copy-Item -Path $ConfigFile -Destination $exportPath -Force
        Write-Host "Successfully exported tracked repositories to:" -ForegroundColor Green
        Write-Host $exportPath -ForegroundColor Cyan
    }

    'import' {
        if (-not $Targets -or -not (Test-Path $Targets[0])) { Write-Host "Error: Please provide a valid path to a JSON file. Usage: gitpkg import <file.json>" -ForegroundColor Red; exit 1 }
        $importedData = Get-Content $Targets[0] -Raw | ConvertFrom-Json
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
        if (-not $Targets) { Write-Host "Error: Target required. Usage: gitpkg freeze <name|id|hash> ..." -ForegroundColor Red; exit 1 }
        [array]$Packages = Get-Packages
        foreach ($t in $Targets) {
            [array]$Matched = $Packages | Where-Object { $_.Name -eq $t -or $_.Id -eq $t -or $_.Hash -eq $t }
            if ($Matched.Count -eq 0) { Write-Host "Repository '$t' not found." -ForegroundColor Yellow; continue }
            if ($Matched.Count -gt 1 -and $t -eq $Matched[0].Name) { $Matched = Resolve-AmbiguousPackage -Candidates $Matched -TargetName $t -ActionName "freeze" }
            foreach ($pkg in $Matched) {
                $idx = [array]::IndexOf($Packages, $pkg)
                $Packages[$idx].Frozen = $true
                Write-Host "==> Frozen $($pkg.Id). It will be skipped during pulls." -ForegroundColor Green
            }
        }
        Save-Packages $Packages
    }

    'unfreeze' {
        if (-not $Targets) { Write-Host "Error: Target required. Usage: gitpkg unfreeze <name|id|hash> ..." -ForegroundColor Red; exit 1 }
        [array]$Packages = Get-Packages
        foreach ($t in $Targets) {
            [array]$Matched = $Packages | Where-Object { $_.Name -eq $t -or $_.Id -eq $t -or $_.Hash -eq $t }
            if ($Matched.Count -eq 0) { Write-Host "Repository '$t' not found." -ForegroundColor Yellow; continue }
            if ($Matched.Count -gt 1 -and $t -eq $Matched[0].Name) { $Matched = Resolve-AmbiguousPackage -Candidates $Matched -TargetName $t -ActionName "unfreeze" }
            foreach ($pkg in $Matched) {
                $idx = [array]::IndexOf($Packages, $pkg)
                $Packages[$idx].Frozen = $false
                Write-Host "==> Unfrozen $($pkg.Id). It will now update normally." -ForegroundColor Green
            }
        }
        Save-Packages $Packages
    }

    'deep' {
        if (-not $Targets) { Write-Host "Error: Target required. Usage: gitpkg deep <name|id|hash> ..." -ForegroundColor Red; exit 1 }
        [array]$Packages = Get-Packages
        foreach ($t in $Targets) {
            [array]$Matched = $Packages | Where-Object { $_.Name -eq $t -or $_.Id -eq $t -or $_.Hash -eq $t }
            if ($Matched.Count -eq 0) { Write-Host "Repository '$t' not found." -ForegroundColor Yellow; continue }
            if ($Matched.Count -gt 1 -and $t -eq $Matched[0].Name) { $Matched = Resolve-AmbiguousPackage -Candidates $Matched -TargetName $t -ActionName "set deep fetch" }
            foreach ($pkg in $Matched) {
                $idx = [array]::IndexOf($Packages, $pkg)
                $Packages[$idx].Depth = 0
                Write-Host "==> Set $($pkg.Id) to deep mode. Next pull will fetch full history." -ForegroundColor Green
            }
        }
        Save-Packages $Packages
    }

    'shallow' {
        if (-not $Targets) { Write-Host "Error: Target required. Usage: gitpkg shallow <name|id|hash> ..." -ForegroundColor Red; exit 1 }
        [array]$Packages = Get-Packages
        foreach ($t in $Targets) {
            [array]$Matched = $Packages | Where-Object { $_.Name -eq $t -or $_.Id -eq $t -or $_.Hash -eq $t }
            if ($Matched.Count -eq 0) { Write-Host "Repository '$t' not found." -ForegroundColor Yellow; continue }
            if ($Matched.Count -gt 1 -and $t -eq $Matched[0].Name) { $Matched = Resolve-AmbiguousPackage -Candidates $Matched -TargetName $t -ActionName "set shallow fetch" }
            foreach ($pkg in $Matched) {
                $idx = [array]::IndexOf($Packages, $pkg)
                $Packages[$idx].Depth = 1
                Write-Host "==> Set $($pkg.Id) to shallow mode. Next pull will use --depth 1." -ForegroundColor Green
            }
        }
        Save-Packages $Packages
    }
}