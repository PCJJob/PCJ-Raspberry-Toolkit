# ============================================
# PCJ Raspberry
# Configuracion inicial
# ============================================

$configFile = Join-Path $PSScriptRoot "..\PCJ-Raspberry.ini"
. "$PSScriptRoot\..\Core\LoadModules.ps1"

do
{
    $profile = New-PCJProfile -ConfigFile $configFile -RequireSave -ShowWelcome
}
while ($profile -and $profile.PCJAction -eq "ReturnToStart")

if (-not $profile)
{
    return $false
}

Set-PCJIniValue -File $configFile -Section "Backups" -Key "Destination" -Value ".\Backups"
Set-PCJIniValue -File $configFile -Section "Installation" -Key "OwnerUser" -Value $env:USERNAME
Set-PCJIniValue -File $configFile -Section "Installation" -Key "OwnerComputer" -Value $env:COMPUTERNAME

Write-Host ""
Write-Host "[OK] Configuracion inicial terminada." -ForegroundColor Green
Pause
return $true
