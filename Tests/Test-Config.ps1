# ============================================
# PCJ Raspberry Toolkit
# Prueba de integridad local (no modifica datos)
# ============================================

$projectRoot = Split-Path -Parent $PSScriptRoot
$requiredFiles = @(
    "PCJ Raspberry.bat",
    "Scripts\menu.ps1",
    "Core\Config.ps1",
    "Core\SSH.ps1",
    "Core\Status.ps1",
    "Core\Backup.ps1",
    "Core\Restore.ps1",
    "Core\Cleanup.ps1",
    "Core\Tools.ps1",
    "Core\UI.ps1"
)

$failed = $false

Write-Host "PCJ Raspberry - Prueba de integridad" -ForegroundColor Cyan
Write-Host "Esta prueba solo revisa archivos; no se conecta a la Raspberry ni borra respaldos." -ForegroundColor DarkGray
Write-Host ""

foreach ($relativeFile in $requiredFiles)
{
    $filePath = Join-Path $projectRoot $relativeFile

    if (Test-Path -LiteralPath $filePath)
    {
        Write-Host "[OK] $relativeFile" -ForegroundColor Green
    }
    else
    {
        Write-Host "[ERROR] Falta: $relativeFile" -ForegroundColor Red
        $failed = $true
    }
}

$scripts = Get-ChildItem -LiteralPath $projectRoot -Recurse -Filter "*.ps1" |
    Where-Object { $_.FullName -notmatch "\\Releases\\" }

foreach ($script in $scripts)
{
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $script.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )

    if ($parseErrors.Count -gt 0)
    {
        Write-Host "[ERROR] Error de sintaxis: $($script.FullName)" -ForegroundColor Red
        $parseErrors | ForEach-Object { Write-Host "        $($_.Message)" -ForegroundColor Red }
        $failed = $true
    }
}

if ($failed)
{
    Write-Host "" 
    Write-Host "[ERROR] La prueba encontró problemas. Revise los mensajes anteriores." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "[OK] Archivos y sintaxis revisados correctamente." -ForegroundColor Green
