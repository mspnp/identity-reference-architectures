Configuration Config {
    param
    (
        [Parameter(Mandatory)]
        [string]$DomainName,

        [Parameter(Mandatory)]
        [string]$PrimaryDcIpAddress,
        
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$AdminCreds
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Import-DscResource -ModuleName ActiveDirectoryDsc
    Import-DscResource -ModuleName ComputerManagementDsc
    Import-DscResource -ModuleName NetworkingDsc
       
    [System.Management.Automation.PSCredential ]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($AdminCreds.UserName)", $AdminCreds.Password)

    $Interface = Get-NetAdapter|Where-Object Name -Like "Ethernet*"|Select-Object -First 1
    $InterfaceAlias = $($Interface.Name)

    Node localhost
    {
        LocalConfigurationManager
        {
            ConfigurationMode = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        # Allows this machine to find the PDC and its DNS server
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

        Computer JoinDomain
        {
            DomainName = $DomainName
            Credential = $DomainCreds
            Name = $env:COMPUTERNAME
            DependsOn   = @("[Script]SetDnsServerAddressToFindPDC")
        }

        # Now make sure this computer uses itself as a DNS source
        DnsServerAddress DnsServerAddress1
        {
            Address        = @('127.0.0.1', $PrimaryDcIpAddress)
            InterfaceAlias = $InterfaceAlias
            AddressFamily  = 'IPv4'
            DependsOn   = "[Computer]JoinDomain"
        }

        #Install the IIS Role
        WindowsFeature IIS
        {
            Ensure = "Present"
            Name = "Web-Server"
        }

        #Install ASP.NET 4.5
        WindowsFeature ASP
        {
            Ensure = "Present"
            Name = "Web-Asp-Net45"
        }

        WindowsFeature WebServerManagementConsole
        {
            Name = "Web-Mgmt-Console"
            Ensure = "Present"
        }
   }
}