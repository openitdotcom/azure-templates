Param(
    [string] $ServerURI = 'https://sample.server.com:443',
    [string] $StorageAccountName = 'clientinstaller',
    [string] $Container = 'openitclientinstaller',
    [string] $SasToken = '?sv=2019-12-12&ss=b&srt=sco&sp=rwdlacx&se=2021-07-15T03:04:12Z&st=2020-09-22T08:04:12Z&spr=https&sig=tMgvMG0kP42ClfH6RvaBpymV975XKDgWRcvSneRcFo4%3D',
    [string] $ApplicationSetupFile = 'openit_9_6_38_client_windows_x64.msi',
    [string] $ApplicationArguments = '/S',
    [string] $ApplicationVersion = '9.6.38'
)

if (Test-Path "$Env:Temp\openit_install.log") 
{
  Remove-Item "$Env:Temp\openit_install.log"
}

function Get-Program-Version {
    [CmdletBinding()]
    Param(
        
        [Parameter(Position = 0, Mandatory=$true, ValueFromPipeline = $true)]
        $Name
    )
    $app = Get-WmiObject -Class Win32_Product | where Name -eq "$Name"
    if ($app) {
        return $app.Version
    }
}


$currentVersion = Get-Program-Version "Open iT Client" 

if ($currentVersion -eq $ApplicationVersion) {
    & "$Env:Programfiles\OpeniT\Core\bin\openit_dcmlban.exe" -o "$Env:Programfiles\OpeniT\Core\Configuration\Components\apicontroller.xml" -y "apicontroller.uri" -v "$ServerURI" -a "set-value" -s
    Stop-Service -Name "openitclient"
    Start-Service -Name "openitclient"
    New-Item -Path  $Env:Temp -Name "openit_install.log" -ItemType "file" -Value "There's an existing Open iT Client with same version ($ApplicationVersion). Ignoring installation initiated by Solution Template. Changing the ServerURI with $ServerURI"
    exit
}

$ErrorActionPreference = 'Stop'

$powershellVersionMajor = $PSVersionTable.PSVersion.Major
$powershellVersionMinor = $PSVersionTable.PSVersion.Minor

if (($powershellVersionMajor -ge "6") -or ($powershellVersionMajor -ge "5" -and $powershellVersionMinor -ge "1")) {
    # Install the NuGet Package Provider, preventing that trusting the PSGallery with the Set-PSRepository cmdlet would hang on user input.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name NuGet -Scope CurrentUser -Force
        Write-Output 'Installed the NuGet Package Provider'
    }
    catch {
        Write-Error "Failed to install NuGet Package Provider. Exception: $($_.Exception.Message)"
    }

    # Trust the PSGallery Repository to install required modules, preventing that installing the AzureRM.Storage Module would hang on user input.
    if((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') {
        try {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
            Write-Output 'Trusted the PSGallery Repository'
        }
        catch {
            Write-Error "Failed to trust PSGallery Repository. Exception: $($_.Exception.Message)"
        }
    } else {
        Write-Output 'PSGallery repository is already trusted.'
    }

    # Install required AzureRM Storage module. Used to retrieve all installer files (Blobs) from a given Azure Blob Storage Container.
    if(-not (Get-Module -Name AzureRM.Storage -ListAvailable)) {
        try {
            Install-Module -Name AzureRM.Storage
            Write-Output 'Installed AzureRM.Storage Module'
        }
        catch {
            Write-Error "Failed to install required AzureRM.Storage module. Exception: $($_.Exception.Message)"
        }
    } else {
        Write-Output 'AzureRM.Storage Module is already present.'
    }

    Import-Module Azure.Storage

    # Create temp directory for storing the installation files in $Env:Temp
    if (!(Test-Path -Path "$Env:Temp\$Container")) { 
        Write-Output "Creating '$Env:Temp\$Container' directory"
        New-Item -ItemType Directory -Path "$Env:Temp\$Container"
    }

    # All files contained inside the given $Container will be downloaded from Azure Blob Storage (Requires SAS Token with Read + List access rights)
    try {
        Write-Output "Trying to download installer files ..."
        $AzureStorageContext = New-AzureStorageContext -StorageAccountName $StorageAccountName -SasToken $SasToken
        $Blobs = Get-AzureStorageBlob -Container $Container -Context $AzureStorageContext
        foreach ($Blob in $Blobs) {
            # Save file to $Env:Temp\$Container
            Start-BitsTransfer -Source ($($Blob.ICloudBlob.StorageUri.PrimaryUri.AbsoluteUri) + $SasToken) -Destination "$Env:Temp\$Container\$($Blob.Name)"     
        }
        Write-Output "Downloaded all installer files"
    }
    catch {
        Write-Error "Failed to download installation files from Azure Blob Storage. Exception: $($_.Exception.Message)"
    }

    # Install application using specified arguments passed with the installer file as configured in the configuration section
    # Waits for installation to finish before continuing
    try {
        
        Start-Process msiexec.exe -Wait -ArgumentList "/I $Env:Temp\$Container\$ApplicationSetupFile SERVERURI=$SERVERURI /l*v $Env:Temp\openit_install.log /quiet"
        Write-Output 'Application installation completed.'
    }
    catch {
        Write-Error "Failed to install application. Exception: $($_.Exception.Message)"
    }

    # Clean-up installation files
    Remove-Item "$Env:Temp\$Container" -Force -Recurse
}
else {
    try {
        Write-Output 'Powershell version is too low to handle Azure Blob Request.. downloading installer from a fallback site'
        Start-Process msiexec.exe -Wait -ArgumentList "/I https://privatebox.openit.com/67880d02f530b30df656b7f2226ed204/openit_9_6_38_client_windows_x64.msi SERVERURI=$SERVERURI /l*v $Env:Temp\openit_install.log /quiet"
        Write-Output 'Application installation completed.'
    }
    catch {
        Write-Error "Failed to install application. Exception: $($_.Exception.Message)"
    }
}
