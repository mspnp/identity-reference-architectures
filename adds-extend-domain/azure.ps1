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

        [Parameter(Mandatory)]
        [string]$SiteName,
        
        [Int]$RetryCount=60,
        [Int]$RetryIntervalSec=60
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Import-DscResource -ModuleName ActiveDirectoryDsc
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

        WaitforDisk Disk2
        {
            DiskId =  2
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
            DependsOn = "[WindowsFeature]DNS"
        }

        WindowsFeature RSAT
        {
             Ensure = "Present"
             Name = "RSAT"
        }

        WindowsFeature ADDSInstall 
        { 
            Ensure = "Present" 
            Name = "AD-Domain-Services"
            IncludeAllSubFeature = $true
        }

        WaitForADDomain WaitForPrimaryDC
        {
            DomainName  = $DomainName
            Credential  = $DomainCreds
            RestartCount = 2
            WaitForValidCredentials = $true
            DependsOn = @("[Script]SetDnsServerAddressToFindPDC")
        }

        ADDomainController SecondaryDC
        {
            DomainName = $DomainName
            Credential = $DomainCreds
            SafemodeAdministratorPassword = $SafeDomainCreds
            SiteName = $SiteName
            DatabasePath = "F:\Adds\NTDS"
            LogPath = "F:\Adds\NTDS"
            SysvolPath = "F:\Adds\SYSVOL"
            DependsOn = "[WaitForADDomain]WaitForPrimaryDC","[WaitForDisk]Disk2","[WindowsFeature]ADDSInstall"
        }

        # Now make sure this computer uses itself as a DNS source
        DnsServerAddress DnsServerAddress1
        {
            Address        = @('127.0.0.1', $PrimaryDcIpAddress)
            InterfaceAlias = $InterfaceAlias
            AddressFamily  = 'IPv4'
            DependsOn = "[ADDomainController]SecondaryDC"
        }

        PendingReboot Reboot1
        { 
            Name = "RebootServer"
            SkipWindowsUpdate           = $true
            SkipComponentBasedServicing = $false
            SkipPendingFileRename       = $false
            SkipPendingComputerRename   = $false
            SkipCcmClientSDK            = $false
            DependsOn = "[DnsServerAddress]DnsServerAddress1"
        }

   }
}