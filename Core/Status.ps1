function Get-RaspberryStatus
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    Write-Host "[INFO] Consultando Raspberry..." -ForegroundColor Yellow
    Write-Host ""

    $status = Invoke-SSHCommand `
        -RaspberryHost $RaspberryHost `
        -User $User `
        -Command "hostname; uptime -p; vcgencmd measure_temp; df -h / | tail -1"

    if (-not $status)
    {
        Write-Host "[ERROR] No se pudo obtener el estado." -ForegroundColor Red
        return
    }

    $lines = $status -split "`n"

    Write-Host "Nombre de la Raspberry:" -ForegroundColor Cyan
    Write-Host $lines[0]
    Write-Host ""

    Write-Host "Tiempo activo:" -ForegroundColor Cyan

    $uptime = $lines[1] -replace "up ", ""
    $uptime = $uptime -replace "weeks", "semanas"
    $uptime = $uptime -replace "week", "semana"
    $uptime = $uptime -replace "days", "dias"
    $uptime = $uptime -replace "day", "dia"
    $uptime = $uptime -replace "hours", "horas"
    $uptime = $uptime -replace "hour", "hora"
    $uptime = $uptime -replace "minutes", "minutos"
    $uptime = $uptime -replace "minute", "minuto"

    Write-Host $uptime
    Write-Host ""

    Write-Host "Temperatura:" -ForegroundColor Cyan

    $temp = $lines[2] -replace "temp=", ""
    $temp = $temp -replace "'C", " C"

    Write-Host $temp
    Write-Host ""

    Write-Host "Almacenamiento:" -ForegroundColor Cyan

    $disk = $lines[3].Split(" ",[System.StringSplitOptions]::RemoveEmptyEntries)

    Write-Host "Total: $($disk[1])   Usado: $($disk[2])   Disponible: $($disk[3])   Uso: $($disk[4])"

    Write-Host ""

    Write-Host "[OK] Consulta terminada." -ForegroundColor Green
}


function Get-RaspberryDashboardData
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    $dashboardScript = @'
printf "PIHOLE="
systemctl is-active pihole-FTL 2>/dev/null || echo "no disponible"
printf "DNS="
sudo pihole-FTL --config dns.upstreams 2>/dev/null || echo "no disponible"
printf "TEMP="
vcgencmd measure_temp 2>/dev/null | sed "s/temp=//; s/'C/ C/" || echo "no disponible"
printf "MEMORY="
free | awk '/Mem:/ {printf "%.0f%%\n", ($3/$2)*100}'
printf "DISK="
df -P / | awk 'NR==2 {print $5}'
'@

    $result = Invoke-SSHScript `
        -RaspberryHost $RaspberryHost `
        -User $User `
        -Script $dashboardScript

    if (-not $result)
    {
        return $null
    }

    $values = @{}

    foreach ($line in $result)
    {
        if ($line -match "^([^=]+)=(.*)$")
        {
            $values[$Matches[1]] = $Matches[2].Trim()
        }
    }

    return [PSCustomObject]@{
        PiHole = $values["PIHOLE"]
        DNS = $values["DNS"]
        Temperature = $values["TEMP"]
        Memory = $values["MEMORY"]
        Disk = $values["DISK"]
    }
}


function Get-DNSProviderName
{
    param
    (
        [string]$DNSValue
    )

    if ([string]::IsNullOrWhiteSpace($DNSValue) -or $DNSValue -eq "No disponible")
    {
        return "No disponible"
    }

    $dnsText = $DNSValue.ToLowerInvariant()

    if ($dnsText -match "9\.9\.9\.9|149\.112\.112\.112|2620:fe::fe")
    {
        return "Quad9"
    }

    if ($dnsText -match "1\.1\.1\.1|1\.0\.0\.1|2606:4700:4700::1111")
    {
        return "Cloudflare"
    }

    if ($dnsText -match "8\.8\.8\.8|8\.8\.4\.4|2001:4860:4860::8888")
    {
        return "Google DNS"
    }

    if ($dnsText -match "208\.67\.222\.222|208\.67\.220\.220")
    {
        return "OpenDNS"
    }

    if ($dnsText -match "94\.140\.14\.14|94\.140\.15\.15|94\.140\.14\.15|94\.140\.15\.16")
    {
        return "AdGuard DNS"
    }

    if ($dnsText -match "185\.228\.168\.9|185\.228\.169\.9")
    {
        return "CleanBrowsing"
    }

    return "Personalizado"
}
