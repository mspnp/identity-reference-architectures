Configuration CreateDomainController {
    param
    (
        [Parameter(Mandatory)]
        [string]$DomainName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$AdminCreds,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$SafeModeAdminCreds,

        [Parameter(Mandatory)]
        [string]$PrimaryDcIpAddress,

        [Int]$RetryCount=20,
        [Int]$RetryIntervalSec=60
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Import-DscResource -ModuleName ActiveDirectoryDsc
    Import-DscResource -ModuleName ComputerManagementDsc
    Import-DscResource -ModuleName NetworkingDsc
    Import-DscResource -ModuleName StorageDsc

    [System.Management.Automation.PSCredential ]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($AdminCreds.UserName)", $AdminCreds.Password)
    [System.Management.Automation.PSCredential ]$SafeDomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($SafeModeAdminCreds.UserName)", $SafeModeAdminCreds.Password)

    $Interface = Get-NetAdapter|Where-Object Name -Like "Ethernet*"|Select-Object -First 1
    $InterfaceAlias = $($Interface.Name)
    
    Node localhost
    {
        LocalConfigurationManager
        {
            ConfigurationMode = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        # Allow this machine to find the PDC and its DNS server
        [ScriptBlock]$SetScript =
        {
            Set-DnsClientServerAddress -InterfaceAlias ("$InterfaceAlias") -ServerAddresses ("$PrimaryDcIpAddress")
        }
        Script SetDnsServerAddressToFindPDC
        {
            GetScript = {return @{}}
            TestScript = {return $false} # Always run the SetScript for this.
            SetScript = $SetScript.ToString().Replace('$PrimaryDcIpAddress', $PrimaryDcIpAddress).Replace('$InterfaceAlias', $InterfaceAlias)
        }
        
        WaitforDisk Disk2
        {
            DiskId = 2
            RetryIntervalSec = $RetryIntervalSec
            RetryCount = $RetryCount
        }
        
        Disk FVolume
        {
            DiskId = 2
            DriveLetter = 'F'
            FSLabel = 'Data'
            FSFormat = 'NTFS'
            DependsOn = '[WaitForDisk]Disk2'
        }        

        WindowsFeature DNS 
        { 
            Ensure = "Present" 
            Name = "DNS"
            IncludeAllSubFeature = $true
        }

        WindowsFeature ADDSInstall 
        { 
            Ensure = "Present" 
            Name = "AD-Domain-Services"
            IncludeAllSubFeature = $true
            DependsOn = "[WindowsFeature]DNS"
        }

        WindowsFeature RSAT
        {
             Ensure = "Present"
             Name = "RSAT"
             DependsOn = "[WindowsFeature]ADDSInstall"
        }

        WaitForADDomain DomainWait
        {
            DomainName = $DomainName
            Credential = $DomainCreds
            WaitForValidCredentials = $true
            DependsOn = "[Script]SetDnsServerAddressToFindPDC"
        }

        ADDomainController SecondaryDC
        {
            DomainName = $DomainName
            Credential = $DomainCreds
            SafemodeAdministratorPassword = $SafeDomainCreds
            DatabasePath = "F:\Adds\NTDS"
            LogPath = "F:\Adds\NTDS"
            SysvolPath = "F:\Adds\SYSVOL"
            DependsOn = @("[WaitForDisk]Disk2","[WindowsFeature]ADDSInstall","[WaitForADDomain]DomainWait")
        }

        PendingReboot RebootAfterSecondaryDC
        { 
            Name = "RebootServer"
            SkipWindowsUpdate           = $true
            SkipComponentBasedServicing = $false
            SkipPendingFileRename       = $false
            SkipPendingComputerRename   = $false
            SkipCcmClientSDK            = $false
            DependsOn = "[ADDomainController]SecondaryDC"
        }

        # Now make sure this computer uses itself as a DNS source
        DnsServerAddress SetDnsServerAddress
        {
            Address        = @('127.0.0.1', $PrimaryDcIpAddress)
            InterfaceAlias = $InterfaceAlias
            AddressFamily  = 'IPv4'
            DependsOn = "[PendingReboot]RebootAfterSecondaryDC"
        }
   }
}