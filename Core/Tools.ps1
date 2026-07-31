function Confirm-ToolAction
{
    param
    (
        [string]$Title,
        [string]$Description,
        [string]$Duration,
        [string]$Warning
    )

    Clear-Host
    Write-UIHeader -Title $Title
    Write-Host ""
    Write-Host $Description -ForegroundColor Cyan
    Write-Host "Tiempo estimado: $Duration" -ForegroundColor Cyan

    if ($Warning)
    {
        Write-Host $Warning -ForegroundColor Yellow
    }

    Write-Host "Una vez iniciada la accion, espere a que termine; no se recomienda cancelarla a mitad." -ForegroundColor Yellow

    Write-Host ""
    Write-Host "1. Iniciar"
    Write-Host "2. Cancelar"
    Write-Host ""

    return ((Read-UIChoice) -eq "1")
}


function Confirm-RemoteToolUninstall
{
    param
    (
        [string]$ToolName,
        [string]$Description
    )

    if (-not (Confirm-ToolAction `
        -Title "Desinstalar $ToolName" `
        -Description $Description `
        -Duration "30 segundos a 2 minutos" `
        -Warning "Se cerrara el acceso remoto de este servicio. Pi-hole y sus perfiles SSH guardados en esta PC no se modificaran."))
    {
        return $false
    }

    Write-Host ""
    Write-Host "CONFIRMACION FINAL" -ForegroundColor Red
    Write-Host "Esta accion quitara $ToolName de la Raspberry." -ForegroundColor Yellow
    Write-Host "Escriba DESINSTALAR para continuar, o cualquier otra cosa para cancelar." -ForegroundColor Yellow
    $confirmation = Read-Host "Confirmar desinstalacion"

    return ($confirmation -ieq "DESINSTALAR")
}


function Convert-SecureStringToPlainText
{
    param
    (
        [Security.SecureString]$SecureValue
    )

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)

    try
    {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally
    {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}


function Change-RaspberryUserPassword
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    if (-not (Confirm-ToolAction `
        -Title "Cambiar contrasena de la Raspberry" `
        -Description "Cambia la contrasena del usuario '$User' que inicia sesion en esta Raspberry." `
        -Duration "10 a 30 segundos" `
        -Warning "La nueva contrasena se guarda solo en la Raspberry. El programa continuara usando su llave SSH y no guardara ninguna contrasena."))
    {
        Write-Host "[INFO] Cambio de contrasena cancelado." -ForegroundColor Yellow
        return
    }

    Clear-Host
    Write-UIHeader -Title "Cambiar contrasena de la Raspberry"
    Write-Host ""
    Write-Host "Usuario de la Raspberry: $User" -ForegroundColor Cyan
    Write-Host "Las contrasenas se muestran con asteriscos y no se guardan en esta PC." -ForegroundColor Cyan
    Write-Host "Escriba 0 en la contrasena actual para cancelar y volver." -ForegroundColor DarkGray
    Write-Host ""

    $currentPassword = Read-Host "Contrasena actual (asteriscos)" -AsSecureString

    if ($currentPassword.Length -eq 1 -and (Convert-SecureStringToPlainText -SecureValue $currentPassword) -eq "0")
    {
        $currentPassword.Dispose()
        Write-Host "[INFO] Cambio de contrasena cancelado." -ForegroundColor Yellow
        return
    }

    if ($currentPassword.Length -eq 0)
    {
        $currentPassword.Dispose()
        Write-Host "[ERROR] La contrasena actual no puede estar vacia." -ForegroundColor Red
        return
    }

    $newPassword = Read-ConfirmedSecurePassword -Prompt "Nueva contrasena (asteriscos)"

    if (-not $newPassword)
    {
        $currentPassword.Dispose()
        return
    }

    $currentText = ""
    $newText = ""

    try
    {
        $currentText = Convert-SecureStringToPlainText -SecureValue $currentPassword
        $newText = Convert-SecureStringToPlainText -SecureValue $newPassword

        if ($newText -match "[:`r`n]")
        {
            Write-Host "[ERROR] La nueva contrasena no puede contener dos puntos ni saltos de linea." -ForegroundColor Red
            return
        }

        if ($newText.Length -lt 8)
        {
            Write-Host "[ERROR] Use una nueva contrasena de al menos 8 caracteres." -ForegroundColor Red
            return
        }

        $changeScript = @'
import base64
import crypt
import re
import spwd
import subprocess
import sys

current = base64.b64decode(sys.stdin.readline().strip()).decode('utf-8')
new = base64.b64decode(sys.stdin.readline().strip()).decode('utf-8')
user = sys.stdin.readline().strip()

if not re.fullmatch(r'[a-z_][a-z0-9_-]*[$]?', user):
    print('PCJ_PASSWORD_ERROR')
    sys.exit(2)

stored_hash = spwd.getspnam(user).sp_pwdp
if crypt.crypt(current, stored_hash) != stored_hash:
    print('PCJ_PASSWORD_INVALID')
    sys.exit(3)

result = subprocess.run(['chpasswd'], input=(user + ':' + new + '\n').encode('utf-8'), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
if result.returncode == 0:
    print('PCJ_PASSWORD_OK')
else:
    print('PCJ_PASSWORD_ERROR')
    sys.exit(result.returncode)
'@

        $encodedScript = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($changeScript))
        $remoteCommand = "bash -c 'sudo python3 <(echo $encodedScript | base64 -d)'"
        $inputLines = @(
            [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($currentText)),
            [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($newText)),
            $User
        )

        $result = Invoke-SSHCommandWithInput `
            -RaspberryHost $RaspberryHost `
            -User $User `
            -Command $remoteCommand `
            -InputLines $inputLines

        if ($result.ExitCode -eq 0 -and $result.Output -match "PCJ_PASSWORD_OK")
        {
            Write-Host "[OK] La contrasena de la Raspberry se cambio correctamente." -ForegroundColor Green
            Write-Host "El programa seguira funcionando con su llave SSH; no tendra que escribir la nueva contrasena para usar los menus." -ForegroundColor Cyan
        }
        elseif ($result.Output -match "PCJ_PASSWORD_INVALID")
        {
            Write-Host "[ERROR] La contrasena actual no es correcta. No se realizo ningun cambio." -ForegroundColor Red
        }
        else
        {
            Write-Host "[ERROR] No se pudo cambiar la contrasena de la Raspberry." -ForegroundColor Red
        }
    }
    finally
    {
        $currentText = ""
        $newText = ""
        $currentPassword.Dispose()
        $newPassword.Dispose()
    }
}


function Get-RaspberryTailscaleStatus
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    $statusScript = @'
if ! command -v tailscale >/dev/null 2>&1; then
    echo PCJ_TAILSCALE_NOT_INSTALLED
    exit 0
fi

if ! systemctl is-active --quiet tailscaled; then
    echo PCJ_TAILSCALE_STOPPED
    exit 0
fi

sudo tailscale status --json 2>/dev/null || echo PCJ_TAILSCALE_STATUS_ERROR
'@

    $result = Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script $statusScript
    $rawText = @($result) -join [Environment]::NewLine

    if ($rawText -match "PCJ_TAILSCALE_NOT_INSTALLED")
    {
        return [PSCustomObject]@{ Installed = $false; Online = $false; State = "No instalado"; IP = ""; Name = "" }
    }

    if ($rawText -match "PCJ_TAILSCALE_STOPPED")
    {
        return [PSCustomObject]@{ Installed = $true; Online = $false; State = "Servicio detenido"; IP = ""; Name = "" }
    }

    try
    {
        $status = $rawText | ConvertFrom-Json
        $tailscaleIP = @($status.Self.TailscaleIPs | Select-Object -First 1)[0]
        $deviceName = ($status.Self.DNSName -replace "\.$", "")
        $isOnline = ($status.BackendState -eq "Running") -and ($status.Self.Online -ne $false)

        return [PSCustomObject]@{
            Installed = $true
            Online = $isOnline
            State = $status.BackendState
            IP = $tailscaleIP
            Name = $deviceName
        }
    }
    catch
    {
        return [PSCustomObject]@{ Installed = $true; Online = $false; State = "No se pudo consultar"; IP = ""; Name = "" }
    }
}


function Get-RaspberryPiHoleListeningMode
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    $statusScript = @'
if ! command -v pihole-FTL >/dev/null 2>&1; then
    echo PCJ_PIHOLE_NOT_INSTALLED
    exit 0
fi

mode="$(sudo pihole-FTL --config dns.listeningMode 2>/dev/null | tail -n 1 | tr -d '\r\n')"
previous=""
if [ -f /etc/pihole/pcj-raspberry-tailscale-listeningmode ]; then
    previous="$(sudo cat /etc/pihole/pcj-raspberry-tailscale-listeningmode 2>/dev/null | tr -d '\r\n')"
fi

echo "PCJ_MODE=$mode"
echo "PCJ_PREVIOUS=$previous"
'@

    $result = Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script $statusScript
    $rawText = @($result) -join [Environment]::NewLine

    if ($rawText -match "PCJ_PIHOLE_NOT_INSTALLED")
    {
        return [PSCustomObject]@{ Installed = $false; Mode = ""; PreviousMode = "" }
    }

    $modeMatch = [regex]::Match($rawText, "(?m)^PCJ_MODE=(.+)$")
    $previousMatch = [regex]::Match($rawText, "(?m)^PCJ_PREVIOUS=(.*)$")

    return [PSCustomObject]@{
        Installed = $true
        Mode = if ($modeMatch.Success) { $modeMatch.Groups[1].Value.Trim() } else { "No disponible" }
        PreviousMode = if ($previousMatch.Success) { $previousMatch.Groups[1].Value.Trim() } else { "" }
    }
}


function Show-TailscalePiHoleDnsAssistant
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    while ($true)
    {
        Clear-Host
        Write-UIHeader -Title "Pi-hole DNS mediante Tailscale"
        Write-Host ""
        Write-Host "Esta opcion permite que sus equipos autorizados en Tailscale usen Pi-hole como servidor DNS." -ForegroundColor Cyan
        Write-Host "Es util si desea bloquear anuncios y usar sus listas de Pi-hole tambien fuera de casa." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "Importante:" -ForegroundColor Yellow
        Write-Host "Para lograrlo, Pi-hole respondera DNS por todas sus interfaces, incluida Tailscale." -ForegroundColor Yellow
        Write-Host "No abra el puerto DNS (53) de la Raspberry hacia Internet. Mantenga su router y firewall protegidos." -ForegroundColor Yellow
        Write-Host ""

        $dnsStatus = Get-RaspberryPiHoleListeningMode -RaspberryHost $RaspberryHost -User $User

        if (-not $dnsStatus.Installed)
        {
            Write-Host "Pi-hole: No instalado o no disponible." -ForegroundColor Red
            Write-Host "Instale Pi-hole antes de configurar su DNS mediante Tailscale." -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "1. Volver a Tailscale"
            Write-Host ""

            if ((Read-UIChoice) -eq "1") { return }
            continue
        }

        $modeColor = if ($dnsStatus.Mode -eq "ALL") { "Green" } else { "Yellow" }
        Write-Host "Modo DNS actual de Pi-hole: $($dnsStatus.Mode)" -ForegroundColor $modeColor

        if ($dnsStatus.Mode -eq "ALL")
        {
            Write-Host "Estado: Pi-hole ya puede responder por la interfaz de Tailscale." -ForegroundColor Green
        }
        else
        {
            Write-Host "Estado: Aun no esta preparado para atender DNS mediante Tailscale." -ForegroundColor DarkGray
        }

        if ($dnsStatus.PreviousMode)
        {
            Write-Host "Configuracion anterior guardada: $($dnsStatus.PreviousMode)" -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host "Que desea hacer?"
        Write-Host ""
        Write-Host "1. Consultar nuevamente la configuracion"
        Write-Host "   Actualiza y muestra el modo DNS actual de Pi-hole." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "2. Permitir DNS de Pi-hole por Tailscale"
        Write-Host "   Guarda el modo actual, cambia a ALL, reinicia Pi-hole y verifica el resultado." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "3. Restaurar configuracion anterior"
        Write-Host "   Recupera el modo que tenia Pi-hole antes de activar esta opcion." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "4. Volver"
        Write-Host "   Regresa al menu de Tailscale sin modificar nada." -ForegroundColor DarkGray
        Write-Host ""

        $option = Read-UIChoice

        if ($option -eq "1")
        {
            continue
        }

        if ($option -eq "4")
        {
            return
        }

        if ($option -eq "2")
        {
            if ($dnsStatus.Mode -eq "ALL")
            {
                Write-Host "[INFO] Pi-hole ya esta configurado en modo ALL. No se hicieron cambios." -ForegroundColor Yellow
                Pause
                continue
            }

            if (-not (Confirm-ToolAction `
                -Title "Permitir DNS de Pi-hole por Tailscale" `
                -Description "Guardara el modo DNS actual ($($dnsStatus.Mode)), cambiara Pi-hole a ALL y reiniciara solo el servicio DNS." `
                -Duration "5 a 15 segundos" `
                -Warning "Esto permite consultas DNS por todas las interfaces de la Raspberry. Mantenga el puerto 53 bloqueado desde Internet y use solo equipos autorizados."))
            {
                Write-Host "[INFO] Configuracion cancelada. Pi-hole no fue modificado." -ForegroundColor Yellow
                Pause
                continue
            }

            Show-UIProgress -Stage "Guardando configuracion DNS actual..." -Percent 25
            Show-UIProgress -Stage "Preparando Pi-hole para Tailscale..." -Percent 55

            $enableScript = @'
current="$(sudo pihole-FTL --config dns.listeningMode 2>/dev/null | tail -n 1 | tr -d '\r\n')"
case "$current" in
    LOCAL|SINGLE|BIND|ALL|NONE) ;;
    *) echo PCJ_INVALID_MODE; exit 1 ;;
esac

printf '%s' "$current" | sudo tee /etc/pihole/pcj-raspberry-tailscale-listeningmode >/dev/null || exit 1
sudo pihole-FTL --config dns.listeningMode ALL || exit 1
sudo systemctl restart pihole-FTL || exit 1
verified="$(sudo pihole-FTL --config dns.listeningMode 2>/dev/null | tail -n 1 | tr -d '\r\n')"
if [ "$verified" = "ALL" ]; then
    echo PCJ_DNS_TAILSCALE_READY
else
    echo PCJ_DNS_TAILSCALE_VERIFY_FAILED
    exit 1
fi
'@

            $result = Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script $enableScript
            $rawText = @($result) -join [Environment]::NewLine

            if ($LASTEXITCODE -eq 0 -and $rawText -match "PCJ_DNS_TAILSCALE_READY")
            {
                Show-UIProgress -Stage "Pi-hole esta listo para DNS mediante Tailscale." -Percent 100
                Complete-UIProgress
                Write-Host "[OK] Pi-hole ahora acepta DNS mediante Tailscale." -ForegroundColor Green
                Write-Host "Verificacion: dns.listeningMode = ALL" -ForegroundColor Cyan
                Write-Host "En Tailscale, configure como DNS la IP Tailscale mostrada para esta Raspberry." -ForegroundColor DarkGray
            }
            else
            {
                Complete-UIProgress
                Write-Host "[ERROR] No se pudo completar o verificar la configuracion DNS." -ForegroundColor Red
                Write-Host "Pi-hole puede seguir usando su modo anterior. Consulte el estado antes de intentar de nuevo." -ForegroundColor Yellow
            }

            Pause
            continue
        }

        if ($option -eq "3")
        {
            if (-not $dnsStatus.PreviousMode)
            {
                Write-Host "[INFO] No hay una configuracion anterior guardada por este programa." -ForegroundColor Yellow
                Write-Host "No se modifico Pi-hole." -ForegroundColor DarkGray
                Pause
                continue
            }

            if (-not (Confirm-ToolAction `
                -Title "Restaurar configuracion DNS anterior" `
                -Description "Restaurara dns.listeningMode a $($dnsStatus.PreviousMode) y reiniciara el servicio Pi-hole." `
                -Duration "5 a 15 segundos" `
                -Warning "Los equipos conectados por Tailscale podrian dejar de usar Pi-hole como DNS despues de este cambio."))
            {
                Write-Host "[INFO] Restauracion cancelada. Pi-hole no fue modificado." -ForegroundColor Yellow
                Pause
                continue
            }

            Show-UIProgress -Stage "Restaurando configuracion DNS anterior..." -Percent 50

            $restoreScript = @'
previous="$(sudo cat /etc/pihole/pcj-raspberry-tailscale-listeningmode 2>/dev/null | tr -d '\r\n')"
case "$previous" in
    LOCAL|SINGLE|BIND|ALL|NONE) ;;
    *) echo PCJ_NO_VALID_PREVIOUS_MODE; exit 1 ;;
esac

sudo pihole-FTL --config dns.listeningMode "$previous" || exit 1
sudo systemctl restart pihole-FTL || exit 1
verified="$(sudo pihole-FTL --config dns.listeningMode 2>/dev/null | tail -n 1 | tr -d '\r\n')"
if [ "$verified" = "$previous" ]; then
    sudo rm -f /etc/pihole/pcj-raspberry-tailscale-listeningmode
    echo "PCJ_DNS_RESTORED=$verified"
else
    echo PCJ_DNS_RESTORE_VERIFY_FAILED
    exit 1
fi
'@

            $result = Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script $restoreScript
            $rawText = @($result) -join [Environment]::NewLine

            if ($LASTEXITCODE -eq 0 -and $rawText -match "PCJ_DNS_RESTORED=")
            {
                $restoredMode = ([regex]::Match($rawText, "PCJ_DNS_RESTORED=(\\w+)")).Groups[1].Value
                Show-UIProgress -Stage "Configuracion DNS anterior restaurada." -Percent 100
                Complete-UIProgress
                Write-Host "[OK] Pi-hole volvio al modo DNS: $restoredMode" -ForegroundColor Green
            }
            else
            {
                Complete-UIProgress
                Write-Host "[ERROR] No se pudo restaurar la configuracion DNS anterior." -ForegroundColor Red
            }

            Pause
        }
    }
}


function Show-TailscaleRemoteAccess
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    while ($true)
    {
        Clear-Host
        Write-UIHeader -Title "Acceso remoto con Tailscale"
        Write-Host ""

        $tailscaleStatus = Get-RaspberryTailscaleStatus -RaspberryHost $RaspberryHost -User $User
        $statusSymbol = [char]0x25CF

        if (-not $tailscaleStatus.Installed)
        {
            Write-Host "Tailscale:  $statusSymbol No instalado" -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "Tailscale permite administrar la Raspberry desde fuera de casa mediante una red privada segura." -ForegroundColor Cyan
            Write-Host "Instalelo y vinculelo primero en la Raspberry para poder activar o cerrar este acceso desde aqui." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "1. Actualizar estado"
            Write-Host "   Vuelve a comprobar si Tailscale esta instalado y conectado." -ForegroundColor DarkGray
            Write-Host "2. Instalar Tailscale"
            Write-Host "   Descarga e instala Tailscale desde su instalador oficial.  1 a 5 minutos" -ForegroundColor DarkGray
            Write-Host "3. Volver"
            Write-Host "   Regresa al menu de acceso remoto sin realizar cambios." -ForegroundColor DarkGray
            Write-Host ""

            $notInstalledOption = Read-UIChoice
            if ($notInstalledOption -eq "3")
            {
                return
            }

            if ($notInstalledOption -eq "2")
            {
                if (-not (Confirm-ToolAction -Title "Instalar Tailscale" -Description "Descarga e instala Tailscale desde el repositorio oficial." -Duration "1 a 5 minutos" -Warning "La instalacion descarga software de Internet. No iniciara sesion ni conectara la Raspberry a una cuenta automaticamente."))
                {
                    Write-Host "[INFO] Instalacion cancelada." -ForegroundColor Yellow
                    Pause
                    continue
                }

                Show-UIProgress -Stage "Preparando instalacion de Tailscale..." -Percent 10
                Show-UIProgress -Stage "Descargando e instalando Tailscale..." -Percent 40
                $installResult = Invoke-SSHCommand -RaspberryHost $RaspberryHost -User $User -Command "if ! command -v curl >/dev/null 2>&1; then sudo apt-get update && sudo apt-get install -y curl; fi; curl -fsSL https://tailscale.com/install.sh | sudo sh 2>&1"

                if ($LASTEXITCODE -eq 0)
                {
                    Show-UIProgress -Stage "Tailscale instalado correctamente." -Percent 100
                    Complete-UIProgress
                    Write-Host "[OK] Tailscale se instalo correctamente. Seleccione Activar acceso remoto para vincularlo a su cuenta." -ForegroundColor Green
                }
                else
                {
                    Complete-UIProgress
                    Write-Host "[ERROR] No se pudo instalar Tailscale." -ForegroundColor Red
                }

                Pause
            }

            continue
        }

        $statusColor = if ($tailscaleStatus.Online) { "Green" } else { "DarkGray" }
        $statusText = if ($tailscaleStatus.Online) { "Conectado" } else { $tailscaleStatus.State }
        Write-Host "Tailscale:  $statusSymbol $statusText" -ForegroundColor $statusColor

        if ($tailscaleStatus.IP)
        {
            Write-Host "IP Tailscale: $($tailscaleStatus.IP)" -ForegroundColor Cyan
        }

        if ($tailscaleStatus.Name)
        {
            Write-Host "Nombre remoto: $($tailscaleStatus.Name)" -ForegroundColor Cyan
        }

        Write-Host ""
        Write-Host "Como confirmar la conexion:" -ForegroundColor Cyan
        Write-Host "Cuando vea 'Conectado' en verde y aparezca una IP Tailscale, la Raspberry ya esta vinculada." -ForegroundColor DarkGray
        Write-Host "No necesita crear un usuario en la Raspberry: Tailscale usa la cuenta autorizada mediante su enlace de inicio de sesion." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "1. Actualizar estado"
        Write-Host "   Vuelve a comprobar la conexion, IP y nombre remoto de Tailscale." -ForegroundColor DarkGray
        Write-Host "2. Iniciar sesion o activar Tailscale"
        Write-Host "   La primera vez muestra un enlace para vincular la Raspberry a su cuenta; despues solo la conecta." -ForegroundColor DarkGray
        Write-Host "3. Cerrar acceso remoto con Tailscale"
        Write-Host "   Desconecta Tailscale temporalmente, sin borrarlo ni perder su configuracion." -ForegroundColor DarkGray
        Write-Host "4. Usar Pi-hole como DNS por Tailscale"
        Write-Host "   Permite que equipos autorizados en Tailscale consulten el DNS de Pi-hole." -ForegroundColor DarkGray
        Write-Host "5. Activar SSH protegido por Tailscale"
        Write-Host "   Permite acceso SSH seguro por Tailscale sin abrir puertos en el router." -ForegroundColor DarkGray
        Write-Host "6. Desinstalar Tailscale"
        Write-Host "   Elimina Tailscale de la Raspberry si ya no desea utilizar este acceso remoto." -ForegroundColor Yellow
        Write-Host "7. Volver"
        Write-Host "   Regresa al menu de acceso remoto sin realizar cambios." -ForegroundColor DarkGray
        Write-Host ""

        $option = Read-UIChoice

        if ($option -eq "1")
        {
            continue
        }

        if ($option -eq "7")
        {
            return
        }

        if ($option -eq "2")
        {
            if (-not (Confirm-ToolAction `
                -Title "Iniciar sesion o activar Tailscale" `
                -Description "Conecta esta Raspberry a Tailscale. Si es la primera vez, mostrara un enlace para iniciar sesion y autorizarla." `
                -Duration "5 a 20 segundos" `
                -Warning "Abra el enlace que aparezca, inicie sesion en Tailscale y autorice esta Raspberry. No se guarda su contrasena en el programa."))
            {
                Write-Host "[INFO] Activacion cancelada." -ForegroundColor Yellow
                Pause
                continue
            }

            $output = Invoke-SSHCommand -RaspberryHost $RaspberryHost -User $User -Command "sudo systemctl start tailscaled && sudo tailscale up 2>&1"

            if ($LASTEXITCODE -eq 0)
            {
                $updatedStatus = Get-RaspberryTailscaleStatus -RaspberryHost $RaspberryHost -User $User
                $loginUrl = @($output | Select-String -Pattern "https://login\.tailscale\.com/\S+" | ForEach-Object { $_.Matches.Value } | Select-Object -First 1)[0]

                Write-Host ""
                Write-Host "Resultado de la conexion:" -ForegroundColor Cyan

                if ($updatedStatus.Online)
                {
                    Write-Host "[OK] TAILSCALE CONECTADO Y VINCULADO" -ForegroundColor Green

                    if ($updatedStatus.IP)
                    {
                        Write-Host "IP Tailscale de esta Raspberry: $($updatedStatus.IP)" -ForegroundColor Cyan
                    }

                    if ($updatedStatus.Name)
                    {
                        Write-Host "Nombre remoto: $($updatedStatus.Name)" -ForegroundColor Cyan
                    }

                    Write-Host ""
                    Write-Host "Siguiente paso:" -ForegroundColor Cyan
                    Write-Host "Instale Tailscale en su otro equipo o telefono e inicie sesion con la misma cuenta." -ForegroundColor DarkGray
                    Write-Host "Despues podra acceder a esta Raspberry usando la IP Tailscale mostrada arriba." -ForegroundColor DarkGray
                    Write-Host "No necesita agregar otro usuario dentro de la Raspberry." -ForegroundColor DarkGray
                }
                elseif ($loginUrl)
                {
                    Write-Host "[INFO] FALTA AUTORIZAR ESTA RASPBERRY" -ForegroundColor Yellow
                    Write-Host "Tailscale entrego un enlace para iniciar sesion y vincular el equipo:" -ForegroundColor Cyan
                    Write-Host $loginUrl -ForegroundColor Cyan
                    Write-Host ""
                    Write-Host "Siguientes pasos:" -ForegroundColor Cyan
                    Write-Host "1. Abra el enlace en el navegador e inicie sesion en su cuenta de Tailscale." -ForegroundColor DarkGray
                    Write-Host "2. Autorice esta Raspberry cuando Tailscale lo solicite." -ForegroundColor DarkGray
                    Write-Host "3. Vuelva aqui y elija 'Actualizar estado'. Si aparece verde, ya esta conectada." -ForegroundColor DarkGray
                    Write-Host ""
                    Write-Host "Que desea hacer?"
                    Write-Host "1. Abrir enlace de autorizacion en el navegador"
                    Write-Host "   Abre el enlace oficial de Tailscale en esta PC." -ForegroundColor Cyan
                    Write-Host "2. Volver al menu de Tailscale"
                    Write-Host "   Podra actualizar el estado despues de autorizar la Raspberry." -ForegroundColor DarkGray
                    Write-Host "3. Cancelar y volver"
                    Write-Host "   No realiza ningun cambio adicional." -ForegroundColor DarkGray
                    Write-Host ""

                    if ((Read-UIChoice) -eq "1")
                    {
                        Start-Process $loginUrl
                        Write-Host "[OK] Se abrio el enlace de autorizacion en el navegador." -ForegroundColor Green
                    }
                }
                else
                {
                    Write-Host "[INFO] La orden se envio, pero la conexion todavia no se pudo confirmar." -ForegroundColor Yellow
                    Write-Host "Seleccione 'Actualizar estado' en unos segundos. Cuando aparezca 'Conectado' en verde, el proceso habra terminado." -ForegroundColor DarkGray
                }

                $details = @($output | Where-Object { $_ })
                if ($details.Count -gt 0 -and -not $updatedStatus.Online)
                {
                    Write-Host ""
                    Write-Host "Detalles tecnicos:" -ForegroundColor DarkGray
                    foreach ($line in $details)
                    {
                        Write-Host $line -ForegroundColor DarkGray
                    }
                }
            }
            else
            {
                Write-Host "[ERROR] No se pudo activar Tailscale." -ForegroundColor Red
            }

            Pause
            continue
        }

        if ($option -eq "3")
        {
            if (-not (Confirm-ToolAction `
                -Title "Cerrar acceso remoto con Tailscale" `
                -Description "Desconecta esta Raspberry de Tailscale sin desinstalar la aplicacion." `
                -Duration "5 a 10 segundos" `
                -Warning "Se perdera el acceso remoto por Tailscale. Para recuperarlo despues, seleccione Activar acceso remoto."))
            {
                Write-Host "[INFO] Cierre de acceso cancelado." -ForegroundColor Yellow
                Pause
                continue
            }

            $scheduled = Invoke-SSHScript `
                -RaspberryHost $RaspberryHost `
                -User $User `
                -Script "sudo nohup sh -c 'sleep 2; tailscale down' >/dev/null 2>&1 & echo OK"

            if ($LASTEXITCODE -eq 0 -and $scheduled -match "OK")
            {
                Write-Host "[OK] Se solicito cerrar el acceso remoto con Tailscale." -ForegroundColor Green
            }
            else
            {
                Write-Host "[ERROR] No se pudo cerrar el acceso remoto con Tailscale." -ForegroundColor Red
            }

            Pause
        }

        if ($option -eq "4")
        {
            Show-TailscalePiHoleDnsAssistant -RaspberryHost $RaspberryHost -User $User
            continue
        }

        if ($option -eq "5")
        {
            Enable-RaspberryTailscaleSSH -RaspberryHost $RaspberryHost -User $User
            Pause
            continue
        }

        if ($option -eq "6")
        {
            if (-not (Confirm-RemoteToolUninstall -ToolName "Tailscale" -Description "Desinstala Tailscale y detiene su servicio en esta Raspberry."))
            {
                Write-Host "[INFO] Desinstalacion cancelada." -ForegroundColor Yellow
                Pause
                continue
            }

            Show-UIProgress -Stage "Cerrando Tailscale..." -Percent 20
            Show-UIProgress -Stage "Desinstalando Tailscale..." -Percent 60
            $result = Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script "sudo tailscale down 2>/dev/null || true; sudo tailscale logout 2>/dev/null || true; sudo apt-get purge -y tailscale && echo OK"

            if ($LASTEXITCODE -eq 0 -and $result -match "OK")
            {
                Show-UIProgress -Stage "Tailscale desinstalado." -Percent 100
                Complete-UIProgress
                Write-Host "[OK] Tailscale fue desinstalado de la Raspberry." -ForegroundColor Green
            }
            else
            {
                Complete-UIProgress
                Write-Host "[ERROR] No se pudo desinstalar Tailscale." -ForegroundColor Red
            }

            Pause
        }
    }
}


function Get-RaspberryZeroTierStatus
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    $statusScript = @'
if ! command -v zerotier-cli >/dev/null 2>&1; then
    echo PCJ_ZEROTIER_NOT_INSTALLED
    exit 0
fi

if ! systemctl is-active --quiet zerotier-one; then
    echo PCJ_ZEROTIER_STOPPED
    exit 0
fi

sudo zerotier-cli status 2>/dev/null || echo PCJ_ZEROTIER_STATUS_ERROR
'@

    $result = Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script $statusScript
    $rawText = @($result) -join [Environment]::NewLine

    if ($rawText -match "PCJ_ZEROTIER_NOT_INSTALLED")
    {
        return [PSCustomObject]@{ Installed = $false; Online = $false; State = "No instalado"; NodeId = "" }
    }

    if ($rawText -match "PCJ_ZEROTIER_STOPPED")
    {
        return [PSCustomObject]@{ Installed = $true; Online = $false; State = "Servicio detenido"; NodeId = "" }
    }

    $statusLine = @($rawText -split "`r?`n" | Where-Object { $_ -match "^200\s+info\s+" } | Select-Object -First 1)[0]
    if ($statusLine)
    {
        $parts = $statusLine -split "\s+"
        $nodeId = if ($parts.Count -ge 3) { $parts[2] } else { "" }
        $state = if ($parts.Count -ge 5) { $parts[4] } else { "Desconocido" }

        return [PSCustomObject]@{
            Installed = $true
            Online = ($state -eq "ONLINE")
            State = $state
            NodeId = $nodeId
        }
    }

    return [PSCustomObject]@{ Installed = $true; Online = $false; State = "No se pudo consultar"; NodeId = "" }
}


function Show-ZeroTierRemoteAccess
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    while ($true)
    {
        Clear-Host
        Write-UIHeader -Title "Acceso remoto con ZeroTier"
        Write-Host ""

        $zeroTierStatus = Get-RaspberryZeroTierStatus -RaspberryHost $RaspberryHost -User $User
        $statusSymbol = [char]0x25CF

        if (-not $zeroTierStatus.Installed)
        {
            Write-Host "ZeroTier:  $statusSymbol No instalado" -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "ZeroTier crea una red privada para acceder a la Raspberry desde fuera de casa." -ForegroundColor Cyan
            Write-Host "Instale ZeroTier en la Raspberry antes de usar las opciones de esta pantalla." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "1. Actualizar estado"
            Write-Host "   Vuelve a comprobar si ZeroTier esta instalado y conectado." -ForegroundColor DarkGray
            Write-Host "2. Instalar ZeroTier"
            Write-Host "   Descarga e instala ZeroTier desde su instalador oficial.  1 a 5 minutos" -ForegroundColor DarkGray
            Write-Host "3. Volver"
            Write-Host "   Regresa al menu de acceso remoto sin realizar cambios." -ForegroundColor DarkGray
            Write-Host ""

            $notInstalledOption = Read-UIChoice
            if ($notInstalledOption -eq "3")
            {
                return
            }

            if ($notInstalledOption -eq "2")
            {
                if (-not (Confirm-ToolAction -Title "Instalar ZeroTier" -Description "Descarga e instala ZeroTier desde el repositorio oficial." -Duration "1 a 5 minutos" -Warning "La instalacion descarga software de Internet. No une la Raspberry a una red ni guarda datos de su cuenta."))
                {
                    Write-Host "[INFO] Instalacion cancelada." -ForegroundColor Yellow
                    Pause
                    continue
                }

                Show-UIProgress -Stage "Preparando instalacion de ZeroTier..." -Percent 10
                Show-UIProgress -Stage "Descargando e instalando ZeroTier..." -Percent 40
                $installResult = Invoke-SSHCommand -RaspberryHost $RaspberryHost -User $User -Command "if ! command -v curl >/dev/null 2>&1; then sudo apt-get update && sudo apt-get install -y curl; fi; curl -s https://install.zerotier.com | sudo bash 2>&1"

                if ($LASTEXITCODE -eq 0)
                {
                    Show-UIProgress -Stage "ZeroTier instalado correctamente." -Percent 100
                    Complete-UIProgress
                    Write-Host "[OK] ZeroTier se instalo correctamente. Ahora puede unir la Raspberry a una red desde este menu." -ForegroundColor Green
                }
                else
                {
                    Complete-UIProgress
                    Write-Host "[ERROR] No se pudo instalar ZeroTier." -ForegroundColor Red
                }

                Pause
            }

            continue
        }

        $statusColor = if ($zeroTierStatus.Online) { "Green" } else { "DarkGray" }
        $statusText = if ($zeroTierStatus.Online) { "Conectado" } else { $zeroTierStatus.State }
        Write-Host "ZeroTier:  $statusSymbol $statusText" -ForegroundColor $statusColor

        if ($zeroTierStatus.NodeId)
        {
            Write-Host "Identificador del equipo: $($zeroTierStatus.NodeId)" -ForegroundColor Cyan
        }

        Write-Host ""
        Write-Host "1. Actualizar estado"
        Write-Host "   Vuelve a comprobar el estado e identificador de ZeroTier." -ForegroundColor DarkGray
        Write-Host "2. Activar ZeroTier"
        Write-Host "   Inicia ZeroTier para recuperar el acceso de sus redes ya guardadas." -ForegroundColor DarkGray
        Write-Host "3. Unir la Raspberry a una red ZeroTier"
        Write-Host "   Solicita unirla a una red nueva usando el identificador que entrega ZeroTier Central; no requiere inicio de sesion en la Raspberry." -ForegroundColor DarkGray
        Write-Host "4. Cerrar acceso remoto con ZeroTier"
        Write-Host "   Detiene ZeroTier temporalmente, sin borrar sus redes ni configuracion." -ForegroundColor DarkGray
        Write-Host "5. Desinstalar ZeroTier"
        Write-Host "   Elimina ZeroTier de la Raspberry si ya no desea utilizar este acceso remoto." -ForegroundColor Yellow
        Write-Host "6. Volver"
        Write-Host "   Regresa al menu de acceso remoto sin realizar cambios." -ForegroundColor DarkGray
        Write-Host ""

        $option = Read-UIChoice

        if ($option -eq "1") { continue }
        if ($option -eq "6") { return }

        if ($option -eq "2")
        {
            if (-not (Confirm-ToolAction -Title "Activar ZeroTier" -Description "Inicia el servicio de ZeroTier en esta Raspberry." -Duration "5 a 15 segundos" -Warning "Solo activa ZeroTier; no une el equipo a una red nueva."))
            {
                Write-Host "[INFO] Activacion cancelada." -ForegroundColor Yellow
                Pause
                continue
            }

            $result = Invoke-SSHCommand -RaspberryHost $RaspberryHost -User $User -Command "sudo systemctl start zerotier-one && echo OK"
            if ($LASTEXITCODE -eq 0 -and $result -match "OK")
            {
                Write-Host "[OK] ZeroTier se activo correctamente." -ForegroundColor Green
            }
            else
            {
                Write-Host "[ERROR] No se pudo activar ZeroTier." -ForegroundColor Red
            }

            Pause
            continue
        }

        if ($option -eq "3")
        {
            Clear-Host
            Write-UIHeader -Title "Unir a una red ZeroTier"
            Write-Host ""
            Write-Host "Escriba el identificador de 16 caracteres de la red creada en ZeroTier Central." -ForegroundColor Cyan
            Write-Host "Despues debe autorizar este equipo desde su cuenta de ZeroTier." -ForegroundColor Yellow
            Write-Host "Escriba 0 para cancelar y volver." -ForegroundColor DarkGray
            Write-Host ""
            $networkId = Read-Host "Identificador de la red"

            if ($networkId -eq "0") { continue }
            if ($networkId -notmatch "^[a-fA-F0-9]{16}$")
            {
                Write-Host "[ERROR] El identificador debe contener exactamente 16 caracteres hexadecimales." -ForegroundColor Red
                Pause
                continue
            }

            if (-not (Confirm-ToolAction -Title "Unir a red ZeroTier" -Description "Conecta esta Raspberry a la red ZeroTier indicada." -Duration "10 a 30 segundos" -Warning "La conexion quedara pendiente de autorizacion en ZeroTier Central."))
            {
                Write-Host "[INFO] Conexion cancelada." -ForegroundColor Yellow
                Pause
                continue
            }

            $result = Invoke-SSHCommand -RaspberryHost $RaspberryHost -User $User -Command "sudo systemctl start zerotier-one && sudo zerotier-cli join $networkId 2>&1"
            if ($LASTEXITCODE -eq 0 -and $result -match "200 join OK")
            {
                Write-Host "[OK] La Raspberry se unio a la red. Autoricela ahora desde ZeroTier Central." -ForegroundColor Green
            }
            else
            {
                Write-Host "[ERROR] No se pudo unir la Raspberry a esa red ZeroTier." -ForegroundColor Red
            }

            Pause
            continue
        }

        if ($option -eq "4")
        {
            if (-not (Confirm-ToolAction -Title "Cerrar acceso remoto con ZeroTier" -Description "Detiene ZeroTier sin borrar su configuracion ni sus redes guardadas." -Duration "5 a 10 segundos" -Warning "Se perdera el acceso remoto por ZeroTier hasta que vuelva a activarlo."))
            {
                Write-Host "[INFO] Cierre de acceso cancelado." -ForegroundColor Yellow
                Pause
                continue
            }

            $scheduled = Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script "sudo nohup sh -c 'sleep 2; systemctl stop zerotier-one' >/dev/null 2>&1 & echo OK"
            if ($LASTEXITCODE -eq 0 -and $scheduled -match "OK")
            {
                Write-Host "[OK] Se solicito cerrar el acceso remoto con ZeroTier." -ForegroundColor Green
            }
            else
            {
                Write-Host "[ERROR] No se pudo cerrar el acceso remoto con ZeroTier." -ForegroundColor Red
            }

            Pause
        }

        if ($option -eq "5")
        {
            if (-not (Confirm-RemoteToolUninstall -ToolName "ZeroTier" -Description "Desinstala ZeroTier y detiene su servicio en esta Raspberry."))
            {
                Write-Host "[INFO] Desinstalacion cancelada." -ForegroundColor Yellow
                Pause
                continue
            }

            Show-UIProgress -Stage "Cerrando ZeroTier..." -Percent 20
            Show-UIProgress -Stage "Desinstalando ZeroTier..." -Percent 60
            $result = Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script "sudo systemctl stop zerotier-one 2>/dev/null || true; sudo apt-get purge -y zerotier-one && echo OK"

            if ($LASTEXITCODE -eq 0 -and $result -match "OK")
            {
                Show-UIProgress -Stage "ZeroTier desinstalado." -Percent 100
                Complete-UIProgress
                Write-Host "[OK] ZeroTier fue desinstalado de la Raspberry." -ForegroundColor Green
            }
            else
            {
                Complete-UIProgress
                Write-Host "[ERROR] No se pudo desinstalar ZeroTier." -ForegroundColor Red
            }

            Pause
        }
    }
}


function Get-RaspberryCloudflareTunnelStatus
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    $statusScript = @'
if ! command -v cloudflared >/dev/null 2>&1; then
    echo PCJ_CLOUDFLARED_NOT_INSTALLED
    exit 0
fi

if systemctl is-active --quiet cloudflared; then
    echo PCJ_CLOUDFLARED_RUNNING
else
    echo PCJ_CLOUDFLARED_STOPPED
fi
'@

    $result = Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script $statusScript
    $rawText = @($result) -join [Environment]::NewLine

    if ($rawText -match "PCJ_CLOUDFLARED_NOT_INSTALLED")
    {
        return [PSCustomObject]@{ Installed = $false; Online = $false; State = "No instalado" }
    }

    if ($rawText -match "PCJ_CLOUDFLARED_RUNNING")
    {
        return [PSCustomObject]@{ Installed = $true; Online = $true; State = "Activo" }
    }

    return [PSCustomObject]@{ Installed = $true; Online = $false; State = "Servicio detenido o sin configurar" }
}


function Show-CloudflareTunnelRemoteAccess
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    while ($true)
    {
        Clear-Host
        Write-UIHeader -Title "Acceso remoto con Cloudflare Tunnel"
        Write-Host ""

        $cloudflareStatus = Get-RaspberryCloudflareTunnelStatus -RaspberryHost $RaspberryHost -User $User
        $statusSymbol = [char]0x25CF
        $statusColor = if ($cloudflareStatus.Online) { "Green" } else { "DarkGray" }
        Write-Host "Cloudflare Tunnel:  $statusSymbol $($cloudflareStatus.State)" -ForegroundColor $statusColor
        Write-Host ""
        Write-Host "Cloudflare Tunnel publica solo los servicios que usted haya configurado en su cuenta de Cloudflare." -ForegroundColor Cyan

        if (-not $cloudflareStatus.Installed)
        {
            Write-Host "Instale cloudflared y cree su tunnel primero. Esta herramienta no crea ni guarda tokens de Cloudflare." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "1. Actualizar estado"
            Write-Host "   Vuelve a comprobar si cloudflared esta instalado y activo." -ForegroundColor DarkGray
            Write-Host "2. Instalar Cloudflare Tunnel"
            Write-Host "   Descarga e instala cloudflared desde el paquete oficial.  1 a 5 minutos" -ForegroundColor DarkGray
            Write-Host "3. Volver"
            Write-Host "   Regresa al menu de acceso remoto sin realizar cambios." -ForegroundColor DarkGray
            Write-Host ""

            $notInstalledOption = Read-UIChoice
            if ($notInstalledOption -eq "3") { return }

            if ($notInstalledOption -eq "2")
            {
                if (-not (Confirm-ToolAction -Title "Instalar Cloudflare Tunnel" -Description "Descarga e instala cloudflared, el conector oficial de Cloudflare Tunnel." -Duration "1 a 5 minutos" -Warning "La instalacion no crea un tunnel, no publica servicios y no guarda tokens de Cloudflare."))
                {
                    Write-Host "[INFO] Instalacion cancelada." -ForegroundColor Yellow
                    Pause
                    continue
                }

                Show-UIProgress -Stage "Preparando instalacion de Cloudflare Tunnel..." -Percent 10
                Show-UIProgress -Stage "Descargando cloudflared para esta Raspberry..." -Percent 40
                $installScript = @'
set -e
if ! command -v curl >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y curl
fi
package_file=$(mktemp)
architecture=$(dpkg --print-architecture)
curl -fsSL -o "$package_file" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${architecture}.deb"
sudo dpkg -i "$package_file"
rm -f "$package_file"
echo OK
'@
                $installResult = Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script $installScript

                if ($LASTEXITCODE -eq 0 -and $installResult -match "OK")
                {
                    Show-UIProgress -Stage "Cloudflare Tunnel instalado correctamente." -Percent 100
                    Complete-UIProgress
                    Write-Host "[OK] cloudflared se instalo correctamente. Falta crear y configurar su tunnel en Cloudflare antes de activarlo." -ForegroundColor Green
                }
                else
                {
                    Complete-UIProgress
                    Write-Host "[ERROR] No se pudo instalar Cloudflare Tunnel." -ForegroundColor Red
                }

                Pause
            }

            continue
        }

        Write-Host ""
        Write-Host "1. Actualizar estado"
        Write-Host "   Vuelve a comprobar si el servicio del tunnel esta activo." -ForegroundColor DarkGray
        Write-Host "2. Iniciar sesion en Cloudflare"
        Write-Host "   Muestra un enlace para vincular cloudflared a su cuenta de Cloudflare. Solo se necesita para crear o administrar tunnels." -ForegroundColor DarkGray
        Write-Host "3. Activar Cloudflare Tunnel"
        Write-Host "   Inicia el tunnel configurado para publicar sus servicios autorizados." -ForegroundColor DarkGray
        Write-Host "4. Cerrar Cloudflare Tunnel"
        Write-Host "   Detiene el tunnel y deja de publicar sus servicios hasta volver a activarlo." -ForegroundColor DarkGray
        Write-Host "5. Desinstalar Cloudflare Tunnel"
        Write-Host "   Elimina cloudflared y detiene el tunnel de esta Raspberry." -ForegroundColor Yellow
        Write-Host "6. Volver"
        Write-Host "   Regresa al menu de acceso remoto sin realizar cambios." -ForegroundColor DarkGray
        Write-Host ""

        $option = Read-UIChoice
        if ($option -eq "1") { continue }
        if ($option -eq "6") { return }

        if ($option -eq "2")
        {
            if (-not (Confirm-ToolAction -Title "Iniciar sesion en Cloudflare" -Description "Muestra un enlace seguro para vincular cloudflared con su cuenta de Cloudflare." -Duration "1 a 5 minutos" -Warning "En la siguiente pantalla copie el enlace, abralo en el navegador de su PC e inicie sesion. Esta accion crea un certificado de cuenta en la Raspberry."))
            {
                Write-Host "[INFO] Inicio de sesion cancelado." -ForegroundColor Yellow
                Pause
                continue
            }

            Clear-Host
            Write-UIHeader -Title "Iniciar sesion en Cloudflare"
            Write-Host ""
            Write-Host "Enseguida aparecera un enlace. Copielo y abraselo en el navegador de esta PC." -ForegroundColor Cyan
            Write-Host "Despues de autorizar, vuelva a esta ventana y espere la confirmacion." -ForegroundColor Yellow
            Write-Host ""
            Invoke-SSHCommand -RaspberryHost $RaspberryHost -User $User -Command "cloudflared tunnel login" | Out-Host

            if ($LASTEXITCODE -eq 0)
            {
                Write-Host "[OK] Cloudflare quedo vinculado correctamente." -ForegroundColor Green
            }
            else
            {
                Write-Host "[ERROR] No se pudo completar el inicio de sesion en Cloudflare." -ForegroundColor Red
            }

            Pause
            continue
        }

        if ($option -eq "3")
        {
            if (-not (Confirm-ToolAction -Title "Activar Cloudflare Tunnel" -Description "Inicia el tunnel ya configurado en esta Raspberry." -Duration "5 a 20 segundos" -Warning "Si el tunnel no tiene configuracion valida, el servicio no podra iniciar."))
            {
                Write-Host "[INFO] Activacion cancelada." -ForegroundColor Yellow
                Pause
                continue
            }

            $result = Invoke-SSHCommand -RaspberryHost $RaspberryHost -User $User -Command "sudo systemctl start cloudflared && echo OK"
            if ($LASTEXITCODE -eq 0 -and $result -match "OK")
            {
                Write-Host "[OK] Se solicito activar Cloudflare Tunnel." -ForegroundColor Green
            }
            else
            {
                Write-Host "[ERROR] No se pudo activar Cloudflare Tunnel. Revise su configuracion en Cloudflare." -ForegroundColor Red
            }

            Pause
            continue
        }

        if ($option -eq "4")
        {
            if (-not (Confirm-ToolAction -Title "Cerrar Cloudflare Tunnel" -Description "Detiene el tunnel sin borrar su configuracion." -Duration "5 a 10 segundos" -Warning "Los servicios publicados mediante este tunnel dejaran de estar disponibles desde Internet."))
            {
                Write-Host "[INFO] Cierre de acceso cancelado." -ForegroundColor Yellow
                Pause
                continue
            }

            $scheduled = Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script "sudo nohup sh -c 'sleep 2; systemctl stop cloudflared' >/dev/null 2>&1 & echo OK"
            if ($LASTEXITCODE -eq 0 -and $scheduled -match "OK")
            {
                Write-Host "[OK] Se solicito cerrar Cloudflare Tunnel." -ForegroundColor Green
            }
            else
            {
                Write-Host "[ERROR] No se pudo cerrar Cloudflare Tunnel." -ForegroundColor Red
            }

            Pause
        }

        if ($option -eq "5")
        {
            if (-not (Confirm-RemoteToolUninstall -ToolName "Cloudflare Tunnel" -Description "Desinstala cloudflared y detiene el tunnel configurado en esta Raspberry."))
            {
                Write-Host "[INFO] Desinstalacion cancelada." -ForegroundColor Yellow
                Pause
                continue
            }

            Show-UIProgress -Stage "Cerrando Cloudflare Tunnel..." -Percent 20
            Show-UIProgress -Stage "Desinstalando cloudflared..." -Percent 60
            $result = Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script "sudo systemctl stop cloudflared 2>/dev/null || true; sudo cloudflared service uninstall 2>/dev/null || true; sudo apt-get purge -y cloudflared && echo OK"

            if ($LASTEXITCODE -eq 0 -and $result -match "OK")
            {
                Show-UIProgress -Stage "Cloudflare Tunnel desinstalado." -Percent 100
                Complete-UIProgress
                Write-Host "[OK] Cloudflare Tunnel fue desinstalado de la Raspberry." -ForegroundColor Green
            }
            else
            {
                Complete-UIProgress
                Write-Host "[ERROR] No se pudo desinstalar Cloudflare Tunnel." -ForegroundColor Red
            }

            Pause
        }
    }
}


function Show-RemoteAccessMenu
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    while ($true)
    {
        Clear-Host
        Write-UIHeader -Title "Acceso remoto"
        Write-Host ""
        Write-Host "Administre las conexiones que permiten acceder a la Raspberry desde fuera de su red local." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "1. Tailscale"
        Write-Host "   Consultar, activar o cerrar el acceso remoto privado." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "2. ZeroTier"
        Write-Host "   Crear o cerrar acceso privado mediante una red ZeroTier." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "3. Cloudflare Tunnel"
        Write-Host "   Activar o cerrar un tunnel configurado en Cloudflare." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "4. Acceso grafico oficial"
        Write-Host "   Instala o abre Raspberry Pi Connect para controlar el escritorio desde un navegador." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "5. Volver" -ForegroundColor DarkGray
        Write-Host ""

        $remoteOption = Read-UIChoice

        switch ($remoteOption)
        {
            "1" {
                Show-TailscaleRemoteAccess -RaspberryHost $RaspberryHost -User $User
            }

            "2" {
                Show-ZeroTierRemoteAccess -RaspberryHost $RaspberryHost -User $User
            }

            "3" {
                Show-CloudflareTunnelRemoteAccess -RaspberryHost $RaspberryHost -User $User
            }

            "4" {
                Show-RaspberryDesktopRemoteAssistant -RaspberryHost $RaspberryHost -User $User
            }

            "5" {
                return
            }
        }
    }
}


function Get-RaspberryGravityScheduleStatus
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    $statusScript = @'
if ! command -v pihole >/dev/null 2>&1; then
    echo PCJ_GRAVITY_PIHOLE_NOT_FOUND
    exit 0
fi

if [ ! -f /etc/cron.d/pihole ]; then
    echo PCJ_GRAVITY_SCHEDULE_UNKNOWN
    exit 0
fi

if grep -Eq '^[[:space:]]*#[[:space:]]*PCJ_GRAVITY_DISABLED.*pihole.*(updateGravity|-g)' /etc/cron.d/pihole; then
    echo PCJ_GRAVITY_MANUAL
elif grep -Eq '^[[:space:]]*[^#].*pihole.*(updateGravity|-g)' /etc/cron.d/pihole; then
    echo PCJ_GRAVITY_AUTOMATIC
else
    echo PCJ_GRAVITY_SCHEDULE_UNKNOWN
fi
'@

    $result = Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script $statusScript
    $rawText = @($result) -join [Environment]::NewLine

    if ($rawText -match "PCJ_GRAVITY_PIHOLE_NOT_FOUND")
    {
        return [PSCustomObject]@{ Available = $false; Automatic = $false; State = "Pi-hole no disponible" }
    }

    if ($rawText -match "PCJ_GRAVITY_AUTOMATIC")
    {
        return [PSCustomObject]@{ Available = $true; Automatic = $true; State = "Automatico: una vez por semana" }
    }

    if ($rawText -match "PCJ_GRAVITY_MANUAL")
    {
        return [PSCustomObject]@{ Available = $true; Automatic = $false; State = "Manual: solo al solicitarlo" }
    }

    return [PSCustomObject]@{ Available = $true; Automatic = $false; State = "No se pudo identificar el horario" }
}


function Set-RaspberryGravitySchedule
{
    param
    (
        [string]$RaspberryHost,
        [string]$User,
        [bool]$EnableAutomatic
    )

    $scheduleScript = if ($EnableAutomatic) {
@'
if [ ! -f /etc/cron.d/pihole ]; then
    exit 1
fi
sudo sed -i 's/^[[:space:]]*#[[:space:]]*PCJ_GRAVITY_DISABLED[[:space:]]*//' /etc/cron.d/pihole
echo OK
'@
    }
    else {
@'
if [ ! -f /etc/cron.d/pihole ]; then
    exit 1
fi
sudo cp /etc/cron.d/pihole /etc/cron.d/pihole.pcj-backup
sudo sed -i '/^[[:space:]]*[^#].*pihole.*\(updateGravity\|-g\)/ s/^[[:space:]]*/# PCJ_GRAVITY_DISABLED /' /etc/cron.d/pihole
echo OK
'@
    }

    return Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script $scheduleScript
}


function Show-GravityAssistant
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    while ($true)
    {
        Clear-Host
        Write-UIHeader -Title "Listas de bloqueo de Pi-hole (Gravity)"
        Write-Host ""

        $gravityStatus = Get-RaspberryGravityScheduleStatus -RaspberryHost $RaspberryHost -User $User
        if (-not $gravityStatus.Available)
        {
            Write-Host "[ERROR] No se encontro Pi-hole en esta Raspberry." -ForegroundColor Red
            Write-Host ""
            Write-Host "1. Actualizar estado"
            Write-Host "   Vuelve a comprobar si Pi-hole esta disponible." -ForegroundColor DarkGray
            Write-Host "2. Volver"
            Write-Host "   Regresa a Herramientas sin realizar cambios." -ForegroundColor DarkGray
            Write-Host ""

            if ((Read-UIChoice) -eq "2") { return }
            continue
        }

        $modeColor = if ($gravityStatus.Automatic) { "Green" } else { "Yellow" }
        Write-Host "Modo actual: " -ForegroundColor Cyan -NoNewline
        Write-Host $gravityStatus.State -ForegroundColor $modeColor
        Write-Host ""
        Write-Host "Gravity descarga las listas de dominios bloqueados y aplica sus cambios a Pi-hole." -ForegroundColor Cyan
        Write-Host "En modo automatico, Pi-hole la actualiza una vez por semana." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "1. Actualizar listas ahora" -ForegroundColor White
        Write-Host "   Descarga y aplica las listas configuradas en este momento.  10 segundos a 2 minutos" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "2. Activar actualizacion automatica" -ForegroundColor White
        Write-Host "   Pi-hole actualizara las listas automaticamente una vez por semana." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "3. Dejar actualizacion manual" -ForegroundColor White
        Write-Host "   Desactiva la actualizacion semanal; usted decidira cuando usar la opcion 1." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "4. Volver" -ForegroundColor DarkGray
        Write-Host "   Regresa a Herramientas sin realizar cambios." -ForegroundColor DarkGray
        Write-Host ""

        $option = Read-UIChoice

        if ($option -eq "1")
        {
            if (-not (Confirm-ToolAction -Title "Actualizar listas de bloqueo" -Description "Descarga y aplica las listas de bloqueo configuradas en Pi-hole." -Duration "10 segundos a 2 minutos" -Warning "Una vez iniciada la descarga no se recomienda cancelarla. El DNS puede recargar brevemente sus listas al finalizar."))
            {
                Write-Host "[INFO] Actualizacion cancelada." -ForegroundColor Yellow
                Pause
                continue
            }

            Show-UIProgress -Stage "Preparando actualizacion de listas..." -Percent 10
            Show-UIProgress -Stage "Descargando y procesando listas de bloqueo..." -Percent 40

            $result = Invoke-SSHCommand -RaspberryHost $RaspberryHost -User $User -Command "sudo pihole updateGravity 2>&1"

            if ($LASTEXITCODE -eq 0)
            {
                Show-UIProgress -Stage "Aplicando listas actualizadas a Pi-hole..." -Percent 90
                Show-UIProgress -Stage "Listas de bloqueo actualizadas." -Percent 100
                Complete-UIProgress
                Write-Host "[OK] Gravity se actualizo correctamente." -ForegroundColor Green
            }
            else
            {
                Complete-UIProgress
                Write-Host "[ERROR] No se pudieron actualizar las listas de bloqueo." -ForegroundColor Red
            }

            Pause
            continue
        }

        if ($option -eq "2")
        {
            if ($gravityStatus.Automatic)
            {
                Write-Host "[INFO] La actualizacion automatica ya esta activa." -ForegroundColor Yellow
                Pause
                continue
            }

            if (-not (Confirm-ToolAction -Title "Activar Gravity automatico" -Description "Restablece la actualizacion automatica semanal de las listas de Pi-hole." -Duration "5 a 10 segundos" -Warning "No actualiza las listas ahora; solo programa las futuras actualizaciones."))
            {
                Write-Host "[INFO] Cambio cancelado." -ForegroundColor Yellow
                Pause
                continue
            }

            $result = Set-RaspberryGravitySchedule -RaspberryHost $RaspberryHost -User $User -EnableAutomatic $true
            if ($LASTEXITCODE -eq 0 -and $result -match "OK")
            {
                Write-Host "[OK] Gravity se actualizara automaticamente una vez por semana." -ForegroundColor Green
            }
            else
            {
                Write-Host "[ERROR] No se pudo activar la actualizacion automatica." -ForegroundColor Red
            }

            Pause
            continue
        }

        if ($option -eq "3")
        {
            if (-not $gravityStatus.Automatic -and $gravityStatus.State -match "Manual")
            {
                Write-Host "[INFO] Gravity ya esta configurado en modo manual." -ForegroundColor Yellow
                Pause
                continue
            }

            if (-not (Confirm-ToolAction -Title "Dejar Gravity en modo manual" -Description "Desactiva la actualizacion semanal de Gravity." -Duration "5 a 10 segundos" -Warning "Las listas no se actualizaran solas. Debera usar 'Actualizar listas ahora' cuando desee renovarlas."))
            {
                Write-Host "[INFO] Cambio cancelado." -ForegroundColor Yellow
                Pause
                continue
            }

            $result = Set-RaspberryGravitySchedule -RaspberryHost $RaspberryHost -User $User -EnableAutomatic $false
            if ($LASTEXITCODE -eq 0 -and $result -match "OK")
            {
                Write-Host "[OK] Gravity quedo en modo manual." -ForegroundColor Green
            }
            else
            {
                Write-Host "[ERROR] No se pudo cambiar Gravity a modo manual." -ForegroundColor Red
            }

            Pause
            continue
        }

        if ($option -eq "4") { return }
    }
}


function Get-RaspberryPiHoleInstallationStatus
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    $statusScript = @'
if ! command -v pihole >/dev/null 2>&1; then
    echo PCJ_PIHOLE_NOT_INSTALLED
    exit 0
fi

if systemctl is-active --quiet pihole-FTL; then
    echo PCJ_PIHOLE_ACTIVE
else
    echo PCJ_PIHOLE_STOPPED
fi
'@

    $result = Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script $statusScript
    $rawText = @($result) -join [Environment]::NewLine

    if ($rawText -match "PCJ_PIHOLE_NOT_INSTALLED")
    {
        return [PSCustomObject]@{ Installed = $false; Active = $false; State = "No instalado" }
    }

    if ($rawText -match "PCJ_PIHOLE_ACTIVE")
    {
        return [PSCustomObject]@{ Installed = $true; Active = $true; State = "Activo" }
    }

    return [PSCustomObject]@{ Installed = $true; Active = $false; State = "Instalado, pero detenido" }
}


function Open-PiHoleDashboard
{
    param
    (
        [string]$RaspberryHost
    )

    $dashboardUrl = "http://$RaspberryHost/admin/login"

    Clear-Host
    Write-UIHeader -Title "Abrir panel de Pi-hole"
    Write-Host ""
    Write-Host "Abrira el panel web de Pi-hole en el navegador predeterminado de esta PC." -ForegroundColor Cyan
    Write-Host "Direccion: $dashboardUrl" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Pi-hole solicita una contrasena de administrador en el navegador." -ForegroundColor Yellow
    Write-Host "Por seguridad, PCJ Raspberry Toolkit no guarda ni envia esa contrasena." -ForegroundColor Yellow
    Write-Host "Si usted ya la guardo en su navegador, este puede rellenarla automaticamente." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "1. Abrir panel de Pi-hole"
    Write-Host "   Abre el navegador con la direccion de esta Raspberry." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "2. Cancelar y volver"
    Write-Host "   Regresa sin abrir el navegador." -ForegroundColor DarkGray
    Write-Host ""

    if ((Read-UIChoice) -ne "1")
    {
        Write-Host "[INFO] Apertura del panel cancelada." -ForegroundColor Yellow
        return
    }

    try
    {
        Start-Process $dashboardUrl
        Write-Host "[OK] El panel de Pi-hole se abrio en el navegador." -ForegroundColor Green
    }
    catch
    {
        Write-Host "[ERROR] No se pudo abrir el navegador automaticamente." -ForegroundColor Red
        Write-Host "Abra manualmente esta direccion: $dashboardUrl" -ForegroundColor Cyan
    }
}


function Test-RaspberryInternetConnection
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    $testScript = @'
ping -c 4 -W 3 google.com
result=$?
if [ "$result" -eq 0 ]; then
    echo PCJ_INTERNET_OK
else
    echo PCJ_INTERNET_ERROR
fi
'@

    $output = Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script $testScript
    $rawText = @($output) -join [Environment]::NewLine
    $summary = [regex]::Match($rawText, "(\d+)\s+packets transmitted,\s+(\d+)\s+(?:packets )?received.*?(\d+)%\s+packet loss")
    $sent = 4
    $received = 0
    $loss = 100

    if ($summary.Success)
    {
        $sent = [int]$summary.Groups[1].Value
        $received = [int]$summary.Groups[2].Value
        $loss = [int]$summary.Groups[3].Value
    }

    $connected = ($rawText -match "PCJ_INTERNET_OK")
    $explanation = if ($connected) {
        "La Raspberry pudo encontrar google.com mediante DNS y comunicarse con Internet correctamente."
    }
    elseif ($rawText -match "Temporary failure in name resolution|Name or service not known") {
        "La Raspberry esta conectada a la red, pero no puede resolver nombres de Internet. Revise el DNS configurado."
    }
    elseif ($rawText -match "Network is unreachable") {
        "La Raspberry no tiene una ruta de red hacia Internet. Revise Wi-Fi, cable o router."
    }
    else {
        "La Raspberry no recibio las cuatro respuestas esperadas. Revise Wi-Fi, cable, router o acceso a Internet."
    }

    return [PSCustomObject]@{
        Connected = $connected
        Sent = $sent
        Received = $received
        Loss = $loss
        Explanation = $explanation
        Output = @($output | Where-Object { $_ -notmatch "PCJ_INTERNET_(OK|ERROR)" })
    }
}


function Show-RaspberryInternetCheck
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    Clear-Host
    Write-UIHeader -Title "Comprobar acceso a Internet"
    Write-Host ""
    Write-Host "Esta funcion confirma si la Raspberry puede usar DNS y conectarse a Internet." -ForegroundColor Cyan
    Write-Host "No modifica ningun ajuste: solo envia 4 comprobaciones a google.com." -ForegroundColor Cyan
    Write-Host "Si recibe las 4 respuestas, podra descargar programas, actualizaciones y listas de Pi-hole." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. Iniciar comprobacion"
    Write-Host "   Ejecuta 4 intentos de conexion a Internet.  10 a 20 segundos" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "2. Cancelar y volver"
    Write-Host "   Regresa sin realizar ninguna comprobacion." -ForegroundColor DarkGray
    Write-Host ""

    if ((Read-UIChoice) -ne "1")
    {
        return $null
    }

    Show-UIProgress -Stage "Comprobando conexion a Internet..." -Percent 20
    $result = Test-RaspberryInternetConnection -RaspberryHost $RaspberryHost -User $User
    Show-UIProgress -Stage "Comprobacion de Internet terminada." -Percent 100
    Complete-UIProgress

    Write-Host ""
    Write-Host "Resultado de la comprobacion:" -ForegroundColor Cyan
    Write-Host "  Paquetes enviados:  $($result.Sent)"
    Write-Host "  Paquetes recibidos: $($result.Received)"
    Write-Host "  Perdida:            $($result.Loss)%"
    Write-Host ""
    Write-Host "Detalles tecnicos de ping:" -ForegroundColor DarkGray
    foreach ($line in $result.Output)
    {
        Write-Host $line -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""

    if ($result.Connected)
    {
        Write-Host "[OK] ACCESO A INTERNET CONFIRMADO" -ForegroundColor Green
        Write-Host $result.Explanation -ForegroundColor Green
    }
    else
    {
        Write-Host "[ERROR] ACCESO A INTERNET NO CONFIRMADO" -ForegroundColor Red
        Write-Host $result.Explanation -ForegroundColor Yellow
    }

    # Esta pantalla ya muestra el resultado; no se devuelve el objeto para evitar datos repetidos al final.
    return
}


function Install-RaspberryPiHole
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
)

    Clear-Host
    Write-UIHeader -Title "Comprobacion previa a instalar Pi-hole"
    Write-Host ""
    Write-Host "Antes de descargar Pi-hole, verificaremos que la Raspberry tenga acceso completo a Internet." -ForegroundColor Cyan
    Write-Host "Se enviaran 4 comprobaciones a google.com. Si falla, el instalador no se iniciara." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "1. Comprobar y continuar"
    Write-Host "   Realiza la comprobacion de Internet antes de mostrar el instalador." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "2. Cancelar y volver"
    Write-Host "   Regresa sin instalar Pi-hole." -ForegroundColor DarkGray
    Write-Host ""

    if ((Read-UIChoice) -ne "1")
    {
        Write-Host "[INFO] Instalacion cancelada." -ForegroundColor Yellow
        return
    }

    Show-UIProgress -Stage "Comprobando Internet en la Raspberry..." -Percent 20
    $internetCheck = Test-RaspberryInternetConnection -RaspberryHost $RaspberryHost -User $User
    Complete-UIProgress

    if (-not $internetCheck.Connected)
    {
        Write-Host "[ERROR] La Raspberry no tiene acceso completo a Internet. Pi-hole no se instalara." -ForegroundColor Red
        Write-Host "Revise su Wi-Fi, cable de red, router o DNS y vuelva a intentarlo." -ForegroundColor Yellow
        return
    }

    Write-Host "[OK] Se recibieron las 4 respuestas de Internet. Puede continuar con seguridad." -ForegroundColor Green
    Write-Host ""

    if (-not (Confirm-ToolAction `
        -Title "Instalar Pi-hole" `
        -Description "Descarga el instalador oficial de Pi-hole y abre su asistente de configuracion." `
        -Duration "5 a 15 minutos" `
        -Warning "Durante la instalacion debera elegir opciones de red y DNS. Antes de continuar, confirme que la Raspberry tiene una IP fija o una reserva DHCP en su router."))
    {
        Write-Host "[INFO] Instalacion cancelada." -ForegroundColor Yellow
        return
    }

    Clear-Host
    Write-UIHeader -Title "Instalacion de Pi-hole"
    Write-Host ""
    Write-Host "Se abrira el asistente oficial de Pi-hole dentro de esta ventana." -ForegroundColor Cyan
    Write-Host "Responda sus preguntas directamente. Una vez iniciado, no se recomienda cancelarlo." -ForegroundColor Yellow
    Write-Host ""

    Invoke-SSHInteractiveCommand -RaspberryHost $RaspberryHost -User $User -Command "if ! command -v curl >/dev/null 2>&1; then sudo apt-get update && sudo apt-get install -y curl; fi; curl -sSL https://install.pi-hole.net | sudo bash" | Out-Host

    if ($LASTEXITCODE -eq 0)
    {
        Write-Host ""
        Write-Host "[OK] El asistente de instalacion de Pi-hole termino." -ForegroundColor Green
        Write-Host "Configure despues el DNS de su router para que los equipos de su red usen la IP de esta Raspberry." -ForegroundColor Cyan
    }
    else
    {
        Write-Host ""
        Write-Host "[ERROR] El instalador de Pi-hole no termino correctamente." -ForegroundColor Red
    }
}


function Uninstall-RaspberryPiHole
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    Clear-Host
    Write-UIHeader -Title "Desinstalar Pi-hole"
    Write-Host ""
    Write-Host "Se abrira el desinstalador oficial de Pi-hole dentro de esta ventana." -ForegroundColor Cyan
    Write-Host "Siga sus preguntas directamente. Una vez iniciado, no se recomienda cancelarlo." -ForegroundColor Yellow
    Write-Host ""

    Invoke-SSHInteractiveCommand -RaspberryHost $RaspberryHost -User $User -Command "sudo pihole uninstall" | Out-Host

    if ($LASTEXITCODE -eq 0)
    {
        Write-Host ""
        Write-Host "[OK] El desinstalador de Pi-hole termino." -ForegroundColor Green
        Write-Host "La Raspberry y el acceso SSH permanecen disponibles." -ForegroundColor Cyan
    }
    else
    {
        Write-Host ""
        Write-Host "[ERROR] El desinstalador de Pi-hole no termino correctamente." -ForegroundColor Red
    }
}


function Test-RaspberryNetwork
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    if (-not (Confirm-ToolAction `
        -Title "Diagnostico de red" `
        -Description "Comprueba la conexion al router, internet, DNS y Pi-hole." `
        -Duration "10 a 20 segundos"))
    {
        Write-Host "[INFO] Diagnostico cancelado." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "[INFO] Ejecutando diagnostico..." -ForegroundColor Yellow

    $diagnosticScript = @'
gateway=$(ip route | awk '/default/ {print $3; exit}')
printf "Router="
if [ -n "$gateway" ] && ping -c 1 -W 3 "$gateway" >/dev/null 2>&1; then echo "OK ($gateway)"; else echo "FALLA"; fi
printf "Internet="
if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then echo "OK"; else echo "FALLA"; fi
printf "DNS="
if getent hosts example.com >/dev/null 2>&1; then echo "OK"; else echo "FALLA"; fi
printf "Pi-hole="
if systemctl is-active --quiet pihole-FTL; then echo "OK"; else echo "FALLA"; fi
'@

    $results = Invoke-SSHScript `
        -RaspberryHost $RaspberryHost `
        -User $User `
        -Script $diagnosticScript

    if (-not $results)
    {
        Write-Host "[ERROR] No se pudo ejecutar el diagnostico." -ForegroundColor Red
        return
    }

    $itemsRevisados = 0
    $itemsCorrectos = 0

    Write-Host ""
    foreach ($line in $results)
    {
        if ($line -match "^([^=]+)=(.*)$")
        {
            $label = $Matches[1]
            $value = $Matches[2]
            $color = if ($value -match "^OK") { "Green" } else { "Red" }
            $itemsRevisados++
            if ($value -match "^OK")
            {
                $itemsCorrectos++
            }
            Write-Host ("{0,-12}" -f "${label}:") -NoNewline
            Write-Host $value -ForegroundColor $color
        }
    }

    Write-Host ""
    if (($itemsRevisados -gt 0) -and ($itemsCorrectos -eq $itemsRevisados))
    {
        Write-Host "[OK] Diagnostico terminado correctamente." -ForegroundColor Green
        Write-Host "Se revisaron el router, Internet, DNS y Pi-hole: todo respondio correctamente." -ForegroundColor Green
        Write-Host "La Raspberry tiene una conexion de red funcional. Puede continuar usando el programa." -ForegroundColor Green
    }
    else
    {
        Write-Host "[AVISO] Diagnostico terminado con elementos por revisar." -ForegroundColor Yellow
        Write-Host "Revise las lineas marcadas en rojo antes de continuar." -ForegroundColor Yellow
    }
}


function Restart-RaspberryPiHole
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    if (-not (Confirm-ToolAction `
        -Title "Reiniciar Pi-hole" `
        -Description "Reinicia solamente el servicio DNS de Pi-hole." `
        -Duration "5 a 15 segundos" `
        -Warning "Las consultas DNS podrian interrumpirse brevemente."))
    {
        Write-Host "[INFO] Reinicio cancelado." -ForegroundColor Yellow
        return
    }

    $result = Invoke-SSHCommand `
        -RaspberryHost $RaspberryHost `
        -User $User `
        -Command "sudo systemctl restart pihole-FTL && echo OK"

    if ($LASTEXITCODE -eq 0 -and $result -match "OK")
    {
        Write-Host "[OK] Pi-hole se reinicio correctamente." -ForegroundColor Green
    }
    else
    {
        Write-Host "[ERROR] No se pudo reiniciar Pi-hole." -ForegroundColor Red
    }
}


function Restart-RaspberrySystem
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    if (-not (Confirm-ToolAction `
        -Title "Reiniciar Raspberry" `
        -Description "Reinicia por completo el sistema operativo de la Raspberry." `
        -Duration "1 a 3 minutos" `
        -Warning "La conexion se perdera temporalmente mientras la Raspberry inicia."))
    {
        Write-Host "[INFO] Reinicio cancelado." -ForegroundColor Yellow
        return
    }

    Invoke-SSHScript `
        -RaspberryHost $RaspberryHost `
        -User $User `
        -Script "sudo nohup sh -c 'sleep 2; systemctl reboot' >/dev/null 2>&1 & echo OK" | Out-Null

    Write-Host "[OK] Reinicio solicitado. Espere unos minutos antes de volver a conectar." -ForegroundColor Green
}


function Stop-RaspberrySystem
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    if (-not (Confirm-ToolAction `
        -Title "Apagar Raspberry" `
        -Description "Apaga la Raspberry de forma segura antes de desconectarla." `
        -Duration "10 a 30 segundos" `
        -Warning "Despues de apagarla se perdera la conexion. Para volver a conectarse, tendra que encenderla de nuevo conectandola a la corriente."))
    {
        Write-Host "[INFO] Apagado cancelado." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "CONFIRMACION FINAL" -ForegroundColor Red
    Write-Host "Al apagarse, la Raspberry quedara sin conexion." -ForegroundColor Yellow
    Write-Host "Para volver a administrarla, conectela nuevamente a la corriente electrica y espere a que inicie." -ForegroundColor Yellow
    $shutdownConfirmation = Read-Host "Escriba SI para confirmar el apagado"

    if ($shutdownConfirmation -ine "SI")
    {
        Write-Host "[INFO] Apagado cancelado. La Raspberry continuara encendida." -ForegroundColor Yellow
        return
    }

    Invoke-SSHScript `
        -RaspberryHost $RaspberryHost `
        -User $User `
        -Script "sudo nohup sh -c 'sleep 2; systemctl poweroff' >/dev/null 2>&1 & echo OK" | Out-Null

    Write-Host "[OK] Apagado solicitado. Espere antes de desconectar la energia." -ForegroundColor Green
    Write-Host "Para volver a conectarse, encienda la Raspberry conectandola nuevamente a la corriente electrica." -ForegroundColor Cyan
}


function Clear-RaspberrySystemSpace
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    if (-not (Confirm-ToolAction `
        -Title "Limpiar espacio del sistema" `
        -Description "Limpia la cache de paquetes y registros del sistema de mas de 14 dias (errores, avisos y eventos tecnicos)." `
        -Duration "10 a 30 segundos" `
        -Warning "No borra configuraciones de Pi-hole, historial DNS ni respaldos."))
    {
        Write-Host "[INFO] Limpieza cancelada." -ForegroundColor Yellow
        return
    }

    $freeBeforeText = Invoke-SSHCommand `
        -RaspberryHost $RaspberryHost `
        -User $User `
        -Command "df -B1 / | awk 'NR==2 {print `$4}'"
    [long]$freeBefore = 0
    $freeBeforeValue = @($freeBeforeText | Select-Object -Last 1)[0]

    if ($freeBeforeValue)
    {
        [void][long]::TryParse($freeBeforeValue.ToString().Trim(), [ref]$freeBefore)
    }

    Show-UIProgress -Stage "Preparando limpieza del sistema..." -Percent 0
    Show-UIProgress -Stage "Limpiando cache de paquetes..." -Percent 20

    $cacheResult = Invoke-SSHScript `
        -RaspberryHost $RaspberryHost `
        -User $User `
        -Script "sudo apt-get clean >/dev/null 2>&1 && echo OK"

    if ($LASTEXITCODE -ne 0 -or $cacheResult -notmatch "OK")
    {
        Complete-UIProgress
        Write-Host "[ERROR] No se pudo limpiar la cache de paquetes." -ForegroundColor Red
        return
    }

    Show-UIProgress -Stage "Cache limpiada. Borrando registros antiguos..." -Percent 55

    $logsResult = Invoke-SSHScript `
        -RaspberryHost $RaspberryHost `
        -User $User `
        -Script "sudo journalctl --vacuum-time=14d >/dev/null 2>&1 && echo OK"

    if ($LASTEXITCODE -ne 0 -or $logsResult -notmatch "OK")
    {
        Complete-UIProgress
        Write-Host "[ERROR] No se pudo completar la limpieza." -ForegroundColor Red
        return
    }

    Show-UIProgress -Stage "Registros eliminados. Finalizando limpieza..." -Percent 90
    Show-UIProgress -Stage "Limpieza del sistema terminada." -Percent 100
    Complete-UIProgress

    $freeAfterText = Invoke-SSHCommand `
        -RaspberryHost $RaspberryHost `
        -User $User `
        -Command "df -B1 / | awk 'NR==2 {print `$4}'"
    [long]$freeAfter = 0
    $freeAfterValue = @($freeAfterText | Select-Object -Last 1)[0]

    if ($freeAfterValue)
    {
        [void][long]::TryParse($freeAfterValue.ToString().Trim(), [ref]$freeAfter)
    }
    $freedBytes = [math]::Max(0, $freeAfter - $freeBefore)

    $freedSpace = if ($freedBytes -ge 1GB) {
        "{0:N2} GB" -f ($freedBytes / 1GB)
    }
    elseif ($freedBytes -ge 1MB) {
        "{0:N2} MB" -f ($freedBytes / 1MB)
    }
    elseif ($freedBytes -ge 1KB) {
        "{0:N2} KB" -f ($freedBytes / 1KB)
    }
    else {
        "$freedBytes bytes"
    }

    Write-Host "[OK] Limpieza del sistema terminada." -ForegroundColor Green
    Write-Host "Espacio liberado en disco: $freedSpace" -ForegroundColor Green
}


function Save-RaspberryDiagnosticReport
{
    param
    (
        [string]$RaspberryHost,
        [string]$User,
        [string]$ReportsFolder
    )

    if (-not (Confirm-ToolAction `
        -Title "Crear informe de diagnostico" `
        -Description "Guarda un informe con red, temperatura, memoria, disco y estado de Pi-hole." `
        -Duration "10 a 20 segundos"))
    {
        Write-Host "[INFO] Informe cancelado." -ForegroundColor Yellow
        return
    }

    $reportScript = @'
echo "PCJ Raspberry - Informe de diagnostico"
echo "Fecha: $(date)"
echo ""
echo "Nombre de la Raspberry: $(hostname)"
echo "Tiempo activo: $(uptime -p)"
echo ""
echo "Red:"
ip -brief address
ip route | awk '/default/ {print "Puerta de enlace: " $3; exit}'
echo ""
echo "Pi-hole: $(systemctl is-active pihole-FTL 2>/dev/null)"
echo "DNS: $(sudo pihole-FTL --config dns.upstreams 2>/dev/null)"
echo "Temperatura: $(vcgencmd measure_temp 2>/dev/null)"
echo ""
echo "Memoria RAM:"
free -h
echo ""
echo "Disco:"
df -h /
'@

    Show-UIProgress -Stage "Obteniendo informacion de la Raspberry..." -Percent 10

    $report = Invoke-SSHScript `
        -RaspberryHost $RaspberryHost `
        -User $User `
        -Script $reportScript

    if (-not $report)
    {
        Complete-UIProgress
        Write-Host "[ERROR] No se pudo crear el informe." -ForegroundColor Red
        return
    }

    Show-UIProgress -Stage "Guardando informe en su PC..." -Percent 70

    if (-not (Test-Path $ReportsFolder))
    {
        New-Item -ItemType Directory -Path $ReportsFolder -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $reportFile = Join-Path $ReportsFolder "pcj-raspberry-informe-$timestamp.txt"
    Set-Content -LiteralPath $reportFile -Value $report -Encoding UTF8

    Show-UIProgress -Stage "Informe creado correctamente." -Percent 100
    Complete-UIProgress
    Write-Host "[OK] Informe guardado correctamente." -ForegroundColor Green
    Write-Host ""
    Write-Host "Para consultarlo despues, abra la carpeta Informes dentro de PCJ Raspberry:" -ForegroundColor Yellow
    Write-Host $ReportsFolder -ForegroundColor Cyan
    Write-Host "Archivo: $(Split-Path $reportFile -Leaf)" -ForegroundColor Cyan
}
