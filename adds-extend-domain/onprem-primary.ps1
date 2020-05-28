Configuration CreateForest {
    param
    (
        [Parameter(Mandatory)]
        [string]$DomainName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$AdminCreds,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$SafeModeAdminCreds,

        [Int]$RetryCount=20,
        [Int]$RetryIntervalSec=30
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

        DnsServerAddress SetDnsServerAddress
        {
            Address        = '127.0.0.1'
            InterfaceAlias = $InterfaceAlias
            AddressFamily  = 'IPv4'
            DependsOn = "[WindowsFeature]DNS"
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

        ADDomain CreateDomainPDC
        {
            DomainName = $DomainName
            Credential = $DomainCreds
            SafemodeAdministratorPassword = $SafeDomainCreds
            DatabasePath = "F:\Adds\NTDS"
            LogPath = "F:\Adds\NTDS"
            SysvolPath = "F:\Adds\SYSVOL"
            DependsOn = @("[WaitForDisk]Disk2", "[WindowsFeature]ADDSInstall", "[DnsServerAddress]SetDnsServerAddress")
        }

        PendingReboot RebootAfterPromotion
        { 
            Name = "RebootAfterPromotion"
            SkipWindowsUpdate           = $true
            SkipComponentBasedServicing = $false
            SkipPendingFileRename       = $false
            SkipPendingComputerRename   = $false
            SkipCcmClientSDK            = $false
            DependsOn = "[ADDomain]CreateDomainPDC"
        }
   }
}