# ansible/files/winrm_setup.ps1

# Only run if HTTPS listener doesn't already exist
$existing = winrm enumerate winrm/config/Listener 2>$null | Select-String "HTTPS"
if ($existing) { exit 0 }

# Create self-signed cert and HTTPS listener
$cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME `
    -CertStoreLocation Cert:\LocalMachine\My

New-Item -Path WSMan:\localhost\Listener `
    -Transport HTTPS `
    -Address * `
    -CertificateThumbPrint $cert.Thumbprint `
    -Force

# Open firewall
netsh advfirewall firewall add rule `
    name="WinRM HTTPS" `
    dir=in `
    action=allow `
    protocol=TCP `
    localport=5986

# Ensure WinRM service is running and set to auto-start
Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM

# Allow Ansible to authenticate
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/service '@{AllowUnencrypted="false"}'