Write-Host "Windows10-Autounattend"

$runOnceRegistryPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce"

# Set Windows Activation Key from UEFI
$licensingService = Get-WmiObject -Query "SELECT * FROM SoftwareLicensingService"
if ($key = $licensingService.OA3xOriginalProductKey) {
	Write-Host "Product Key: $licensingService.OA3xOriginalProductKey"
	$licensingService.InstallProductKey($key) | Out-Null
} else {
	Write-Host "Windows Activation Key not found."
}


# Change Power Plan
powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
powercfg -change standby-timeout-ac 0
powercfg -change disk-timeout-ac 0
powercfg -change monitor-timeout-ac 0
powercfg -change hibernate-timeout-ac 0

# Install Nuget PackageProvider
#if (-Not (Get-PackageProvider -Name NuGet)) {
    Write-Host "Install Nuget PackageProvider"
    Install-PackageProvider -Name NuGet -Confirm:$false -Force | Out-Null
#}

# Install PendingReboot Module
if (-Not (Get-Module -ListAvailable -Name PendingReboot)) {
    Write-Host "Install PendingReboot Module"
    Install-Module PendingReboot -Confirm:$false -Force | Out-Null
}

# Import PendingReboot Module
Import-Module PendingReboot

# Install WindowsUpdate Module
if (-Not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
    Write-Host "Install WindowsUpdate Module"
    Install-Module PSWindowsUpdate -Confirm:$false -Force | Out-Null
}

# Check is busy
while ((Get-WUInstallerStatus).IsBusy) {
    Write-Host "Windows Update installer is busy, wait..."
    Start-Sleep -s 10
}

# Install available Windows Updates
Write-Host "Start installation system updates..."
Write-Host "This job will be automatically canceled if it takes longer than 30 minutes to complete"
Set-ItemProperty $runOnceRegistryPath -Name "UnattendInstall!" -Value "cmd /c powershell -ExecutionPolicy ByPass -File $PSCommandPath" | Out-Null

$updateJobTimeoutSeconds = 1800

$code = {
    if ((Get-WindowsUpdate -Verbose).Count -gt 0) {
        try {
            $status = Get-WindowsUpdate -Install -AcceptAll -Confirm:$false
            if (($status | Where Result -eq "Installed").Length -gt 0)
            {
                Restart-Computer -Force
                return
            }
            
            if ((Test-PendingReboot).IsRebootPending) {
                Restart-Computer -Force
                return
            }
        } catch {
            Write-Host "Error:`r`n $_.Exception.Message"
            Restart-Computer -Force
        }
    }
}

$updateJob = Start-Job -ScriptBlock $code
if (Wait-Job $updateJob -Timeout $updateJobTimeoutSeconds) { 
    Receive-Job $updateJob
} else {
    Write-Host "Timeout exceeded"
    Receive-Job $updateJob
    Start-Sleep -s 10
}
Remove-Job -force $updateJob

# Install Chocolatey
if (-Not (Test-Path "$($env:ProgramData)\chocolatey\choco.exe")) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
}

# Required Chocolatey packages
$requiredPackages = @([pscustomobject]@{Name="7zip.install";Trust=$False},
                      [pscustomobject]@{Name="firefox";Trust=$False},
                      [pscustomobject]@{Name="googlechrome";Trust=$True},
                      [pscustomobject]@{Name="protonvpn";Trust=$True}
                      [pscustomobject]@{Name="discord.install";Trust=$True}
                      [pscustomobject]@{Name="greenshot";Trust=$True}
                      [pscustomobject]@{Name="qbittorrent";Trust=$True}
                      [pscustomobject]@{Name="signal";Trust=$True}
                      [pscustomobject]@{Name="spotify";Trust=$True}
                      [pscustomobject]@{Name="vlc";Trust=$True}
                      [pscustomobject]@{Name="vlc-skins";Trust=$True}
                      [pscustomobject]@{Name="vmwareworkstation";Trust=$True},
		      [pscustomobject]@{Name="microsoft-windows-terminal";Trust=$True},
		      [pscustomobject]@{Name="powertoys";Trust=$True})

# Load installed packages
$installedPackages = New-Object Collections.Generic.List[String]
$installedPackagesPath = Join-Path -Path $PSScriptRoot -ChildPath "installedPackages.txt"
if (Test-Path $installedPackagesPath -PathType Leaf) {
    $installedPackages.AddRange([string[]](Get-Content $installedPackagesPath))
}

# Calculate missing packages
$missingPackages = $requiredPackages | Where-Object { $installedPackages -NotContains $_.Name }

foreach ($package in $missingPackages) {
    if ((Test-PendingReboot).IsRebootPending) {
        Set-ItemProperty $runOnceRegistryPath -Name "UnattendInstall!" -Value "cmd /c powershell -ExecutionPolicy ByPass -File $PSCommandPath"
        Restart-Computer -Force
        return
    }

    if ($package.Trust) {
        Write-Host "Install Package without checksum check"
        choco install $package.Name -y --ignore-checksums
    } else {
        Write-Host "Install Package with checksum check"
        choco install $package.Name -y
    }

    # Add package to installed package list
    $installedPackages.Add($package.Name)

    # Save update to file
    $installedPackages | Out-File $installedPackagesPath
}

Remove-ItemProperty $runOnceRegistryPath -Name "UnattendInstall!"

$pathCustomizeScript = "C:\Temp\Unattended\customize.ps1"
if (Test-Path $pathCustomizeScript -PathType Leaf) {
    Write-Host "Found customize scirpt"
    & $pathCustomizeScript
}

Write-Host "Installation done"
Start-Sleep -s 60
