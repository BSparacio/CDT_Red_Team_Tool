# winrm_setup.ps1

# Dropped into CloudBase-init LocalScripts by Ansible as 01_winrm_setup.ps1
# Purpose: Ensures WinRM over HTTPS is configured on the target so Ansible
# can continue to reach the machine on subsequent deployments. Runs automatically
# every time CloudBase-init executes. Safe to run multiple times because it
# checks if the HTTPS listener already exists before doing anything.

# ── Check if HTTPS listener already exists ────────────────────────────────────
# winrm enumerate lists all current WinRM listeners. We redirect stderr to null
# to suppress any error output and pipe the result to Select-String to search
# for an existing HTTPS listener. If one is found we exit immediately so we do
# not create a duplicate listener or overwrite a working configuration.
$existing = winrm enumerate winrm/config/Listener 2>$null | Select-String "HTTPS"
if ($existing) { exit 0 }

# ── Create a self-signed TLS certificate ─────────────────────────────────────
# Windows requires a certificate to create an HTTPS listener. We generate a
# self-signed certificate using the machine's own hostname as the common name
# and store it in the local machine's personal certificate store. This cert
# is not trusted by external CAs but is sufficient for encrypting the WinRM
# channel. Ansible is configured to ignore certificate validation which is
# why this works without a CA-signed cert.
$cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME `
    -CertStoreLocation Cert:\LocalMachine\My

# ── Create the HTTPS WinRM listener ──────────────────────────────────────────
# Creates a new WinRM listener bound to all network interfaces (*) using HTTPS
# transport. The certificate thumbprint links this listener to the cert we just
# created. -Force overwrites any existing HTTP listener without prompting.
# This listener is what Ansible connects to on port 5986. 
New-Item -Path WSMan:\localhost\Listener `
    -Transport HTTPS `
    -Address * `
    -CertificateThumbPrint $cert.Thumbprint `
    -Force

# ── Open Windows Firewall for WinRM HTTPS ────────────────────────────────────
# By default Windows Firewall blocks inbound connections on port 5986.
# This creates an inbound allow rule so Ansible can reach the WinRM listener
# from the Kali machine through the OpenStack network.
netsh advfirewall firewall add rule `
    name="WinRM HTTPS" `
    dir=in `
    action=allow `
    protocol=TCP `
    localport=5986

# ── Ensure WinRM service is running and persistent ───────────────────────────
# Sets WinRM to start automatically on boot so it survives reboots, then
# starts it immediately in case it is currently stopped.
Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM

# ── Configure WinRM authentication ───────────────────────────────────────────
# Basic authentication allows Ansible to authenticate using a plain
# username and password over the encrypted HTTPS channel. Without this
# Ansible cannot log in even if the listener is running.
# AllowUnencrypted is explicitly set to false as an additional safeguard
# ensuring credentials are never sent in plaintext even if something
# attempts to downgrade the connection to HTTP.
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/service '@{AllowUnencrypted="false"}'