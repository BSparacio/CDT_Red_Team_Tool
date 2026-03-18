# CDT_Red_Team_Tool

'''
winrm quickconfig -force; netsh advfirewall firewall add rule name="WinRM HTTPS" dir=in action=allow protocol=TCP localport=5986; winrm set winrm/config/service/auth '@{Basic="true"}'
'''