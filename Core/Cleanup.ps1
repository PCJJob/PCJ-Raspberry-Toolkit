function Format-BackupStorageSize
{
    param([long]$Bytes)

    if ($Bytes -ge 1GB)
    {
        return ("{0:N2} GB" -f ($Bytes / 1GB))
    }

    if ($Bytes -ge 1MB)
    {
        return ("{0:N2} MB" -f ($Bytes / 1MB))
    }

    if ($Bytes -ge 1KB)
    {
        return ("{0:N2} KB" -f ($Bytes / 1KB))
    }

    return "$Bytes bytes"
}


function Clean-OldBackups
{
    param
    (
        [string]$Folder,
        [string]$BackupType,
        [int]$Days = 30
    )

    Write-Host "[INFO] Revisando respaldos: $BackupType" -ForegroundColor Yellow
    Write-Host ""

    if (-not (Test-Path $Folder))
    {
        Write-Host "[INFO] Todavia no existe esta carpeta de respaldos."
        return
    }

    $files = @(Get-ChildItem -Path $Folder -File | Sort-Object LastWriteTime -Descending)

    if ($files.Count -eq 0)
    {
        Write-Host "[INFO] No hay respaldos disponibles."
        return
    }

    $totalSize = ($files | Measure-Object Length -Sum).Sum
    $sizeMB = [math]::Round($totalSize / 1MB, 2)

    Write-Host "Respaldos encontrados: $($files.Count)"
    Write-Host "Espacio utilizado: $sizeMB MB"
    Write-Host ""

    $oldFiles = @($files | Where-Object {
        $_.LastWriteTime -lt (Get-Date).AddDays(-$Days)
    })

    if ($oldFiles.Count -eq 0)
    {
        Write-Host "[OK] No hay respaldos de mas de $Days dias para eliminar." -ForegroundColor Green
        return
    }

    $deletedSize = ($oldFiles | Measure-Object Length -Sum).Sum
    $deletedMB = [math]::Round($deletedSize / 1MB, 2)

    Write-Host "Se eliminaran $($oldFiles.Count) respaldo(s) de mas de $Days dias:" -ForegroundColor Yellow

    foreach ($file in $oldFiles)
    {
        Write-Host "- $($file.Name)"
    }

    Write-Host ""
    Write-Host "Espacio que se liberara: $deletedMB MB"
    Write-Host "Despues de confirmar, la eliminacion local no se puede cancelar a mitad." -ForegroundColor Yellow
    $confirmation = Read-Host "Escriba SI para confirmar la eliminacion"

    if ($confirmation -ine "SI")
    {
        Write-Host "[INFO] Limpieza cancelada."
        return
    }

    $deletedCount = 0
    [long]$deletedBytes = 0

    foreach ($file in $oldFiles)
    {
        try
        {
            Remove-Item -LiteralPath $file.FullName -ErrorAction Stop
            $deletedCount++
            $deletedBytes += $file.Length
        }
        catch
        {
            Write-Host "[ERROR] No se pudo borrar: $($file.Name)" -ForegroundColor Red
        }
    }

    Write-Host "[OK] Limpieza terminada." -ForegroundColor Green
    Write-Host "Archivos eliminados: $deletedCount"
    Write-Host "Espacio liberado: $(Format-BackupStorageSize -Bytes $deletedBytes)" -ForegroundColor Green
}


function Remove-AllLocalBackups
{
    param([string]$BackupFolder)

    $backupGroups = @(
        [PSCustomObject]@{ Name = "Solo configuracion de Pi-hole"; Folder = (Join-Path $BackupFolder "PiHole-Solo-Configuracion") },
        [PSCustomObject]@{ Name = "Configuracion + historial DNS"; Folder = (Join-Path $BackupFolder "PiHole-Configuracion-Historial-DNS") },
        [PSCustomObject]@{ Name = "Imagenes completas del sistema"; Folder = (Join-Path $BackupFolder "Sistema") }
    )

    $allFiles = @()

    foreach ($backupGroup in $backupGroups)
    {
        if (Test-Path -LiteralPath $backupGroup.Folder)
        {
            $allFiles += @(Get-ChildItem -LiteralPath $backupGroup.Folder -File -Recurse -Force)
        }
    }

    if ($allFiles.Count -eq 0)
    {
        Write-Host "[INFO] No hay respaldos locales para borrar." -ForegroundColor Yellow
        return
    }

    $totalSize = ($allFiles | Measure-Object -Property Length -Sum).Sum
    $sizeMB = [math]::Round($totalSize / 1MB, 2)

    Write-Host "ATENCION: se borraran todos los respaldos locales." -ForegroundColor Red
    Write-Host "Incluye configuracion de Pi-hole, historial DNS e imagenes completas del sistema." -ForegroundColor Yellow
    Write-Host "Archivos encontrados: $($allFiles.Count)" -ForegroundColor Yellow
    Write-Host "Espacio que se liberara: $sizeMB MB" -ForegroundColor Yellow
    Write-Host ""

    $firstConfirmation = Read-Host "Primera confirmacion: escriba SI para continuar"

    if ($firstConfirmation -ine "SI")
    {
        Write-Host "[INFO] Borrado total cancelado. No se elimino ningun respaldo." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "Esta accion no se puede deshacer." -ForegroundColor Red
    $secondConfirmation = Read-Host "Segunda confirmacion: escriba SI nuevamente"

    if ($secondConfirmation -ine "SI")
    {
        Write-Host "[INFO] Borrado total cancelado. No se elimino ningun respaldo." -ForegroundColor Yellow
        return
    }

    $deletedCount = 0
    [long]$deletedBytes = 0
    $failedFiles = @()
    $totalFiles = $allFiles.Count

    Show-UIProgress -Stage "Borrando respaldos locales..." -Percent 0

    for ($index = 0; $index -lt $totalFiles; $index++)
    {
        $file = $allFiles[$index]

        try
        {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $deletedCount++
            $deletedBytes += $file.Length
        }
        catch
        {
            $failedFiles += $file.Name
        }

        $percent = [math]::Floor((($index + 1) / $totalFiles) * 100)
        Show-UIProgress -Stage "Borrando respaldos locales..." -Percent $percent
    }

    Complete-UIProgress

    foreach ($failedFile in $failedFiles)
    {
        Write-Host "[ERROR] No se pudo borrar: $failedFile" -ForegroundColor Red
    }

    Write-Host "[OK] Borrado total terminado." -ForegroundColor Green
    Write-Host "Respaldos eliminados: $deletedCount" -ForegroundColor Green
    Write-Host "Espacio liberado: $(Format-BackupStorageSize -Bytes $deletedBytes)" -ForegroundColor Green
}
