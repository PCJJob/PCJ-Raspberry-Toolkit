function Write-UIHeader
{
    param
    (
        [string]$Title,
        [string]$Subtitle,
        [int]$Width = 60
    )

    $line = "=" * $Width
    $leftPadding = [math]::Max(0, [math]::Floor(($Width - $Title.Length) / 2))

    Write-Host $line -ForegroundColor Cyan
    Write-Host ((" " * $leftPadding) + $Title) -ForegroundColor Cyan

    if (-not [string]::IsNullOrWhiteSpace($Subtitle))
    {
        $subtitlePadding = [math]::Max(0, [math]::Floor(($Width - $Subtitle.Length) / 2))
        Write-Host ((" " * $subtitlePadding) + $Subtitle) -ForegroundColor Magenta
    }

    Write-Host $line -ForegroundColor Cyan
}


function Write-UISection
{
    param
    (
        [string]$Text
    )

    Write-Host $Text -ForegroundColor Cyan
}


function Write-UITypewriter
{
    param
    (
        [string]$Text,
        [ConsoleColor]$Color = "Green",
        [int]$DelayMilliseconds = 14,
        [switch]$NoNewline
    )

    foreach ($character in $Text.ToCharArray())
    {
        Write-Host $character -NoNewline -ForegroundColor $Color
        Start-Sleep -Milliseconds $DelayMilliseconds
    }

    if (-not $NoNewline)
    {
        Write-Host ""
    }
}


function Show-UIWelcome
{
    param
    (
        [int]$Width = 60
    )

    Clear-Host
    Write-Host ""

    $welcomeLines = @(
        @{ Text = "PCJ Raspberry Toolkit"; Color = "Cyan" },
        @{ Text = "Una herramienta para facilitar el uso y cuidado de tu Raspberry."; Color = "Green" },
        @{ Text = "Un proyecto de Pensamiento Creativo #Job para la comunidad."; Color = "DarkCyan" }
    )

    $logoLines = @(
        @{ Text = "        .-^^-. .-^^-."; Color = "Green" },
        @{ Text = "     .-'     V     '-."; Color = "Green" },
        @{ Text = "           \  |  /"; Color = "Green" },
        @{ Text = "        .-=========-."; Color = "Red" },
        @{ Text = "      .'  @   @   @  '."; Color = "Red" },
        @{ Text = "     /  @    RPi    @  \"; Color = "Red" },
        @{ Text = "     \  @   @   @   @  /"; Color = "Red" },
        @{ Text = "      '.  @   @   @  .'"; Color = "Red" },
        @{ Text = "        '-._______,-'"; Color = "Red" },
        @{ Text = "Conexion segura para tu Raspberry"; Color = "DarkCyan" }
    )

    $animationLines = @($welcomeLines + $logoLines)
    $frameCount = 55

    for ($frame = 0; $frame -le $frameCount; $frame++)
    {
        [Console]::SetCursorPosition(0, 0)
        Write-Host ""

        for ($index = 0; $index -lt $animationLines.Count; $index++)
        {
            if ($index -eq $welcomeLines.Count)
            {
                Write-Host ""
            }

            $animationLine = $animationLines[$index]
            $visibleLength = [math]::Min($animationLine.Text.Length, [math]::Ceiling($animationLine.Text.Length * $frame / $frameCount))
            $visibleText = $animationLine.Text.Substring(0, $visibleLength)
            $padding = [math]::Max(0, [math]::Floor(($Width - $animationLine.Text.Length) / 2))

            Write-Host (" " * $padding) -NoNewline
            Write-Host $visibleText -ForegroundColor $animationLine.Color
        }

        Start-Sleep -Milliseconds 18
    }

    Write-Host ""
    Start-Sleep -Milliseconds 850
}


function Write-UIRaspberryLogo
{
    param
    (
        [int]$Width = 60,
        [switch]$Static
    )

    $logo = @(
        @{ Text = "        .-^^-. .-^^-."; Color = "Green" }
        @{ Text = "     .-'     V     '-."; Color = "Green" }
        @{ Text = "           \  |  /"; Color = "Green" }
        @{ Text = "        .-=========-."; Color = "Red" }
        @{ Text = "      .'  @   @   @  '."; Color = "Red" }
        @{ Text = "     /  @    RPi    @  \"; Color = "Red" }
        @{ Text = "     \  @   @   @   @  /"; Color = "Red" }
        @{ Text = "      '.  @   @   @  .'"; Color = "Red" }
        @{ Text = "        '-._______,-'"; Color = "Red" }
    )

    foreach ($logoLine in $logo)
    {
        $padding = [math]::Max(0, [math]::Floor(($Width - $logoLine.Text.Length) / 2))
        Write-Host (" " * $padding) -NoNewline

        if ($Static)
        {
            Write-Host $logoLine.Text -ForegroundColor $logoLine.Color
        }
        else
        {
            Write-UITypewriter -Text $logoLine.Text -Color $logoLine.Color -DelayMilliseconds 12
        }
    }

    $tagline = "Conexion segura para tu Raspberry"
    $taglinePadding = [math]::Max(0, [math]::Floor(($Width - $tagline.Length) / 2))
    Write-Host (" " * $taglinePadding) -NoNewline

    if ($Static)
    {
        Write-Host $tagline -ForegroundColor DarkCyan
    }
    else
    {
        Write-UITypewriter -Text $tagline -Color DarkCyan -DelayMilliseconds 12
    }
}


function Read-UIChoice
{
    param
    (
        [string]$Prompt = "Seleccione una opcion"
    )

    Write-Host $Prompt -ForegroundColor Yellow -NoNewline
    return (Read-Host " ")
}


function Read-UIColoredInput
{
    param
    (
        [string]$Prompt,
        [ConsoleColor]$InputColor = "Cyan"
    )

    Write-Host $Prompt -NoNewline -ForegroundColor Yellow
    $inputText = [System.Text.StringBuilder]::new()

    try
    {
        while ($true)
        {
            $key = [Console]::ReadKey($true)

            if ($key.Key -eq [ConsoleKey]::Enter)
            {
                Write-Host ""
                break
            }

            if ($key.Key -eq [ConsoleKey]::Backspace)
            {
                if ($inputText.Length -gt 0)
                {
                    [void]$inputText.Remove($inputText.Length - 1, 1)
                    Write-Host "`b `b" -NoNewline
                }

                continue
            }

            if (-not [char]::IsControl($key.KeyChar))
            {
                [void]$inputText.Append($key.KeyChar)
                Write-Host $key.KeyChar -NoNewline -ForegroundColor $InputColor
            }
        }
    }
    catch
    {
        return (Read-Host $Prompt)
    }

    return $inputText.ToString()
}


function Show-UIProgress
{
    param
    (
        [string]$Stage,
        [int]$Percent
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

    $progressText = "$Stage  $bar $percentSafe%"

    try
    {
        $paddingLength = [math]::Max(0, [Console]::WindowWidth - $progressText.Length - 1)
        $padding = " " * $paddingLength
    }
    catch
    {
        $padding = " " * 20
    }

    Write-Host -NoNewline "`r$progressText$padding"
}


function Complete-UIProgress
{
    Write-Host ""
}


function Read-ConfirmedSecurePassword
{
    param
    (
        [string]$Prompt = "Contrasena"
    )

    $firstPassword = Read-Host "$Prompt (se oculta por seguridad)" -AsSecureString

    Write-Host ""
    Write-Host "Para evitar errores, es necesario confirmar la contrasena una segunda vez." -ForegroundColor Yellow
    Write-Host "1. Continuar y confirmar contrasena"
    Write-Host "2. Cancelar y volver"
    Write-Host ""

    if ((Read-UIChoice) -ne "1")
    {
        $firstPassword.Dispose()
        Write-Host "[INFO] Proceso cancelado. No se realizo ningun cambio." -ForegroundColor Yellow
        return $null
    }

    $secondPassword = Read-Host "Confirme la contrasena" -AsSecureString
    $firstPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($firstPassword)
    $secondPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secondPassword)

    try
    {
        $firstText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($firstPointer)
        $secondText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secondPointer)

        if ([string]::IsNullOrEmpty($firstText))
        {
            Write-Host "[ERROR] La contrasena no puede estar vacia." -ForegroundColor Red
            return $null
        }

        if ($firstText -ne $secondText)
        {
            Write-Host "[ERROR] Las contrasenas no coinciden. No se realizo ningun cambio." -ForegroundColor Red
            return $null
        }
    }
    finally
    {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstPointer)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secondPointer)
    }

    return $firstPassword
}
