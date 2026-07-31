function Get-PCJProfileRoot
{
    return (Join-Path $env:USERPROFILE ".pcj-raspberry\profiles")
}


function Set-PCJIniValue
{
    param
    (
        [string]$File,
        [string]$Section,
        [string]$Key,
        [string]$Value
    )

    $lines = if (Test-Path $File) { @(Get-Content -LiteralPath $File) } else { @() }
    $insideSection = $false
    $sectionFound = $false

    for ($index = 0; $index -lt $lines.Count; $index++)
    {
        if ($lines[$index] -match "^\[(.+)\]$")
        {
            $insideSection = ($Matches[1] -eq $Section)

            if ($insideSection)
            {
                $sectionFound = $true
            }

            continue
        }

        if ($insideSection -and $lines[$index] -match "^(.+?)=(.*)$" -and $Matches[1].Trim() -eq $Key)
        {
            $lines[$index] = "$Key=$Value"
            Set-Content -LiteralPath $File -Value $lines
            return
        }
    }

    if (-not $sectionFound)
    {
        if ($lines.Count -gt 0)
        {
            $lines += ""
        }

        $lines += "[$Section]"
    }

    $lines += "$Key=$Value"
    Set-Content -LiteralPath $File -Value $lines
}


function Get-PCJProfileFile
{
    param([string]$ProfileId)

    return (Join-Path (Get-PCJProfileRoot) "$ProfileId.ini")
}


function Get-PCJSavedProfiles
{
    $profileRoot = Get-PCJProfileRoot

    if (-not (Test-Path $profileRoot))
    {
        return @()
    }

    return @(
        Get-ChildItem -Path $profileRoot -Filter "*.ini" -File | ForEach-Object {
            [PSCustomObject]@{
                Id = Get-IniValue -File $_.FullName -Section "Profile" -Key "Id"
                Name = Get-IniValue -File $_.FullName -Section "Profile" -Key "Name"
                Host = Get-IniValue -File $_.FullName -Section "Raspberry" -Key "Host"
                User = Get-IniValue -File $_.FullName -Section "Raspberry" -Key "User"
                KeyFile = Get-IniValue -File $_.FullName -Section "SSH" -Key "KeyFile"
                File = $_.FullName
                RegisteredAt = $_.CreationTimeUtc
            }
        } | Where-Object { $_.Id -and $_.Host -and $_.User } | Sort-Object RegisteredAt
    )
}


function Test-PCJProfileConnection
{
    param([PSCustomObject]$Profile)

    if (-not $Profile -or -not $Profile.Host)
    {
        return $false
    }

    $client = $null

    try
    {
        $client = [System.Net.Sockets.TcpClient]::new()
        $connectionAttempt = $client.BeginConnect($Profile.Host, 22, $null, $null)

        if (-not $connectionAttempt.AsyncWaitHandle.WaitOne(800))
        {
            return $false
        }

        $client.EndConnect($connectionAttempt)
        return $true
    }
    catch
    {
        return $false
    }
    finally
    {
        if ($client)
        {
            $client.Close()
        }
    }
}


function Initialize-PCJProfiles
{
    param([string]$ConfigFile)

    if (-not (Test-Path $ConfigFile))
    {
        return
    }

    $activeId = Get-IniValue -File $ConfigFile -Section "Profiles" -Key "ActiveId"

    if ($activeId)
    {
        $activeFile = Get-PCJProfileFile -ProfileId $activeId
        $storedHost = Get-IniValue -File $activeFile -Section "Raspberry" -Key "Host"
        $configuredHost = Get-IniValue -File $ConfigFile -Section "Raspberry" -Key "Host"

        if ($storedHost -match "^System\.Management\.Automation\.Internal\.Host" -and $configuredHost)
        {
            Set-PCJIniValue -File $activeFile -Section "Raspberry" -Key "Host" -Value $configuredHost
        }

        return
    }

    $raspberryHost = Get-IniValue -File $ConfigFile -Section "Raspberry" -Key "Host"
    $user = Get-IniValue -File $ConfigFile -Section "Raspberry" -Key "User"
    $legacyKey = Join-Path $env:USERPROFILE ".pcj-raspberry\id_ed25519"

    if (-not $raspberryHost -or -not $user -or -not (Test-Path $legacyKey))
    {
        return
    }

    $profileRoot = Get-PCJProfileRoot
    New-Item -ItemType Directory -Path $profileRoot -Force | Out-Null
    $profileId = "principal"
    $profileFile = Get-PCJProfileFile -ProfileId $profileId

    if (-not (Test-Path $profileFile))
    {
@"
[Profile]
Id=$profileId
Name=Raspberry principal

[Raspberry]
Host=$raspberryHost
User=$user

[SSH]
KeyFile=$legacyKey
"@ | Set-Content -LiteralPath $profileFile
    }

    Set-PCJIniValue -File $ConfigFile -Section "Profiles" -Key "ActiveId" -Value $profileId
}


function Get-PCJActiveProfile
{
    param([string]$ConfigFile)

    if ($script:PCJTemporaryProfile)
    {
        return $script:PCJTemporaryProfile
    }

    Initialize-PCJProfiles -ConfigFile $ConfigFile
    $activeId = Get-IniValue -File $ConfigFile -Section "Profiles" -Key "ActiveId"

    if (-not $activeId)
    {
        return $null
    }

    return (Get-PCJSavedProfiles | Where-Object { $_.Id -eq $activeId } | Select-Object -First 1)
}


function Set-PCJActiveProfile
{
    param
    (
        [string]$ConfigFile,
        [PSCustomObject]$Profile
    )

    if ($script:PCJTemporaryProfile)
    {
        Close-PCJTemporarySession
    }
    Set-PCJIniValue -File $ConfigFile -Section "Profiles" -Key "ActiveId" -Value $Profile.Id
    Set-PCJIniValue -File $ConfigFile -Section "Raspberry" -Key "Host" -Value $Profile.Host
    Set-PCJIniValue -File $ConfigFile -Section "Raspberry" -Key "User" -Value $Profile.User
}


function Select-PCJStartupProfile
{
    param([string]$ConfigFile)

    $profiles = @(Get-PCJSavedProfiles)

    if ($profiles.Count -le 1)
    {
        return ($profiles | Select-Object -First 1)
    }

    while ($true)
    {
        Clear-Host
        Write-UIHeader -Title "Seleccionar Raspberry"
        Write-Host ""
        Write-UIRaspberryLogo -Static
        Write-Host ""
        Write-Host "Sesiones y usuarios guardados:" -ForegroundColor Cyan
        Write-Host "Seleccione la Raspberry que desea administrar en esta sesion." -ForegroundColor DarkGray
        Write-Host ""

        $profileStates = @()

        foreach ($profile in $profiles)
        {
            $isOnline = (Test-Path $profile.KeyFile) -and (Test-PCJProfileConnection -Profile $profile)
            $profileStates += [PSCustomObject]@{
                Profile = $profile
                Online = $isOnline
            }
        }

        for ($index = 0; $index -lt $profileStates.Count; $index++)
        {
            $number = $index + 1
            $item = $profileStates[$index]
            $statusSymbol = [char]0x25CF
            $statusText = if ($item.Online) { "En linea" } else { "Fuera de linea" }
            $statusColor = if ($item.Online) { "Green" } else { "DarkGray" }

            Write-Host "$number. $statusSymbol Usuario: $($item.Profile.User) ($($item.Profile.Name)) - $statusText" -ForegroundColor $statusColor
            Write-Host "   Raspberry: $($item.Profile.Host)" -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host "0. Salir"
        $selection = Read-UIChoice -Prompt "Seleccione una Raspberry"
        $selectedNumber = 0

        if ($selection -eq "0")
        {
            return $null
        }

        if (-not ([int]::TryParse($selection, [ref]$selectedNumber)) -or
            $selectedNumber -lt 1 -or $selectedNumber -gt $profileStates.Count)
        {
            Write-Host "[ERROR] Seleccione una opcion valida." -ForegroundColor Red
            Start-Sleep -Milliseconds 900
            continue
        }

        $selectedItem = $profileStates[$selectedNumber - 1]

        if (-not $selectedItem.Online)
        {
            Write-Host "[ERROR] Esta Raspberry esta fuera de linea; seleccione otra o enciendala." -ForegroundColor Red
            Start-Sleep -Milliseconds 1300
            continue
        }

        Set-PCJActiveProfile -ConfigFile $ConfigFile -Profile $selectedItem.Profile
        return $selectedItem.Profile
    }
}


function New-PCJProfile
{
    param
    (
        [string]$ConfigFile,
        [switch]$RequireSave,
        [switch]$ShowWelcome
    )

    if ($ShowWelcome)
    {
        Show-UIWelcome
    }

    Clear-Host
    Write-UIHeader -Title "Agregar Raspberry"
    Write-Host ""
    Write-UIRaspberryLogo -Static
    Write-Host ""
    $savedProfiles = @(Get-PCJSavedProfiles)

    Write-Host "Crea una conexion segura para una Raspberry nueva." -ForegroundColor Cyan
    Write-Host "La contrasena se usara una sola vez para instalar una llave SSH segura." -ForegroundColor Yellow
    Write-Host "La contrasena no se guarda: se guarda la llave SSH, que permite entrar despues sin pedirla." -ForegroundColor Yellow
    Write-Host "Una vez registrada la llave SSH, espere a que termine la configuracion." -ForegroundColor Yellow
    Write-Host ""

    if ($savedProfiles.Count -eq 0)
    {
        Write-Host "Aun no ha registrado ninguna Raspberry en el programa." -ForegroundColor Yellow
        Write-Host "Agregue una para crear su primer acceso seguro." -ForegroundColor Cyan
    }
    else
    {
        Write-Host "Conexiones activas actualmente:" -ForegroundColor Cyan

        foreach ($savedProfile in $savedProfiles)
        {
            $isOnline = Test-PCJProfileConnection -Profile $savedProfile
            $statusSymbol = [char]0x25CF
            $statusText = if ($isOnline) { "En linea" } else { "Fuera de linea" }
            $statusColor = if ($isOnline) { "Green" } else { "DarkGray" }

            Write-Host "$statusSymbol Usuario: $($savedProfile.User) ($($savedProfile.Name)) - $statusText" -ForegroundColor $statusColor
            Write-Host "  Raspberry: $($savedProfile.Host)" -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host "Puede iniciar sesion con un usuario guardado o agregar una Raspberry nueva." -ForegroundColor Cyan
    }

    Write-Host ""

    Write-Host "1. Agregar Raspberry nueva"

    if ($savedProfiles.Count -gt 0)
    {
        Write-Host "2. Iniciar sesion con un usuario guardado"
            Write-Host "   Elija uno de los usuarios disponibles mostrados arriba." -ForegroundColor Cyan
        Write-Host "3. Cancelar"
    }
    else
    {
        Write-Host "2. Cancelar"
    }

    Write-Host ""

    $startOption = Read-UIChoice

    if ($savedProfiles.Count -gt 0 -and $startOption -eq "2")
    {
        Clear-Host
        Write-UIHeader -Title "Conexiones y usuarios registrados"
        Write-Host ""

        $profileStates = @()

        foreach ($savedProfile in $savedProfiles)
        {
            $profileStates += [PSCustomObject]@{
                Profile = $savedProfile
                Online = Test-PCJProfileConnection -Profile $savedProfile
            }
        }

        for ($index = 0; $index -lt $profileStates.Count; $index++)
        {
            $number = $index + 1
            $item = $profileStates[$index]
            $statusSymbol = [char]0x25CF
            $statusText = if ($item.Online) { "Disponible" } else { "Fuera de linea" }
            $statusColor = if ($item.Online) { "Green" } else { "DarkGray" }

            Write-Host "$number. $statusSymbol $($item.Profile.Name) - $statusText" -ForegroundColor $statusColor
            Write-Host "   Usuario: $($item.Profile.User)   Raspberry: $($item.Profile.Host)"
        }

        Write-Host ""
        Write-Host "0. Cancelar"
        $selection = Read-UIChoice -Prompt "Seleccione una conexion"
        $selectedNumber = 0

        if ([int]::TryParse($selection, [ref]$selectedNumber) -and
            $selectedNumber -ge 1 -and $selectedNumber -le $savedProfiles.Count)
        {
            $selectedItem = $profileStates[$selectedNumber - 1]

            if (-not $selectedItem.Online)
            {
                Write-Host "[ERROR] Esta Raspberry esta fuera de linea; no se puede iniciar sesion." -ForegroundColor Red
                return $null
            }

            Write-Host ""
            Write-Host "Conexion disponible: $($selectedItem.Profile.User)@$($selectedItem.Profile.Host)" -ForegroundColor Cyan
            Write-Host "1. Iniciar sesion con este usuario"
            Write-Host "2. Cancelar"
            Write-Host ""

            if ((Read-UIChoice) -eq "1")
            {
                Set-PCJActiveProfile -ConfigFile $ConfigFile -Profile $selectedItem.Profile
                Write-Host "[OK] Conexion activa: $($selectedItem.Profile.Name)." -ForegroundColor Green
                return $selectedItem.Profile
            }

            Write-Host "[INFO] Inicio de sesion cancelado." -ForegroundColor Yellow
            return $null
        }

        Write-Host "[INFO] Seleccion cancelada." -ForegroundColor Yellow
        return $null
    }

    if ($startOption -ne "1")
    {
        Write-Host "[INFO] Agregar Raspberry cancelado." -ForegroundColor Yellow
        return $null
    }

    Write-Host ""
    Write-Host "0. Cancelar y volver al menu anterior" -ForegroundColor Yellow
    Write-Host "   Puede escribir 0 en cualquiera de los campos para cancelar." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Elija cualquier nombre para reconocer esta conexion en el programa." -ForegroundColor Cyan
    Write-Host "Es solo una etiqueta local: no cambia el nombre ni el usuario de la Raspberry." -ForegroundColor DarkGray
    $profileName = Read-UIColoredInput -Prompt "Nombre para identificarla (ejemplo: Casa): " -InputColor Cyan

    if ($profileName -eq "0")
    {
        Write-Host "[INFO] Agregar Raspberry cancelado." -ForegroundColor Yellow
        return [PSCustomObject]@{ PCJAction = "ReturnToStart" }
    }

    Write-Host ""
    Write-Host "Indique la direccion IP local de la Raspberry en su red Wi-Fi o cableada." -ForegroundColor DarkGray
    $hostIP = ""

    while ($true)
    {
        $hostIP = Read-UIColoredInput -Prompt "IP de la Raspberry: " -InputColor Green

        if ($hostIP -eq "0")
        {
            Write-Host "[INFO] Agregar Raspberry cancelado." -ForegroundColor Yellow
            return [PSCustomObject]@{ PCJAction = "ReturnToStart" }
        }

        $parsedIPAddress = $null

        if (-not [System.Net.IPAddress]::TryParse($hostIP, [ref]$parsedIPAddress) -or
            $parsedIPAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork)
        {
            Write-Host "[ERROR] La IP no tiene un formato valido. Ejemplo: 192.168.1.25" -ForegroundColor Red
            Write-Host "Escriba otra IP o 0 para cancelar." -ForegroundColor Yellow
            continue
        }

        Write-Host "[INFO] Verificando conexion con la Raspberry..." -ForegroundColor Cyan

        if (-not (Test-PCJProfileConnection -Profile ([PSCustomObject]@{ Host = $hostIP })))
        {
            Write-Host "[ERROR] No se encontro una Raspberry con SSH disponible en esa IP." -ForegroundColor Red
            Write-Host "Revise que este encendida, conectada a la misma red y que la IP sea correcta." -ForegroundColor Yellow
            Write-Host "Escriba otra IP o 0 para cancelar." -ForegroundColor Yellow
            continue
        }

        Write-Host "[OK] Equipo con SSH detectado en $hostIP." -ForegroundColor Green
        Write-Host "El modelo se verificara al confirmar el acceso." -ForegroundColor DarkGray
        break
    }

    Write-Host ""
    Write-Host "Este es el usuario con el que inicia sesion directamente en la Raspberry." -ForegroundColor DarkGray
    Write-Host "No es el nombre de esta conexion ni el usuario de Windows." -ForegroundColor DarkGray
    $raspberryUser = Read-UIColoredInput -Prompt "Usuario de la Raspberry: " -InputColor Magenta

    if ($raspberryUser -eq "0")
    {
        Write-Host "[INFO] Agregar Raspberry cancelado." -ForegroundColor Yellow
        return [PSCustomObject]@{ PCJAction = "ReturnToStart" }
    }

    if ([string]::IsNullOrWhiteSpace($profileName) -or
        [string]::IsNullOrWhiteSpace($hostIP) -or
        [string]::IsNullOrWhiteSpace($raspberryUser))
    {
        Write-Host "[ERROR] Debe completar todos los datos." -ForegroundColor Red
        return $null
    }

    $saveProfile = $true

    if (-not $RequireSave)
    {
        Write-Host ""
        Write-Host "Desea guardar esta conexion para acceso rapido?" -ForegroundColor Cyan
        Write-Host "1. Si, guardar perfil"
        Write-Host "2. No, usar solo durante esta sesion"
        Write-Host "3. Cancelar y volver al menu anterior"
        Write-Host ""
        $saveChoice = Read-UIChoice

        if ($saveChoice -notin @("1", "2"))
        {
            Write-Host "[INFO] Agregar Raspberry cancelado. No se guardo ningun cambio." -ForegroundColor Yellow
            return [PSCustomObject]@{ PCJAction = "ReturnToStart" }
        }

        $saveProfile = ($saveChoice -eq "1")
    }

    $profileId = [Guid]::NewGuid().ToString("N")
    $keyFolder = if ($saveProfile) {
        Join-Path (Get-PCJProfileRoot) $profileId
    }
    else {
        Join-Path $env:TEMP "pcj-raspberry-$profileId"
    }
    $keyFile = Join-Path $keyFolder "id_ed25519"

    New-Item -ItemType Directory -Path $keyFolder -Force | Out-Null
    Write-Host ""
    Write-Host "[INFO] Creando llave SSH para este perfil..." -ForegroundColor Yellow

    $keygenArguments = "-q -t ed25519 -f `"$keyFile`" -N `"`" -C `"pcj-raspberry-$profileId`""
    $keygenProcess = Start-Process -FilePath "ssh-keygen.exe" -ArgumentList $keygenArguments -NoNewWindow -Wait -PassThru

    if ($keygenProcess.ExitCode -ne 0)
    {
        Write-Host "[ERROR] No se pudo crear la llave SSH." -ForegroundColor Red
        return $null
    }

    Write-Host ""
    Write-Host "La siguiente pantalla solicitara la contrasena de la Raspberry." -ForegroundColor Yellow
    Write-Host "OpenSSH la oculta por seguridad y no se almacena en esta PC." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "1. Continuar y escribir contrasena"
    Write-Host "2. Cancelar y volver al inicio"
    Write-Host "3. Cancelar y cerrar programa"
    Write-Host ""
    $passwordOption = Read-UIChoice

    if ($passwordOption -eq "2")
    {
        Remove-Item -LiteralPath $keyFolder -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[INFO] Registro cancelado. No se guardo ninguna conexion." -ForegroundColor Yellow
        return [PSCustomObject]@{ PCJAction = "ReturnToStart" }
    }

    if ($passwordOption -eq "3")
    {
        Remove-Item -LiteralPath $keyFolder -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[INFO] Registro cancelado. Cerrando programa..." -ForegroundColor Yellow
        exit
    }

    if ($passwordOption -ne "1")
    {
        Remove-Item -LiteralPath $keyFolder -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[INFO] Registro cancelado. No se guardo ninguna conexion." -ForegroundColor Yellow
        return [PSCustomObject]@{ PCJAction = "ReturnToStart" }
    }

    Write-Host ""
    Write-Host "[INFO] Escriba la contrasena de la Raspberry cuando se solicite." -ForegroundColor Yellow

    $publicKey = Get-Content "$keyFile.pub" -Raw
    $encodedKey = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($publicKey))
    $remoteCommand = "model=`$(cat /proc/device-tree/model 2>/dev/null || true); if echo `"`$model`" | grep -qi 'Raspberry'; then echo `"PCJ_RASPBERRY:`$model`"; mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && echo $encodedKey | base64 -d >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys; else echo PCJ_NOT_RASPBERRY; exit 42; fi"
    $keyRegistered = $false

    while (-not $keyRegistered)
    {
        $sshOutput = & ssh -o StrictHostKeyChecking=accept-new -o NumberOfPasswordPrompts=1 "$raspberryUser@$hostIP" $remoteCommand 2>&1
        $sshExitCode = $LASTEXITCODE

        if ($sshExitCode -eq 0)
        {
            $modelLine = @($sshOutput | Where-Object { $_ -match "^PCJ_RASPBERRY:" } | Select-Object -Last 1)[0]
            $raspberryModel = if ($modelLine) { $modelLine -replace "^PCJ_RASPBERRY:", "" } else { "Modelo Raspberry Pi compatible" }
            Write-Host "[OK] Raspberry Pi detectada: $raspberryModel" -ForegroundColor Green
            $keyRegistered = $true
            break
        }

        $sshErrorText = ($sshOutput | Out-String)

        if ($sshErrorText -match "PCJ_NOT_RASPBERRY")
        {
            Remove-Item -LiteralPath $keyFolder -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "[ERROR] El equipo responde por SSH, pero no se identifico como una Raspberry Pi." -ForegroundColor Red
            Write-Host "No se guardo ninguna llave ni conexion para ese equipo." -ForegroundColor Yellow
            return [PSCustomObject]@{ PCJAction = "ReturnToStart" }
        }

        if ($sshErrorText -match "Permission denied")
        {
            Write-Host "[ERROR] Permiso denegado: la contrasena es incorrecta." -ForegroundColor Red
            Write-Host "        Permission denied: password incorrect. Intente nuevamente." -ForegroundColor Red
            Write-Host ""
            Write-Host "1. Reintentar contrasena"
            Write-Host "2. Cancelar y volver al inicio"
            Write-Host "3. Cancelar y cerrar programa"
            Write-Host ""
            $retryOption = Read-UIChoice

            if ($retryOption -eq "1")
            {
                Write-Host ""
                Write-Host "[INFO] Escriba nuevamente la contrasena de la Raspberry." -ForegroundColor Yellow
                continue
            }

            Remove-Item -LiteralPath $keyFolder -Recurse -Force -ErrorAction SilentlyContinue

            if ($retryOption -eq "3")
            {
                Write-Host "[INFO] Registro cancelado. Cerrando programa..." -ForegroundColor Yellow
                exit
            }

            Write-Host "[INFO] Registro cancelado. No se guardo ninguna conexion." -ForegroundColor Yellow
            return [PSCustomObject]@{ PCJAction = "ReturnToStart" }
        }

        Remove-Item -LiteralPath $keyFolder -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[ERROR] No se pudo conectar con la Raspberry para registrar la llave." -ForegroundColor Red
        Write-Host "[INFO] Revise la IP, el usuario y que la Raspberry este encendida." -ForegroundColor Yellow
        return $null
    }

    $profile = [PSCustomObject]@{
        Id = $profileId
        Name = $profileName
        Host = $hostIP
        User = $raspberryUser
        KeyFile = $keyFile
    }

    if ($saveProfile)
    {
        $profileFile = Get-PCJProfileFile -ProfileId $profileId
@"
[Profile]
Id=$profileId
Name=$profileName

[Raspberry]
Host=$hostIP
User=$raspberryUser

[SSH]
KeyFile=$keyFile
"@ | Set-Content -LiteralPath $profileFile

        Set-PCJActiveProfile -ConfigFile $ConfigFile -Profile $profile
        Write-Host "[OK] Perfil guardado y seleccionado correctamente." -ForegroundColor Green
    }
    else
    {
        $script:PCJTemporaryProfile = $profile
        Write-Host "[OK] Conexion temporal lista para esta sesion." -ForegroundColor Green
    }

    return $profile
}


function Remove-PCJProfile
{
    param
    (
        [string]$ConfigFile,
        [PSCustomObject]$Profile
    )

    $confirmation = Read-Host "Escriba SI para eliminar el acceso local de '$($Profile.Name)'"

    if ($confirmation -ine "SI")
    {
        Write-Host "[INFO] Eliminacion cancelada." -ForegroundColor Yellow
        return $false
    }

    $activeProfile = Get-PCJActiveProfile -ConfigFile $ConfigFile
    $keyFolder = Split-Path -Parent $Profile.KeyFile
    Remove-Item -LiteralPath $Profile.File -Force -ErrorAction SilentlyContinue

    if ($keyFolder -like "$(Get-PCJProfileRoot)*")
    {
        Remove-Item -LiteralPath $keyFolder -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($activeProfile -and $activeProfile.Id -eq $Profile.Id)
    {
        Set-PCJIniValue -File $ConfigFile -Section "Profiles" -Key "ActiveId" -Value ""
    }

    Write-Host "[OK] Acceso local eliminado." -ForegroundColor Green
    return $true
}


function Close-PCJTemporarySession
{
    if (-not $script:PCJTemporaryProfile)
    {
        return
    }

    $keyFolder = Split-Path -Parent $script:PCJTemporaryProfile.KeyFile
    Remove-Item -LiteralPath $keyFolder -Recurse -Force -ErrorAction SilentlyContinue
    $script:PCJTemporaryProfile = $null
}


function SignOut-PCJProfile
{
    param
    (
        [string]$ConfigFile,
        [PSCustomObject]$Profile
    )

    if ($script:PCJTemporaryProfile)
    {
        Close-PCJTemporarySession
    }

    if ($Profile -and $Profile.File -and (Test-Path $Profile.File))
    {
        Remove-Item -LiteralPath $Profile.File -Force -ErrorAction SilentlyContinue
    }

    if ($Profile -and $Profile.KeyFile -and (Test-Path $Profile.KeyFile))
    {
        $keyFolder = Split-Path -Parent $Profile.KeyFile

        if ($keyFolder -like "$(Get-PCJProfileRoot)*")
        {
            Remove-Item -LiteralPath $keyFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
        else
        {
            Remove-Item -LiteralPath $Profile.KeyFile -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "$($Profile.KeyFile).pub" -Force -ErrorAction SilentlyContinue
        }
    }

    Set-PCJIniValue -File $ConfigFile -Section "Profiles" -Key "ActiveId" -Value ""
    Set-PCJIniValue -File $ConfigFile -Section "Raspberry" -Key "Host" -Value ""
    Set-PCJIniValue -File $ConfigFile -Section "Raspberry" -Key "User" -Value ""
}


function Show-RaspberryWifiAssistant
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    while ($true)
    {
        Clear-Host
        Write-UIHeader -Title "Cambiar red Wi-Fi"
        Write-Host ""
        Write-Host "Permite consultar redes y conectar la Raspberry a otra red Wi-Fi." -ForegroundColor Cyan
        Write-Host "Al cambiar de red se perdera la conexion temporalmente." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "1. Buscar y elegir una red Wi-Fi"
        Write-Host "   Busca redes cercanas y permite seleccionar una.  10 a 20 segundos" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "2. Agregar una red manualmente"
        Write-Host "   Escriba el nombre de una red que no aparezca en la lista." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "3. Cancelar"
        Write-Host ""

        $wifiOption = Read-UIChoice

        if ($wifiOption -eq "3")
        {
            return
        }

        $networkManager = Invoke-SSHCommand `
            -RaspberryHost $RaspberryHost `
            -User $User `
            -Command "command -v nmcli >/dev/null 2>&1 && echo OK"

        if ($LASTEXITCODE -ne 0 -or $networkManager -notmatch "OK")
        {
            Write-Host "[ERROR] Esta Raspberry no usa NetworkManager; no se puede cambiar Wi-Fi desde esta herramienta." -ForegroundColor Red
            Write-Host "Use la configuracion de red del sistema o Raspberry Pi Imager." -ForegroundColor Yellow
            Pause
            continue
        }

        $ssid = $null

        if ($wifiOption -eq "1")
        {
            Write-Host ""
            Write-Host "[INFO] Buscando redes Wi-Fi..." -ForegroundColor Yellow
            $networks = @(Invoke-SSHCommand `
                -RaspberryHost $RaspberryHost `
                -User $User `
                -Command "nmcli -t -f SSID dev wifi list | sed '/^$/d' | sort -u | head -20")

            Write-Host ""

            if ($networks)
            {
                Write-Host "Redes disponibles:" -ForegroundColor Cyan

                for ($index = 0; $index -lt $networks.Count; $index++)
                {
                    $number = $index + 1
                    Write-Host "$number. $($networks[$index])"
                }

                Write-Host ""
                Write-Host "0. Cancelar y volver"
                $networkSelection = Read-UIChoice -Prompt "Seleccione una red"
                $selectedNumber = 0

                if (-not [int]::TryParse($networkSelection, [ref]$selectedNumber) -or
                    $selectedNumber -lt 1 -or
                    $selectedNumber -gt $networks.Count)
                {
                    continue
                }

                $ssid = $networks[$selectedNumber - 1]
            }
            else
            {
                Write-Host "[INFO] No se encontraron redes Wi-Fi." -ForegroundColor Yellow
                Pause
                continue
            }
        }

        if ($wifiOption -eq "2")
        {
            Clear-Host
            Write-UIHeader -Title "Agregar red Wi-Fi manualmente"
            Write-Host ""
            Write-Host "Escriba el nombre exacto de la red Wi-Fi." -ForegroundColor Cyan
            Write-Host "Deje el campo vacio para cancelar y volver." -ForegroundColor Yellow
            Write-Host ""
            $ssid = Read-Host "Nombre de la red Wi-Fi"
        }

        if ([string]::IsNullOrWhiteSpace($ssid))
        {
            continue
        }

        Clear-Host
        Write-UIHeader -Title "Conectar a otra red Wi-Fi"
        Write-Host ""
        Write-Host "Red seleccionada: $ssid" -ForegroundColor Cyan
        Write-Host "La Raspberry se desconectara de la red actual mientras se conecta a la nueva." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "1. Red protegida con contrasena"
        Write-Host "2. Red abierta, sin contrasena"
        Write-Host "3. Cancelar y volver"
        Write-Host ""
        $securityOption = Read-UIChoice -Prompt "Seleccione el tipo de red"

        if ($securityOption -eq "3" -or $securityOption -notin @("1", "2"))
        {
            continue
        }

        $encodedPassword = ""

        if ($securityOption -eq "1")
        {
            $securePassword = Read-ConfirmedSecurePassword -Prompt "Contrasena Wi-Fi"

            if (-not $securePassword)
            {
                Write-Host "[INFO] Cambio de Wi-Fi cancelado." -ForegroundColor Yellow
                Pause
                continue
            }

            $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)

            try
            {
                $wifiPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
                $encodedPassword = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($wifiPassword))
            }
            finally
            {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
            }
        }

        Write-Host ""
        Write-Host "Punto sin retorno:" -ForegroundColor Yellow
        Write-Host "Al confirmar, la Raspberry intentara conectarse a '$ssid' con los datos indicados." -ForegroundColor Yellow
        Write-Host "Este programa perdera la conexion actual y no podra confirmar el resultado de inmediato." -ForegroundColor Yellow
        Write-Host "Si los datos son correctos, espere 1 a 3 minutos y vuelva a conectarse; la IP podria cambiar." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Escriba SI para continuar o NO para cancelar sin hacer cambios." -ForegroundColor Cyan
        $confirmation = Read-Host "Confirmar cambio a '$ssid' (SI/NO)"

        if ($confirmation -ine "SI")
        {
            Write-Host "[INFO] Cambio de Wi-Fi cancelado." -ForegroundColor Yellow
            Pause
            continue
        }

        $encodedSsid = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ssid))
        $connectCommand = if ($securityOption -eq "1") {
            'sudo nmcli dev wifi connect "$ssid" password "$password" ifname wlan0'
        }
        else {
            'sudo nmcli dev wifi connect "$ssid" ifname wlan0'
        }

        $wifiScript = @"
cat > /tmp/pcj-wifi-change.sh <<'EOF'
#!/bin/bash
trap 'rm -f /tmp/pcj-wifi-change.sh' EXIT
sleep 2
ssid=`$(echo '$encodedSsid' | base64 -d)
password=`$(echo '$encodedPassword' | base64 -d)
$connectCommand
EOF
chmod 700 /tmp/pcj-wifi-change.sh
nohup /bin/bash /tmp/pcj-wifi-change.sh >/tmp/pcj-wifi-change.log 2>&1 &
echo OK
"@

        $scheduled = Invoke-SSHScript `
            -RaspberryHost $RaspberryHost `
            -User $User `
            -Script $wifiScript

        if ($LASTEXITCODE -eq 0 -and $scheduled -match "OK")
        {
            Write-Host "[OK] Cambio de Wi-Fi solicitado." -ForegroundColor Green
            Write-Host "A partir de este punto no es recomendable cancelar el proceso." -ForegroundColor Yellow
            Write-Host "Espere 1 a 3 minutos y vuelva a abrir el programa con la nueva IP si cambio." -ForegroundColor Yellow
        }
        else
        {
            Write-Host "[ERROR] No se pudo solicitar el cambio de Wi-Fi." -ForegroundColor Red
        }

        Pause
        return
    }
}
