
param(
    [string]
    [Parameter(Mandatory=$true)]
    $VirtualMachineName,

    [string]
    [Parameter(Mandatory=$true)]
    $RootDiskPath,

    [int]
    [Parameter(Mandatory=$true)]
    $VirtualDiskSize,

    [string]
    [Parameter(Mandatory=$true)]
    $CloudInitDirectory,

    [int]
    [Parameter(Mandatory=$true)]
    $MemorySize,

    [string]
    $OSCDImagePath = "",

    [switch]
    $DontStart,

    [int]
    $ProcessorCount = 1,

    [string]
    $VirtualSwitchName = "Default Switch",

    [string]
    $VirtualDiskPath = "",

    [bool]
    $EnableSecureBoot = $true
)

$gig=1024 * 1024 * 1024

#S-1-5-32-544 is the well known sid for administrators,
#S-1-5-32-578 is the well known sid for hyper-v administrators
if ((-not (([System.Security.Principal.WindowsIdentity]::GetCurrent()).groups -match "S-1-5-32-544")) `
    -and (-not (([System.Security.Principal.WindowsIdentity]::GetCurrent()).groups -match "S-1-5-32-578"))) {
    Write-Error "This script must be ran as an administrator"
}

# Figure out oscdpath
if ("$OSCDImagePath" -eq "") {
    if (Get-Command "oscdimg" -ErrorAction SilentlyContinue) {
        $OSCDImagePath = "oscdimg"
    }
    else {
        $adkpath="C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
        if (Get-Command $adkpath -ErrorAction SilentlyContinue) {
            $OSCDImagePath = $adkpath
        }
        else {
            Write-Error "oscdimg.exe not found, aborting"
            exit 1
        }
    }
}

if (-not (Get-Command $OSCDImagePath -ErrorAction SilentlyContinue)) {
    Write-Error "oscdimg.exe not found, aborting"
    exit 1
}

if (-not (Test-Path $RootDiskPath)) {
    Write-Error "RootDiskPath '$RootDiskPath' does not exist."
    exit 1
}

if ($VirtualDiskSize -le 0) {
    Write-Error "VirtualDiskSize must be greater than 0"
    exit 1
}

if ("$VirtualDiskPath" -eq "") {
    $VirtualDiskPath = "$((get-vmhost -ComputerName $env:COMPUTERNAME).VirtualHardDiskPath)"
}

if ($MemorySize -le 0) {
    Write-Error "MemorySize must be greater than 0"
    exit 1
}

if ($ProcessorCount -le 0) {
    Write-Error "ProcessorCount must be greater than 0"
    exit 1
}

$rootvhdx = Get-VHD -Path $RootDiskPath
if (-not $?) {
    Write-Error "$RootDiskPath is not a valid VHDX"
    exit 1
}

if ($rootvhdx.MinimumSize -gt $VirtualDiskSize * $gig) {
    Write-Error "Requested disk size is smaller than the minimum size"
    exit 1
}

if (-not (Test-Path $CloudInitDirectory)) {
    Write-Error "Cloud init directory '$CloudInitDirectory' does not exist"
    exit 1
}

$switch = Get-VMSwitch -Name $VirtualSwitchName -ErrorAction SilentlyContinue
if ($null -eq $switch) {
    Write-Error "Invalid virtual switch name"
    exit 1
}

$vm = Get-VM -Name $VirtualMachineName -ErrorAction SilentlyContinue
if ($null -ne $vm) {
    Write-Error "Virtual machine '$VirtualMachineName' already exists"
    exit 1
}

Write-Debug "OSCDImagePath      = $OSCDImagePath"
Write-Debug "VirtualMachineName = $VirtualMachineName"
Write-Debug "VirtualDiskPath    = $VirtualDiskPath"
Write-Debug "RootDiskPath       = $RootDiskPath"
Write-Debug "VirtualDiskSize    = $VirtualDiskSize"
Write-Debug "CloudInitDirectory = $CloudInitDirectory"
Write-Debug "VirtualSwitchName  = $VirtualSwitchName"
$VirtualDiskPath="$VirtualDiskPath\$VirtualMachineName"
Write-Debug "VirtualDiskPrefix  = $VirtualDiskPath"

$state = 0
function Revert {
    #do the steps in reverse order, remove the vm, then the cidata iso, then the vhdx
    if ($state -gt 2) {
        Remove-VM -Name $VirtualMachineName
    }
    if ($state -gt 1) {
        if (Test-Path $VirtualDiskPath-cidata.iso) {
            Remove-Item $VirtualDiskPath-cidata.iso
        }
        else {
            Write-Information "$VirtualDiskPath-cidata.iso already removed"
        }
    }
    if ($state -gt 0) {
        if (Test-Path "$VirtualDiskPath.vhdx") {
            Remove-Item "$VirtualDiskPath.vhdx"
        }
        else {
            Write-Information "$VirtualDiskPath.vhdx already removed"
        }
    }
}

Write-Host -ForegroundColor Green "Copying root disk from $RootDiskPath to $VirtualDiskPath.vhdx"
Copy-Item $RootDiskPath "$VirtualDiskPath.vhdx"
if (-not $?) {
    Write-Error "Unable to copy the root vhdx"
    exit 1
}
$state = 1

Write-Host -ForegroundColor Green "Resizing virtual disk to $VirtualDiskSize gigabytes"
Resize-VHD -Path "$VirtualDiskPath.vhdx" -SizeBytes ($VirtualDiskSize * $gig)
if (-not $?) {
    Write-Error "Unable to resize disk"
    Revert
    exit 1
}

Write-Host -ForegroundColor Green "Creating cloud init iso at $VirtualDiskPath-cidata.iso"
$state = 2
& $OSCDImagePath -j2 -lcidata "$CloudInitDirectory" "$VirtualDiskPath-cidata.iso"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Unable to create cloud init disk"
    Revert
    exit 1
}

$state = 3
Write-Host -ForegroundColor Green "Creating virtual machine $VirtualMachine"
$vm = New-VM -Name $VirtualMachineName `
    -MemoryStartupBytes ($MemorySize*$gig) `
    -Generation 2 `
    -VHDPath "$VirtualDiskPath.vhdx" `
    -SwitchName $VirtualSwitchName
if (-not $?) {
    Write-Error "Unable to create virtual machine"
    Revert
    exit 1
}

Write-Host -ForegroundColor Green "Disabling dynamic memory"
$vm | Set-VMMemory -DynamicMemoryEnabled $false
if (-not $?) {
    Write-Error "Unable to disable dynamic memory"
    Revert
    exit 1
}

if (-not $?) {
    Write-Information "Setting CPU Count"
    $vm | Set-VMProcessor -Count $ProcessorCount
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Unable to disable dynamic memory"
        Revert
        exit 1
    }
}

Write-Host -ForegroundColor Green "Setting secure boot settings"
if ($EnableSecureBoot) {
    $vm | Set-VMFirmware -EnableSecureBoot On -SecureBootTemplate "MicrosoftUEFICertificateAuthority"
    if (-not $?){
        Write-Error "Unable to set secure boot to MicrosoftUEFICertificateAuthority"
        Revert
        exit 1
    }
}
else {
    $vm | Set-VMFirmware -EnableSecureBoot Off
    if (-not $?) {
        Write-Error "Unable to disable secure boot"
        Revert
        exit 1
    }
}

Write-Host -ForegroundColor Green "Adding cidata iso to the virtual machine"
$vm | Add-VMDvdDrive -Path "$VirtualDiskPath-cidata.iso"

if (-not $?){
    Write-Error "Unable to attach cidata iso image"
    Revert
    exit 1
}

if ($DontStart) {
    Write-Warning "Not starting the virtual machine"
}
else {
    Write-Host -ForegroundColor Green "Starting virtual machine"
    $vm | Start-VM
}

Write-Host -ForegroundColor Green "Virtual machine creation complete"