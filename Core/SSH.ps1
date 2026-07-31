function Get-SSHKeyPath
{
    $configFile = Join-Path $PSScriptRoot "..\PCJ-Raspberry.ini"
    $profile = Get-PCJActiveProfile -ConfigFile $configFile

    if ($profile -and $profile.KeyFile)
    {
        return $profile.KeyFile
    }

    $keyFolder = Join-Path $env:USERPROFILE ".pcj-raspberry"
    return (Join-Path $keyFolder "id_ed25519")
}


function Invoke-SSHCommand
{
    param
    (
        [string]$RaspberryHost,
        [string]$User,
        [string]$Command
    )

    $keyFile = Get-SSHKeyPath

    if (-not (Test-Path $keyFile))
    {
        Write-Host "[ERROR] No existe la llave SSH." -ForegroundColor Red
        return $false
    }

    ssh -i $keyFile -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$User@$RaspberryHost" $Command
}


function Invoke-SSHInteractiveCommand
{
    param
    (
        [string]$RaspberryHost,
        [string]$User,
        [string]$Command
    )

    $keyFile = Get-SSHKeyPath

    if (-not (Test-Path $keyFile))
    {
        Write-Host "[ERROR] No existe la llave SSH." -ForegroundColor Red
        return $false
    }

    # -tt permite responder a los asistentes interactivos que se ejecutan dentro de la Raspberry.
    ssh -tt -i $keyFile -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$User@$RaspberryHost" $Command
}


function Invoke-SSHCommandWithInput
{
    param
    (
        [string]$RaspberryHost,
        [string]$User,
        [string]$Command,
        [string[]]$InputLines
    )

    $keyFile = Get-SSHKeyPath

    if (-not (Test-Path $keyFile))
    {
        return [PSCustomObject]@{ ExitCode = 1; Output = ""; Error = "No existe la llave SSH." }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "ssh"
    $startInfo.Arguments = "-i `"$keyFile`" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new `"$User@$RaspberryHost`" `"$Command`""
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try
    {
        [void]$process.Start()

        foreach ($line in $InputLines)
        {
            $process.StandardInput.WriteLine($line)
        }

        $process.StandardInput.Close()
        $output = $process.StandardOutput.ReadToEnd()
        $errorOutput = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        return [PSCustomObject]@{
            ExitCode = $process.ExitCode
            Output = $output
            Error = $errorOutput
        }
    }
    catch
    {
        return [PSCustomObject]@{ ExitCode = 1; Output = ""; Error = $_.Exception.Message }
    }
    finally
    {
        $process.Dispose()
    }
}


function Invoke-SSHScript
{
    param
    (
        [string]$RaspberryHost,
        [string]$User,
        [string]$Script
    )

    $keyFile = Get-SSHKeyPath

    if (-not (Test-Path $keyFile))
    {
        Write-Host "[ERROR] No existe la llave SSH." -ForegroundColor Red
        return $false
    }

    $encodedScript = [Convert]::ToBase64String(
        [System.Text.Encoding]::UTF8.GetBytes($Script)
    )

    ssh -i $keyFile -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$User@$RaspberryHost" "echo $encodedScript | base64 -d | bash"
}


function Download-FileSSH
{
    param
    (
        [string]$RaspberryHost,
        [string]$User,
        [string]$RemoteFile,
        [string]$LocalFolder,
        [scriptblock]$ProgressCallback
    )

    $keyFile = Get-SSHKeyPath

    if (-not (Test-Path $keyFile))
    {
        Write-Host "[ERROR] No existe la llave SSH." -ForegroundColor Red
        return $false
    }

    if (-not (Test-Path $LocalFolder))
    {
        New-Item -ItemType Directory -Path $LocalFolder | Out-Null
    }

    $remoteSizeText = Invoke-SSHCommand `
        -RaspberryHost $RaspberryHost `
        -User $User `
        -Command "stat -c%s $RemoteFile"

    [long]$remoteSize = 0
    $remoteSizeValue = @($remoteSizeText | Select-Object -Last 1)[0]

    if ($remoteSizeValue)
    {
        [void][long]::TryParse($remoteSizeValue.Trim(), [ref]$remoteSize)
    }

    $localFile = Join-Path $LocalFolder (Split-Path $RemoteFile -Leaf)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "scp"
    $startInfo.Arguments = "-q -i `"$keyFile`" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new `"$User@$RaspberryHost`:$RemoteFile`" `"$LocalFolder`""
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try
    {
        [void]$process.Start()

        while (-not $process.HasExited)
        {
            if ($ProgressCallback -and $remoteSize -gt 0 -and (Test-Path -LiteralPath $localFile))
            {
                $localSize = (Get-Item -LiteralPath $localFile).Length
                $downloadPercent = [math]::Min(99, [math]::Floor(($localSize / $remoteSize) * 100))
                & $ProgressCallback $downloadPercent
            }

            Start-Sleep -Milliseconds 150
        }

        $process.WaitForExit()

        if ($process.ExitCode -eq 0 -and $ProgressCallback)
        {
            & $ProgressCallback 100
        }

        return ($process.ExitCode -eq 0)
    }
    catch
    {
        return $false
    }
    finally
    {
        $process.Dispose()
    }
}


function Upload-FileSSH
{
    param
    (
        [string]$RaspberryHost,
        [string]$User,
        [string]$LocalFile,
        [string]$RemoteFile
    )

    $keyFile = Get-SSHKeyPath

    if (-not (Test-Path $keyFile))
    {
        Write-Host "[ERROR] No existe la llave SSH." -ForegroundColor Red
        return $false
    }

    if (-not (Test-Path -LiteralPath $LocalFile))
    {
        Write-Host "[ERROR] No existe el archivo que se desea subir." -ForegroundColor Red
        return $false
    }

    scp -i $keyFile -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new $LocalFile "$User@$RaspberryHost`:$RemoteFile"

    return ($LASTEXITCODE -eq 0)
}


function Save-SSHBinaryStream
{
    param
    (
        [string]$RaspberryHost,
        [string]$User,
        [string]$Command,
        [string]$LocalFile,
        [long]$TotalBytes,
        [switch]$AllowCancel,
        [scriptblock]$ProgressCallback
    )

    $keyFile = Get-SSHKeyPath

    if (-not (Test-Path $keyFile))
    {
        Write-Host "[ERROR] No existe la llave SSH." -ForegroundColor Red
        return @{ Succeeded = $false; Cancelled = $false }
    }

    $localFolder = Split-Path -Parent $LocalFile

    if (-not (Test-Path $localFolder))
    {
        New-Item -ItemType Directory -Path $localFolder -Force | Out-Null
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "ssh"
    $startInfo.Arguments = "-i `"$keyFile`" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new `"$User@$RaspberryHost`" `"$Command`""
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $progressState = [hashtable]::Synchronized(@{
        BytesRead = [long]0
        LastPercent = -1
        Errors = New-Object System.Collections.ArrayList
    })
    $errorHandler = [System.Diagnostics.DataReceivedEventHandler]{
        param($sender, $eventArgs)

        if ([string]::IsNullOrWhiteSpace($eventArgs.Data))
        {
            return
        }

        [void]$progressState.Errors.Add($eventArgs.Data)
        $progressMatch = [regex]::Match($eventArgs.Data, "(\d+)\s+bytes")

        if ($progressMatch.Success)
        {
            $progressState.BytesRead = [long]$progressMatch.Groups[1].Value
        }
    }

    try
    {
        [void]$process.Start()
        $process.add_ErrorDataReceived($errorHandler)
        $process.BeginErrorReadLine()

        $fileStream = [System.IO.File]::Open(
            $LocalFile,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write
        )

        try
        {
            $buffer = New-Object byte[] 1048576
            $wasCancelled = $false

            while ($true)
            {
                $read = $process.StandardOutput.BaseStream.Read($buffer, 0, $buffer.Length)

                if ($read -le 0)
                {
                    break
                }

                $fileStream.Write($buffer, 0, $read)

                if ($ProgressCallback -and $TotalBytes -gt 0)
                {
                    $percent = [math]::Min(99, [math]::Floor(($progressState.BytesRead / $TotalBytes) * 100))

                    if ($percent -ne $progressState.LastPercent)
                    {
                        $progressState.LastPercent = $percent
                        & $ProgressCallback $percent
                    }
                }

                if ($AllowCancel -and [Console]::KeyAvailable)
                {
                    $key = [Console]::ReadKey($true)

                    if ($key.Key -eq [ConsoleKey]::C)
                    {
                        $wasCancelled = $true
                        break
                    }
                }
            }
        }
        finally
        {
            $fileStream.Dispose()
        }

        if ($wasCancelled -and -not $process.HasExited)
        {
            $process.Kill()
        }

        $process.WaitForExit()

        if ($wasCancelled)
        {
            Remove-Item -LiteralPath $LocalFile -Force -ErrorAction SilentlyContinue
            return @{ Succeeded = $false; Cancelled = $true }
        }

        if ($process.ExitCode -ne 0)
        {
            Remove-Item -LiteralPath $LocalFile -Force -ErrorAction SilentlyContinue
            Write-Host "[ERROR] No se pudo descargar la imagen del sistema." -ForegroundColor Red

            if ($progressState.Errors.Count -gt 0)
            {
                Write-Host ($progressState.Errors -join [Environment]::NewLine)
            }

            return @{ Succeeded = $false; Cancelled = $false }
        }

        return @{ Succeeded = $true; Cancelled = $false }
    }
    catch
    {
        Remove-Item -LiteralPath $LocalFile -Force -ErrorAction SilentlyContinue
        Write-Host "[ERROR] No se pudo iniciar la descarga de la imagen." -ForegroundColor Red
        return @{ Succeeded = $false; Cancelled = $false }
    }
    finally
    {
        if ($process)
        {
            $process.Dispose()
        }
    }
}


function Test-SSHConnection
{
    param
    (
        [string]$RaspberryHost,
        [string]$User
    )

    $keyFile = Get-SSHKeyPath

    if (-not (Test-Path $keyFile))
    {
        return "ERROR"
    }

    $resultado = ssh `
        -i $keyFile `
        -o BatchMode=yes `
        -o NumberOfPasswordPrompts=0 `
        -o ConnectTimeout=5 `
        -o StrictHostKeyChecking=accept-new `
        -o LogLevel=ERROR `
        "$User@$RaspberryHost" `
        "echo OK" 2>$null

    if ($resultado -eq "OK")
    {
        return "OK"
    }
    else
    {
        return "ERROR"
    }
}
