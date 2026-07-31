function Invoke-RaspberryManualUpdate
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    Clear-Host
    Write-UIHeader -Title "Actualizar ahora"
    Write-Host ""
    Write-Host "Busca e instala ahora mismo las actualizaciones disponibles del sistema." -ForegroundColor Cyan
    Write-Host "Esta opcion es manual: solo se ejecuta cuando usted la inicia." -ForegroundColor DarkGray
    Write-Host "Tiempo estimado: 2 a 15 minutos, segun las actualizaciones y su conexion." -ForegroundColor DarkGray
    Write-Host ""

    if (-not (Confirm-ToolAction -Title "Descargar e instalar actualizaciones" -Description "Actualizara la lista de paquetes y aplicara las actualizaciones disponibles ahora." -Duration "2 a 15 minutos" -Warning "Una vez iniciada, no cierre la ventana ni apague la Raspberry hasta que termine."))
    {
        Write-Host "[INFO] Actualizacion cancelada antes de iniciar." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "[INFO] Iniciando actualizacion de Raspberry..." -ForegroundColor Yellow
    Show-UIProgress -Stage "Preparando actualizacion..." -Percent 5

    $update = Invoke-SSHCommand `
        -RaspberryHost $RaspberryHost `
        -User $User `
        -Command "sudo apt-get update"

    if ($LASTEXITCODE -ne 0)
    {
        Complete-UIProgress
        Write-Host "[ERROR] No se pudo actualizar la lista de paquetes." -ForegroundColor Red
        return
    }

    Show-UIProgress -Stage "Lista de paquetes actualizada." -Percent 35
    Show-UIProgress -Stage "Actualizaciones encontradas. Instalando..." -Percent 55

    $upgrade = Invoke-SSHCommand `
        -RaspberryHost $RaspberryHost `
        -User $User `
        -Command "sudo apt-get full-upgrade -y"

    if ($LASTEXITCODE -ne 0)
    {
        Complete-UIProgress
        Write-Host "[ERROR] Fallo durante la actualizacion." -ForegroundColor Red
        return
    }

    Show-UIProgress -Stage "Sistema actualizado correctamente." -Percent 100
    Complete-UIProgress
    Write-Host "[OK] Sistema actualizado correctamente." -ForegroundColor Green
}


function Get-RaspberryAutomaticUpdatesStatus
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    $statusScript = @'
packages="$(dpkg-query -W -f='${db:Status-Status}\n' unattended-upgrades apt-listchanges 2>/dev/null | grep -c '^installed$')"
enabled="$(systemctl is-enabled unattended-upgrades 2>/dev/null || true)"
active="$(systemctl is-active unattended-upgrades 2>/dev/null || true)"
automatic="$(apt-config dump 2>/dev/null | grep -E '^APT::Periodic::Unattended-Upgrade "1";' | wc -l)"

echo "PCJ_PACKAGES=$packages"
echo "PCJ_ENABLED=$enabled"
echo "PCJ_ACTIVE=$active"
echo "PCJ_AUTOMATIC=$automatic"
'@

    $result = Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script $statusScript
    $rawText = @($result) -join [Environment]::NewLine
    $getValue = {
        param([string]$Name)
        $match = [regex]::Match($rawText, "(?m)^$Name=(.*)$")
        if ($match.Success) { return $match.Groups[1].Value.Trim() }
        return ""
    }

    return [PSCustomObject]@{
        PackagesInstalled = (& $getValue "PCJ_PACKAGES") -eq "2"
        Enabled = (& $getValue "PCJ_ENABLED")
        Active = (& $getValue "PCJ_ACTIVE")
        Automatic = (& $getValue "PCJ_AUTOMATIC") -eq "1"
    }
}


function Show-RaspberryAutomaticUpdates
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    while ($true)
    {
        Clear-Host
        Write-UIHeader -Title "Actualizaciones automaticas"
        Write-Host ""
        Write-Host "Mantiene protegida la Raspberry instalando automaticamente actualizaciones estables de seguridad." -ForegroundColor Cyan
        Write-Host "No sustituye la opcion 'Actualizar ahora': esa opcion instala manualmente todas las actualizaciones disponibles." -ForegroundColor DarkGray
        Write-Host ""

        $status = Get-RaspberryAutomaticUpdatesStatus -RaspberryHost $RaspberryHost -User $User
        $statusColor = if ($status.Automatic) { "Green" } else { "Yellow" }
        $statusText = if ($status.Automatic) { "Activadas" } else { "Desactivadas" }
        Write-Host "Actualizaciones automaticas: $statusText" -ForegroundColor $statusColor
        Write-Host "Servicio unattended-upgrades: $($status.Active)" -ForegroundColor DarkGray
        Write-Host ""

        Write-Host "Que desea hacer?"
        Write-Host ""
        Write-Host "1. Consultar estado"
        Write-Host "   Muestra si el servicio y las actualizaciones automaticas estan activos. No cambia nada." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "2. Activar actualizaciones automaticas"
        Write-Host "   Instala lo necesario y habilita la descarga e instalacion automatica de actualizaciones estables." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "3. Probar sin instalar cambios"
        Write-Host "   Simula una actualizacion automatica y muestra si la Raspberry esta lista. No instala ni elimina paquetes." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "4. Desactivar actualizaciones automaticas"
        Write-Host "   Evita instalaciones automaticas futuras. Podra seguir usando 'Actualizar ahora' manualmente." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "5. Volver"
        Write-Host "   Regresa al menu de actualizaciones sin modificar nada." -ForegroundColor DarkGray
        Write-Host ""

        $option = Read-UIChoice

        if ($option -eq "1") { continue }
        if ($option -eq "5") { return }

        if ($option -eq "2")
        {
            if ($status.Automatic)
            {
                Write-Host "[INFO] Las actualizaciones automaticas ya estan activadas." -ForegroundColor Yellow
                Pause
                continue
            }

            if (-not (Confirm-ToolAction -Title "Activar actualizaciones automaticas" -Description "Instalara unattended-upgrades y configurara la Raspberry para instalar actualizaciones estables automaticamente." -Duration "1 a 5 minutos" -Warning "En el futuro la Raspberry podra instalar actualizaciones de seguridad sin pedir confirmacion. Las actualizaciones manuales siguen siendo independientes."))
            {
                Write-Host "[INFO] Activacion cancelada. No se hicieron cambios." -ForegroundColor Yellow
                Pause
                continue
            }

            Show-UIProgress -Stage "Instalando componentes para actualizaciones automaticas..." -Percent 35
            $enableScript = @'
sudo apt-get update && sudo apt-get install -y unattended-upgrades apt-listchanges || exit 1
echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | sudo debconf-set-selections || exit 1
sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure unattended-upgrades || exit 1
sudo systemctl enable --now unattended-upgrades || exit 1
automatic="$(apt-config dump 2>/dev/null | grep -E '^APT::Periodic::Unattended-Upgrade "1";' | wc -l)"
if [ "$automatic" = "1" ]; then
    echo PCJ_AUTO_UPDATES_ENABLED
else
    echo PCJ_AUTO_UPDATES_VERIFY_FAILED
    exit 1
fi
'@
            $result = Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script $enableScript
            $rawText = @($result) -join [Environment]::NewLine

            if ($LASTEXITCODE -eq 0 -and $rawText -match "PCJ_AUTO_UPDATES_ENABLED")
            {
                Show-UIProgress -Stage "Actualizaciones automaticas activadas." -Percent 100
                Complete-UIProgress
                Write-Host "[OK] Las actualizaciones automaticas ya estan activadas." -ForegroundColor Green
                Write-Host "El servicio puede mostrarse como 'active (running)' o 'active (exited)': ambos estados son normales." -ForegroundColor DarkGray
            }
            else
            {
                Complete-UIProgress
                Write-Host "[ERROR] No se pudo activar o verificar las actualizaciones automaticas." -ForegroundColor Red
            }

            Pause
            continue
        }

        if ($option -eq "3")
        {
            if (-not $status.PackagesInstalled)
            {
                Write-Host "[INFO] Primero active las actualizaciones automaticas para instalar la herramienta de prueba." -ForegroundColor Yellow
                Pause
                continue
            }

            if (-not (Confirm-ToolAction -Title "Probar actualizaciones automaticas" -Description "Ejecutara una simulacion para comprobar que unattended-upgrade puede revisar actualizaciones." -Duration "1 a 3 minutos" -Warning "La simulacion no instala, actualiza ni elimina ningun paquete."))
            {
                Write-Host "[INFO] Prueba cancelada." -ForegroundColor Yellow
                Pause
                continue
            }

            Show-UIProgress -Stage "Simulando actualizacion automatica..." -Percent 50
            $result = Invoke-SSHCommand -RaspberryHost $RaspberryHost -User $User -Command "sudo unattended-upgrade --dry-run --debug 2>&1"
            $rawText = @($result) -join [Environment]::NewLine

            Complete-UIProgress
            if ($LASTEXITCODE -eq 0)
            {
                Show-UIProgress -Stage "Simulacion terminada sin instalar cambios." -Percent 100
                Complete-UIProgress
                Write-Host "[OK] La simulacion termino. No se instalaron cambios." -ForegroundColor Green
                if ($rawText -match "No packages found that can be upgraded")
                {
                    Write-Host "Resultado: no hay actualizaciones automaticas pendientes en este momento." -ForegroundColor Cyan
                }
                else
                {
                    Write-Host "Resultado: la Raspberry pudo revisar las actualizaciones disponibles." -ForegroundColor Cyan
                }
            }
            else
            {
                Write-Host "[ERROR] La simulacion no pudo terminar correctamente." -ForegroundColor Red
            }

            Pause
            continue
        }

        if ($option -eq "4")
        {
            if (-not $status.Automatic)
            {
                Write-Host "[INFO] Las actualizaciones automaticas ya estan desactivadas." -ForegroundColor Yellow
                Pause
                continue
            }

            if (-not (Confirm-ToolAction -Title "Desactivar actualizaciones automaticas" -Description "Desactivara la instalacion automatica futura de actualizaciones estables." -Duration "5 a 15 segundos" -Warning "La Raspberry dejara de instalar actualizaciones por si sola. Aun podra actualizarlas manualmente desde este programa."))
            {
                Write-Host "[INFO] Desactivacion cancelada. No se hicieron cambios." -ForegroundColor Yellow
                Pause
                continue
            }

            Show-UIProgress -Stage "Desactivando actualizaciones automaticas..." -Percent 60
            $disableScript = @'
echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean false' | sudo debconf-set-selections || exit 1
sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure unattended-upgrades || exit 1
automatic="$(apt-config dump 2>/dev/null | grep -E '^APT::Periodic::Unattended-Upgrade "1";' | wc -l)"
if [ "$automatic" = "0" ]; then
    echo PCJ_AUTO_UPDATES_DISABLED
else
    echo PCJ_AUTO_UPDATES_DISABLE_VERIFY_FAILED
    exit 1
fi
'@
            $result = Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script $disableScript
            $rawText = @($result) -join [Environment]::NewLine

            if ($LASTEXITCODE -eq 0 -and $rawText -match "PCJ_AUTO_UPDATES_DISABLED")
            {
                Show-UIProgress -Stage "Actualizaciones automaticas desactivadas." -Percent 100
                Complete-UIProgress
                Write-Host "[OK] Las actualizaciones automaticas fueron desactivadas." -ForegroundColor Green
            }
            else
            {
                Complete-UIProgress
                Write-Host "[ERROR] No se pudo desactivar o verificar la configuracion." -ForegroundColor Red
            }

            Pause
        }
    }
}


function Update-Raspberry
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    while ($true)
    {
        Clear-Host
        Write-UIHeader -Title "Actualizaciones"
        Write-Host ""
        Write-Host "Elija si desea actualizar la Raspberry ahora o mantener sus actualizaciones estables de forma automatica." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "1. Descargar e instalar actualizaciones ahora"
        Write-Host "   Busca e instala manualmente las actualizaciones disponibles en este momento." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "2. Configurar actualizaciones automaticas"
        Write-Host "   Instala actualizaciones estables de seguridad en el futuro, sin tener que abrir el programa." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "3. Volver"
        Write-Host "   Regresa al menu principal sin modificar nada." -ForegroundColor DarkGray
        Write-Host ""

        switch (Read-UIChoice)
        {
            "1" { Invoke-RaspberryManualUpdate -RaspberryHost $RaspberryHost -User $User; Pause }
            "2" { Show-RaspberryAutomaticUpdates -RaspberryHost $RaspberryHost -User $User }
            "3" { return }
            default { Write-Host "[ERROR] Seleccione una opcion valida." -ForegroundColor Red; Pause }
        }
    }
}
