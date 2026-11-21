@echo off
setlocal
set "THIS_BAT=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$code = ((Get-Content -LiteralPath $env:THIS_BAT -Raw -Encoding UTF8) -split '(?m)^###__POWERSHELL__###\r?$', 2)[1]; & ([ScriptBlock]::Create($code)) @args" %*
exit /b %errorlevel%

###__POWERSHELL__###
$ErrorActionPreference = 'Stop'

$ScriptDir = [System.IO.Path]::GetDirectoryName($env:THIS_BAT)
$RecipesDir = Join-Path $ScriptDir 'recipes'

function Log-Info($msg)  { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Log-Ok($msg)    { Write-Host "[SUCCESS] $msg" -ForegroundColor Green }
function Log-Warn($msg)  { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Log-Err($msg)   { [Console]::Error.WriteLine("[ERROR] $msg") }

function Show-Usage {
    @"
Usage:
  generate.bat [OPTIONS] <package> <version>

Arguments:
  <package>               Package directory name inside recipes\ (e.g. pydantic-core, scipy)
  <version>               Target version to create (e.g. 2.50.6, 1.18.2)

Options:
  -e, --edit              Open generated recipe.yaml in nano (or --editor) after creation
      --editor <cmd>      Editor command to use with --edit (default: nano)
  -f, --force             Overwrite target version directory if it already exists
  -s, --from <version>    Use a specific existing version as template instead of closest match
      --new               Create a starter recipe.yaml if package has no existing versions
      --git-commit-and-push
                          Stage, commit ("feat(<pkg>): v<ver>"), and push to git
      --dry-run           Show what would be done without creating/modifying files or pushing
  -h, --help              Show this help message and exit

Examples:
  generate.bat pydantic-core 2.50.6
  generate.bat scipy 1.18.2 --edit
  generate.bat numpy 2.4.5 --git-commit-and-push
  generate.bat maturin 1.16.1 --from 1.16.0 --edit --git-commit-and-push
  generate.bat httpx 0.28.1 --new --edit
  generate.bat scipy 1.17.9 --dry-run
"@ | Write-Host
}

function Test-SafeSegment([string]$Value, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Contains('..') -or $Value.Contains('/') -or $Value.Contains('\')) {
        Log-Err "Invalid ${Label}: '$Value'"
        exit 2
    }
    if ($Value -notmatch '^[A-Za-z0-9._+-]+$') {
        Log-Err "Invalid characters in ${Label}: '$Value'"
        exit 2
    }
}

function Parse-VersionTuple([string]$Ver) {
    $isPre = if ($Ver -match '[A-Za-z]') { 1 } else { 0 }
    $parts = $Ver -split '[._+-]'
    $nums = New-Object int[] 8
    for ($i = 0; $i -lt 8; $i++) {
        if ($i -lt $parts.Length -and $parts[$i] -match '^(\d+)') {
            $nums[$i] = [int]$Matches[1]
        } else {
            $nums[$i] = 0
        }
    }
    return @{ Nums = $nums; IsPre = $isPre; Raw = $Ver }
}

function Find-ClosestVersion([string]$Target, [string[]]$Candidates) {
    $t = Parse-VersionTuple $Target
    $best = $null
    $bestDist = $null

    foreach ($cand in $Candidates) {
        $c = Parse-VersionTuple $cand
        $dist = New-Object int[] 8
        for ($i = 0; $i -lt 8; $i++) {
            $dist[$i] = [Math]::Abs($t.Nums[$i] - $c.Nums[$i])
        }

        $better = $false
        if ($null -eq $best) {
            $better = $true
        } else {
            $decided = $false
            for ($i = 0; $i -lt 8; $i++) {
                if ($dist[$i] -lt $bestDist[$i]) { $better = $true; $decided = $true; break }
                if ($dist[$i] -gt $bestDist[$i]) { $better = $false; $decided = $true; break }
            }
            if (-not $decided) {
                if ($c.IsPre -lt $best.IsPre) { $better = $true; $decided = $true }
                elseif ($c.IsPre -gt $best.IsPre) { $better = $false; $decided = $true }
            }
            if (-not $decided) {
                for ($i = 0; $i -lt 8; $i++) {
                    if ($c.Nums[$i] -gt $best.Nums[$i]) { $better = $true; break }
                    if ($c.Nums[$i] -lt $best.Nums[$i]) { $better = $false; break }
                }
            }
        }

        if ($better) {
            $best = $c
            $bestDist = $dist
        }
    }
    return $best.Raw
}

function Update-RecipeYaml([string]$SrcFile, [string]$DstFile, [string]$NewVer) {
    $lines = [System.IO.File]::ReadAllLines($SrcFile, [System.Text.Encoding]::UTF8)
    $inMeta = $false
    $out = New-Object System.Collections.Generic.List[string]

    foreach ($line in $lines) {
        if ($line -match '^[^\s#]') {
            $inMeta = ($line -match '^metadata:\s*(#.*)?$')
        }
        if ($inMeta -and $line -match '^(\s+version:\s*)([^#]*?)(\s+#.*)?$') {
            $comment = if ($Matches[3]) { $Matches[3] } else { '' }
            $out.Add("$($Matches[1])`"$NewVer`"$comment")
            continue
        }
        if ($inMeta -and $line -match '^(\s+download_version:\s*)([^#]*?)(\s+#.*)?$') {
            $comment = if ($Matches[3]) { $Matches[3] } else { '' }
            $out.Add("$($Matches[1])`"$NewVer`"$comment")
            continue
        }
        $out.Add($line)
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($DstFile, ($out -join "`n") + "`n", $utf8NoBom)
}

function Resolve-Editor([string]$EditorCmd) {
    $cmd = Get-Command $EditorCmd -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    if ($EditorCmd -eq 'nano') {
        $candidates = @(
            (Join-Path $env:ProgramFiles 'Git\usr\bin\nano.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Git\usr\bin\nano.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\Git\usr\bin\nano.exe')
        )
        foreach ($p in $candidates) {
            if ($p -and (Test-Path -LiteralPath $p)) { return $p }
        }
    }
    return $null
}

# --- Argument Parsing ---
$Edit = $false
$Force = $false
$CreateNew = $false
$DryRun = $false
$GitCommitAndPush = $false
$FromVersion = ''
$EditorCmd = 'nano'
$Positional = New-Object System.Collections.Generic.List[string]

$i = 0
while ($i -lt $args.Count) {
    $arg = [string]$args[$i]
    switch -Regex ($arg) {
        '^(-h|--help)$' {
            Show-Usage
            exit 0
        }
        '^(-e|--edit)$' {
            $Edit = $true
            $i++
            break
        }
        '^--editor$' {
            if ($i + 1 -ge $args.Count) { Log-Err "Option $arg requires an editor command."; exit 2 }
            $EditorCmd = [string]$args[$i + 1]
            $i += 2
            break
        }
        '^--editor=(.+)$' {
            $EditorCmd = $Matches[1]
            $i++
            break
        }
        '^(-f|--force)$' {
            $Force = $true
            $i++
            break
        }
        '^--new$' {
            $CreateNew = $true
            $i++
            break
        }
        '^--git-commit-and-push$' {
            $GitCommitAndPush = $true
            $i++
            break
        }
        '^--dry-run$' {
            $DryRun = $true
            $i++
            break
        }
        '^(-s|--from)$' {
            if ($i + 1 -ge $args.Count) { Log-Err "Option $arg requires a version argument."; exit 2 }
            $FromVersion = [string]$args[$i + 1]
            $i += 2
            break
        }
        '^--from=(.+)$' {
            $FromVersion = $Matches[1]
            $i++
            break
        }
        '^--$' {
            $i++
            while ($i -lt $args.Count) { $Positional.Add([string]$args[$i]); $i++ }
            break
        }
        '^-.' {
            Log-Err "Unknown option: $arg"
            Show-Usage
            exit 2
        }
        default {
            $Positional.Add($arg)
            $i++
            break
        }
    }
}

if ($Positional.Count -ne 2) {
    Log-Err "Expected 2 positional arguments: <package> <version>"
    Show-Usage
    exit 2
}

$Package = $Positional[0]
$TargetVersion = $Positional[1]

Test-SafeSegment $Package 'package name'
Test-SafeSegment $TargetVersion 'version'
if ($FromVersion) { Test-SafeSegment $FromVersion 'source version' }

if (-not (Test-Path -LiteralPath $RecipesDir -PathType Container)) {
    Log-Err "Recipes directory not found: $RecipesDir"
    exit 1
}

$PkgDir = Join-Path $RecipesDir $Package
if (-not (Test-Path -LiteralPath $PkgDir -PathType Container)) {
    $alt = $null
    if ($Package.Contains('_') -and (Test-Path -LiteralPath (Join-Path $RecipesDir $Package.Replace('_', '-')))) {
        $alt = $Package.Replace('_', '-')
    } elseif ($Package.Contains('-') -and (Test-Path -LiteralPath (Join-Path $RecipesDir $Package.Replace('-', '_')))) {
        $alt = $Package.Replace('-', '_')
    }
    if ($alt) {
        Log-Warn "Folder '$Package' not found, using '$alt' instead."
        $Package = $alt
        $PkgDir = Join-Path $RecipesDir $Package
    }
}

$RelTarget = "recipes/$Package/$TargetVersion"
$TargetDir = Join-Path $PkgDir $TargetVersion
$TargetRecipe = Join-Path $TargetDir 'recipe.yaml'

if ((Test-Path -LiteralPath $TargetDir) -and (-not $Force)) {
    Log-Err "Target already exists: recipes\$Package\$TargetVersion (use --force to overwrite)"
    exit 1
}

$ExistingVersions = @()
if (Test-Path -LiteralPath $PkgDir -PathType Container) {
    $ExistingVersions = Get-ChildItem -LiteralPath $PkgDir -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'recipe.yaml') -PathType Leaf } |
        ForEach-Object { $_.Name }
}

if ($ExistingVersions.Count -eq 0) {
    if (-not $CreateNew) {
        Log-Err "No existing recipes found for '$Package' in recipes\$Package."
        Log-Info "Pass --new to scaffold a blank recipe.yaml."
        exit 1
    }

    Log-Info "Creating new package recipe: recipes\$Package\$TargetVersion\recipe.yaml"
    if ($DryRun) {
        Log-Info "[dry-run] Would create $TargetRecipe"
    } else {
        if ($Force -and (Test-Path -LiteralPath $TargetDir)) { Remove-Item -LiteralPath $TargetDir -Recurse -Force }
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
        $content = @"
metadata:
  name: "$($Package.Replace('-', '_'))"
  version: "$TargetVersion"
  download_version: "$TargetVersion"

build:
  system_dependencies: []
  env: {}
  patches: []
"@ -replace "`r`n", "`n"
        [System.IO.File]::WriteAllText($TargetRecipe, $content + "`n", (New-Object System.Text.UTF8Encoding($false)))
        Log-Ok "Created $TargetRecipe"
    }
} else {
    if ($FromVersion) {
        $SourceVersion = $FromVersion
        $SourceRecipeCheck = Join-Path (Join-Path $PkgDir $SourceVersion) 'recipe.yaml'
        if (-not (Test-Path -LiteralPath $SourceRecipeCheck -PathType Leaf)) {
            Log-Err "Specified source recipe not found: recipes\$Package\$SourceVersion\recipe.yaml"
            exit 1
        }
    } else {
        $SourceVersion = Find-ClosestVersion $TargetVersion $ExistingVersions
    }

    if ($SourceVersion -eq $TargetVersion) {
        Log-Err "Source and target versions are identical ($TargetVersion)."
        exit 1
    }

    $SourceDir = Join-Path $PkgDir $SourceVersion
    Log-Info "Package: $Package | Closest template: $SourceVersion -> Target: $TargetVersion"

    if ($DryRun) {
        Log-Info "[dry-run] Would copy $SourceDir -> $TargetDir"
        Log-Info "[dry-run] Would set version & download_version to `"$TargetVersion`""
    } else {
        if ($Force -and (Test-Path -LiteralPath $TargetDir)) { Remove-Item -LiteralPath $TargetDir -Recurse -Force }
        Copy-Item -LiteralPath $SourceDir -Destination $TargetDir -Recurse -Force
        Update-RecipeYaml (Join-Path $SourceDir 'recipe.yaml') $TargetRecipe $TargetVersion

        Log-Ok "Generated recipes\$Package\$TargetVersion\recipe.yaml"

        $PatchesDir = Join-Path $TargetDir 'patches'
        if ((Test-Path -LiteralPath $PatchesDir -PathType Container) -and (Get-ChildItem -LiteralPath $PatchesDir | Measure-Object).Count -gt 0) {
            Log-Warn "Patches were copied from $SourceVersion. Verify they still apply cleanly to $TargetVersion!"
        }
    }
}

# --- Optional Edit ---
if ($Edit) {
    if ($DryRun) {
        Log-Info "[dry-run] Would open $TargetRecipe in '$EditorCmd'"
    } else {
        $resolvedEditor = Resolve-Editor $EditorCmd
        if (-not $resolvedEditor) {
            Log-Err "Editor '$EditorCmd' not found in PATH."
            exit 1
        }
        & $resolvedEditor $TargetRecipe
        if ($LASTEXITCODE -ne 0) {
            Log-Err "Editor exited with code $LASTEXITCODE."
            exit $LASTEXITCODE
        }
    }
}

# --- Optional Git Commit & Push ---
if ($GitCommitAndPush) {
    $CommitMsg = "feat(${Package}): v${TargetVersion}"
    if ($DryRun) {
        Log-Info "[dry-run] Would run: git add -- `"$RelTarget`" && git commit -m `"$CommitMsg`" -- `"$RelTarget`" && git push"
        exit 0
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Log-Err "'git' not found in PATH."
        exit 1
    }

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & git -C $ScriptDir rev-parse --is-inside-work-tree 1>$null 2>$null
    $gitCheckCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEap

    if ($gitCheckCode -ne 0) {
        Log-Err "Directory is not a git repository: $ScriptDir"
        exit 1
    }

    Log-Info "Staging $RelTarget..."
    & git -C $ScriptDir add -- $RelTarget
    if ($LASTEXITCODE -ne 0) { Log-Err "git add failed."; exit $LASTEXITCODE }

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & git -C $ScriptDir diff --cached --quiet -- $RelTarget 1>$null 2>$null
    $diffCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEap

    if ($diffCode -eq 0) {
        Log-Warn "No changes to commit in $RelTarget. Skipping commit and push."
    } elseif ($diffCode -eq 1) {
        Log-Info "Committing: $CommitMsg"
        & git -C $ScriptDir commit -m $CommitMsg -- $RelTarget
        if ($LASTEXITCODE -ne 0) { Log-Err "git commit failed."; exit $LASTEXITCODE }

        Log-Info "Pushing to remote..."
        & git -C $ScriptDir push
        if ($LASTEXITCODE -ne 0) { Log-Err "git push failed."; exit $LASTEXITCODE }

        Log-Ok "Committed and pushed $RelTarget"
    } else {
        Log-Err "git diff failed."
        exit $diffCode
    }
}