[CmdletBinding()]
param (
    # [Parameter(Mandatory=$true)]
    [string]
    $Source = "livecd.ubuntu-cpc.azure.vhd",

    # [Parameter(Mandatory=$true)]
    [string]
    $Destination = "testsource.vhdx",

    [switch]
    $OverwriteDestination
)

if (-not (Test-Path $Source)) {
    Write-Error "Source '$Source' does not exist"
    exit 1
}

if (-not (([System.Security.Principal.WindowsIdentity]::GetCurrent()).groups -match "S-1-5-32-544")) {
    Write-Error "This script must be ran as an administrator"
}

if (Test-Path $Destination) {
    if ($OverwriteDestination) {
        Remove-Item $Destination
        if (-not $?) {
            Write-Error "Unable to remove destination disk"
            exit 1
        }
    }
    else {
        Write-Error "Destination already exists"
        exit 1
    }
}

Write-Host "Converting image to a dynamic disk" -ForegroundColor Green
Convert-VHD -Path $Source -DestinationPath $Destination -VHDType Dynamic
if (-not $?) {
    Write-Host "Unable to convert image to a dynamic disk"
    exit 1
}

$FullDestinationPath = (Get-Item $Destination).FullName
if (-not $?)
{
    Write-Host "Unable to get destination disk"
    exit 1
}

Write-Host "Mounting in WSL" -ForegroundColor Green
$id=[System.Guid]::NewGuid().ToString()
wsl --mount --vhd "$FullDestinationPath" -p 1 --name "$id"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Error mounting the $FullDestinationPath disk in WSL, WSL supporting --mount --vhd must be used."
    Write-Error "This is generally only found by using the WSL application from the Microsoft Store."
    exit 1
}

Write-Host "Modifying the cloud-init data source" -ForegroundColor Green
wsl -u root echo "datasource_list: [ NoCloud ]" `> /mnt/wsl/$id/etc/cloud/cloud.cfg.d/90_dpkg.cfg
if ($LASTEXITCODE -ne 0) {
    Write-Error "Unable to set /mnt/wsl/$id/etc/cloud/cloud.cfg.d/90_dpkg.cfg"
    wsl --unmount \\?\$FullDestinationPath
    exit 1
}

Write-Host "Removing the azure specific configuration" -ForegroundColor Green
wsl -u root rm /mnt/wsl/$id/etc/cloud/cloud.cfg.d/90-azure.cfg
if ($LASTEXITCODE -ne 0) {
    Write-Error "Unable to remove /mnt/wsl/$id/etc/cloud/cloud.cfg.d/90_azure.cfg"
    wsl --unmount \\?\$FullDestinationPath
    exit 1
}

Write-Host "Tarring up old resolv.conf" -ForegroundColor Green
$hasresolv = $true
wsl -u root cd /mnt/wsl/$id/etc `&`& tar -c resolv.conf -f ~/${id}.resolv.tar
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Unable to backup /etc/resolv.conf"
    $hasresolv = $false
}

Write-Host "Overriding resolv.conf" -ForegroundColor Green
wsl -u root rm /mnt/wsl/$id/etc/resolv.conf `&`& cp /etc/resolv.conf /mnt/wsl/$id/etc/resolv.conf
if ($LASTEXITCODE -ne 0){
    Write-Warning "Unable to set temporary resolv.conf, name resolution may fail."
}

Write-Host "Entering your image environment" -ForegroundColor Green
Write-Host "Press ctrl+d or type exit when you are done customizing your image" -ForegroundColor Green
wsl -u root chroot /mnt/wsl/$id

if ($hasresolv) {
    Write-Host "Resetting resolv.conf" -ForegroundColor Green
    wsl -u root tar -xC /mnt/wsl/$id/etc -f ~/${id}.resolv.tar
    wsl -u root rm ~/${id}.resolv.tar
} else {
    Write-Host "Resolv.conf didn't exist before, removing the temporary one" -ForegroundColor Green
    wsl -u root rm /mnt/wsl/$id/etc/resolv.conf
}

Write-Host "Unmounting from WSL" -ForegroundColor Green
wsl --unmount \\?\$FullDestinationPath