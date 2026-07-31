function Convert-PCJBytesToText
{
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N2} KB" -f ($Bytes / 1KB)) }
    return "$Bytes bytes"
}

function Get-PCJKeyValueOutput
{
    param([object[]]$Output)
    $values = @{}
    foreach ($line in $Output)
    {
        if ($line -match '^([^=]+)=(.*)$') { $values[$Matches[1]] = $Matches[2].Trim() }
    }
    return $values
}

function Show-RaspberryHealthAssistant
{
    param([string]$RaspberryHost, [string]$User)
    Clear-Host
    Write-UIHeader -Title "Salud de la Raspberry"
    Write-Host ""
    Write-Host "Revisa temperatura, alimentacion, memoria, discos y posibles limites de rendimiento." -ForegroundColor Cyan
    Write-Host "No cambia ninguna configuracion. Tiempo estimado: 5 a 15 segundos." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. Revisar salud ahora" -ForegroundColor White
    Write-Host "   Muestra alertas que pueden indicar fuente de poder debil o falta de ventilacion." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "2. Cancelar y volver" -ForegroundColor DarkGray
    Write-Host ""
    if ((Read-UIChoice) -ne '1') { return }

    Show-UIProgress -Stage "Revisando salud de la Raspberry..." -Percent 25
    $script = @'
echo "MODELO=$(tr -d '\0' </proc/device-tree/model 2>/dev/null)"
echo "TEMPERATURA=$(vcgencmd measure_temp 2>/dev/null || echo NO_DISPONIBLE)"
echo "LIMITACION=$(vcgencmd get_throttled 2>/dev/null || echo NO_DISPONIBLE)"
echo "MEMORIA=$(free -m | awk '/Mem:/ {print $3 "/" $2 " MB"}')"
echo "DISCO=$(df -h / | awk 'NR==2 {print $3 "/" $2 " usados (" $5 ")"}')"
echo "UNIDADES=$(lsblk -o NAME,SIZE,TYPE,MOUNTPOINT -nr 2>/dev/null | tr '\n' ';')"
'@
    $values = Get-PCJKeyValueOutput (Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script $script)
    Show-UIProgress -Stage "Interpretando resultados..." -Percent 100
    Complete-UIProgress
    if ($values.Count -eq 0) { Write-Host "[ERROR] No se pudo consultar la salud de la Raspberry." -ForegroundColor Red; return }

    Write-Host ""
    Write-Host "Modelo: $($values['MODELO'])" -ForegroundColor White
    Write-Host "Temperatura: $($values['TEMPERATURA'])" -ForegroundColor Cyan
    Write-Host "Memoria RAM: $($values['MEMORIA'])" -ForegroundColor Cyan
    Write-Host "Disco principal: $($values['DISCO'])" -ForegroundColor Cyan
    Write-Host "Unidades detectadas: $($values['UNIDADES'])" -ForegroundColor DarkGray
    if ($values['LIMITACION'] -match '0x0$')
    {
        Write-Host "[OK] No se detectaron avisos de bajo voltaje ni limitacion de rendimiento." -ForegroundColor Green
    }
    elseif ($values['LIMITACION'] -and $values['LIMITACION'] -ne 'NO_DISPONIBLE')
    {
        Write-Host "[AVISO] Se detecto un posible evento de bajo voltaje, temperatura o limitacion: $($values['LIMITACION'])" -ForegroundColor Yellow
        Write-Host "Revise la fuente de poder, el cable y la ventilacion de la Raspberry." -ForegroundColor Yellow
    }
    else { Write-Host "[INFO] Este modelo no reporta el estado detallado de alimentacion." -ForegroundColor DarkGray }
}

function Show-RaspberryInternetQuality
{
    param([string]$RaspberryHost, [string]$User)
    if (-not (Confirm-ToolAction -Title "Estabilidad de Internet" -Description "Mide respuesta al router e Internet, perdida de paquetes y una descarga de prueba pequena." -Duration "15 a 30 segundos"))
    { Write-Host "[INFO] Comprobacion cancelada. Volviendo al menu anterior." -ForegroundColor Yellow; return }

    Show-UIProgress -Stage "Midiendo estabilidad de red..." -Percent 20
    $script = @'
gateway=$(ip route | awk '/default/ {print $3; exit}')
echo "ROUTER=$gateway"
echo "PING_ROUTER=$(ping -c 4 -W 2 "$gateway" 2>/dev/null | tail -1)"
echo "PING_INTERNET=$(ping -c 4 -W 3 1.1.1.1 2>/dev/null | tail -1)"
echo "VELOCIDAD=$(curl -L --max-time 20 -s -o /dev/null -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=1000000' 2>/dev/null || true)"
'@
    $values = Get-PCJKeyValueOutput (Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script $script)
    Show-UIProgress -Stage "Finalizando medicion..." -Percent 100
    Complete-UIProgress
    if ($values.Count -eq 0) { Write-Host "[ERROR] No se pudo completar la medicion." -ForegroundColor Red; return }
    Write-Host ""
    Write-Host "Router ($($values['ROUTER'])): $($values['PING_ROUTER'])" -ForegroundColor White
    Write-Host "Internet: $($values['PING_INTERNET'])" -ForegroundColor White
    [double]$speed = 0
    if ([double]::TryParse($values['VELOCIDAD'], [ref]$speed) -and $speed -gt 0) { Write-Host ("Descarga de prueba: {0:N2} Mbps" -f (($speed * 8) / 1MB)) -ForegroundColor Green }
    else { Write-Host "Descarga de prueba: no disponible." -ForegroundColor DarkGray }
    Write-Host "[OK] Prueba terminada. Una perdida de 0% y tiempos bajos indican una conexion estable." -ForegroundColor Green
}

function Show-RaspberryServicesAssistant
{
    param([string]$RaspberryHost, [string]$User)
    Clear-Host
    Write-UIHeader -Title "Servicios importantes"
    Write-Host ""
    Write-Host "Comprueba los servicios que mantienen disponible Pi-hole y el acceso remoto." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. Consultar servicios" -ForegroundColor White
    Write-Host "   Revisa Pi-hole, SSH, Tailscale, ZeroTier y Cloudflare Tunnel." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "2. Cancelar y volver" -ForegroundColor DarkGray
    Write-Host ""
    if ((Read-UIChoice) -ne '1') { return }
    $script = @'
for item in "Pi-hole|pihole-FTL" "SSH|ssh" "Tailscale|tailscaled" "ZeroTier|zerotier-one" "Cloudflare Tunnel|cloudflared"; do
  name=${item%%|*}; service=${item##*|}
  if systemctl list-unit-files "$service.service" >/dev/null 2>&1; then state=$(systemctl is-active "$service" 2>/dev/null || true); else state=NO_INSTALADO; fi
  echo "$name=$state"
done
'@
    $values = Get-PCJKeyValueOutput (Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script $script)
    if ($values.Count -eq 0) { Write-Host "[ERROR] No se pudieron consultar los servicios." -ForegroundColor Red; return }
    Write-Host ""
    foreach ($name in $values.Keys | Sort-Object)
    {
        $state=$values[$name]
        $color=if($state -eq 'active'){'Green'}elseif($state -eq 'NO_INSTALADO'){'DarkGray'}else{'Yellow'}
        $text=if($state -eq 'active'){'Activo'}elseif($state -eq 'NO_INSTALADO'){'No instalado'}else{"Estado: $state"}
        Write-Host ("{0,-20}" -f ($name + ':')) -NoNewline
        Write-Host "$([char]0x25CF) $text" -ForegroundColor $color
    }
    Write-Host ""
    Write-Host "[OK] Consulta terminada. Los servicios en verde estan listos para usarse." -ForegroundColor Green
}

function Show-RaspberryTimeAssistant
{
    param([string]$RaspberryHost, [string]$User)
    while ($true)
    {
        Clear-Host
        Write-UIHeader -Title "Hora y zona horaria"
        Write-Host ""
        $lines=@(Invoke-SSHCommand -RaspberryHost $RaspberryHost -User $User -Command "timedatectl show -p LocalTime -p Timezone -p NTPSynchronized --value 2>/dev/null" | Where-Object { $_.ToString().Trim() -ne '' })
        Write-Host "Fecha y hora: $($lines[0])" -ForegroundColor Cyan
        Write-Host "Zona horaria: $($lines[1])" -ForegroundColor Cyan
        Write-Host "Hora automatica sincronizada: $($lines[2])" -ForegroundColor $(if($lines[2] -eq 'yes'){'Green'}else{'Yellow'})
        Write-Host ""
        Write-Host "1. Activar sincronizacion automatica" -ForegroundColor White
        Write-Host "   Usa Internet para mantener correcta la fecha y hora. Recomendado." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "2. Volver" -ForegroundColor DarkGray
        Write-Host ""
        if ((Read-UIChoice) -ne '1') { return }
        if (-not (Confirm-ToolAction -Title "Activar hora automatica" -Description "Activa la sincronizacion de fecha y hora por Internet." -Duration "5 a 15 segundos")) { return }
        $result=Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script "sudo timedatectl set-ntp true && echo OK"
        if($result -match 'OK'){Write-Host "[OK] La sincronizacion automatica de hora fue activada." -ForegroundColor Green}else{Write-Host "[ERROR] No se pudo activar la sincronizacion de hora." -ForegroundColor Red}
        Pause
    }
}

function Show-RaspberryIpReservationGuide
{
    param([string]$RaspberryHost, [string]$User)
    Clear-Host
    Write-UIHeader -Title "Reservar IP en el router"
    Write-Host ""
    Write-Host "Una reserva evita que cambie la IP que usan Pi-hole, SSH y este programa." -ForegroundColor Cyan
    Write-Host "No modifica nada automaticamente: cada router tiene un menu diferente." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. Obtener datos de la Raspberry" -ForegroundColor White
    Write-Host "   Muestra IP, direccion fisica y puerta de enlace para anotarlas en el router." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "2. Cancelar y volver" -ForegroundColor DarkGray
    Write-Host ""
    if((Read-UIChoice) -ne '1'){return}
    $result=Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script "echo IP=`$(hostname -I | awk '{print `$1}'); echo MAC=`$(cat /sys/class/net/eth0/address 2>/dev/null || cat /sys/class/net/wlan0/address 2>/dev/null); echo ROUTER=`$(ip route | awk '/default/ {print `$3; exit}')"
    $v=Get-PCJKeyValueOutput $result
    Write-Host ""
    Write-Host "IP actual de la Raspberry: $($v['IP'])" -ForegroundColor Green
    Write-Host "Direccion fisica (MAC): $($v['MAC'])" -ForegroundColor Green
    Write-Host "Direccion del router: $($v['ROUTER'])" -ForegroundColor Green
    Write-Host ""
    Write-Host "En el router busque: Reserva DHCP, Direccion IP reservada o Static lease." -ForegroundColor Cyan
    Write-Host "Cree una reserva usando la MAC mostrada y la IP actual de la Raspberry." -ForegroundColor Cyan
}

function Show-PiHoleInsights
{
    param([string]$RaspberryHost, [string]$User)
    Clear-Host; Write-UIHeader -Title "Resumen de actividad de Pi-hole"; Write-Host ""
    Write-Host "Muestra el estado, el espacio del historial y datos basicos sin modificar Pi-hole." -ForegroundColor Cyan
    Write-Host ""; Write-Host "1. Consultar resumen" -ForegroundColor White; Write-Host "   Revisa servicio DNS, historial almacenado y espacio ocupado." -ForegroundColor Cyan
    Write-Host ""; Write-Host "2. Cancelar y volver" -ForegroundColor DarkGray; Write-Host ""
    if((Read-UIChoice) -ne '1'){return}
    $script=@'
db=$(sudo pihole-FTL --config files.database 2>/dev/null | tail -1); [ -f "$db" ] || db=/etc/pihole/pihole-FTL.db
echo "SERVICIO=$(systemctl is-active pihole-FTL 2>/dev/null || true)"; echo "TAMANO=$(sudo stat -c%s "$db" 2>/dev/null || echo 0)"; echo "RETENCION=$(sudo pihole-FTL --config database.maxDBdays 2>/dev/null | tail -1)"
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$db" ]; then echo "CONSULTAS=$(sudo sqlite3 "$db" 'SELECT COUNT(*) FROM queries;' 2>/dev/null || echo NO_DISPONIBLE)"; fi
'@
    $v=Get-PCJKeyValueOutput (Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script $script)
    if($v.Count -eq 0){Write-Host "[ERROR] No se pudo consultar Pi-hole." -ForegroundColor Red;return}
    [long]$size=0;[void][long]::TryParse($v['TAMANO'],[ref]$size)
    Write-Host ""; Write-Host "Servicio DNS: $($v['SERVICIO'])" -ForegroundColor $(if($v['SERVICIO'] -eq 'active'){'Green'}else{'Yellow'})
    Write-Host "Historial guardado: $(Convert-PCJBytesToText $size)" -ForegroundColor Cyan
    Write-Host "Conservacion configurada: $($v['RETENCION']) dias" -ForegroundColor Cyan
    if($v['CONSULTAS']){Write-Host "Consultas registradas: $($v['CONSULTAS'])" -ForegroundColor Cyan}
    Write-Host "[OK] Resumen terminado. Este historial corresponde a consultas DNS, no a respaldos de su PC." -ForegroundColor Green
}

function Show-PiHoleDomainCheck
{
    param([string]$RaspberryHost, [string]$User)
    Clear-Host; Write-UIHeader -Title "Comprobar dominio en Pi-hole"; Write-Host ""
    Write-Host "Busca dominios en las listas configuradas de Pi-hole." -ForegroundColor Cyan
    Write-Host "Puede buscar un dominio exacto o solo una palabra para encontrar coincidencias parecidas." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. Buscar dominio exacto" -ForegroundColor White
    Write-Host "   Ejemplo: google.com. Busca solamente ese dominio exacto." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "2. Buscar coincidencias" -ForegroundColor White
    Write-Host "   Ejemplo: google. Puede encontrar google.com, googleapis.com y nombres parecidos." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "3. Cancelar y volver" -ForegroundColor DarkGray
    Write-Host ""
    $mode=Read-UIChoice
    if($mode -eq '3'){return}
    if($mode -notin @('1','2')){return}
    $prompt=if($mode -eq '1'){'Dominio exacto: '}else{'Palabra o parte del dominio: '}
    Write-Host "Escriba 0 para cancelar y volver." -ForegroundColor DarkGray
    $domain=Read-UIColoredInput -Prompt $prompt
    if([string]::IsNullOrWhiteSpace($domain) -or $domain -eq '0'){return}
    if($domain -notmatch '^[A-Za-z0-9.-]+$'){Write-Host "[ERROR] Escriba solo un dominio, por ejemplo: ejemplo.com" -ForegroundColor Red;return}
    Show-UIProgress -Stage "Buscando dominio en las listas..." -Percent 50
    $searchOption=if($mode -eq '1'){'--exact'}else{'--partial'}
    $result=Invoke-SSHCommand -RaspberryHost $RaspberryHost -User $User -Command "sudo pihole -q $searchOption -adlist '$domain' 2>&1"
    Show-UIProgress -Stage "Busqueda terminada." -Percent 100;Complete-UIProgress;Write-Host ""
    $allowedDomains = New-Object System.Collections.Generic.List[string]
    $blockedDomains = New-Object System.Collections.Generic.List[string]
    $blockSources = New-Object System.Collections.Generic.List[string]
    $readingBlockList = $false

    foreach ($rawLine in @($result))
    {
        $line = $rawLine.ToString().Trim()

        if ($line -match '^[- ]*([A-Za-z0-9.-]+)\s+\(type:\s+.+\s+allow domain\)$')
        {
            $allowedDomains.Add($Matches[1])
            $readingBlockList = $false
            continue
        }

        if ($line -match '^[- ]*(https?://.+)\s+\(block\)$')
        {
            $blockSources.Add($Matches[1])
            $readingBlockList = $true
            continue
        }

        if ($readingBlockList -and $line -match '^[- ]*([A-Za-z0-9.-]+)$')
        {
            $blockedDomains.Add($Matches[1])
        }
    }

    Write-Host "Interpretacion de resultados:" -ForegroundColor Cyan
    Write-Host ""

    $uniqueAllowedDomains = @($allowedDomains | Select-Object -Unique)
    $uniqueBlockedDomains = @($blockedDomains | Select-Object -Unique)
    $shownBlockedDomains = @($uniqueBlockedDomains | Select-Object -First 40)

    if ($uniqueAllowedDomains.Count -gt 0)
    {
        Write-Host "DOMINIOS PERMITIDOS: $($uniqueAllowedDomains.Count)" -ForegroundColor Green
        for ($index = 0; $index -lt $uniqueAllowedDomains.Count; $index++)
        {
            Write-Host "  $($index + 1). $($uniqueAllowedDomains[$index])  - permitido por su lista blanca" -ForegroundColor Green
        }
        Write-Host ""
    }

    if ($uniqueBlockedDomains.Count -gt 0)
    {
        Write-Host "DOMINIOS BLOQUEADOS EN LAS LISTAS: $($uniqueBlockedDomains.Count)" -ForegroundColor Red
        Write-Host "Estos dominios aparecen en una lista de bloqueo. Pi-hole los bloqueara cuando se consulten exactamente." -ForegroundColor Cyan
        for ($index = 0; $index -lt $shownBlockedDomains.Count; $index++)
        {
            Write-Host "  $($index + 1). $($shownBlockedDomains[$index])" -ForegroundColor Red
        }
        if ($uniqueBlockedDomains.Count -gt 40)
        {
            Write-Host "  Se muestran los primeros 40 resultados." -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    if ($blockSources.Count -gt 0)
    {
        Write-Host "Lista que contiene estas coincidencias:" -ForegroundColor Cyan
        foreach ($source in ($blockSources | Select-Object -Unique))
        {
            Write-Host "  $source" -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    if ($uniqueAllowedDomains.Count -eq 0 -and $uniqueBlockedDomains.Count -eq 0)
    {
        $type = if($mode -eq '1'){'exacto'}else{'parecido'}
        Write-Host "[OK] No se encontro ningun dominio $type para '$domain' en las listas de bloqueo." -ForegroundColor Green
        Write-Host "Esto no garantiza que la pagina no tenga otros dominios relacionados." -ForegroundColor Cyan
    }
    else
    {
        Write-Host "Nota: una pagina puede usar muchos dominios. Que uno este permitido no implica que todos los demas tambien lo esten." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Que desea hacer?" -ForegroundColor Cyan
        if ($shownBlockedDomains.Count -gt 0)
        {
            Write-Host "1. Permitir un dominio bloqueado" -ForegroundColor White
            Write-Host "   Lo agrega a la lista blanca. Esta regla tiene prioridad sobre las listas de bloqueo." -ForegroundColor Cyan
        }
        if ($uniqueAllowedDomains.Count -gt 0)
        {
            Write-Host "2. Bloquear un dominio permitido" -ForegroundColor White
            Write-Host "   Quita su regla de lista blanca y lo agrega a la lista de bloqueo." -ForegroundColor Cyan
        }
        Write-Host "3. No realizar cambios y volver" -ForegroundColor DarkGray
        Write-Host ""

        $action = Read-UIChoice

        if ($action -eq '1' -and $shownBlockedDomains.Count -gt 0)
        {
            Write-Host ""
            Write-Host "Que desea hacer?" -ForegroundColor Cyan
            Write-Host "1. Elegir un dominio bloqueado para permitir" -ForegroundColor White
            Write-Host "   Despues escribira el numero que aparece junto al dominio rojo." -ForegroundColor Cyan
            Write-Host "0. Cancelar y volver" -ForegroundColor DarkGray
            Write-Host ""
            if ((Read-UIChoice) -ne '1')
            {
                Write-Host "[INFO] No se realizo ningun cambio. Volviendo al menu anterior." -ForegroundColor Yellow
                return
            }
            Write-Host ""
            Write-Host "Escriba el numero del dominio bloqueado que desea permitir." -ForegroundColor Cyan
            Write-Host "Puede escribir 0 para cancelar y volver." -ForegroundColor DarkGray
            $selection = Read-UIChoice -Prompt "Numero de dominio bloqueado"
            [int]$selectedNumber = 0

            if ($selection -eq '0' -or -not [int]::TryParse($selection, [ref]$selectedNumber) -or $selectedNumber -lt 1 -or $selectedNumber -gt $shownBlockedDomains.Count)
            {
                Write-Host "[INFO] No se realizo ningun cambio." -ForegroundColor Yellow
                return
            }

            $selectedDomain = $shownBlockedDomains[$selectedNumber - 1]
            if (-not (Confirm-ToolAction -Title "Permitir dominio en Pi-hole" -Description "Agregara '$selectedDomain' a la lista blanca de Pi-hole." -Duration "5 a 15 segundos" -Warning "Este dominio dejara de bloquearse aunque aparezca en una lista de bloqueo."))
            {
                Write-Host "[INFO] Cambio cancelado. El dominio continuara bloqueado." -ForegroundColor Yellow
                return
            }

            $changeResult = Invoke-SSHCommand -RaspberryHost $RaspberryHost -User $User -Command "sudo pihole allow '$selectedDomain' 2>&1"
            if ($LASTEXITCODE -eq 0)
            {
                Write-Host "[OK] '$selectedDomain' fue agregado a la lista blanca." -ForegroundColor Green
                Write-Host "Pi-hole permitira este dominio a partir de ahora." -ForegroundColor Green
            }
            else
            {
                Write-Host "[ERROR] No se pudo agregar el dominio a la lista blanca." -ForegroundColor Red
                $changeResult | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
            }
        }
        elseif ($action -eq '2' -and $uniqueAllowedDomains.Count -gt 0)
        {
            Write-Host ""
            Write-Host "Que desea hacer?" -ForegroundColor Cyan
            Write-Host "1. Elegir un dominio permitido para bloquear" -ForegroundColor White
            Write-Host "   Despues escribira el numero que aparece junto al dominio verde." -ForegroundColor Cyan
            Write-Host "0. Cancelar y volver" -ForegroundColor DarkGray
            Write-Host ""
            if ((Read-UIChoice) -ne '1')
            {
                Write-Host "[INFO] No se realizo ningun cambio. Volviendo al menu anterior." -ForegroundColor Yellow
                return
            }
            Write-Host ""
            Write-Host "Escriba el numero del dominio permitido que desea bloquear." -ForegroundColor Cyan
            Write-Host "Puede escribir 0 para cancelar y volver." -ForegroundColor DarkGray
            $selection = Read-UIChoice -Prompt "Numero de dominio permitido"
            [int]$selectedNumber = 0

            if ($selection -eq '0' -or -not [int]::TryParse($selection, [ref]$selectedNumber) -or $selectedNumber -lt 1 -or $selectedNumber -gt $uniqueAllowedDomains.Count)
            {
                Write-Host "[INFO] No se realizo ningun cambio." -ForegroundColor Yellow
                return
            }

            $selectedDomain = $uniqueAllowedDomains[$selectedNumber - 1]
            if (-not (Confirm-ToolAction -Title "Bloquear dominio en Pi-hole" -Description "Quitara '$selectedDomain' de la lista blanca y lo agregara a la lista de bloqueo." -Duration "5 a 15 segundos" -Warning "Las paginas o aplicaciones que dependan de este dominio podrian dejar de funcionar."))
            {
                Write-Host "[INFO] Cambio cancelado. El dominio continuara permitido." -ForegroundColor Yellow
                return
            }

            $changeResult = Invoke-SSHCommand -RaspberryHost $RaspberryHost -User $User -Command "sudo pihole deny '$selectedDomain' 2>&1 && sudo pihole allow remove '$selectedDomain' 2>&1"
            if ($LASTEXITCODE -eq 0)
            {
                Write-Host "[OK] '$selectedDomain' fue quitado de la lista blanca y agregado a la lista de bloqueo." -ForegroundColor Green
            }
            else
            {
                Write-Host "[ERROR] No se pudo completar el cambio de bloqueo." -ForegroundColor Red
                Write-Host "Revise el resultado o vuelva a buscar el dominio antes de intentarlo de nuevo." -ForegroundColor Yellow
                $changeResult | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
            }
        }
    }
}

function Show-PiHoleHistoryAssistant
{
    param([string]$RaspberryHost, [string]$User)
    while($true)
    {
        Clear-Host;Write-UIHeader -Title "Historial DNS de Pi-hole";Write-Host ""
        Write-Host "Este historial son consultas DNS guardadas dentro de la Raspberry." -ForegroundColor Cyan
        Write-Host "Es diferente de los respaldos: borrar respaldos de la PC no elimina este historial." -ForegroundColor Cyan
        Write-Host "";Write-Host "1. Conservar historial por 30 dias" -ForegroundColor White;Write-Host "   Pi-hole eliminara automaticamente consultas mas antiguas. Recomendado para ahorrar espacio." -ForegroundColor Cyan
        Write-Host "";Write-Host "2. Conservar historial por 90 dias" -ForegroundColor White;Write-Host "   Mantiene mas informacion para revisar, ocupando mas espacio." -ForegroundColor Cyan
        Write-Host "";Write-Host "3. Vaciar solo el registro operativo" -ForegroundColor White;Write-Host "   Borra el archivo de registro actual; no borra listas, ajustes ni respaldos." -ForegroundColor Cyan
        Write-Host "";Write-Host "4. Volver" -ForegroundColor DarkGray;Write-Host ""
        $choice=Read-UIChoice;if($choice -eq '4'){return}
        if($choice -in @('1','2'))
        {
            $days=if($choice -eq '1'){30}else{90}
            if(-not (Confirm-ToolAction -Title "Cambiar conservacion del historial" -Description "Pi-hole conservara las consultas DNS durante $days dias y eliminara las mas antiguas automaticamente." -Duration "5 a 15 segundos" -Warning "No borra listas de bloqueo ni respaldos.")){return}
            $r=Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script "sudo pihole-FTL --config database.maxDBdays $days >/dev/null && echo OK"
            if($r -match 'OK'){Write-Host "[OK] Pi-hole conservara el historial DNS durante $days dias." -ForegroundColor Green}else{Write-Host "[ERROR] No se pudo cambiar la conservacion del historial." -ForegroundColor Red};Pause
        }
        elseif($choice -eq '3')
        {
            if(-not (Confirm-ToolAction -Title "Vaciar registro operativo de Pi-hole" -Description "Borra el registro actual de actividad DNS de Pi-hole." -Duration "5 a 15 segundos" -Warning "No modifica listas, ajustes, respaldos ni la conservacion del historial.")){return}
            $r=Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script "sudo pihole flush >/dev/null 2>&1 && echo OK"
            if($r -match 'OK'){Write-Host "[OK] El registro operativo de Pi-hole fue vaciado." -ForegroundColor Green}else{Write-Host "[ERROR] No se pudo vaciar el registro operativo." -ForegroundColor Red};Pause
        }
    }
}

function Show-RaspberryWifiPriorityAssistant
{
    param([string]$RaspberryHost, [string]$User)
    while ($true)
    {
        Clear-Host
        Write-UIHeader -Title "Prioridad de redes Wi-Fi"
        Write-Host ""
        Write-Host "Define cual red conocida debe preferir la Raspberry cuando encuentre varias disponibles." -ForegroundColor Cyan
        Write-Host "No desconecta la red actual: el cambio se usa en la proxima reconexion." -ForegroundColor Cyan
        Write-Host ""

        $currentWifi = Invoke-SSHCommand `
            -RaspberryHost $RaspberryHost `
            -User $User `
            -Command "if command -v nmcli >/dev/null 2>&1; then nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | grep '^yes:' | cut -d: -f2- | head -1; else iwgetid -r 2>/dev/null; fi"
        $currentWifiName = @($currentWifi | Where-Object { $_.ToString().Trim() -ne '' } | Select-Object -First 1)[0]

        if ($currentWifiName)
        {
            Write-Host "Wi-Fi conectado actualmente: $currentWifiName" -ForegroundColor Green
            Write-Host ""
        }

        $result = Invoke-SSHCommand -RaspberryHost $RaspberryHost -User $User -Command "nmcli -t -f NAME,TYPE,AUTOCONNECT-PRIORITY connection show 2>/dev/null"
        $networks = @($result | Where-Object { $_ -match ':(wifi|802-11-wireless):' })
        if ($networks.Count -eq 0)
        {
            if ($currentWifiName)
            {
                Write-Host "[INFO] La Raspberry si esta conectada por Wi-Fi a '$currentWifiName'." -ForegroundColor Green
                Write-Host "Esta opcion solo muestra redes guardadas que el administrador de red permite ordenar por prioridad." -ForegroundColor Cyan
                Write-Host "En esta version del sistema, la red actual no se puede ordenar automaticamente desde este apartado." -ForegroundColor Yellow
            }
            else
            {
                Write-Host "[INFO] No se encontraron redes Wi-Fi guardadas que puedan ordenarse por prioridad." -ForegroundColor Yellow
                Write-Host "Esto no confirma por si solo que el Wi-Fi este apagado: puede usar otro administrador de red." -ForegroundColor Cyan
            }
            Write-Host ""
            Write-Host "1. Volver" -ForegroundColor DarkGray
            Read-UIChoice | Out-Null
            return
        }

        Write-Host "Redes guardadas:" -ForegroundColor Cyan
        for ($i=0; $i -lt $networks.Count; $i++)
        {
            $parts=$networks[$i] -split ':'
            [int]$storedPriority = 0
            [void][int]::TryParse($parts[-1], [ref]$storedPriority)
            $priorityText = if ($storedPriority -ge 900 -and $storedPriority -le 999) {
                "Posicion " + (1000 - $storedPriority) + " (1 se intenta primero)"
            }
            else {
                "Sin orden personalizado"
            }
            Write-Host "$($i + 1). $($parts[0])" -ForegroundColor White
            Write-Host "   Orden actual: $priorityText" -ForegroundColor Cyan
        }
        Write-Host ""
        Write-Host "0. Cancelar y volver" -ForegroundColor DarkGray
        $choice=Read-UIChoice -Prompt "Seleccione una red"
        if($choice -eq '0'){return}
        [int]$index=0
        if(-not [int]::TryParse($choice,[ref]$index) -or $index -lt 1 -or $index -gt $networks.Count){continue}
        $networkName=($networks[$index-1] -split ':')[0]
        Write-Host ""
        Write-Host "Red seleccionada: $networkName" -ForegroundColor Green
        Write-Host "Escriba la posicion que desea para esta red." -ForegroundColor Cyan
        Write-Host "1 = red principal; se intenta primero.  2 = segunda opcion; se intenta si la primera no esta disponible." -ForegroundColor Cyan
        Write-Host "Puede usar de 1 a 100 para ordenar varias redes guardadas." -ForegroundColor Cyan
        Write-Host "Escriba 0 para cancelar y volver." -ForegroundColor DarkGray
        $priority=Read-UIColoredInput -Prompt "Posicion de la red: "
        [int]$priorityNumber=0
        if($priority -eq '0'){return}
        if(-not [int]::TryParse($priority,[ref]$priorityNumber) -or $priorityNumber -lt 1 -or $priorityNumber -gt 100)
        { Write-Host "[ERROR] Escriba una posicion entre 1 y 100." -ForegroundColor Red; Pause; continue }
        if(-not (Confirm-ToolAction -Title "Cambiar prioridad Wi-Fi" -Description "La red '$networkName' quedara en la posicion $priorityNumber. La posicion 1 se intenta primero; 2 despues, y asi sucesivamente." -Duration "5 a 10 segundos" -Warning "No asigne la misma posicion a varias redes si desea un orden claro.")){return}
        $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($networkName))
        $networkManagerPriority = 1000 - $priorityNumber
        $apply="name=`$(echo $encoded | base64 -d); sudo nmcli connection modify `"`$name`" connection.autoconnect-priority $networkManagerPriority && echo OK"
        $changed=Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script $apply
        if($changed -match 'OK'){Write-Host "[OK] '$networkName' quedo en la posicion $priorityNumber." -ForegroundColor Green;Write-Host "La Raspberry intentara primero las redes con numero mas bajo." -ForegroundColor Cyan}else{Write-Host "[ERROR] No se pudo actualizar la prioridad Wi-Fi." -ForegroundColor Red}
        Pause
    }
}

function Show-RaspberryDesktopRemoteAssistant
{
    param([string]$RaspberryHost, [string]$User)
    while($true)
    {
        Clear-Host
        Write-UIHeader -Title "Acceso grafico remoto"
        Write-Host ""
        Write-Host "Raspberry Pi Connect permite ver y controlar el escritorio desde un navegador." -ForegroundColor Cyan
        Write-Host "Solo funciona en Raspberry Pi OS con escritorio; no esta disponible en Raspberry Pi OS Lite." -ForegroundColor Cyan
        Write-Host ""
        $status=Invoke-SSHCommand -RaspberryHost $RaspberryHost -User $User -Command "if command -v rpi-connect >/dev/null 2>&1; then echo INSTALADO; else echo NO_INSTALADO; fi"
        $installed=($status -match 'INSTALADO') -and -not ($status -match 'NO_INSTALADO')
        Write-Host "Raspberry Pi Connect: $(if($installed){'Instalado'}else{'No instalado'})" -ForegroundColor $(if($installed){'Green'}else{'DarkGray'})
        Write-Host ""
        if(-not $installed)
        {
            Write-Host "1. Instalar Raspberry Pi Connect" -ForegroundColor White
            Write-Host "   Instala la herramienta oficial; despues iniciara sesion con una cuenta de Raspberry Pi en el navegador." -ForegroundColor Cyan
            Write-Host ""
            Write-Host "2. Volver" -ForegroundColor DarkGray
            $choice=Read-UIChoice
            if($choice -ne '1'){return}
            if(-not (Confirm-ToolAction -Title "Instalar Raspberry Pi Connect" -Description "Descarga e instala el acceso grafico remoto oficial de Raspberry Pi." -Duration "1 a 5 minutos" -Warning "Requiere Raspberry Pi OS con escritorio y conexion a Internet.")){return}
            Show-UIProgress -Stage "Instalando Raspberry Pi Connect..." -Percent 40
            $install=Invoke-SSHScript -RaspberryHost $RaspberryHost -User $User -Script "sudo apt-get update && sudo apt-get install -y rpi-connect && echo OK"
            Show-UIProgress -Stage "Instalacion terminada." -Percent 100;Complete-UIProgress
            if($install -match 'OK'){Write-Host "[OK] Raspberry Pi Connect fue instalado." -ForegroundColor Green;Write-Host "Abra el escritorio de la Raspberry y active Raspberry Pi Connect para vincular su cuenta." -ForegroundColor Cyan}else{Write-Host "[ERROR] No se pudo instalar Raspberry Pi Connect." -ForegroundColor Red}
            Pause
        }
        else
        {
            Write-Host "1. Abrir pagina oficial de Raspberry Pi Connect" -ForegroundColor White
            Write-Host "   Abre la pagina para iniciar sesion y administrar equipos vinculados." -ForegroundColor Cyan
            Write-Host ""
            Write-Host "2. Volver" -ForegroundColor DarkGray
            if((Read-UIChoice) -eq '1'){Start-Process 'https://connect.raspberrypi.com/';Write-Host "[OK] Se abrio la pagina de Raspberry Pi Connect." -ForegroundColor Green;Pause}else{return}
        }
    }
}

function Enable-RaspberryTailscaleSSH
{
    param([string]$RaspberryHost, [string]$User)
    if(-not (Confirm-ToolAction -Title "Activar SSH protegido por Tailscale" -Description "Permite iniciar sesiones SSH a traves de Tailscale sin abrir puertos en el router." -Duration "5 a 15 segundos" -Warning "Necesita tener Tailscale conectado y reglas de acceso autorizadas en su cuenta.")){return}
    $result=Invoke-SSHCommand -RaspberryHost $RaspberryHost -User $User -Command "sudo tailscale set --ssh 2>&1"
    if($LASTEXITCODE -eq 0){Write-Host "[OK] Tailscale SSH fue activado." -ForegroundColor Green;Write-Host "Use las reglas de acceso de Tailscale para decidir quien puede conectarse." -ForegroundColor Cyan}else{Write-Host "[ERROR] No se pudo activar Tailscale SSH." -ForegroundColor Red;$result|ForEach-Object{Write-Host $_ -ForegroundColor DarkGray}}
}
