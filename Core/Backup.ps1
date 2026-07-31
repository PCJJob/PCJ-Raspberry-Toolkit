function Show-BackupProgress
{
    param
    (
        [string]$Stage,
        [int]$Percent,
        [string]$Activity = "Respaldo de Pi-hole"
    )

    $percentSafe = [math]::Max(0, [math]::Min(100, $Percent))
    $blocksFilled = [math]::Floor($percentSafe / 5)
    $blocksEmpty = 20 - $blocksFilled
    $bar = ""

    for ($index = 0; $index -lt $blocksFilled; $index++)
    {
        $bar += [char]0x2588
    }

    for ($index = 0; $index -lt $blocksEmpty; $index++)
    {
        $bar += [char]0x2591
    }

    $line = "$Stage  $bar $percentSafe%"
    # Mantiene todas las etapas en una sola linea, incluso al ejecutarse desde cmd.exe.
    try
    {
        if ($null -eq $script:PCJBackupProgressRow)
        {
            $script:PCJBackupProgressRow = [Console]::CursorTop
        }

        $width = [math]::Max(1, [Console]::WindowWidth - 1)
        $visibleLine = $line.Substring(0, [math]::Min($line.Length, $width))
        [Console]::SetCursorPosition(0, $script:PCJBackupProgressRow)
        [Console]::Write($visibleLine.PadRight($width))
        [Console]::SetCursorPosition([math]::Min($visibleLine.Length, $width), $script:PCJBackupProgressRow)
    }
    catch
    {
        Write-Host -NoNewline "`r$line$(' ' * 160)"
    }
}


function Complete-BackupProgress
{
    try
    {
        if ($null -ne $script:PCJBackupProgressRow)
        {
            [Console]::SetCursorPosition(0, $script:PCJBackupProgressRow + 1)
        }
    }
    catch
    {
        Write-Host ""
    }
    finally
    {
        $script:PCJBackupProgressRow = $null
    }
}


function Show-BackupLocationNote
{
    param
    (
        [string]$BackupFolder,
        [string]$Category
    )

    Write-Host ""
    Write-Host "Nota para encontrar su respaldo:" -ForegroundColor Cyan
    Write-Host "Abra la carpeta 'Backups' que esta dentro de la carpeta del programa portatil." -ForegroundColor DarkGray
    Write-Host "Tipo de respaldo: $Category" -ForegroundColor DarkGray
    Write-Host "Ubicacion: $BackupFolder" -ForegroundColor DarkGray
}


function Confirm-BackupStart
{
    param
    (
        [string]$Title,
        [string]$Description,
        [string]$Duration,
        [switch]$CanCancelDuringProcess
    )

    $script:PCJBackupProgressRow = $null
    Clear-Host
    Write-UIHeader -Title $Title
    Write-Host ""
    Write-Host $Description -ForegroundColor Cyan
    Write-Host "Tiempo estimado: $Duration" -ForegroundColor Cyan

    if ($CanCancelDuringProcess)
    {
        Write-Host "Durante la descarga puede presionar C para cancelar y borrar el archivo parcial." -ForegroundColor Yellow
    }
    else
    {
        Write-Host "Una vez iniciado, espere a que termine; esta accion no se debe cancelar a mitad." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "1. Iniciar respaldo"
    Write-Host "2. Cancelar"
    Write-Host ""
    return ((Read-UIChoice) -eq "1")
}


function Backup-PiHole
{
    param
    (
        [string]$RaspberryHost,
        [string]$User,
        [string]$BackupFolder
    )

    $configurationFolder = Join-Path $BackupFolder "PiHole-Solo-Configuracion"

    if (-not (Confirm-BackupStart `
        -Title "Respaldo de configuracion" `
        -Description "Guarda listas, dominios, clientes y ajustes de Pi-hole." `
        -Duration "menos de 1 minuto"))
    {
        Write-Host "[INFO] Respaldo cancelado antes de iniciar." -ForegroundColor Yellow
        return
    }

    if (-not (Test-Path $configurationFolder))
    {
        New-Item -ItemType Directory -Path $configurationFolder -Force | Out-Null
    }

    Write-Host "[INFO] Creando respaldo Pi-hole..." -ForegroundColor Yellow
    Show-BackupProgress -Stage "Preparando respaldo de configuracion..." -Percent 5

    $backupName = Invoke-SSHCommand `
        -RaspberryHost $RaspberryHost `
        -User $User `
        -Command "sudo pihole-FTL --teleporter"

    if (-not $backupName)
    {
        Write-Host ""
        Write-Host "[ERROR] No se pudo crear el respaldo." -ForegroundColor Red
        return
    }

    $backupName = $backupName.Trim()

    Show-BackupProgress -Stage "Configuracion preparada. Descargando archivo..." -Percent 35

    $remoteFile = "/home/$User/$backupName"

    $downloaded = Download-FileSSH `
        -RaspberryHost $RaspberryHost `
        -User $User `
        -RemoteFile $remoteFile `
        -LocalFolder $configurationFolder `
        -ProgressCallback {
            param($downloadPercent)
            $overallPercent = 35 + [math]::Round($downloadPercent * 0.65)
            Show-BackupProgress -Stage "Descargando configuracion..." -Percent $overallPercent
        }

    if (-not $downloaded)
    {
        Write-Host ""
        Write-Host "[ERROR] No se pudo descargar el respaldo." -ForegroundColor Red
        return
    }

    Show-BackupProgress -Stage "Respaldo de configuracion completado correctamente." -Percent 100
    Complete-BackupProgress
    Write-Host "[OK] Respaldo guardado correctamente." -ForegroundColor Green
    Show-BackupLocationNote -BackupFolder $configurationFolder -Category "Solo configuracion de Pi-hole"
}


function Backup-PiHoleComplete
{
    param
    (
        [string]$RaspberryHost,
        [string]$User,
        [string]$BackupFolder
    )

    $completeFolder = Join-Path $BackupFolder "PiHole-Configuracion-Historial-DNS"
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $tempFolder = Join-Path $completeFolder "Temp-$timestamp"
    $archiveFile = Join-Path $completeFolder "pcj-pihole-completo-$timestamp.zip"
    $remoteHistory = "/home/$User/pcj-pihole-history-$timestamp.db"

    if (-not (Confirm-BackupStart `
        -Title "Respaldo completo de Pi-hole" `
        -Description "Guarda configuracion e historial de consultas DNS." `
        -Duration "1 a 5 minutos"))
    {
        Write-Host "[INFO] Respaldo cancelado antes de iniciar." -ForegroundColor Yellow
        return
    }

    Write-Host "[INFO] Creando respaldo completo de Pi-hole..." -ForegroundColor Yellow
    Write-Host "[INFO] Incluye configuracion e historial DNS." -ForegroundColor Yellow
    Show-BackupProgress -Stage "Preparando respaldo..." -Percent 5 -Activity "Respaldo completo de Pi-hole"

    if (-not (Test-Path $completeFolder))
    {
        New-Item -ItemType Directory -Path $completeFolder -Force | Out-Null
    }

    New-Item -ItemType Directory -Path $tempFolder -Force | Out-Null

    try
    {
        $teleporterName = Invoke-SSHCommand `
            -RaspberryHost $RaspberryHost `
            -User $User `
            -Command "sudo pihole-FTL --teleporter"

        if (-not $teleporterName)
        {
            Write-Host ""
            Write-Host "[ERROR] No se pudo crear el respaldo de configuracion." -ForegroundColor Red
            return
        }

        $teleporterName = $teleporterName.Trim()
        $remoteTeleporter = "/home/$User/$teleporterName"

        $databaseScript = @"
sudo pihole-FTL sqlite3 /etc/pihole/pihole-FTL.db "VACUUM INTO '$remoteHistory'" && sudo chown ${User}:${User} $remoteHistory && echo OK
"@

        $databaseBackup = Invoke-SSHScript `
            -RaspberryHost $RaspberryHost `
            -User $User `
            -Script $databaseScript

        if ($LASTEXITCODE -ne 0 -or $databaseBackup -notmatch "OK")
        {
            Write-Host ""
            Write-Host "[ERROR] No se pudo crear la copia del historial DNS." -ForegroundColor Red
            return
        }

        Show-BackupProgress -Stage "Respaldo preparado. Descargando Teleporter..." -Percent 30 -Activity "Respaldo completo de Pi-hole"

        $teleporterDownloaded = Download-FileSSH `
            -RaspberryHost $RaspberryHost `
            -User $User `
            -RemoteFile $remoteTeleporter `
            -LocalFolder $tempFolder `
            -ProgressCallback {
                param($downloadPercent)
                $overallPercent = 30 + [math]::Round($downloadPercent * 0.30)
                Show-BackupProgress -Stage "Descargando Teleporter..." -Percent $overallPercent -Activity "Respaldo completo de Pi-hole"
            }

        if (-not $teleporterDownloaded)
        {
            Write-Host ""
            Write-Host "[ERROR] No se pudo descargar la configuracion de Pi-hole." -ForegroundColor Red
            return
        }

        Show-BackupProgress -Stage "Teleporter descargado. Descargando historial DNS..." -Percent 60 -Activity "Respaldo completo de Pi-hole"

        $historyDownloaded = Download-FileSSH `
            -RaspberryHost $RaspberryHost `
            -User $User `
            -RemoteFile $remoteHistory `
            -LocalFolder $tempFolder `
            -ProgressCallback {
                param($downloadPercent)
                $overallPercent = 60 + [math]::Round($downloadPercent * 0.30)
                Show-BackupProgress -Stage "Descargando historial DNS..." -Percent $overallPercent -Activity "Respaldo completo de Pi-hole"
            }

        if (-not $historyDownloaded)
        {
            Write-Host ""
            Write-Host "[ERROR] No se pudo descargar el historial DNS." -ForegroundColor Red
            return
        }

        Show-BackupProgress -Stage "Historial DNS descargado. Empaquetando respaldo..." -Percent 90 -Activity "Respaldo completo de Pi-hole"

        $localTeleporter = Join-Path $tempFolder $teleporterName
        $localHistory = Join-Path $tempFolder (Split-Path $remoteHistory -Leaf)

        if (-not (Test-Path -LiteralPath $localTeleporter) -or
            -not (Test-Path -LiteralPath $localHistory))
        {
            Write-Host ""
            Write-Host "[ERROR] No se pudieron descargar todos los archivos del respaldo." -ForegroundColor Red
            return
        }

        Compress-Archive `
            -Path $localTeleporter, $localHistory `
            -DestinationPath $archiveFile `
            -Force

        Show-BackupProgress -Stage "Respaldo completado correctamente." -Percent 100 -Activity "Respaldo completo de Pi-hole"
        Complete-BackupProgress
        Write-Host "[OK] Respaldo completo guardado correctamente." -ForegroundColor Green
        Write-Host "Archivo: $archiveFile"
        Show-BackupLocationNote -BackupFolder $completeFolder -Category "Configuracion + historial DNS de Pi-hole"
    }
    finally
    {
        Remove-Item -LiteralPath $tempFolder -Recurse -Force -ErrorAction SilentlyContinue

        Invoke-SSHCommand `
            -RaspberryHost $RaspberryHost `
            -User $User `
            -Command "rm -f $remoteHistory" | Out-Null
    }
}


function Backup-RaspberrySystem
{
    param
    (
        [string]$RaspberryHost,
        [string]$User,
        [string]$BackupFolder
    )

    $systemFolder = Join-Path $BackupFolder "Sistema"
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $imageFile = Join-Path $systemFolder "pcj-raspberry-sistema-$timestamp.img.gz"

    if (-not (Confirm-BackupStart `
        -Title "Imagen completa del sistema" `
        -Description "Crea un respaldo completo de la microSD de la Raspberry mientras esta encendida." `
        -Duration "varios minutos o mas" `
        -CanCancelDuringProcess))
    {
        Write-Host "[INFO] Respaldo cancelado antes de iniciar." -ForegroundColor Yellow
        return
    }

    Write-Host "[INFO] Preparando respaldo completo de la microSD..." -ForegroundColor Yellow
    Write-Host "[INFO] La Raspberry seguira funcionando durante el respaldo." -ForegroundColor Yellow
    Write-Host "[INFO] Es un respaldo de emergencia: archivos que cambien durante la copia podrian no quedar totalmente sincronizados." -ForegroundColor DarkYellow

    $rootPartition = Invoke-SSHCommand `
        -RaspberryHost $RaspberryHost `
        -User $User `
        -Command "findmnt -n -o SOURCE /"

    if (-not $rootPartition)
    {
        Write-Host "[ERROR] No se pudo identificar el disco del sistema." -ForegroundColor Red
        return
    }

    $rootPartition = $rootPartition.Trim()
    $systemDisk = $rootPartition -replace "p?\d+$", ""

    if ($systemDisk -notmatch "^/dev/")
    {
        Write-Host "[ERROR] El dispositivo del sistema no es compatible con este respaldo." -ForegroundColor Red
        return
    }

    $diskSize = Invoke-SSHCommand `
        -RaspberryHost $RaspberryHost `
        -User $User `
        -Command "sudo blockdev --getsize64 $systemDisk"

    [long]$diskBytes = 0

    if (-not [long]::TryParse($diskSize.Trim(), [ref]$diskBytes) -or $diskBytes -le 0)
    {
        Write-Host "[ERROR] No se pudo conocer el tamano de la microSD." -ForegroundColor Red
        return
    }

    if (-not (Test-Path $systemFolder))
    {
        New-Item -ItemType Directory -Path $systemFolder -Force | Out-Null
    }

    $systemDrive = Get-Item -LiteralPath $systemFolder
    $driveRoot = [System.IO.Path]::GetPathRoot($systemDrive.FullName)
    $freeBytes = (New-Object System.IO.DriveInfo($driveRoot)).AvailableFreeSpace

    if ($freeBytes -lt $diskBytes)
    {
        $requiredGB = [math]::Round($diskBytes / 1GB, 1)
        $availableGB = [math]::Round($freeBytes / 1GB, 1)

        Write-Host "[ERROR] No hay suficiente espacio libre para la imagen." -ForegroundColor Red
        Write-Host "Necesario como minimo: $requiredGB GB"
        Write-Host "Disponible: $availableGB GB"
        return
    }

    Write-Host "[INFO] Creando y descargando la imagen. Puede tardar bastante tiempo..." -ForegroundColor Yellow
    Write-Host "[INFO] Presione la tecla C para cancelar y borrar la imagen parcial." -ForegroundColor Yellow
    Show-BackupProgress -Stage "Preparando imagen del sistema..." -Percent 0

    $saveResult = Save-SSHBinaryStream `
        -RaspberryHost $RaspberryHost `
        -User $User `
        -Command "sudo dd if=$systemDisk bs=4M status=progress | gzip -1" `
        -LocalFile $imageFile `
        -TotalBytes $diskBytes `
        -AllowCancel `
        -ProgressCallback {
            param($imagePercent)
            Show-BackupProgress -Stage "Creando imagen del sistema... (C para cancelar)" -Percent $imagePercent
        }

    if (-not $saveResult.Succeeded)
    {
        Write-Host ""

        if ($saveResult.Cancelled)
        {
            Write-Host "[INFO] Respaldo cancelado. La imagen parcial fue eliminada." -ForegroundColor Yellow
        }

        return
    }

    Show-BackupProgress -Stage "Imagen completa guardada correctamente." -Percent 100
    Complete-BackupProgress
    $imageSizeGB = [math]::Round((Get-Item -LiteralPath $imageFile).Length / 1GB, 2)

    Write-Host "[OK] Imagen completa guardada correctamente." -ForegroundColor Green
    Write-Host "Archivo: $imageFile"
    Write-Host "Tamano comprimido: $imageSizeGB GB"
    Show-BackupLocationNote -BackupFolder $systemFolder -Category "Imagen completa de la Raspberry"
    Write-Host ""
    Write-Host "Para restaurarla, grabala en una microSD con Raspberry Pi Imager."
}
