# OSDCloud specific variables
[string]$WindowsVersion = "25H2"
[string]$WindowsLanguage = "da-dk","en-us"
[string]$WindowsEdition = "Pro"
[string]$OSDCloudDir = "C:\OSDCloud"
[string]$OSDCloudDriver = "None" #Dell,HP,IntelNet,LenovoDock,Nutanix,USB,VMware,WiFi or * for all drivers - None = no drivers

# WDS specific variables
$WDSStandAlone = "true" # true or false
$WDSAnswerClients = "All" # All, known or None
clear
# Create transscript folder - C:\temp
If (!(Test-Path -Path "C:\Temp"))
{
    New-Item -Path "C:\temp" -ItemType Directory | Out-Null
}

# Start transscript
Start-Transcript -Path "C:\temp\Install-WDS-OSDCloud.log" | Out-Null

# Install the Windows Deployment Services role
Write-Host "Installing Windows Deployment Services role" -ForegroundColor Cyan
Install-WindowsFeature -Name WDS -IncludeAllSubFeature | Out-Null
If ($WDSStandAlone -eq "true")
{
    Write-Host "Configuring Windows Deployment Services in stand alone mode" -ForegroundColor Cyan
    Start-Process -Wait "C:\Windows\System32\wdsutil.exe" -ArgumentList  "/initialize-Server /reminst:`"C:\RemoteInstall`" /Standalone" 
}

If ($WDSStandAlone -eq "false")
{
    Write-Host "Configuring Windows Deployment Services in Active Directory domain mode" -ForegroundColor Cyan
    Start-Process -Wait "C:\Windows\System32\wdsutil.exe" -ArgumentList  "/initialize-Server /reminst:`"C:\RemoteInstall`""
}

Write-Host "Configuring Windows Deployment Services PXE response to None" -ForegroundColor Cyan
Start-Process -Wait "C:\Windows\System32\wdsutil.exe" -ArgumentList "/set-server /AnswerClients:$WDSAnswerClients"

# Download Windows ADK and WinPE
Write-Host "Downloading Windows ADK and Windows ADK WinPE" -ForegroundColor Cyan
$ADKSourceURL = "https://go.microsoft.com/fwlink/?linkid=2289980"
$WinPESourceURL = "https://go.microsoft.com/fwlink/?linkid=2289981"
If (!(Test-Path -Path "C:\temp"))
{
    New-Item -Path "C:\temp" -ItemType Directory
}
Start-BitsTransfer -Source $ADKSourceURL -Destination "C:\temp\adksetup.exe" -TransferType Download
Start-BitsTransfer -Source $WinPESourceURL -Destination "C:\temp\adkwinpesetup.exe" -TransferType Download

Write-Host "Installing Windows ADK Deployment Tools" -ForegroundColor Cyan
Start-Process -FilePath "C:\temp\adksetup.exe" -ArgumentList "/quiet /features OptionId.DeploymentTools" -Wait

Write-Host "Installing Windows ADK WinPE Environment" -ForegroundColor Cyan
Start-Process -FilePath  "C:\temp\adkwinpesetup.exe" -ArgumentList "/quiet /features OptionId.WindowsPreinstallationEnvironment /norestart" -Wait

Write-Host "Installing NuGet Package Provider" -ForegroundColor Cyan
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
Write-Host "Installing OSDCloud Powershell module" -ForegroundColor Cyan
Install-Module OSD -Force | Out-Null
Import-Module OSD | Out-Null

# Create OSDCloud Template and OSDCloud Workspace
ForEach ($language in $WindowsLanguage)
{
$BuildDir = $("W11-$WindowsVersion-$Language")
$WorkspaceDir = $($OSDCloudDir+"\"+$BuildDir)
$OSName = $("Windows 11 $WindowsVersion x64")
$OSLanguage = $Language

Write-Host "Create OSDCloud template" -ForegroundColor Cyan
$GetExistingTemplate = Get-OSDCloudTemplate -ErrorAction SilentlyContinue
If ($GetExistingTemplate)
{
    Write-Host "OSDCloud template already exist" -ForegroundColor Yellow  
}
    else
    {
        New-OSDCloudTemplate -Language $Language -SetInputLocale $Language
    }

# Create OSDCloud folder if it does not exist
If (!(Test-Path -Path $OSDCloudDir))
{
    New-Item -Path $OSDCloudDir -ItemType Directory
}

If (!(Test-Path -Path $WorkspaceDir))
{
    New-Item -Path $WorkspaceDir -ItemType Directory
}

Write-Host "Create OSDCloud workspace" -ForegroundColor Cyan
New-OSDCloudWorkspace -WorkspacePath "$WorkspaceDir"
Set-OSDCloudWorkspace -WorkspacePath "$WorkspaceDir"

Write-Host "Create OSDCloud WinPE boot image" -ForegroundColor Cyan
If ($OSDCloudDriver -eq "None")
{
    Edit-OSDCloudWinPE -StartOSDCloud "-OSName `'$($OSName)`' -OSLanguage `"$OSLanguage`" -OSEdition Pro -OSActivation Retail -Zti -Restart"
}
    else
    {
        Edit-OSDCloudWinPE -StartOSDCloud "-OSName `'$($OSName)`' -OSLanguage `"$OSLanguage`" -OSEdition Pro -OSActivation Retail -Zti -Restart" -CloudDriver "$OSDCloudDriver"
    }

# Import OSDCloud WinPE boot image to WDS
Write-Host "Importing OSDCloud WinPE boot image to Windows Deployment Services" -ForegroundColor Cyan
Import-WdsBootImage -NewImageName "Windows 11 - $WindowsVersion - $WindowsLanguage" -NewDescription "Windows 11 - $WindowsVersion - $WindowsLanguage" -Path "$WorkspaceDir\Media\Sources\boot.wim" | Out-Null
}
# Stop transscript
Stop-Transcript