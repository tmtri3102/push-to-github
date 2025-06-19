# Smart-Bulk-GitHub-Push.ps1 - Latest Final Revised Script (Error Corrected)

<#
.SYNOPSIS
    Smart script that analyzes existing repos and only processes what's needed.

.DESCRIPTION
    This script intelligently categorizes repositories and only processes what actually needs work:
    - Skips repos that are already properly connected
    - Reconnects repos where remote exists but connection is broken  
    - Only creates new GitHub repos for local repos that don't exist remotely
    - Provides detailed analysis before processing

.PARAMETER ParentFolder
    The full path to the main folder containing all your local Git project folders.
    Default: "D:\Desktop"

.PARAMETER Visibility
    The visibility for NEW repositories on GitHub. Existing repos keep their current visibility.
    Must be either 'public' or 'private'. Defaults to 'private'.

.PARAMETER DelaySeconds
    Seconds to pause between creating NEW repositories (not reconnections).
    Defaults to 90 seconds to avoid rate limits.

.PARAMETER AnalyzeOnly
    If specified, only shows the analysis without making any changes.
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ParentFolder = "D:\Desktop",

    [Parameter(Mandatory=$false)]
    [ValidateSet("public", "private")]
    [string]$Visibility = "private",

    [Parameter(Mandatory=$false)]
    [int]$DelaySeconds = 90,

    [Parameter(Mandatory=$false)]
    [switch]$AnalyzeOnly
)

# Set the parameters for this run (you can change these values)
# For the final step, you would typically set AnalyzeOnly to $false
$ParentFolder = "D:\Desktop" 
$Visibility = "private" 
$DelaySeconds = 90 
$AnalyzeOnly = $false # <<< IMPORTANT: Set to $false to perform operations

# Repository status categories
$script:RepoCategories = @{
    AlreadySynced = @()      # Local repo with working remote to correct GitHub repo
    NeedsReconnection = @()  # Both exist but remote is broken/missing
    ReadyToPush = @()        # Local exists, no GitHub counterpart
    NeedsCommits = @()       # Local exists, no commits, no GitHub counterpart
    Problems = @()           # Corrupted or problematic repos
}

Write-Host "🚀 Smart Bulk GitHub Push Script" -ForegroundColor Magenta
Write-Host "=================================" -ForegroundColor Magenta
Write-Host ""

# Validate inputs
if (-not (Test-Path $ParentFolder)) {
    Write-Host "❌ ERROR: Parent folder does not exist: $ParentFolder" -ForegroundColor Red
    exit 1
}

# --- Function Definitions (All Functions) ---

# Function to check if a directory contains a valid git repository
function Test-GitRepository {
    param([string]$Path)
    
    $gitPath = Join-Path $Path ".git"
    if (-not (Test-Path $gitPath)) {
        return $false
    }
    
    Push-Location $Path -ErrorAction SilentlyContinue
    try {
        # Check if it's a real git repo and get basic info
        $null = git status 2>$null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    } finally {
        Pop-Location -ErrorAction SilentlyContinue
    }
}

# Function to get repository status and remote info
function Get-RepositoryStatus {
    param([string]$RepoPath, [string]$RepoName, [array]$GitHubRepos)
    
    Push-Location $RepoPath -ErrorAction SilentlyContinue
    try {
        $status = @{
            Name = $RepoName
            Path = $RepoPath
            HasCommits = $false
            Remotes = @()
            GitHubExists = $false
            RemoteWorking = $false
            Category = "Unknown"
        }
        
        # Check if repo has commits
        $commits = git log --oneline -1 2>$null
        $status.HasCommits = $LASTEXITCODE -eq 0 -and $commits
        
        # Get all remotes
        $remoteNames = git remote 2>$null
        if ($remoteNames) {
            foreach ($remoteName in $remoteNames) {
                $remoteUrl = git remote get-url $remoteName 2>$null
                $status.Remotes += @{
                    Name = $remoteName
                    Url = $remoteUrl
                }
            }
        }
        
        # Check if GitHub repo exists
        $status.GitHubExists = $GitHubRepos -contains $RepoName
        
        # Test if any remote is working and points to the correct GitHub repo
        foreach ($remote in $status.Remotes) {
            if ($remote.Url -match "github\.com[:/]([^/]+)/$RepoName(\.git)?$") {
                # Test if remote is reachable
                $testRemote = git ls-remote $remote.Name HEAD 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $status.RemoteWorking = $true
                    break
                }
            }
        }
        
        # Categorize the repository
        if ($status.GitHubExists -and $status.RemoteWorking -and $status.HasCommits) {
            $status.Category = "AlreadySynced"
        } elseif ($status.GitHubExists -and $status.HasCommits -and -not $status.RemoteWorking) {
            $status.Category = "NeedsReconnection" 
        } elseif (-not $status.GitHubExists -and $status.HasCommits) {
            $status.Category = "ReadyToPush"
        } elseif (-not $status.GitHubExists -and -not $status.HasCommits) {
            $status.Category = "NeedsCommits"
        } else {
            $status.Category = "Problems"
        }
        
        return $status
        
    } finally {
        Pop-Location -ErrorAction SilentlyContinue
    }
}

# Function to get all existing GitHub repository names (REVISED)
function Get-GitHubRepositories { 
    Write-Host "Fetching your GitHub repositories directly..." -ForegroundColor Cyan
    try {
        $fetchLimit = 500 # Set a sufficiently high limit based on your actual repo count
        Write-Host "  Attempting to fetch all repositories with a limit of $fetchLimit..." -ForegroundColor DarkCyan

        $commandOutput = gh repo list --json name --limit $fetchLimit 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host ('  Error - gh CLI command failed: ' + $commandOutput) -ForegroundColor Red
            return @()
        }

        try {
            $pageRepos = $commandOutput | ConvertFrom-Json
        } catch {
            Write-Host ('  Error - Failed to convert JSON. Output: ' + $commandOutput) -ForegroundColor Red
            return @()
        }
        
        if ($pageRepos -and $pageRepos.Count -gt 0) {
            $allRepos = $pageRepos.name
            Write-Host "Successfully found $($allRepos.Count) repositories on GitHub." -ForegroundColor Green
            return $allRepos
        } else {
            Write-Host "No repositories found on GitHub or an empty list was returned." -ForegroundColor Yellow
            return @()
        }
    } catch {
        Write-Host "Warning: Could not fetch GitHub repositories. Error: $_.Exception.Message. Continuing with limited analysis." -ForegroundColor Yellow
        return @()
    }
}

# Function to find all Git repositories with exclusions
function Find-GitRepositories {
    param([string]$RootPath)
    
    Write-Host "🔍 Scanning for Git repositories in: $RootPath" -ForegroundColor Cyan
    
    $excludePatterns = @("node_modules", ".npm", ".yarn", "bower_components", "vendor", "dist", "build", ".next", ".nuxt")
    $gitRepos = @()
    
    # Get all directories recursively
    $allDirs = Get-ChildItem -Path $RootPath -Directory -Recurse -ErrorAction SilentlyContinue | 
        Where-Object { 
            $dirName = $_.Name
            $shouldExclude = $excludePatterns | Where-Object { $dirName -like "*$_*" }
            -not $shouldExclude
        }
    
    # Add root directory to check
    $allDirs = @(Get-Item $RootPath) + $allDirs
    
    $totalDirs = $allDirs.Count
    $checkedDirs = 0
    
    foreach ($dir in $allDirs) {
        $checkedDirs++
        if ($checkedDirs % 50 -eq 0) {
            Write-Host "  Checked $checkedDirs/$totalDirs directories..." -ForegroundColor DarkCyan
        }
        
        if (Test-GitRepository -Path $dir.FullName) {
            $gitRepos += $dir
        }
    }
    
    Write-Host "✅ Found $($gitRepos.Count) Git repositories." -ForegroundColor Green
    return $gitRepos
}

# Function to analyze all repositories
function Invoke-RepositoryAnalysis {
    param([array]$LocalRepos, [array]$GitHubRepos)
    
    Write-Host ""
    Write-Host "📊 Analyzing repository status..." -ForegroundColor Magenta
    
    $total = $LocalRepos.Count
    $processed = 0
    
    foreach ($repo in $LocalRepos) {
        $processed++
        if ($processed % 25 -eq 0) {
            Write-Host "  Analyzed $processed/$total repositories..." -ForegroundColor DarkMagenta
        }
        
        $status = Get-RepositoryStatus -RepoPath $repo.FullName -RepoName $repo.Name -GitHubRepos $GitHubRepos
        $script:RepoCategories[$status.Category] += $status
    }
    
    Write-Host "✅ Analysis complete!" -ForegroundColor Green
}

# Function to display analysis results
function Show-AnalysisResults {
    Write-Host ""
    Write-Host "📈 ANALYSIS RESULTS" -ForegroundColor Magenta
    Write-Host "===================" -ForegroundColor Magenta
    Write-Host ""

    Write-Host "✅ Already Synced: $($script:RepoCategories.AlreadySynced.Count)" -ForegroundColor Green
    Write-Host "   These repos are properly connected and don't need processing."
    Write-Host ""

    Write-Host "🔗 Needs Reconnection: $($script:RepoCategories.NeedsReconnection.Count)" -ForegroundColor Yellow
    Write-Host "   These exist on GitHub but have broken/missing remotes (FAST to fix)."
    if ($script:RepoCategories.NeedsReconnection.Count -gt 0) {
        $script:RepoCategories.NeedsReconnection | ForEach-Object { 
            Write-Host "   - $($_.Name)" -ForegroundColor DarkYellow 
        }
    }
    Write-Host ""

    Write-Host "🚀 Ready to Push: $($script:RepoCategories.ReadyToPush.Count)" -ForegroundColor Cyan
    Write-Host "   These have commits and need new GitHub repos created."
    if ($script:RepoCategories.ReadyToPush.Count -gt 0 -and $script:RepoCategories.ReadyToPush.Count -le 10) {
        $script:RepoCategories.ReadyToPush[0..9] | ForEach-Object { 
            Write-Host "   - $($_.Name)" -ForegroundColor DarkCyan 
        }
    } elseif ($script:RepoCategories.ReadyToPush.Count -gt 10) {
        $script:RepoCategories.ReadyToPush[0..9] | ForEach-Object { 
            Write-Host "   - $($_.Name)" -ForegroundColor DarkCyan 
        }
        Write-Host "   ... and $($script:RepoCategories.ReadyToPush.Count - 10) more" -ForegroundColor DarkCyan
    }
    Write-Host ""

    Write-Host "📝 Needs Commits: $($script:RepoCategories.NeedsCommits.Count)" -ForegroundColor Blue
    Write-Host "   These need initial commits before creating GitHub repos."
    Write-Host ""

    Write-Host "❌ Problems: $($script:RepoCategories.Problems.Count)" -ForegroundColor Red
    Write-Host "   These have issues that need manual attention."
    if ($script:RepoCategories.Problems.Count -gt 0) {
        $script:RepoCategories.Problems | ForEach-Object { 
            Write-Host "   - $($_.Name): $($_.Path)" -ForegroundColor DarkRed 
        }
    }
    Write-Host ""

    $totalWork = $script:RepoCategories.NeedsReconnection.Count + 
                 $script:RepoCategories.ReadyToPush.Count + 
                 $script:RepoCategories.NeedsCommits.Count

    $needProcessingColor = if ($totalWork -eq 0) { "Green" } else { "Yellow" }
    Write-Host "📋 SUMMARY:" -ForegroundColor White
    Write-Host "   Total repositories found: $($LocalRepos.Count)"
    Write-Host "   Already handled: $($script:RepoCategories.AlreadySynced.Count)" -ForegroundColor Green
    Write-Host "   Need processing: $totalWork" -ForegroundColor $needProcessingColor

    $rateLimitedColor = if (($script:RepoCategories.ReadyToPush.Count + $script:RepoCategories.NeedsCommits.Count) -eq 0) { "Green" } else { "Red" }
    Write-Host "   Rate-limited operations: $($script:RepoCategories.ReadyToPush.Count + $script:RepoCategories.NeedsCommits.Count)" -ForegroundColor $rateLimitedColor

    if ($totalWork -gt 0) {
        $estimatedTime = [Math]::Ceiling(($script:RepoCategories.ReadyToPush.Count + $script:RepoCategories.NeedsCommits.Count) * $DelaySeconds / 60)
        Write-Host "   Estimated time: ~$estimatedTime minutes (for new repo creation)" -ForegroundColor Cyan
    }
} # <-- Ensure this closing brace is present

# Function to reconnect repositories
function Repair-RepositoryConnections {
    if ($script:RepoCategories.NeedsReconnection.Count -eq 0) {
        return
    }
    
    Write-Host ""
    Write-Host "🔗 Reconnecting repositories with broken remotes..." -ForegroundColor Yellow
    
    foreach ($repo in $script:RepoCategories.NeedsReconnection) {
        Write-Host "  Reconnecting: $($repo.Name)" -ForegroundColor Yellow
        
        Push-Location $repo.Path -ErrorAction SilentlyContinue
        try {
            # Remove all existing remotes
            $remotes = git remote 2>$null
            if ($remotes) {
                foreach ($remote in $remotes) {
                    git remote remove $remote 2>$null
                }
            }
            
            # Add correct origin remote
            $username = gh auth status 2>&1 | Select-String "Logged in to github.com as (\w+)" | ForEach-Object { $_.Matches[0].Groups[1].Value }
            if ($username) {
                git remote add origin "git@github.com:$username/$($repo.Name).git" 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "    ✅ Reconnected successfully" -ForegroundColor Green
                } else {
                    Write-Host "    ❌ Failed to add remote" -ForegroundColor Red
                }
            }
        } finally {
            Pop-Location -ErrorAction SilentlyContinue
        }
    }
}

# Function to process repositories that need new GitHub repos
function New-MissingRepositories {
    $reposToCreate = $script:RepoCategories.ReadyToPush + $script:RepoCategories.NeedsCommits
    
    if ($reposToCreate.Count -eq 0) {
        return
    }
    
    Write-Host ""
    Write-Host "🚀 Creating new GitHub repositories..." -ForegroundColor Cyan
    Write-Host "This will create $($reposToCreate.Count) new repositories with $DelaySeconds second delays."
    
    $count = 0
    foreach ($repo in $reposToCreate) {
        $count++
        Write-Host ""
        Write-Host "[$count/$($reposToCreate.Count)] Creating: $($repo.Name)" -ForegroundColor White
        
        Push-Location $repo.Path -ErrorAction SilentlyContinue
        try {
        # Handle repos that need commits first
            if ($repo.Category -eq "NeedsCommits") {
                Write-Host "  📝 Creating initial commit..." -ForegroundColor Blue
                
                # Set temporary git config if needed
                $userName = git config user.name 2>$null
                $userEmail = git config user.email 2>$null
                $tempConfig = $false
                
                if (-not $userName) {
                    git config user.name "Bulk Push Script"
                    $tempConfig = $true
                }
                if (-not $userEmail) {
                    git config user.email "bulk-push@example.com"  
                    $tempConfig = $true
                }
                
                git add . 2>$null
                git commit -m "Initial commit via bulk push script" 2>$null
                
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "  ❌ Failed to create initial commit" -ForegroundColor Red
                    continue
                }
                
                Write-Host "  ✅ Initial commit created" -ForegroundColor Green
            }
            
            # Remove existing remotes
            $remotes = git remote 2>$null
            if ($remotes) {
                foreach ($remote in $remotes) {
                    git remote remove $remote 2>$null
                }
            }
            
            # Create GitHub repository and push
            $visibilityFlag = "--$Visibility"
            Write-Host "  🌐 Creating GitHub repository..." -ForegroundColor Cyan
            
            $output = gh repo create $repo.Name --source=. --push $visibilityFlag 2>&1
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ✅ SUCCESS: Repository created and pushed!" -ForegroundColor Green
            } else {
                Write-Host "  ❌ ERROR: Failed to create repository" -ForegroundColor Red
                Write-Host "     Output: $output" -ForegroundColor Red
                
                # Check for rate limiting
                if ($output -match "too many repositories|rate limit") {
                    Write-Host "  ⏸️ Rate limited! Consider increasing delay or waiting before resuming." -ForegroundColor Yellow
                }
            }
            
        } finally {
            Pop-Location -ErrorAction SilentlyContinue
        }
        
        # Apply delay between creations (not for the last one)
        if ($count -lt $reposToCreate.Count) {
            Write-Host "  ⏱️ Waiting $DelaySeconds seconds..." -ForegroundColor DarkGray
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

# --- Main Script Logic ---

Write-Host "Starting Step 1: Finding local repositories..." -ForegroundColor Green
$localRepos = Find-GitRepositories -RootPath $ParentFolder

if ($localRepos.Count -eq 0) {
    Write-Host "❌ No Git repositories found in $ParentFolder" -ForegroundColor Red
    exit 0
}

Write-Host "Starting Step 2: Fetching GitHub repositories..." -ForegroundColor Green
$gitHubRepos = Get-GitHubRepositories

Write-Host "Starting Step 3: Analyzing all repositories..." -ForegroundColor Green
Invoke-RepositoryAnalysis -LocalRepos $localRepos -GitHubRepos $gitHubRepos

Write-Host "Starting Step 4: Showing analysis results..." -ForegroundColor Green
Show-AnalysisResults

# Step 5: Process if not just analyzing
if (-not $AnalyzeOnly) {
    $totalWork = $script:RepoCategories.NeedsReconnection.Count + 
                 $script:RepoCategories.ReadyToPush.Count + 
                 $script:RepoCategories.NeedsCommits.Count
    
    if ($totalWork -eq 0) {
        Write-Host "🎉 All repositories are already properly synced! Nothing to do." -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "You are about to process $totalWork repositories." -ForegroundColor Yellow
Write-Host "This includes reconnecting existing GitHub repos and creating new ones." -ForegroundColor Yellow
$confirm = Read-Host "Do you want to proceed with these operations? (Type 'YES' to continue)"
        
        if ($confirm -eq "YES") { 
            Write-Host "Proceeding with processing..." -ForegroundColor Yellow
            
            # Fast operations first (no rate limits)
            Repair-RepositoryConnections
            
            # Slow operations (rate limited)
            New-MissingRepositories
            
            Write-Host ""
            Write-Host "🎉 Processing complete!" -ForegroundColor Green
        } else {
            Write-Host "Operation cancelled by user." -ForegroundColor Yellow
        }
    }
} else {
    Write-Host ""
    Write-Host "AnalyzeOnly mode was active. No changes have been made to your repositories." -ForegroundColor DarkGreen
}

Write-Host ""
Read-Host "Press Enter to exit"