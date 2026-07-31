# ============================================
# PCJ Raspberry
# Menú principal
# ============================================

$configFile = Join-Path $PSScriptRoot "..\PCJ-Raspberry.ini"
$versionFile = Join-Path $PSScriptRoot "..\VERSION.txt"
$backupFolder = Join-Path $PSScriptRoot "..\Backups"
$reportsFolder = Join-Path $PSScriptRoot "..\Informes"

. "$PSScriptRoot\..\Core\LoadModules.ps1"
. "$PSScriptRoot\..\Setup\Setup-DesktopIntegration.ps1"

Initialize-PCJDesktopIntegration -ProgramRoot (Split-Path -Parent $PSScriptRoot)

$requiresSetup = -not (Test-Path $configFile)

if (-not $requiresSetup)
{
    $configText = Get-Content -LiteralPath $configFile -Raw
    $ownerUser = [regex]::Match($configText, "(?m)^OwnerUser=(.+)$").Groups[1].Value.Trim()
    $ownerComputer = [regex]::Match($configText, "(?m)^OwnerComputer=(.+)$").Groups[1].Value.Trim()

    $activeProfile = Get-PCJActiveProfile -ConfigFile $configFile

    if ($ownerUser -ne $env:USERNAME -or
        $ownerComputer -ne $env:COMPUTERNAME -or
        -not $activeProfile -or
        -not (Test-Path $activeProfile.KeyFile))
    {
        $requiresSetup = $true
    }
}

if (-not $requiresSetup)
{
    Show-UIWelcome
}

if ($requiresSetup)
{
    $setupCompleted = & "$PSScriptRoot\..\Setup\Setup.ps1"

    # Si el usuario cancela el asistente inicial, todavia no existe ningun
    # archivo de configuracion. Terminamos aqui para evitar errores tecnicos.
    if (-not $setupCompleted)
    {
        return
    }

    $configText = Get-Content -LiteralPath $configFile -Raw -ErrorAction SilentlyContinue
    $ownerUser = [regex]::Match($configText, "(?m)^OwnerUser=(.+)$").Groups[1].Value.Trim()
    $ownerComputer = [regex]::Match($configText, "(?m)^OwnerComputer=(.+)$").Groups[1].Value.Trim()
    $activeProfile = Get-PCJActiveProfile -ConfigFile $configFile

    if ($ownerUser -ne $env:USERNAME -or
        $ownerComputer -ne $env:COMPUTERNAME -or
        -not $activeProfile -or
        -not (Test-Path $activeProfile.KeyFile))
    {
        exit
    }
}

$savedProfiles = @(Get-PCJSavedProfiles)

if ($savedProfiles.Count -gt 1)
{
    $activeProfile = Select-PCJStartupProfile -ConfigFile $configFile

    if (-not $activeProfile)
    {
        exit
    }
}
else
{
    $activeProfile = Get-PCJActiveProfile -ConfigFile $configFile
}

$raspberryHost = $activeProfile.Host
$user = $activeProfile.User


$version = "Desconocida"

if (Test-Path $versionFile)
{
    $version = Get-Content $versionFile | Select-Object -First 2 | Select-Object -Last 1
}


function Show-BackupMenu
{
    param
    (
        [string]$RaspberryHost,
        [string]$User,
        [string]$BackupFolder
    )

    while ($true)
    {
        Clear-Host

        Write-UIHeader -Title "Respaldos"
        Write-Host ""

        Write-Host "Que desea hacer?" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "1. Crear un respaldo" -ForegroundColor White
        Write-Host "   Guarda una copia de configuracion, historial DNS o de todo el sistema para recuperarla despues." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "2. Restaurar respaldos" -ForegroundColor White
        Write-Host "   Recupera configuraciones o datos desde una copia que ya esta guardada en esta PC." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "3. Borrar respaldos locales para liberar espacio" -ForegroundColor White
        Write-Host "   Elimina copias guardadas en esta PC. Muestra confirmaciones antes de borrar archivos." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "4. Cancelar y volver" -ForegroundColor DarkGray
        Write-Host "   Regresa al menu principal sin crear, restaurar ni borrar respaldos." -ForegroundColor DarkGray
        Write-Host ""

        $opcionRespaldo = Read-UIChoice

        switch ($opcionRespaldo)
        {
            "1" {
                Show-CreateBackupAssistant `
                    -RaspberryHost $RaspberryHost `
                    -User $User `
                    -BackupFolder $BackupFolder
            }

            "2" {
                Show-RestoreMenu `
                    -RaspberryHost $RaspberryHost `
                    -User $User `
                    -BackupFolder $BackupFolder
            }

            "3" {
                Show-CleanupMenu -BackupFolder $BackupFolder
            }

            "4" {
                return
            }
        }
    }
}


function Get-LocalDefaultGateway
{
    try
    {
        $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction Stop |
            Where-Object { $_.NextHop -and $_.NextHop -ne "0.0.0.0" } |
            Sort-Object RouteMetric |
            Select-Object -First 1

        return $route.NextHop
    }
    catch
    {
        return ""
    }
}


function Wait-PCJEnter
{
    param([string]$Message = "Presione Enter para volver...")

    Write-Host $Message -ForegroundColor DarkGray

    try
    {
        do
        {
            $returnKey = [Console]::ReadKey($true)
        }
        while ($returnKey.Key -ne [ConsoleKey]::Enter)
    }
    catch
    {
        Read-Host | Out-Null
    }
}


function Get-LocalDNSPiHoleCheck
{
    param
    (
        [string]$RaspberryHost
    )

    try
    {
        $dnsAddresses = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
            ForEach-Object { $_.ServerAddresses } |
            Where-Object { $_ })

        return [PSCustomObject]@{
            CouldCheck = $true
            UsesPiHole = ($dnsAddresses -contains $RaspberryHost)
            Addresses = $dnsAddresses
        }
    }
    catch
    {
        return [PSCustomObject]@{ CouldCheck = $false; UsesPiHole = $false; Addresses = @() }
    }
}


function Show-PiHoleUninstallAssistant
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    while ($true)
    {
        Clear-Host
        Write-UIHeader -Title "Preparar y desinstalar Pi-hole"
        Write-Host ""
        Write-Host "Siga esta guia para evitar quedarse sin Internet al quitar Pi-hole." -ForegroundColor Cyan
        Write-Host "La IP actual de Pi-hole es: $RaspberryHost" -ForegroundColor Cyan
        Write-Host ""

        $dnsCheck = Get-LocalDNSPiHoleCheck -RaspberryHost $RaspberryHost
        if (-not $dnsCheck.CouldCheck)
        {
            Write-Host "Comprobacion de esta PC: no se pudo revisar automaticamente su DNS." -ForegroundColor Yellow
            Write-Host "Complete los pasos y confirme manualmente que ya no usa $RaspberryHost como DNS." -ForegroundColor Yellow
        }
        elseif ($dnsCheck.UsesPiHole)
        {
            Write-Host "Comprobacion de esta PC: aun usa $RaspberryHost como DNS de Pi-hole." -ForegroundColor Yellow
            Write-Host "Todavia no es seguro desinstalar Pi-hole." -ForegroundColor Yellow
        }
        else
        {
            Write-Host "[OK] Comprobacion de esta PC: ya no usa $RaspberryHost como DNS." -ForegroundColor Green
            Write-Host "Puede continuar a la opcion 4, despues de confirmar que los demas equipos tambien recibieron el nuevo DNS." -ForegroundColor Green
        }

        Write-Host ""
        Write-Host "Antes de desinstalar, cambie el DNS de esta PC o del router." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Elija como desea hacer el cambio:" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "1. Cambiar DNS solo en esta PC (mas sencillo)" -ForegroundColor White
        Write-Host "   Recomendado si solo desea que esta computadora y el programa sigan funcionando sin Pi-hole." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "2. Cambiar DNS en el router (para toda la red)" -ForegroundColor White
        Write-Host "   Recomendado si desea que todos los equipos de la casa dejen de usar Pi-hole." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "3. Comprobar los cambios" -ForegroundColor White
        Write-Host "   Vuelve a revisar si esta PC ya dejo de usar la IP de Pi-hole como DNS." -ForegroundColor Cyan
        Write-Host ""
        if ($dnsCheck.CouldCheck -and -not $dnsCheck.UsesPiHole)
        {
            Write-Host "4. Desinstalar Pi-hole" -ForegroundColor White
            Write-Host "   Listo para abrir el desinstalador oficial. Aun pedira dos confirmaciones de seguridad." -ForegroundColor Green
        }
        else
        {
            Write-Host "4. Desinstalar Pi-hole (aun no disponible)" -ForegroundColor DarkGray
            Write-Host "   Elija una de las dos opciones anteriores y use el paso 3 hasta que la comprobacion sea correcta." -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host "5. Cancelar y volver" -ForegroundColor DarkGray
        Write-Host "   Regresa al menu de Pi-hole sin realizar cambios." -ForegroundColor DarkGray
        Write-Host ""

        $option = Read-UIChoice

        if ($option -eq "1")
        {
            Clear-Host
            Write-UIHeader -Title "Cambiar DNS solo en esta PC"
            Write-Host ""
            Write-Host "Esta es la ruta mas sencilla. Solo cambia el DNS de esta computadora." -ForegroundColor Cyan
            Write-Host "El programa y la conexion por IP con la Raspberry seguiran funcionando." -ForegroundColor Cyan
            Write-Host ""
            Write-Host "Primero, elija un solo par de DNS. No combine proveedores diferentes:" -ForegroundColor Yellow
            Write-Host "  Quad9:       9.9.9.9  y  149.112.112.112" -ForegroundColor Cyan
            Write-Host "  Cloudflare:  1.1.1.1  y  1.0.0.1" -ForegroundColor Cyan
            Write-Host "  Google:      8.8.8.8  y  8.8.4.4" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "Despues siga estos pasos:" -ForegroundColor Yellow
            Write-Host "1. Abra Configuracion de Windows > Red e Internet > Configuracion de red avanzada." -ForegroundColor Cyan
            Write-Host "2. Seleccione su adaptador de red y elija Ver propiedades adicionales > Editar DNS." -ForegroundColor Cyan
            Write-Host "3. Seleccione Manual, active IPv4 e ingrese el par de DNS que eligio arriba." -ForegroundColor Cyan
            Write-Host "4. Guarde los cambios y vuelva a conectar la red." -ForegroundColor Cyan
            Write-Host ""
            Write-Host "Cuando termine, vuelva al asistente y elija la opcion 3 para comprobar los cambios." -ForegroundColor Yellow
            Wait-PCJEnter -Message "Presione Enter para volver al asistente..."
            continue
        }

        if ($option -eq "2")
        {
            Clear-Host
            Write-UIHeader -Title "Cambiar DNS en el router"
            Write-Host ""
            Write-Host "Este cambio aplica el nuevo DNS a todos los equipos conectados a su red." -ForegroundColor Cyan
            Write-Host ""
            Write-Host "Primero, elija un solo par de DNS. No combine proveedores diferentes:" -ForegroundColor Yellow
            Write-Host "  Quad9:       9.9.9.9  y  149.112.112.112" -ForegroundColor Cyan
            Write-Host "  Cloudflare:  1.1.1.1  y  1.0.0.1" -ForegroundColor Cyan
            Write-Host "  Google:      8.8.8.8  y  8.8.4.4" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "Despues siga estos pasos:" -ForegroundColor Yellow
            $gateway = Get-LocalDefaultGateway
            if ($gateway)
            {
                Write-Host "1. Abra el navegador e ingrese a la configuracion del router: http://$gateway" -ForegroundColor Cyan
                Write-Host "   Esta direccion fue detectada automaticamente como la puerta de enlace de esta PC." -ForegroundColor DarkGray
                Write-Host "   Si no abre el panel, revise la etiqueta del modem/router o la guia de su proveedor de Internet." -ForegroundColor Yellow
            }
            else
            {
                Write-Host "1. Abra la direccion de configuracion de su router en el navegador." -ForegroundColor Cyan
                Write-Host "   Busquela en la etiqueta del modem/router o en la guia de su proveedor de Internet." -ForegroundColor Yellow
            }
            Write-Host "2. Busque un apartado llamado LAN, DHCP, Red local o Servidores DNS." -ForegroundColor Cyan
            Write-Host "3. Reemplace $RaspberryHost por el par de DNS que eligio arriba." -ForegroundColor Cyan
            Write-Host "4. Guarde los cambios y reconecte los equipos a la red." -ForegroundColor Cyan
            Write-Host ""
            Write-Host "El nombre exacto de cada apartado cambia segun la marca del router." -ForegroundColor Yellow
            Write-Host "Cuando termine, vuelva al asistente y elija la opcion 3 para comprobar los cambios." -ForegroundColor Cyan
            Write-Host "Solo proceda con la desinstalacion cuando confirme que esta PC ya no usa $RaspberryHost como DNS." -ForegroundColor Yellow
            Write-Host "No desinstale Pi-hole hasta confirmar que los equipos ya recibieron el nuevo DNS." -ForegroundColor Yellow
            Write-Host ""
            Wait-PCJEnter
            continue
        }

        if ($option -eq "3")
        {
            Clear-Host
            Write-UIHeader -Title "Comprobar cambios de DNS"
            Write-Host ""
            $updatedCheck = Get-LocalDNSPiHoleCheck -RaspberryHost $RaspberryHost

            if (-not $updatedCheck.CouldCheck)
            {
                Write-Host "[AVISO] No se pudo comprobar el DNS de esta PC automaticamente." -ForegroundColor Yellow
                Write-Host "Revise manualmente que ya no este configurada la IP $RaspberryHost como DNS." -ForegroundColor Cyan
            }
            elseif ($updatedCheck.UsesPiHole)
            {
                Write-Host "[AVISO] Esta PC todavia usa $RaspberryHost como DNS de Pi-hole." -ForegroundColor Yellow
                Write-Host "Vuelva a la opcion 1 o 2, aplique los cambios y reconecte la red antes de intentar otra vez." -ForegroundColor Cyan
            }
            else
            {
                Write-Host "[OK] CAMBIOS DETECTADOS CORRECTAMENTE" -ForegroundColor Green
                Write-Host "Esta PC ya no usa $RaspberryHost como DNS de Pi-hole." -ForegroundColor Green
                Write-Host "Puede volver al asistente y elegir la opcion 4 para desinstalar Pi-hole." -ForegroundColor Cyan
            }

            Write-Host ""
            Wait-PCJEnter -Message "Presione Enter para volver al asistente..."
            continue
        }

        if ($option -eq "4")
        {
            if (-not $dnsCheck.CouldCheck -or $dnsCheck.UsesPiHole)
            {
                Write-Host "[AVISO] Aun no es seguro abrir el desinstalador." -ForegroundColor Yellow
                Write-Host "Complete la opcion 1 o 2 y use la opcion 3 hasta que este asistente confirme el cambio de DNS en esta PC." -ForegroundColor Cyan
                Wait-PCJEnter
                continue
            }

            if (-not (Confirm-ToolAction -Title "Desinstalar Pi-hole" -Description "Quita Pi-hole de la Raspberry mediante su desinstalador oficial." -Duration "1 a 5 minutos" -Warning "Antes de continuar, cambie el DNS de su router o equipos. Si aun usan $RaspberryHost, podrian perder acceso a paginas por nombre."))
            {
                Write-Host "[INFO] Desinstalacion cancelada." -ForegroundColor Yellow
                Pause
                continue
            }

            Write-Host ""
            Write-Host "CONFIRMACION FINAL" -ForegroundColor Red
            Write-Host "Confirme que ya cambio el DNS de la red o de los equipos que utilizaban $RaspberryHost." -ForegroundColor Yellow
            $dnsConfirmation = Read-Host "Escriba SI para continuar"

            if ($dnsConfirmation -ine "SI")
            {
                Write-Host "[INFO] Desinstalacion cancelada. Pi-hole continua instalado." -ForegroundColor Yellow
                Pause
                continue
            }

            Write-Host "Esta accion eliminara Pi-hole, pero no borrara el sistema, Wi-Fi ni el acceso SSH de la Raspberry." -ForegroundColor Yellow
            $finalConfirmation = Read-Host "Escriba DESINSTALAR para abrir el desinstalador oficial"

            if ($finalConfirmation -ine "DESINSTALAR")
            {
                Write-Host "[INFO] Desinstalacion cancelada. Pi-hole continua instalado." -ForegroundColor Yellow
                Pause
                continue
            }

            Uninstall-RaspberryPiHole -RaspberryHost $RaspberryHost -User $User
            Pause
            return
        }

        if ($option -eq "5") { return }
    }
}


function Show-PiHoleMenu
{
    param
    (
        [string]$RaspberryHost,
        [string]$User,
        [string]$BackupFolder
    )

    while ($true)
    {
        Clear-Host
        Write-UIHeader -Title "Pi-hole"
        Write-Host ""

        $piHoleStatus = Get-RaspberryPiHoleInstallationStatus -RaspberryHost $RaspberryHost -User $User
        $statusSymbol = [char]0x25CF
        $statusColor = if ($piHoleStatus.Active) { "Green" } elseif ($piHoleStatus.Installed) { "Yellow" } else { "DarkGray" }
        Write-Host "Pi-hole:  $statusSymbol $($piHoleStatus.State)" -ForegroundColor $statusColor
        Write-Host ""
        Write-Host "Administre aqui las funciones relacionadas solo con Pi-hole." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "1. Instalar Pi-hole" -ForegroundColor White
        Write-Host "   Abre el asistente oficial para instalar y configurar Pi-hole.  5 a 15 minutos" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "2. Abrir panel web de Pi-hole" -ForegroundColor White
        Write-Host "   Abre el panel de administracion en su navegador con la IP de esta Raspberry." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "3. Comprobar acceso a Internet" -ForegroundColor White
        Write-Host "   Envia 4 comprobaciones a google.com antes de instalar o actualizar programas." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "4. Consultar estado de Pi-hole" -ForegroundColor White
        Write-Host "   Comprueba si Pi-hole esta instalado y si su servicio DNS esta activo." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "5. Reiniciar Pi-hole" -ForegroundColor White
        Write-Host "   Reinicia solo el servicio DNS de Pi-hole.  5 a 15 segundos" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "6. Listas de bloqueo (Gravity)" -ForegroundColor White
        Write-Host "   Actualiza o programa las listas de dominios bloqueados por Pi-hole." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "7. Resumen de actividad" -ForegroundColor White
        Write-Host "   Muestra el espacio ocupado por el historial DNS y datos basicos de Pi-hole." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "8. Comprobar dominio en listas" -ForegroundColor White
        Write-Host "   Busca si un dominio podria estar bloqueado por las listas configuradas." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "9. Historial DNS y registros" -ForegroundColor White
        Write-Host "   Ajusta cuanto tiempo se conservan consultas DNS o vacia solo el registro operativo." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "10. Preparar y desinstalar Pi-hole" -ForegroundColor White
        Write-Host "   Muestra DNS alternativos e instrucciones antes de quitar Pi-hole de forma segura." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "11. Volver" -ForegroundColor DarkGray
        Write-Host "   Regresa al menu principal sin realizar cambios." -ForegroundColor DarkGray
        Write-Host ""

        $piHoleOption = Read-UIChoice

        switch ($piHoleOption)
        {
            "1" {
                if ($piHoleStatus.Installed)
                {
                    Write-Host "[INFO] Pi-hole ya esta instalado. Use las demas opciones para administrarlo." -ForegroundColor Yellow
                    Pause
                }
                else
                {
                    Install-RaspberryPiHole -RaspberryHost $RaspberryHost -User $User
                    Pause
                }
            }
            "2" {
                if (-not $piHoleStatus.Installed)
                {
                    Write-Host "[INFO] Primero debe instalar Pi-hole para abrir su panel web." -ForegroundColor Yellow
                    Pause
                }
                else
                {
                    Open-PiHoleDashboard -RaspberryHost $RaspberryHost
                    Pause
                }
            }
            "3" {
                Show-RaspberryInternetCheck -RaspberryHost $RaspberryHost -User $User
                Pause
            }
            "4" {
                Clear-Host
                Write-UIHeader -Title "Estado de Pi-hole"
                Write-Host ""
                Write-Host "Resultado de la revision:" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "Pi-hole: $statusSymbol $($piHoleStatus.State)" -ForegroundColor $statusColor
                Write-Host ""

                if ($piHoleStatus.Active)
                {
                    Write-Host "Estado actual: Activo y funcionando correctamente." -ForegroundColor Green
                    Write-Host "Pi-hole esta atendiendo las consultas DNS de su red." -ForegroundColor Cyan
                }
                elseif ($piHoleStatus.Installed)
                {
                    Write-Host "Estado actual: Pi-hole esta instalado, pero su servicio DNS no esta activo." -ForegroundColor Yellow
                    Write-Host "Puede intentar reiniciarlo desde la opcion 'Reiniciar Pi-hole'." -ForegroundColor Cyan
                }
                else
                {
                    Write-Host "Estado actual: Pi-hole no esta instalado o no se pudo comprobar." -ForegroundColor Yellow
                    Write-Host "Use la opcion 'Instalar Pi-hole' si desea configurarlo en esta Raspberry." -ForegroundColor Cyan
                }

                Write-Host ""
                Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray
                Write-Host ""
                Write-Host "Presione Enter para volver al menu de Pi-hole..." -ForegroundColor DarkGray
                try
                {
                    do
                    {
                        $returnKey = [Console]::ReadKey($true)
                    }
                    while ($returnKey.Key -ne [ConsoleKey]::Enter)
                }
                catch
                {
                    Read-Host | Out-Null
                }
            }
            "5" {
                if (-not $piHoleStatus.Installed)
                {
                    Write-Host "[INFO] Primero debe instalar Pi-hole." -ForegroundColor Yellow
                    Pause
                }
                else
                {
                    Restart-RaspberryPiHole -RaspberryHost $RaspberryHost -User $User
                    Pause
                }
            }
            "6" {
                if (-not $piHoleStatus.Installed)
                {
                    Write-Host "[INFO] Primero debe instalar Pi-hole." -ForegroundColor Yellow
                    Pause
                }
                else
                {
                    Show-GravityAssistant -RaspberryHost $RaspberryHost -User $User
                }
            }
            "7" {
                if (-not $piHoleStatus.Installed)
                {
                    Write-Host "[INFO] Pi-hole no esta instalado en esta Raspberry." -ForegroundColor Yellow
                    Pause
                }
                else
                {
                    Show-PiHoleInsights -RaspberryHost $RaspberryHost -User $User
                    Pause
                }
            }
            "8" {
                if (-not $piHoleStatus.Installed)
                {
                    Write-Host "[INFO] Primero debe instalar Pi-hole." -ForegroundColor Yellow
                    Pause
                }
                else
                {
                    Show-PiHoleDomainCheck -RaspberryHost $RaspberryHost -User $User
                    Pause
                }
            }
            "9" {
                if (-not $piHoleStatus.Installed)
                {
                    Write-Host "[INFO] Primero debe instalar Pi-hole." -ForegroundColor Yellow
                    Pause
                }
                else
                {
                    Show-PiHoleHistoryAssistant -RaspberryHost $RaspberryHost -User $User
                }
            }
            "10" {
                if (-not $piHoleStatus.Installed)
                {
                    Write-Host "[INFO] Pi-hole no esta instalado en esta Raspberry." -ForegroundColor Yellow
                    Pause
                }
                else
                {
                    Show-PiHoleUninstallAssistant -RaspberryHost $RaspberryHost -User $User
                }
            }
            "11" { return }
        }
    }
}


function Show-CreateBackupAssistant
{
    param
    (
        [string]$RaspberryHost,
        [string]$User,
        [string]$BackupFolder
    )

    while ($true)
    {
        Clear-Host

        $driveRoot = [System.IO.Path]::GetPathRoot((Get-Item -LiteralPath $BackupFolder).FullName)
        $freeGB = [math]::Round((New-Object System.IO.DriveInfo($driveRoot)).AvailableFreeSpace / 1GB, 1)

        Write-UIHeader -Title "Asistente de respaldos"
        Write-Host ""
        Write-Host "Que desea respaldar?" -ForegroundColor Cyan
        Write-Host "Espacio libre actual en su PC: $freeGB GB" -ForegroundColor Green
        Write-Host ""
        Write-Host "1. Solo configuracion de Pi-hole" -ForegroundColor White
        Write-Host "   Incluye listas, dominios, clientes y ajustes." -ForegroundColor Cyan
        Write-Host "   Tamano habitual: 20 a 50 KB" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "2. Configuracion + historial DNS" -ForegroundColor White
        Write-Host "   Incluye todo lo anterior y las consultas DNS guardadas." -ForegroundColor Cyan
        Write-Host "   Tamano habitual: 20 a 30 MB" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "3. Imagen completa de la Raspberry" -ForegroundColor White
        Write-Host "   Incluye el sistema operativo y todos sus archivos." -ForegroundColor Cyan
        Write-Host "   Tamano habitual: varios GB" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "4. Cancelar" -ForegroundColor DarkGray
        Write-Host ""

        $assistantOption = Read-UIChoice

        switch ($assistantOption)
        {
            "1" {
                Backup-PiHole `
                    -RaspberryHost $RaspberryHost `
                    -User $User `
                    -BackupFolder $BackupFolder
                Pause
                return
            }

            "2" {
                Backup-PiHoleComplete `
                    -RaspberryHost $RaspberryHost `
                    -User $User `
                    -BackupFolder $BackupFolder
                Pause
                return
            }

            "3" {
                Backup-RaspberrySystem `
                    -RaspberryHost $RaspberryHost `
                    -User $User `
                    -BackupFolder $BackupFolder
                Pause
                return
            }

            "4" {
                return
            }
        }
    }
}


function Show-CleanupMenu
{
    param
    (
        [string]$BackupFolder
    )

    while ($true)
    {
        Clear-Host

        Write-UIHeader -Title "Borrar respaldos locales"
        Write-Host ""
        Write-Host "Que tipo de respaldo desea borrar para liberar espacio?" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "1. Solo configuracion de Pi-hole" -ForegroundColor White
        Write-Host "   Archivos pequenos con listas, dominios y ajustes." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "2. Configuracion + historial DNS de Pi-hole" -ForegroundColor White
        Write-Host "   Archivos con configuracion y consultas DNS guardadas." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "3. Imagen completa de la Raspberry" -ForegroundColor White
        Write-Host "   Archivos grandes con el sistema operativo completo." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "4. Borrar todos los respaldos locales" -ForegroundColor White
        Write-Host "   Elimina los respaldos de los tres tipos y libera todo su espacio." -ForegroundColor Cyan
        Write-Host "   Pedira dos confirmaciones antes de borrar." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "5. Cancelar" -ForegroundColor DarkGray
        Write-Host ""

        $cleanupOption = Read-UIChoice

        switch ($cleanupOption)
        {
            "1" {
                Show-CleanupPeriodMenu `
                    -Folder (Join-Path $BackupFolder "PiHole-Solo-Configuracion") `
                    -BackupType "Solo configuracion de Pi-hole"
            }

            "2" {
                Show-CleanupPeriodMenu `
                    -Folder (Join-Path $BackupFolder "PiHole-Configuracion-Historial-DNS") `
                    -BackupType "Configuracion + historial DNS de Pi-hole"
            }

            "3" {
                Show-CleanupPeriodMenu `
                    -Folder (Join-Path $BackupFolder "Sistema") `
                    -BackupType "Imagen completa del sistema operativo"
            }

            "4" {
                Remove-AllLocalBackups -BackupFolder $BackupFolder
                Pause
                return
            }

            "5" {
                return
            }
        }
    }
}


function Show-CleanupPeriodMenu
{
    param
    (
        [string]$Folder,
        [string]$BackupType
    )

    while ($true)
    {
        Clear-Host

        Write-UIHeader -Title "Asistente de limpieza"
        Write-Host ""
        Write-Host "Tipo: $BackupType" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Que respaldos desea eliminar?"
        Write-Host "Solo se eliminaran archivos locales del tipo seleccionado."
        Write-Host ""
        Write-Host "Eliminar respaldos de mas de:"
        Write-Host "1. 30 dias"
        Write-Host "2. 15 dias"
        Write-Host "3. 1 semana (7 dias)"
        Write-Host "4. 3 dias"
        Write-Host "5. Cancelar"
        Write-Host ""

        $periodOption = Read-UIChoice
        $days = 0

        switch ($periodOption)
        {
            "1" { $days = 30 }
            "2" { $days = 15 }
            "3" { $days = 7 }
            "4" { $days = 3 }
            "5" { return }
            default { continue }
        }

        Clean-OldBackups `
            -Folder $Folder `
            -BackupType $BackupType `
            -Days $days
        Pause
        return
    }
}


function Show-RestoreMenu
{
    param
    (
        [string]$RaspberryHost,
        [string]$User,
        [string]$BackupFolder
    )

    while ($true)
    {
        Clear-Host

        Write-UIHeader -Title "Asistente de restauracion"
        Write-Host ""

        Write-Host "Que desea restaurar?" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "1. Solo configuracion de Pi-hole" -ForegroundColor White
        Write-Host "   Restaura listas, dominios, clientes y ajustes." -ForegroundColor Cyan
        Write-Host "   No modifica el historial DNS ni el sistema operativo." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "2. Configuracion + historial DNS de Pi-hole" -ForegroundColor White
        Write-Host "   Restaura ajustes y consultas DNS guardadas." -ForegroundColor Cyan
        Write-Host "   Pi-hole se reiniciara brevemente durante el proceso." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "3. Imagen completa de la Raspberry" -ForegroundColor White
        Write-Host "   No se restaura desde aqui: apague la Raspberry y retire la microSD." -ForegroundColor Yellow
        Write-Host "   Grabela en su PC con Raspberry Pi Imager y vuelvala a conectar al Wi-Fi." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "4. Cancelar" -ForegroundColor DarkGray
        Write-Host ""

        $opcionRestaurar = Read-UIChoice

        switch ($opcionRestaurar)
        {
            "1" {
                Restore-PiHoleBackup `
                    -RaspberryHost $RaspberryHost `
                    -User $User `
                    -BackupFolder $BackupFolder
                Pause
            }

            "2" {
                Restore-PiHoleCompleteBackup `
                    -RaspberryHost $RaspberryHost `
                    -User $User `
                    -BackupFolder $BackupFolder
                Pause
            }

            "3" {
                Show-SystemRestoreInstructions `
                    -BackupFolder $BackupFolder
                Pause
            }

            "4" {
                return
            }
        }
    }
}


function Show-ToolsMenu
{
    param
    (
        [string]$RaspberryHost,
        [string]$User,
        [string]$ReportsFolder
    )

    while ($true)
    {
        Clear-Host
        Write-UIHeader -Title "Herramientas"
        Write-Host ""
        Write-Host "Que desea hacer?" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "1. Diagnostico de red"
        Write-Host "   Revisa router, internet, DNS y Pi-hole.  10 a 20 segundos" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "2. Salud y almacenamiento"
        Write-Host "   Revisa temperatura, alimentacion, memoria, discos y alertas de rendimiento." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "3. Estabilidad de Internet"
        Write-Host "   Mide respuesta, perdida de paquetes y descarga de prueba.  15 a 30 segundos" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "4. Servicios importantes"
        Write-Host "   Comprueba Pi-hole, SSH y los accesos remotos instalados." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "5. Hora y zona horaria"
        Write-Host "   Consulta y activa la sincronizacion automatica de hora." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "6. Limpiar espacio del sistema"
        Write-Host "   Limpia cache y registros tecnicos antiguos.  10 a 30 segundos" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "7. Crear informe de diagnostico"
        Write-Host "   Guarda un reporte para revisar o compartir.  10 a 20 segundos" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "8. Acceso remoto"
        Write-Host "   Administra Tailscale, ZeroTier, Cloudflare Tunnel y acceso grafico." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "9. Reiniciar Raspberry"
        Write-Host "   Reinicia todo el sistema.  1 a 3 minutos" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "10. Volver" -ForegroundColor DarkGray
        Write-Host ""

        $toolOption = Read-UIChoice

        switch ($toolOption)
        {
            "1" {
                Test-RaspberryNetwork -RaspberryHost $RaspberryHost -User $User
                Pause
            }

            "2" {
                Show-RaspberryHealthAssistant -RaspberryHost $RaspberryHost -User $User
                Pause
            }

            "3" {
                Show-RaspberryInternetQuality -RaspberryHost $RaspberryHost -User $User
                Pause
            }

            "4" {
                Show-RaspberryServicesAssistant -RaspberryHost $RaspberryHost -User $User
                Pause
            }

            "5" {
                Show-RaspberryTimeAssistant -RaspberryHost $RaspberryHost -User $User
            }

            "6" {
                Clear-RaspberrySystemSpace -RaspberryHost $RaspberryHost -User $User
                Pause
            }

            "7" {
                Save-RaspberryDiagnosticReport `
                    -RaspberryHost $RaspberryHost `
                    -User $User `
                    -ReportsFolder $ReportsFolder
                Pause
            }

            "8" {
                Show-RemoteAccessMenu -RaspberryHost $RaspberryHost -User $User
            }

            "9" {
                Restart-RaspberrySystem -RaspberryHost $RaspberryHost -User $User
                Pause
            }

            "10" {
                return
            }
        }
    }
}


function Show-ProfilesMenu
{
    param
    (
        [string]$ConfigFile
    )

    while ($true)
    {
        Clear-Host
        $activeProfile = Get-PCJActiveProfile -ConfigFile $ConfigFile
        Write-UIHeader -Title "Conexiones y perfiles"
        Write-Host ""
        Write-Host "Conexion actual:" -ForegroundColor Cyan
        Write-Host "  $($activeProfile.Name) - $($activeProfile.User)@$($activeProfile.Host)" -ForegroundColor Green
        Write-Host ""
        Write-Host "1. Cambiar a una Raspberry guardada"
        Write-Host "   Cambia de equipo sin volver a pedir contrasena." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "2. Agregar una Raspberry nueva"
        Write-Host "   Pide IP y usuario; la contrasena se usa solo una vez." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "3. Eliminar un usuario guardado"
        Write-Host "   Elimina el acceso local de un usuario que ya no desea usar." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "4. Cerrar sesion y borrar conexion actual"
        Write-Host "   Al abrir de nuevo pedira IP, usuario y contrasena otra vez." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "5. Volver"
        Write-Host ""

        $profileOption = Read-UIChoice

        switch ($profileOption)
        {
            "1" {
                $profiles = @(Get-PCJSavedProfiles)

                if ($profiles.Count -eq 0)
                {
                    Write-Host "[INFO] No hay perfiles guardados." -ForegroundColor Yellow
                    Pause
                    continue
                }

                Clear-Host
                Write-UIHeader -Title "Cambiar de Raspberry"
                Write-Host ""

                for ($index = 0; $index -lt $profiles.Count; $index++)
                {
                    $number = $index + 1
                    Write-Host "$number. $($profiles[$index].Name)" -ForegroundColor Cyan
                    Write-Host "   $($profiles[$index].User)@$($profiles[$index].Host)"
                }

                Write-Host ""
                Write-Host "0. Cancelar"
                $selection = Read-UIChoice -Prompt "Seleccione una Raspberry"
                $selectedNumber = 0

                if ([int]::TryParse($selection, [ref]$selectedNumber) -and
                    $selectedNumber -ge 1 -and $selectedNumber -le $profiles.Count)
                {
                    $selectedProfile = $profiles[$selectedNumber - 1]
                    Set-PCJActiveProfile -ConfigFile $ConfigFile -Profile $selectedProfile
                    Clear-Host
                    Write-UIHeader -Title "Usuario cambiado"
                    Write-Host ""
                    Write-Host "[OK] La sesion se cambio correctamente." -ForegroundColor Green
                    Write-Host "Ahora administrara: $($selectedProfile.Name) - $($selectedProfile.User)@$($selectedProfile.Host)" -ForegroundColor Cyan
                    Write-Host ""
                    Write-Host "Volviendo al menu principal en 3 segundos..." -ForegroundColor Yellow
                    Start-Sleep -Seconds 3
                    return $true
                }

                Pause
            }

            "2" {
                New-PCJProfile -ConfigFile $ConfigFile | Out-Null
                Pause
            }

            "3" {
                $profiles = @(Get-PCJSavedProfiles)

                if ($profiles.Count -eq 0)
                {
                    Write-Host "[INFO] No hay perfiles guardados." -ForegroundColor Yellow
                    Pause
                    continue
                }

                Clear-Host
                Write-UIHeader -Title "Eliminar conexion guardada"
                Write-Host ""
                Write-Host "Seleccione la conexion o usuario que desea borrar de esta PC." -ForegroundColor Yellow
                Write-Host "Esto no modifica ni elimina nada dentro de la Raspberry." -ForegroundColor DarkGray
                Write-Host ""

                for ($index = 0; $index -lt $profiles.Count; $index++)
                {
                    $number = $index + 1
                    $isOnline = Test-PCJProfileConnection -Profile $profiles[$index]
                    $statusSymbol = [char]0x25CF
                    $statusText = if ($isOnline) { "En linea" } else { "Fuera de linea" }
                    $statusColor = if ($isOnline) { "Green" } else { "DarkGray" }

                    Write-Host "$number. $statusSymbol $($profiles[$index].Name) - $($profiles[$index].User)@$($profiles[$index].Host) - $statusText" -ForegroundColor $statusColor
                }

                Write-Host ""
                Write-Host "0. Cancelar"
                $selection = Read-UIChoice -Prompt "Seleccione una conexion"
                $selectedNumber = 0

                if ([int]::TryParse($selection, [ref]$selectedNumber) -and
                    $selectedNumber -ge 1 -and $selectedNumber -le $profiles.Count)
                {
                    $selectedProfile = $profiles[$selectedNumber - 1]

                    if ($activeProfile -and $selectedProfile.Id -eq $activeProfile.Id)
                    {
                        Write-Host "[ERROR] Primero cambie a otra Raspberry antes de eliminar la conexion actual." -ForegroundColor Red
                    }
                    else
                    {
                        Remove-PCJProfile -ConfigFile $ConfigFile -Profile $selectedProfile | Out-Null
                    }
                }

                Pause
            }

            "4" {
                Write-Host ""
                Write-Host "Se eliminara el acceso local de '$($activeProfile.Name)'." -ForegroundColor Yellow
                Write-Host "La Raspberry no se modificara; solo se borrara esta conexion de la PC." -ForegroundColor Yellow
                Write-Host "Escriba SI para cerrar sesion o NO para cancelar sin hacer cambios." -ForegroundColor Cyan
                $confirmation = Read-Host "Confirmar cierre de sesion (SI/NO)"

                if ($confirmation -ieq "SI")
                {
                    SignOut-PCJProfile -ConfigFile $ConfigFile -Profile $activeProfile
                    exit
                }
            }

            "5" {
                return
            }
        }
    }
}


function Show-SettingsMenu
{
    param
    (
        [string]$ConfigFile
    )

    while ($true)
    {
        Clear-Host
        $activeProfile = Get-PCJActiveProfile -ConfigFile $ConfigFile
        Write-UIHeader -Title "Configuracion"
        Write-Host ""
        Write-Host "Que desea configurar?" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "1. Conexiones y perfiles"
        Write-Host "   Agregue, cambie o elimine accesos a sus Raspberry." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "2. Cambiar red Wi-Fi"
        Write-Host "   Consulte redes o conecte la Raspberry a otro Wi-Fi." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "3. Cambiar contrasena de la Raspberry"
        Write-Host "   Solicita la contrasena actual y la nueva; se guarda solo en la Raspberry." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "4. Reservar IP en el router"
        Write-Host "   Muestra los datos necesarios para evitar que cambie la IP de la Raspberry." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "5. Prioridad de redes Wi-Fi"
        Write-Host "   Decide que red conocida debe preferir la Raspberry al volver a conectarse." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "6. Volver" -ForegroundColor DarkGray
        Write-Host ""

        $settingsOption = Read-UIChoice

        switch ($settingsOption)
        {
            "1" {
                $profileChanged = Show-ProfilesMenu -ConfigFile $ConfigFile

                if ($profileChanged)
                {
                    return
                }
            }
            "2" {
                Show-RaspberryWifiAssistant `
                    -RaspberryHost $activeProfile.Host `
                    -User $activeProfile.User
            }
            "3" {
                Change-RaspberryUserPassword `
                    -RaspberryHost $activeProfile.Host `
                    -User $activeProfile.User
                Pause
            }
            "4" {
                Show-RaspberryIpReservationGuide -RaspberryHost $activeProfile.Host -User $activeProfile.User
                Pause
            }
            "5" {
                Show-RaspberryWifiPriorityAssistant -RaspberryHost $activeProfile.Host -User $activeProfile.User
            }
            "6" { return }
        }
    }
}


function Write-DashboardValue
{
    param
    (
        [string]$Label,
        [string]$Value,
        [ConsoleColor]$Color = [ConsoleColor]::White
    )

    Write-Host (" {0,-14}" -f $Label) -NoNewline
    Write-Host $Value -ForegroundColor $Color
}


function Show-DashboardLoading
{
    param
    (
        [string]$Stage = "Preparando el panel...",
        [int]$Percent = 0
    )

    Clear-Host
    Write-UIHeader -Title "PCJ Raspberry Toolkit" -Subtitle $version
    Write-Host ""
    Write-Host "Cargando la informacion de su Raspberry..." -ForegroundColor Cyan
    Write-Host "Espere unos segundos; el programa continuara automaticamente." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "[INFO] $Stage ($Percent%)" -ForegroundColor Cyan
}


function Update-DashboardLoading
{
    param
    (
        [string]$Stage,
        [int]$Percent
    )

    Write-Host "[INFO] $Stage ($Percent%)" -ForegroundColor Cyan
}


function Complete-DashboardLoading
{
    Write-Host "[OK] Panel listo. Abriendo menu principal..." -ForegroundColor Green
}


while ($true)
{
    Clear-Host

    $activeProfile = Get-PCJActiveProfile -ConfigFile $configFile

    if (-not $activeProfile)
    {
        Write-Host "No hay una conexion activa. Ejecute nuevamente el programa para configurar una." -ForegroundColor Yellow
        exit
    }

    $raspberryHost = $activeProfile.Host
    $user = $activeProfile.User

    Show-DashboardLoading -Stage "Comprobando conexion segura con la Raspberry..." -Percent 10

    $connection = Test-SSHConnection `
        -RaspberryHost $raspberryHost `
        -User $user

    $onlineSymbol = [char]0x25CF

    if ($connection -eq "OK")
    {
        Update-DashboardLoading -Stage "Consultando Pi-hole, DNS y recursos del sistema..." -Percent 35
        $dashboard = Get-RaspberryDashboardData `
            -RaspberryHost $raspberryHost `
            -User $user
        Update-DashboardLoading -Stage "Informacion principal recibida." -Percent 65
    }

    if ($connection -ne "OK")
    {
        Update-DashboardLoading -Stage "No fue posible conectar; preparando informacion disponible..." -Percent 65
    }

    $otherProfiles = @(Get-PCJSavedProfiles | Where-Object { $_.Id -ne $activeProfile.Id })
    $otherProfileStates = @()

    if ($otherProfiles.Count -gt 0)
    {
        for ($index = 0; $index -lt $otherProfiles.Count; $index++)
        {
            $otherProfile = $otherProfiles[$index]
            $progress = 65 + [math]::Floor((($index + 1) / $otherProfiles.Count) * 30)
            Update-DashboardLoading -Stage "Comprobando otras conexiones guardadas..." -Percent $progress
            $isOnline = (Test-Path $otherProfile.KeyFile) -and (Test-PCJProfileConnection -Profile $otherProfile)
            $otherProfileStates += [PSCustomObject]@{ Profile = $otherProfile; Online = $isOnline }
        }
    }

    Update-DashboardLoading -Stage "Panel listo." -Percent 100
    Complete-DashboardLoading
    Clear-Host

    Write-UIHeader -Title "PCJ Raspberry Toolkit" -Subtitle $version
    Write-Host ""

    if ($connection -eq "OK")
    {
        if ($dashboard -and $dashboard.PiHole -eq "active")
        {
            Write-DashboardValue -Label "Pi-hole:" -Value "$onlineSymbol Activo" -Color Green
        }
        else
        {
            Write-DashboardValue -Label "Pi-hole:" -Value "$onlineSymbol No disponible" -Color Red
        }

        Write-DashboardValue -Label "Raspberry:" -Value "$onlineSymbol Conectada ($raspberryHost)" -Color Green
        Write-DashboardValue -Label "Usuario:" -Value $user -Color Cyan

        $dnsValue = if ($dashboard -and $dashboard.DNS) { $dashboard.DNS } else { "No disponible" }
        $dnsProvider = Get-DNSProviderName -DNSValue $dnsValue
        $temperatureValue = if ($dashboard -and $dashboard.Temperature) { $dashboard.Temperature } else { "No disponible" }
        $memoryValue = if ($dashboard -and $dashboard.Memory) { $dashboard.Memory } else { "No disponible" }
        $diskValue = if ($dashboard -and $dashboard.Disk) { $dashboard.Disk } else { "No disponible" }

        Write-DashboardValue -Label "DNS:" -Value "$dnsValue  ($dnsProvider)" -Color Cyan
        Write-DashboardValue -Label "Temperatura:" -Value $temperatureValue -Color Yellow
        Write-DashboardValue -Label "Memoria RAM:" -Value $memoryValue -Color Cyan
        Write-DashboardValue -Label "Disco:" -Value $diskValue -Color Cyan
    }
    else
    {
        Write-DashboardValue -Label "Pi-hole:" -Value "No disponible" -Color DarkGray
        Write-DashboardValue -Label "Raspberry:" -Value "$onlineSymbol Sin conexion ($raspberryHost)" -Color Red
        Write-DashboardValue -Label "Usuario:" -Value $user -Color Cyan
        Write-DashboardValue -Label "DNS:" -Value "No disponible" -Color DarkGray
        Write-DashboardValue -Label "Temperatura:" -Value "No disponible" -Color DarkGray
        Write-DashboardValue -Label "Memoria RAM:" -Value "No disponible" -Color DarkGray
        Write-DashboardValue -Label "Disco:" -Value "No disponible" -Color DarkGray
    }

    if ($otherProfileStates.Count -gt 0)
    {
        Write-Host ""
        Write-Host "Otras conexiones activas:" -ForegroundColor Cyan

        foreach ($item in $otherProfileStates)
        {
            $statusSymbol = [char]0x25CF
            $statusText = if ($item.Online) { "En linea" } else { "Fuera de linea" }
            $statusColor = if ($item.Online) { "Green" } else { "DarkGray" }

            Write-Host "  $statusSymbol $($item.Profile.Name) ($($item.Profile.User)) - $statusText" -ForegroundColor $statusColor
        }
    }

    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "1. Estado"
    Write-Host "2. Descargar e instalar actualizaciones"
    Write-Host "3. Respaldos"
    Write-Host "4. Pi-hole"
    Write-Host "   Instalar, administrar listas, respaldar y restaurar Pi-hole." -ForegroundColor DarkGray
    Write-Host "5. Herramientas"
    Write-Host "6. Configuracion"
    Write-Host "7. Apagar Raspberry"
    Write-Host "   Apaga la Raspberry de forma segura antes de desconectarla de la energia." -ForegroundColor DarkGray
    Write-Host "8. Salir"
    Write-Host ""

    $opcion = Read-UIChoice

    switch ($opcion)
    {
        "1" {
            Get-RaspberryStatus `
                -RaspberryHost $raspberryHost `
                -User $user
            Pause
        }

        "2" {
            Update-Raspberry `
                -RaspberryHost $raspberryHost `
                -User $user
            Pause
        }

        "3" {
            Show-BackupMenu `
                -RaspberryHost $raspberryHost `
                -User $user `
                -BackupFolder $backupFolder
        }

        "4" {
            Show-PiHoleMenu `
                -RaspberryHost $raspberryHost `
                -User $user `
                -BackupFolder $backupFolder
        }

        "5" {
            Show-ToolsMenu `
                -RaspberryHost $raspberryHost `
                -User $user `
                -ReportsFolder $reportsFolder
        }

        "6" {
            Show-SettingsMenu -ConfigFile $configFile
        }

        "7" {
            Stop-RaspberrySystem `
                -RaspberryHost $raspberryHost `
                -User $user
            Pause
        }

        "8" {
            Close-PCJTemporarySession
            exit
        }
    }
}
