$Env:ArcBoxDir = "C:\ArcBox"
$Env:ArcBoxLogsDir = "$Env:ArcBoxDir\Logs"
$Env:ArcBoxVMDir = "$Env:ArcBoxDir\Virtual Machines"
$agentScript = "$Env:ArcBoxDir\agentScript"

Start-Transcript -Path $Env:ArcBoxLogsDir\ArcServersLogonScript.log

Function Set-VMNetworkConfiguration {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true,
                   Position=1,
                   ParameterSetName='DHCP',
                   ValueFromPipeline=$true)]
        [Parameter(Mandatory=$true,
                   Position=0,
                   ParameterSetName='Static',
                   ValueFromPipeline=$true)]
        [Microsoft.HyperV.PowerShell.VMNetworkAdapter]$NetworkAdapter,

        [Parameter(Mandatory=$true,
                   Position=1,
                   ParameterSetName='Static')]
        [String[]]$IPAddress=@(),

        [Parameter(Mandatory=$false,
                   Position=2,
                   ParameterSetName='Static')]
        [String[]]$Subnet=@(),

        [Parameter(Mandatory=$false,
                   Position=3,
                   ParameterSetName='Static')]
        [String[]]$DefaultGateway = @(),

        [Parameter(Mandatory=$false,
                   Position=4,
                   ParameterSetName='Static')]
        [String[]]$DNSServer = @(),

        [Parameter(Mandatory=$false,
                   Position=0,
                   ParameterSetName='DHCP')]
        [Switch]$Dhcp
    )

    $VM = Get-WmiObject -Namespace 'root\virtualization\v2' -Class 'Msvm_ComputerSystem' | Where-Object { $_.ElementName -eq $NetworkAdapter.VMName } 
    $VMSettings = $vm.GetRelated('Msvm_VirtualSystemSettingData') | Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' }    
    $VMNetAdapters = $VMSettings.GetRelated('Msvm_SyntheticEthernetPortSettingData') 

    $NetworkSettings = @()
    foreach ($NetAdapter in $VMNetAdapters) {
        if ($NetAdapter.Address -eq $NetworkAdapter.MacAddress) {
            $NetworkSettings = $NetworkSettings + $NetAdapter.GetRelated("Msvm_GuestNetworkAdapterConfiguration")
        }
    }

    $NetworkSettings[0].IPAddresses = $IPAddress
    $NetworkSettings[0].Subnets = $Subnet
    $NetworkSettings[0].DefaultGateways = $DefaultGateway
    $NetworkSettings[0].DNSServers = $DNSServer
    $NetworkSettings[0].ProtocolIFType = 4096

    if ($dhcp) {
        $NetworkSettings[0].DHCPEnabled = $true
    } else {
        $NetworkSettings[0].DHCPEnabled = $false
    }

    $Service = Get-WmiObject -Class "Msvm_VirtualSystemManagementService" -Namespace "root\virtualization\v2"
    $setIP = $Service.SetGuestNetworkAdapterConfiguration($VM, $NetworkSettings[0].GetText(1))

    if ($setip.ReturnValue -eq 4096) {
        $job=[WMI]$setip.job 

        while ($job.JobState -eq 3 -or $job.JobState -eq 4) {
            Start-Sleep -Seconds 1
            $job=[WMI]$setip.job
        }

        if ($job.JobState -eq 7) {
            Write-Output "Success"
        }
        else {
            $job.GetError()
        }
    } elseif($setip.ReturnValue -eq 0) {
        Write-Output "Success"
    }
}

# Required for CLI commands
az login --service-principal --username $env:spnClientID --password $env:spnClientSecret --tenant $env:spnTenantId

# Register Azure providers
az provider register --namespace Microsoft.HybridCompute --wait
az provider register --namespace Microsoft.GuestConfiguration --wait
az provider register --namespace Microsoft.AzureArcData --wait

# Install and configure DHCP service (used by Hyper-V nested VMs)
Write-Output "Configure DHCP service"
$dnsClient = Get-DnsClient | Where-Object {$_.InterfaceAlias -eq "Ethernet" }
Add-DhcpServerv4Scope -Name "ArcBox" -StartRange 10.10.1.1 -EndRange 10.10.1.254 -SubnetMask 255.0.0.0 -State Active
Add-DhcpServerv4ExclusionRange -ScopeID 10.10.1.0 -StartRange 10.10.1.101 -EndRange 10.10.1.120
Set-DhcpServerv4OptionValue -DnsDomain $dnsClient.ConnectionSpecificSuffix -DnsServer 168.63.129.16
Set-DhcpServerv4OptionValue -OptionID 3 -Value 10.10.1.1 -ScopeID 10.10.1.0
Set-DhcpServerv4Scope -ScopeId 10.10.1.0 -LeaseDuration 1.00:00:00
Set-DhcpServerv4OptionValue -ComputerName localhost -ScopeId 10.10.10.0 -DnsServer 8.8.8.8
Restart-Service dhcpserver

# Create the NAT network
Write-Output "Create internal NAT"
$natName = "InternalNat"
New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix 10.10.0.0/16

# Create an internal switch with NAT
Write-Output "Create internal switch"
$switchName = 'InternalNATSwitch'
New-VMSwitch -Name $switchName -SwitchType Internal
$adapter = Get-NetAdapter | Where-Object { $_.Name -like "*"+$switchName+"*" }

# Create an internal network (gateway first)
Write-Output "Create gateway"
New-NetIPAddress -IPAddress 10.10.1.1 -PrefixLength 24 -InterfaceIndex $adapter.ifIndex

# Enable Enhanced Session Mode on Host
Write-Output "Enable Enhanced Session Mode"
Set-VMHost -EnableEnhancedSessionMode $true

$sourceFolder = 'https://jumpstart.blob.core.windows.net/v2images'
$sas = "?sp=rl&st=2022-01-27T01:47:01Z&se=2025-01-27T09:47:01Z&spr=https&sv=2020-08-04&sr=c&sig=NB8g7f4JT3IM%2FL6bUfjFdmnGIqcc8WU015socFtkLYc%3D"
$Env:AZCOPY_BUFFER_GB=4
if ($env:flavor -eq "Full") {
    # The "Full" ArcBox flavor has an azcopy network throughput capping
    Write-Output "Downloading nested VMs VHDX files. This can take some time, hold tight..."  
    azcopy cp $sourceFolder/*$sas $Env:ArcBoxVMDir --recursive=true --check-length=false --cap-mbps 1200 --log-level=ERROR
} else {
    # Other ArcBox flavors does not have an azcopy network throughput capping
    Write-Output "Downloading nested VMs VHDX files. This can take some time, hold tight..."
    azcopy cp $sourceFolder/*$sas $Env:ArcBoxVMDir --recursive=true --check-length=false --log-level=ERROR
}

# Create the nested VMs
Write-Output "Create Hyper-V VMs"
New-VM -Name ArcBox-Win2K19 -MemoryStartupBytes 12GB -BootDevice VHD -VHDPath "$Env:ArcBoxVMDir\ArcBox-Win2K19.vhdx" -Path $Env:ArcBoxVMDir -Generation 2 -Switch $switchName
Set-VMProcessor -VMName ArcBox-Win2K19 -Count 2

New-VM -Name ArcBox-Win2K22 -MemoryStartupBytes 12GB -BootDevice VHD -VHDPath "$Env:ArcBoxVMDir\ArcBox-Win2K22.vhdx" -Path $Env:ArcBoxVMDir -Generation 2 -Switch $switchName
Set-VMProcessor -VMName ArcBox-Win2K22 -Count 2

New-VM -Name ArcBox-SQL -MemoryStartupBytes 12GB -BootDevice VHD -VHDPath "$Env:ArcBoxVMDir\ArcBox-SQL.vhdx" -Path $Env:ArcBoxVMDir -Generation 2 -Switch $switchName
Set-VMProcessor -VMName ArcBox-SQL -Count 2

New-VM -Name ArcBox-Ubuntu -MemoryStartupBytes 4GB -BootDevice VHD -VHDPath "$Env:ArcBoxVMDir\ArcBox-Ubuntu.vhdx" -Path $Env:ArcBoxVMDir -Generation 2 -Switch $switchName
Set-VMFirmware -VMName ArcBox-Ubuntu -EnableSecureBoot On -SecureBootTemplate 'MicrosoftUEFICertificateAuthority'
Set-VMProcessor -VMName ArcBox-Ubuntu -Count 1

New-VM -Name ArcBox-CentOS -MemoryStartupBytes 4GB -BootDevice VHD -VHDPath "$Env:ArcBoxVMDir\ArcBox-CentOS.vhdx" -Path $Env:ArcBoxVMDir -Generation 2 -Switch $switchName
Set-VMFirmware -VMName ArcBox-CentOS -EnableSecureBoot On -SecureBootTemplate 'MicrosoftUEFICertificateAuthority'
Set-VMProcessor -VMName ArcBox-CentOS -Count 1

# We always want the VMs to start with the host and shut down cleanly with the host
Write-Output "Set VM auto start/stop"
Set-VM -Name ArcBox-Win2K19 -AutomaticStartAction Start -AutomaticStopAction ShutDown
Set-VM -Name ArcBox-Win2K22 -AutomaticStartAction Start -AutomaticStopAction ShutDown
Set-VM -Name ArcBox-SQL -AutomaticStartAction Start -AutomaticStopAction ShutDown
Set-VM -Name ArcBox-Ubuntu -AutomaticStartAction Start -AutomaticStopAction ShutDown
Set-VM -Name ArcBox-CentOS -AutomaticStartAction Start -AutomaticStopAction ShutDown

Write-Output "Enabling Guest Integration Service"
Get-VM | Get-VMIntegrationService | Where-Object {-not($_.Enabled)} | Enable-VMIntegrationService -Verbose

# Start all the VMs
Write-Output "Start VMs"
Start-VM -Name ArcBox-Win2K19
Start-VM -Name ArcBox-Win2K22
Start-VM -Name ArcBox-SQL
Start-VM -Name ArcBox-Ubuntu
Start-VM -Name ArcBox-CentOS

# Expand Windows partition sizes
Start-Sleep -Seconds 20
$username = "Administrator"
$password = "ArcDemo123!!"
$secstr = New-Object -TypeName System.Security.SecureString
$password.ToCharArray() | ForEach-Object {$secstr.AppendChar($_)}
$cred = new-object -typename System.Management.Automation.PSCredential -argumentlist $username, $secstr
Invoke-Command -VMName ArcBox-Win2K19 -ScriptBlock { Get-NetAdapter | Restart-NetAdapter } -Credential $cred
Invoke-Command -VMName ArcBox-Win2K22 -ScriptBlock { Get-NetAdapter | Restart-NetAdapter } -Credential $cred
Invoke-Command -VMName ArcBox-SQL -ScriptBlock { Get-NetAdapter | Restart-NetAdapter } -Credential $cred

Start-Sleep -Seconds 5

# Configure the ArcBox Hyper-V host to allow the nested VMs onboard as Azure Arc-enabled servers
Write-Output "Configure the ArcBox VM to allow the nested VMs onboard as Azure Arc-enabled servers"
Set-Service WindowsAzureGuestAgent -StartupType Disabled -Verbose
Stop-Service WindowsAzureGuestAgent -Force -Verbose
New-NetFirewallRule -Name BlockAzureIMDS -DisplayName "Block access to Azure IMDS" -Enabled True -Profile Any -Direction Outbound -Action Block -RemoteAddress 169.254.169.254

# Hard-coded username and password for the nested VMs
$nestedWindowsUsername = "Administrator"
$nestedWindowsPassword = "ArcDemo123!!"
$nestedLinuxUsername = "arcdemo"
$nestedLinuxPassword = "ArcDemo123!!"

# Getting the Ubuntu nested VM IP address
Get-VM -Name ArcBox-Ubuntu | Select-Object -ExpandProperty NetworkAdapters | Select-Object IPAddresses | Format-List | Out-File "$agentScript\Ubuntu-IP.txt"
$UbuntuIP = "$agentScript\Ubuntu-IP.txt"
(Get-Content $UbuntuIP | Select-Object -Skip 2) | Set-Content $UbuntuIP
$string = Get-Content "$UbuntuIP"
$string.split(',')[0] | Set-Content $UbuntuIP
$string = Get-Content "$UbuntuIP"
$string.split('{')[-1] | Set-Content $UbuntuIP
$UbuntuVmIp = Get-Content "$UbuntuIP"

# Getting the CentOS nested VM IP address
Get-VM -Name ArcBox-CentOS | Select-Object -ExpandProperty NetworkAdapters | Select-Object IPAddresses | Format-List | Out-File "$agentScript\CentOS-IP.txt"
$CentOSIP = "$agentScript\CentOS-IP.txt"
(Get-Content $CentOSIP | Select-Object -Skip 2) | Set-Content $CentOSIP
$string = Get-Content "$CentOSIP"
$string.split(',')[0] | Set-Content $CentOSIP
$string = Get-Content "$CentOSIP"
$string.split('{')[-1] | Set-Content $CentOSIP
$CentOSVmIp = Get-Content "$CentOSIP"

# Check if Service Principal has 'write' permissions to target Resource Group
$requiredActions = @('*', 'Microsoft.Authorization/roleAssignments/write', 'Microsoft.Authorization/*', 'Microsoft.Authorization/*/write')

$roleDefinitions = az role definition list --out json | ConvertFrom-Json
$spnObjectId = az ad sp show --id $env:spnClientID --query objectId -o tsv
$rolePermissions = az role assignment list --include-inherited --include-groups --scope "/subscriptions/${env:subscriptionId}/resourceGroups/${env:resourceGroup}" | ConvertFrom-Json
$authorizedRoles = $roleDefinitions | ForEach-Object { $_ | Where-Object { (Compare-Object -ReferenceObject $requiredActions -DifferenceObject @($_.permissions.actions | Select-Object) -ExcludeDifferent -IncludeEqual) -and -not (Compare-Object -ReferenceObject $requiredActions -DifferenceObject @($_.permissions.notactions | Select-Object) -ExcludeDifferent -IncludeEqual) } } | Select-Object -ExpandProperty roleName
$hasPermission = $rolePermissions | Where-Object {($_.principalId -eq $spnObjectId) -and ($_.roleDefinitionName -in $authorizedRoles)}

# Copying the Azure Arc Connected Agent to nested VMs
Write-Output "Copying the Azure Arc onboarding script to the nested VMs"
(Get-Content -path "$agentScript\installArcAgent.ps1" -Raw) -replace '\$spnClientId',"'$env:spnClientId'" -replace '\$spnClientSecret',"'$env:spnClientSecret'" -replace '\$resourceGroup',"'$env:resourceGroup'" -replace '\$spnTenantId',"'$env:spnTenantId'" -replace '\$azureLocation',"'$env:azureLocation'" -replace '\$subscriptionId',"'$env:subscriptionId'" | Set-Content -Path "$agentScript\installArcAgentModified.ps1"
(Get-Content -path "$agentScript\installArcAgentUbuntu.sh" -Raw) -replace '\$spnClientId',"'$env:spnClientId'" -replace '\$spnClientSecret',"'$env:spnClientSecret'" -replace '\$resourceGroup',"'$env:resourceGroup'" -replace '\$spnTenantId',"'$env:spnTenantId'" -replace '\$azureLocation',"'$env:azureLocation'" -replace '\$subscriptionId',"'$env:subscriptionId'" | Set-Content -Path "$agentScript\installArcAgentModifiedUbuntu.sh"
(Get-Content -path "$agentScript\installArcAgentCentOS.sh" -Raw) -replace '\$spnClientId',"'$env:spnClientId'" -replace '\$spnClientSecret',"'$env:spnClientSecret'" -replace '\$resourceGroup',"'$env:resourceGroup'" -replace '\$spnTenantId',"'$env:spnTenantId'" -replace '\$azureLocation',"'$env:azureLocation'" -replace '\$subscriptionId',"'$env:subscriptionId'" | Set-Content -Path "$agentScript\installArcAgentModifiedCentOS.sh"

# Create appropriate onboard script to SQL VM depending on whether or not the Service Principal has permission to peroperly onboard it to Azure Arc
if(-not $hasPermission) {
    (Get-Content -path "$agentScript\installArcAgent.ps1" -Raw) -replace '\$spnClientId',"'$env:spnClientId'" -replace '\$spnClientSecret',"'$env:spnClientSecret'" -replace '\$resourceGroup',"'$env:resourceGroup'" -replace '\$spnTenantId',"'$env:spnTenantId'" -replace '\$azureLocation',"'$env:azureLocation'" -replace '\$subscriptionId',"'$env:subscriptionId'" | Set-Content -Path "$agentScript\installArcAgentSQLModified.ps1"
} else {
    (Get-Content -path "$agentScript\installArcAgentSQLSP.ps1" -Raw) -replace '\$spnClientId',"'$env:spnClientId'" -replace '\$spnClientSecret',"'$env:spnClientSecret'" -replace '\$myResourceGroup',"'$env:resourceGroup'" -replace '\$spnTenantId',"'$env:spnTenantId'" -replace '\$azureLocation',"'$env:azureLocation'" -replace '\$subscriptionId',"'$env:subscriptionId'" -replace '\$logAnalyticsWorkspaceName',"'$env:workspaceName'" | Set-Content -Path "$agentScript\installArcAgentSQLModified.ps1"
}

Copy-VMFile ArcBox-Win2K19 -SourcePath "$agentScript\installArcAgentModified.ps1" -DestinationPath C:\ArcBox\installArcAgent.ps1 -CreateFullPath -FileSource Host
Copy-VMFile ArcBox-Win2K22 -SourcePath "$agentScript\installArcAgentModified.ps1" -DestinationPath C:\ArcBox\installArcAgent.ps1 -CreateFullPath -FileSource Host
Copy-VMFile ArcBox-SQL -SourcePath "$agentScript\installArcAgentSQLModified.ps1" -DestinationPath C:\ArcBox\installArcAgentSQL.ps1 -CreateFullPath -FileSource Host

Write-Output y | pscp -P 22 -pw $nestedLinuxPassword "$agentScript\installArcAgentModifiedUbuntu.sh" $nestedLinuxUsername@"$UbuntuVmIp":/home/"$nestedLinuxUsername"
Write-Output y | pscp -P 22 -pw $nestedLinuxPassword "$agentScript\installArcAgentModifiedCentOS.sh" $nestedLinuxUsername@"$CentOSVmIp":/home/"$nestedLinuxUsername"

# Onboarding the nested VMs as Azure Arc-enabled servers
Write-Output "Onboarding the nested Windows VMs as Azure Arc-enabled servers"
$secstr = New-Object -TypeName System.Security.SecureString
$nestedWindowsPassword.ToCharArray() | ForEach-Object {$secstr.AppendChar($_)}
$cred = new-object -typename System.Management.Automation.PSCredential -argumentlist $nestedWindowsUsername, $secstr

Invoke-Command -VMName ArcBox-Win2K19 -ScriptBlock { powershell -File C:\ArcBox\installArcAgent.ps1 } -Credential $cred
Invoke-Command -VMName ArcBox-Win2K22 -ScriptBlock { powershell -File C:\ArcBox\installArcAgent.ps1 } -Credential $cred
Invoke-Command -VMName ArcBox-SQL -ScriptBlock { powershell -File C:\ArcBox\installArcAgentSQL.ps1 } -Credential $cred

Write-Output "Onboarding the nested Linux VMs as an Azure Arc-enabled servers"
# Converting Linux credentials to secure string  
$secpasswd = ConvertTo-SecureString $nestedLinuxPassword -AsPlainText -Force
$Credentials = New-Object System.Management.Automation.PSCredential($nestedLinuxUsername, $secpasswd)

$SessionID = New-SSHSession -ComputerName $UbuntuVmIp -Credential $Credentials -Force -WarningAction SilentlyContinue # Connect Over SSH
$Command = "sudo sh /home/$nestedLinuxUsername/installArcAgentModifiedUbuntu.sh"
Invoke-SSHCommand -Index $sessionid.sessionid -Command $Command -Timeout 120 -WarningAction SilentlyContinue | Out-Null

# Onboarding nested CentOS server VM
$SessionID = New-SSHSession -ComputerName $CentOSVmIp -Credential $Credentials -Force -WarningAction SilentlyContinue # Connect Over SSH
$Command = "sudo sh /home/$nestedLinuxUsername/installArcAgentModifiedCentOS.sh"
Invoke-SSHCommand -Index $sessionid.sessionid -Command $Command -TimeOut 500 -WarningAction SilentlyContinue | Out-Null

# Sending deployement status message to Azure storage account queue
# if ($env:flavor -eq "ITPro") {
#     # Sleeping for allowing Azure Resource Manager API updates
#     Start-Sleep -Seconds 30
#     & "C:\ArcBox\DeploymentStatus.ps1"
# }

# Creating Hyper-V Manager desktop shortcut
Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Hyper-V Manager.lnk" -Destination "C:\Users\All Users\Desktop" -Force

# Prepare ArcBox-SQL onboarding script and create shortcut on desktop if the current Service Principal doesn't have appropriate permission to onboard the VM to Azure Arc
if(-not $hasPermission) {
    # Replace variables in Arc-enabled SQL onboarding scripts
    $sqlServerName = "ArcBox-SQL"

    (Get-Content -path "$Env:ArcBoxDir\installArcAgentSQLUser.ps1" -Raw) -replace '<subscriptionId>',"$env:subscriptionId" -replace '<resourceGroup>',"$env:resourceGroup" -replace '<location>',"$env:azureLocation" | Set-Content -Path "$Env:ArcBoxDir\installArcAgentSQLUser.ps1"
    (Get-Content -path "$Env:ArcBoxDir\ArcSQLManualOnboarding.ps1" -Raw) -replace '<subscriptionId>',"$env:subscriptionId" -replace '<resourceGroup>',"$env:resourceGroup" -replace '<sqlServerName>',"$sqlServerName" | Set-Content -Path "$Env:ArcBoxDir\ArcSQLManualOnboarding.ps1"

    # Set Edge as the Default Browser
    & SetDefaultBrowser.exe HKLM "Microsoft Edge"

    # Disable Edge 'First Run' Setup
    $edgePolicyRegistryPath  = 'HKLM:SOFTWARE\Policies\Microsoft\Edge'
    $firstRunRegistryName  = 'HideFirstRunExperience'
    $firstRunRegistryValue = '0x00000001'
    $savePasswordRegistryName = 'PasswordManagerEnabled'
    $savePasswordRegistryValue = '0x00000000'

    If (-NOT (Test-Path -Path $edgePolicyRegistryPath)) {
        New-Item -Path $edgePolicyRegistryPath -Force | Out-Null
    }

    New-ItemProperty -Path $edgePolicyRegistryPath -Name $firstRunRegistryName -Value $firstRunRegistryValue -PropertyType DWORD -Force
    New-ItemProperty -Path $edgePolicyRegistryPath -Name $savePasswordRegistryName -Value $savePasswordRegistryValue -PropertyType DWORD -Force

    # Creating Arc-enabled SQL Server onboarding desktop shortcut
    $sourceFileLocation = "${Env:ArcBoxDir}\ArcSQLManualOnboarding.ps1"
    $shortcutLocation = "$env:Public\Desktop\Onboard SQL Server.lnk"
    $wScriptShell = New-Object -ComObject WScript.Shell
    $shortcut = $wScriptShell.CreateShortcut($shortcutLocation)
    $shortcut.TargetPath = "powershell.exe"
    $shortcut.Arguments = "-ExecutionPolicy Bypass -File $sourceFileLocation"
    $shortcut.IconLocation="${Env:ArcBoxDir}\ArcSQLIcon.ico, 0"
    $shortcut.WindowStyle = 3
    $shortcut.Save()
}

# Changing to Jumpstart ArcBox wallpaper
if ($env:flavor -eq "Full" -or "ITPro") {
$imgPath="$Env:ArcBoxDir\wallpaper.png"
$code = @' 
using System.Runtime.InteropServices; 
namespace Win32{ 
    
     public class Wallpaper{ 
        [DllImport("user32.dll", CharSet=CharSet.Auto)] 
         static extern int SystemParametersInfo (int uAction , int uParam , string lpvParam , int fuWinIni) ; 
         
         public static void SetWallpaper(string thePath){ 
            SystemParametersInfo(20,0,thePath,3); 
         }
    }
 } 
'@

add-type $code 
[Win32.Wallpaper]::SetWallpaper($imgPath)
}
# Removing the LogonScript Scheduled Task so it won't run on next reboot
Unregister-ScheduledTask -TaskName "ArcServersLogonScript" -Confirm:$false

# Executing the deployment logs bundle PowerShell script in a new window
Invoke-Expression 'cmd /c start Powershell -Command { 
    $RandomString = -join ((48..57) + (97..122) | Get-Random -Count 6 | % {[char]$_})
    Write-Host "Sleeping for 5 seconds before creating deployment logs bundle..."
    Start-Sleep -Seconds 5
    Write-Host "`n"
    Write-Host "Creating deployment logs bundle"
    7z a $Env:ArcBoxLogsDir\LogsBundle-"$RandomString".zip $Env:ArcBoxLogsDir\*.log
}'
