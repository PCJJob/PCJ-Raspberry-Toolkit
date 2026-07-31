function Restore-PiHoleBackup
{
    param
    (
        [string]$RaspberryHost,
        [string]$User,
        [string]$BackupFolder
    )

    $configurationFolder = Join-Path $BackupFolder "PiHole-Solo-Configuracion"

    Write-Host "[INFO] Buscando respaldos disponibles..." -ForegroundColor Yellow
    Write-Host ""

    if (-not (Test-Path $configurationFolder))
    {
        Write-Host "[ERROR] No existe la carpeta de respaldos." -ForegroundColor Red
        return
    }

    $files = Get-ChildItem -Path $configurationFolder -File -Filter "*.zip" |
        Sort-Object LastWriteTime -Descending

    if ($files.Count -eq 0)
    {
        Write-Host "[INFO] No hay respaldos de Pi-hole disponibles."
        return
    }

    Write-Host "Respaldos disponibles:" -ForegroundColor Cyan
    Write-Host ""

    for ($index = 0; $index -lt $files.Count; $index++)
    {
        $file = $files[$index]
        $fileSize = [math]::Round($file.Length / 1KB, 2)
        $number = $index + 1

        Write-Host "$number. $($file.Name)  |  $($file.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))  |  $fileSize KB"
    }

    Write-Host ""

    $selection = Read-Host "Seleccione el numero del respaldo (o presione ENTER para cancelar)"

    if ([string]::IsNullOrWhiteSpace($selection))
    {
        Write-Host "[INFO] Restauracion cancelada."
        return
    }

    $selectedNumber = 0

    if (-not [int]::TryParse($selection, [ref]$selectedNumber) -or
        $selectedNumber -lt 1 -or
        $selectedNumber -gt $files.Count)
    {
        Write-Host "[ERROR] Seleccion no valida." -ForegroundColor Red
        return
    }

    $selectedFile = $files[$selectedNumber - 1]

    if (-not (Test-Path -LiteralPath $selectedFile.FullName))
    {
        Write-Host "[ERROR] El archivo seleccionado ya no existe." -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "IMPORTANTE: Se reemplazara la configuracion actual de Pi-hole." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Se restauraran:" -ForegroundColor Cyan
    Write-Host "- Listas de bloqueo y listas permitidas."
    Write-Host "- Dominios bloqueados o permitidos manualmente."
    Write-Host "- Clientes, grupos y asignaciones."
    Write-Host "- Ajustes DNS, DHCP y demas configuraciones de Pi-hole."
    Write-Host ""
    Write-Host "No se restauraran:" -ForegroundColor Cyan
    Write-Host "- Historial de consultas DNS."
    Write-Host "- Sistema operativo ni archivos ajenos a Pi-hole."
    Write-Host ""
    Write-Host "Despues de confirmar, espere a que termine; no se puede cancelar la importacion a mitad." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Respaldo seleccionado: $($selectedFile.Name)" -ForegroundColor Yellow
    $confirmation = Read-Host "Escriba SI para confirmar"

    if ($confirmation -ine "SI")
    {
        Write-Host "[INFO] Restauracion cancelada."
        return
    }

    Write-Host ""
    Write-Host "[INFO] Subiendo respaldo a la Raspberry..." -ForegroundColor Yellow

    $remoteFile = "/home/$User/pcj-pihole-restore.zip"

    $uploaded = Upload-FileSSH `
        -RaspberryHost $RaspberryHost `
        -User $User `
        -LocalFile $selectedFile.FullName `
        -RemoteFile $remoteFile

    if (-not $uploaded)
    {
        Write-Host "[ERROR] No se pudo subir el respaldo a la Raspberry." -ForegroundColor Red
        return
    }

    Write-Host "[INFO] Importando configuracion en Pi-hole..." -ForegroundColor Yellow

    $restoreResult = Invoke-SSHCommand `
        -RaspberryHost $RaspberryHost `
        -User $User `
        -Command "sudo pihole-FTL --teleporter $remoteFile; result=`$?; rm -f $remoteFile; exit `$result"

    if ($LASTEXITCODE -ne 0)
    {
        Write-Host "[ERROR] Pi-hole no pudo importar el respaldo." -ForegroundColor Red

        if ($restoreResult)
        {
            Write-Host $restoreResult
        }

        return
    }

    Write-Host "[OK] Respaldo restaurado correctamente en Pi-hole." -ForegroundColor Green
}


function Restore-PiHoleCompleteBackup
{
    param
    (
        [string]$RaspberryHost,
        [string]$User,
        [string]$BackupFolder
    )

    $completeFolder = Join-Path $BackupFolder "PiHole-Configuracion-Historial-DNS"

    if (-not (Test-Path $completeFolder))
    {
        Write-Host "[ERROR] No existe la carpeta de respaldos completos." -ForegroundColor Red
        return
    }

    $files = Get-ChildItem -Path $completeFolder -File -Filter "*.zip" |
        Sort-Object LastWriteTime -Descending

    if ($files.Count -eq 0)
    {
        Write-Host "[INFO] No hay respaldos completos disponibles."
        return
    }

    Write-Host "Respaldos completos disponibles:" -ForegroundColor Cyan
    Write-Host ""

    for ($index = 0; $index -lt $files.Count; $index++)
    {
        $file = $files[$index]
        $fileSizeMB = [math]::Round($file.Length / 1MB, 2)
        $number = $index + 1

        Write-Host "$number. $($file.Name)  |  $($file.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))  |  $fileSizeMB MB"
    }

    Write-Host ""
    $selection = Read-Host "Seleccione el numero del respaldo (o presione ENTER para cancelar)"

    if ([string]::IsNullOrWhiteSpace($selection))
    {
        Write-Host "[INFO] Restauracion cancelada."
        return
    }

    $selectedNumber = 0

    if (-not [int]::TryParse($selection, [ref]$selectedNumber) -or
        $selectedNumber -lt 1 -or
        $selectedNumber -gt $files.Count)
    {
        Write-Host "[ERROR] Seleccion no valida." -ForegroundColor Red
        return
    }

    $selectedFile = $files[$selectedNumber - 1]
    $tempFolder = Join-Path $completeFolder "Restore-Temp-$([guid]::NewGuid().ToString('N'))"

    try
    {
        Expand-Archive -LiteralPath $selectedFile.FullName -DestinationPath $tempFolder -Force

        $teleporterFile = Get-ChildItem -Path $tempFolder -File -Filter "*.zip" | Select-Object -First 1
        $historyFile = Get-ChildItem -Path $tempFolder -File -Filter "*.db" | Select-Object -First 1

        if (-not $teleporterFile -or -not $historyFile)
        {
            Write-Host "[ERROR] El respaldo completo no contiene los archivos requeridos." -ForegroundColor Red
            return
        }

        Write-Host ""
        Write-Host "IMPORTANTE: Se reemplazara la configuracion actual y el historial DNS de Pi-hole." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Se restauraran:" -ForegroundColor Cyan
        Write-Host "- Configuracion, listas, dominios, clientes, grupos, DNS y DHCP."
        Write-Host "- Historial y estadisticas DNS almacenados por Pi-hole."
        Write-Host ""
        Write-Host "El servicio DNS se reiniciara brevemente para restaurar el historial." -ForegroundColor Yellow
        Write-Host "Despues de confirmar, espere a que termine; no se puede cancelar la restauracion a mitad." -ForegroundColor Yellow
        Write-Host "Respaldo seleccionado: $($selectedFile.Name)" -ForegroundColor Yellow

        $confirmation = Read-Host "Escriba SI para confirmar"

        if ($confirmation -ine "SI")
        {
            Write-Host "[INFO] Restauracion cancelada."
            return
        }

        $remoteTeleporter = "/home/$User/pcj-pihole-restore.zip"
        $remoteHistory = "/home/$User/pcj-pihole-history-restore.db"

        Write-Host "[INFO] Restaurando configuracion de Pi-hole..." -ForegroundColor Yellow

        $uploadedTeleporter = Upload-FileSSH `
            -RaspberryHost $RaspberryHost `
            -User $User `
            -LocalFile $teleporterFile.FullName `
            -RemoteFile $remoteTeleporter

        if (-not $uploadedTeleporter)
        {
            Write-Host "[ERROR] No se pudo subir la configuracion del respaldo." -ForegroundColor Red
            return
        }

        Invoke-SSHCommand `
            -RaspberryHost $RaspberryHost `
            -User $User `
            -Command "sudo pihole-FTL --teleporter $remoteTeleporter; result=`$?; rm -f $remoteTeleporter; exit `$result" | Out-Null

        if ($LASTEXITCODE -ne 0)
        {
            Write-Host "[ERROR] Pi-hole no pudo restaurar la configuracion." -ForegroundColor Red
            return
        }

        Write-Host "[INFO] Restaurando historial DNS..." -ForegroundColor Yellow

        $uploadedHistory = Upload-FileSSH `
            -RaspberryHost $RaspberryHost `
            -User $User `
            -LocalFile $historyFile.FullName `
            -RemoteFile $remoteHistory

        if (-not $uploadedHistory)
        {
            Write-Host "[ERROR] No se pudo subir el historial DNS." -ForegroundColor Red
            return
        }

        $restoreHistoryScript = @"
sudo systemctl stop pihole-FTL
result=`$?
if [ `$result -eq 0 ]; then
    sudo cp $remoteHistory /etc/pihole/pihole-FTL.db
    result=`$?
    if [ `$result -eq 0 ]; then
        sudo chown pihole:pihole /etc/pihole/pihole-FTL.db
        result=`$?
    fi
fi
sudo systemctl start pihole-FTL
rm -f $remoteHistory
exit `$result
"@

        Invoke-SSHScript `
            -RaspberryHost $RaspberryHost `
            -User $User `
            -Script $restoreHistoryScript | Out-Null

        if ($LASTEXITCODE -ne 0)
        {
            Write-Host "[ERROR] No se pudo restaurar el historial DNS." -ForegroundColor Red
            return
        }

        Write-Host "[OK] Pi-hole e historial DNS restaurados correctamente." -ForegroundColor Green
    }
    finally
    {
        Remove-Item -LiteralPath $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}


function Show-SystemRestoreInstructions
{
    param
    (
        [string]$BackupFolder
    )

    $systemFolder = Join-Path $BackupFolder "Sistema"

    if (-not (Test-Path $systemFolder))
    {
        Write-Host "[ERROR] No existe la carpeta de imagenes del sistema." -ForegroundColor Red
        return
    }

    $images = Get-ChildItem -Path $systemFolder -File -Filter "*.img.gz" |
        Sort-Object LastWriteTime -Descending

    if ($images.Count -eq 0)
    {
        Write-Host "[INFO] No hay imagenes completas del sistema disponibles."
        return
    }

    Write-Host "Imagenes disponibles:" -ForegroundColor Cyan
    Write-Host ""

    for ($index = 0; $index -lt $images.Count; $index++)
    {
        $image = $images[$index]
        $imageSizeGB = [math]::Round($image.Length / 1GB, 2)
        $number = $index + 1

        Write-Host "$number. $($image.Name)  |  $($image.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))  |  $imageSizeGB GB"
    }

    Write-Host ""
    Write-Host "La imagen del sistema no se restaura desde una Raspberry encendida." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Para restaurarla:" -ForegroundColor Cyan
    Write-Host "1. Apague la Raspberry y retire la microSD."
    Write-Host "2. Conecte la microSD a su PC."
    Write-Host "3. Abra Raspberry Pi Imager (recomendado) u otro programa compatible."
    Write-Host "4. Elija 'Use custom' y seleccione la imagen .img.gz indicada arriba."
    Write-Host "5. Elija la microSD correcta y pulse 'Write'."
    Write-Host "6. Cuando termine, inserte nuevamente la microSD en la Raspberry y enciendala."
    Write-Host "7. Conecte la Raspberry a su red Wi-Fi si no se reconecta automaticamente."
}
