#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Installs and configures Windows Deployment Services with OSDCloud WinPE boot images.

.DESCRIPTION
    Installs the WDS role, configures it as standalone or domain-joined, downloads and
    installs the Windows ADK and WinPE add-on, installs the OSD PowerShell module, then
    builds an OSDCloud template and workspace per requested Windows language and imports
    the resulting WinPE boot image into WDS. The WDS and OSDCloud portions can each be
    included or excluded independently via the Configure parameter. All actions are
    written to a log file via Write-Log instead of a transcript.

.PARAMETER Configure
    Which parts of the script to run. Both (default) installs and configures WDS and
    builds/imports the OSDCloud boot images. WDS only installs and configures the WDS
    role without touching ADK or OSDCloud. OSDCloud only builds the OSDCloud template,
    workspace and boot image without touching WDS, and skips the WDS boot image import.

.PARAMETER WindowsVersion
    Windows 11 feature update version, e.g. 25H2.

.PARAMETER WindowsLanguage
    One or more language tags to build boot images for, e.g. da-dk, en-us.

.PARAMETER WindowsEdition
    Windows edition to deploy. Default is Pro.

.PARAMETER OSDCloudDir
    Root directory for OSDCloud templates and workspaces. Default is C:\OSDCloud.

.PARAMETER OSDCloudDriver
    Driver pack to inject into the WinPE boot image. Use None for no drivers, or one of
    Dell, HP, IntelNet, LenovoDock, Nutanix, USB, VMware, WiFi, or * for all.

.PARAMETER WDSMode
    WDS configuration mode. StandAlone (default) configures WDS without Active Directory.
    Domain configures WDS joined to an Active Directory domain.

.PARAMETER WDSAnswerClients
    WDS PXE response setting. All, Known, or None. Default is None to avoid unattended PXE boots.

.PARAMETER LogPath
    Path to the log file written by Write-Log. Default is C:\Temp\Install-WDS-OSDCloud.log.

.EXAMPLE
    .\Install-WDS-OSDCloud.ps1 -WindowsVersion 25H2 -WindowsLanguage da-dk,en-us

    Runs with the default StandAlone WDS mode.

.EXAMPLE
    .\Install-WDS-OSDCloud.ps1 -Configure WDS -WDSMode Domain

    Installs and configures WDS only, joined to an Active Directory domain, skipping ADK and OSDCloud.

.EXAMPLE
    .\Install-WDS-OSDCloud.ps1 -Configure OSDCloud -WindowsLanguage en-us

    Builds the OSDCloud template, workspace and boot image only, without touching WDS
    and without importing the boot image into WDS.

.NOTES
    Kasper Johansen | kasperjohansen.net
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter()]
    [ValidateSet("Both", "WDS", "OSDCloud")]
    [string]$Configure = "Both",

    [Parameter()]
    [string]$WindowsVersion = "25H2",

    [Parameter()]
    [string[]]$WindowsLanguage = @("da-dk", "en-us"),

    [Parameter()]
    [ValidateSet("Home", "Pro", "Enterprise", "Education")]
    [string]$WindowsEdition = "Pro",

    [Parameter()]
    [string]$OSDCloudDir = "C:\OSDCloud",

    [Parameter()]
    [ValidateSet("None", "Dell", "HP", "IntelNet", "LenovoDock", "Nutanix", "USB", "VMware", "WiFi", "*")]
    [string]$OSDCloudDriver = "None",

    [Parameter()]
    [ValidateSet("StandAlone", "Domain")]
    [string]$WDSMode = "StandAlone",

    [Parameter()]
    [ValidateSet("All", "Known", "None")]
    [string]$WDSAnswerClients = "None",

    [Parameter()]
    [string]$LogPath = "C:\Temp\Install-WDS-OSDCloud.log"
)

$ErrorActionPreference = "Stop"

$ADKSourceURL = "https://go.microsoft.com/fwlink/?linkid=2289980"
$WinPESourceURL = "https://go.microsoft.com/fwlink/?linkid=2289981"
$ADKInstaller = "C:\Temp\adksetup.exe"
$WinPEInstaller = "C:\Temp\adkwinpesetup.exe"

function Write-Log {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("Info", "Warning", "Error", "Success")]
        [string]$Level = "Info"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        "Info"    { Write-Host $line -ForegroundColor Cyan }
        "Warning" { Write-Host $line -ForegroundColor Yellow }
        "Error"   { Write-Host $line -ForegroundColor Red }
        "Success" { Write-Host $line -ForegroundColor Green }
    }

    try {
        Add-Content -Path $LogPath -Value $line
    }
    catch {
        Write-Host "[$timestamp] [Warning] Failed to write to log file $($LogPath): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Install-WDSRole {
    [CmdletBinding()]
    param ()

    try {
        Write-Log -Message "Installing Windows Deployment Services role"
        $result = Install-WindowsFeature -Name WDS -IncludeAllSubFeature
        if (-not $result.Success) {
            throw "Windows Deployment Services feature installation reported failure. Exit code: $($result.ExitCode)"
        }
    }
    catch {
        throw "Failed to install WDS role: $($_.Exception.Message)"
    }
}

function Set-WDSConfiguration {
    [CmdletBinding()]
    param (
        [ValidateSet("StandAlone", "Domain")]
        [string]$Mode,
        [string]$AnswerClients
    )

    try {
        if ($Mode -eq "StandAlone") {
            Write-Log -Message "Configuring Windows Deployment Services in stand alone mode"
            $arguments = '/initialize-Server /reminst:"C:\RemoteInstall" /Standalone'
        }
        else {
            Write-Log -Message "Configuring Windows Deployment Services in Active Directory domain mode"
            $arguments = '/initialize-Server /reminst:"C:\RemoteInstall"'
        }

        $init = Start-Process -Wait -PassThru -FilePath "C:\Windows\System32\wdsutil.exe" -ArgumentList $arguments
        if ($init.ExitCode -ne 0) {
            throw "wdsutil.exe initialize-Server returned exit code $($init.ExitCode)"
        }

        Write-Log -Message "Configuring Windows Deployment Services PXE response to $AnswerClients"
        $answer = Start-Process -Wait -PassThru -FilePath "C:\Windows\System32\wdsutil.exe" -ArgumentList "/set-server /AnswerClients:$AnswerClients"
        if ($answer.ExitCode -ne 0) {
            throw "wdsutil.exe set-server returned exit code $($answer.ExitCode)"
        }
    }
    catch {
        throw "Failed to configure WDS: $($_.Exception.Message)"
    }
}

function Install-ADKComponents {
    [CmdletBinding()]
    param (
        [string]$AdkUrl,
        [string]$WinPEUrl,
        [string]$AdkPath,
        [string]$WinPEPath
    )

    try {
        Write-Log -Message "Downloading Windows ADK and Windows ADK WinPE"
        Start-BitsTransfer -Source $AdkUrl -Destination $AdkPath -TransferType Download
        Start-BitsTransfer -Source $WinPEUrl -Destination $WinPEPath -TransferType Download

        Write-Log -Message "Installing Windows ADK Deployment Tools"
        $adkInstall = Start-Process -Wait -PassThru -FilePath $AdkPath -ArgumentList "/quiet /features OptionId.DeploymentTools"
        if ($adkInstall.ExitCode -ne 0) {
            throw "ADK setup returned exit code $($adkInstall.ExitCode)"
        }

        Write-Log -Message "Installing Windows ADK WinPE Environment"
        $winPEInstall = Start-Process -Wait -PassThru -FilePath $WinPEPath -ArgumentList "/quiet /features OptionId.WindowsPreinstallationEnvironment /norestart"
        if ($winPEInstall.ExitCode -ne 0) {
            throw "ADK WinPE setup returned exit code $($winPEInstall.ExitCode)"
        }
    }
    catch {
        throw "Failed to install ADK components: $($_.Exception.Message)"
    }
}

function Install-OSDCloudModule {
    [CmdletBinding()]
    param ()

    try {
        Write-Log -Message "Installing NuGet Package Provider"
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null

        Write-Log -Message "Installing OSDCloud PowerShell module"
        Install-Module -Name OSD -Force
        Import-Module -Name OSD -Force
    }
    catch {
        throw "Failed to install or import the OSD module: $($_.Exception.Message)"
    }
}

function New-OSDCloudDeployment {
    [CmdletBinding()]
    param (
        [string]$Language,
        [string]$Version,
        [string]$Edition,
        [string]$RootDir,
        [string]$Driver,
        [bool]$ImportToWds
    )

    try {
        $buildDir = "W11-$Version-$Language"
        $workspaceDir = Join-Path -Path $RootDir -ChildPath $buildDir
        $osName = "Windows 11 $Version x64"

        Write-Log -Message "Checking for existing OSDCloud template"
        $existingTemplate = Get-OSDCloudTemplate -ErrorAction SilentlyContinue
        if ($existingTemplate) {
            Write-Log -Message "OSDCloud template already exists" -Level Warning
        }
        else {
            Write-Log -Message "Creating OSDCloud template for $Language"
            New-OSDCloudTemplate -Language $Language -SetInputLocale $Language
        }

        if (!(Test-Path -Path $RootDir)) {
            New-Item -Path $RootDir -ItemType Directory | Out-Null
        }

        if (!(Test-Path -Path $workspaceDir)) {
            New-Item -Path $workspaceDir -ItemType Directory | Out-Null
        }

        Write-Log -Message "Creating OSDCloud workspace at $workspaceDir"
        New-OSDCloudWorkspace -WorkspacePath $workspaceDir
        Set-OSDCloudWorkspace -WorkspacePath $workspaceDir

        Write-Log -Message "Building OSDCloud WinPE boot image for $Language"
        $startOSDCloud = "-OSName '$osName' -OSLanguage `"$Language`" -OSEdition $Edition -OSActivation Retail -Zti -Restart"
        if ($Driver -eq "None") {
            Edit-OSDCloudWinPE -StartOSDCloud $startOSDCloud
        }
        else {
            Edit-OSDCloudWinPE -StartOSDCloud $startOSDCloud -CloudDriver $Driver
        }

        $bootImagePath = Join-Path -Path $workspaceDir -ChildPath "Media\Sources\boot.wim"
        if (!(Test-Path -Path $bootImagePath)) {
            throw "Boot image not found at $bootImagePath"
        }

        if ($ImportToWds) {
            Write-Log -Message "Importing OSDCloud WinPE boot image to Windows Deployment Services"
            $imageName = "Windows 11 - $Version - $Language"
            Import-WdsBootImage -NewImageName $imageName -NewDescription $imageName -Path $bootImagePath | Out-Null
        }
        else {
            Write-Log -Message "Skipping WDS import for $Language boot image (Configure = OSDCloud)" -Level Warning
        }
    }
    catch {
        throw "Failed to build or import OSDCloud deployment for $($Language): $($_.Exception.Message)"
    }
}

# Main

if (!(Test-Path -Path "C:\Temp")) {
    New-Item -Path "C:\Temp" -ItemType Directory | Out-Null
}

try {
    $includeWDS = $Configure -in @("Both", "WDS")
    $includeOSDCloud = $Configure -in @("Both", "OSDCloud")

    if ($includeWDS) {
        Install-WDSRole
        Set-WDSConfiguration -Mode $WDSMode -AnswerClients $WDSAnswerClients
    }
    else {
        Write-Log -Message "Skipping WDS role installation and configuration (Configure = $Configure)" -Level Warning
    }

    if ($includeOSDCloud) {
        Install-ADKComponents -AdkUrl $ADKSourceURL -WinPEUrl $WinPESourceURL -AdkPath $ADKInstaller -WinPEPath $WinPEInstaller
        Install-OSDCloudModule

        foreach ($language in $WindowsLanguage) {
            New-OSDCloudDeployment -Language $language -Version $WindowsVersion -Edition $WindowsEdition -RootDir $OSDCloudDir -Driver $OSDCloudDriver -ImportToWds $includeWDS
        }
    }
    else {
        Write-Log -Message "Skipping ADK and OSDCloud configuration (Configure = $Configure)" -Level Warning
    }

    Write-Log -Message "Deployment completed successfully (Configure = $Configure)" -Level Success
}
catch {
    Write-Log -Message "Deployment failed: $($_.Exception.Message)" -Level Error
    throw
}