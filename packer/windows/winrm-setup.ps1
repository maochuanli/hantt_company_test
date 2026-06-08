<powershell>
# Enable WinRM HTTPS so Packer can connect
winrm quickconfig -q
winrm set winrm/config '@{MaxTimeoutms="1800000"}'
winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="1024"}'
winrm set winrm/config/service '@{AllowUnencrypted="false"}'
winrm set winrm/config/service/auth '@{Basic="true"}'

# Create self-signed cert and bind HTTPS listener
$cert = New-SelfSignedCertificate `
    -DnsName "packer-build" `
    -CertStoreLocation Cert:\LocalMachine\My `
    -NotAfter (Get-Date).AddYears(1)

New-Item -Path WSMan:\localhost\Listener `
    -Transport HTTPS `
    -Address * `
    -CertificateThumbPrint $cert.Thumbprint `
    -Force

# Open firewall for WinRM HTTPS
netsh advfirewall firewall add rule `
    name="WinRM-HTTPS" protocol=TCP dir=in localport=5986 action=allow

Restart-Service WinRM
</powershell>
