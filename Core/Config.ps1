function Get-IniValue
{
    param
    (
        [string]$File,
        [string]$Section,
        [string]$Key
    )

    if (-not (Test-Path $File))
    {
        throw "No existe el archivo: $File"
    }

    $lines = Get-Content $File

    $insideSection = $false

    foreach ($line in $lines)
    {
        $line = $line.Trim()

        if ($line -eq "")
        {
            continue
        }

        if ($line -match "^\[(.+)\]$")
        {
            $insideSection = ($Matches[1] -eq $Section)
            continue
        }

        if ($insideSection -and $line -match "^(.+?)=(.*)$")
        {
            if ($Matches[1].Trim() -eq $Key)
            {
                return $Matches[2].Trim()
            }
        }
    }

    return $null
}

function Set-IniValue
{
    param
    (
        [string]$File,
        [string]$Section,
        [string]$Key,
        [string]$Value
    )

    if (-not (Test-Path $File))
    {
        throw "No existe el archivo: $File"
    }

    $lines = Get-Content $File

    $insideSection = $false

    for ($i = 0; $i -lt $lines.Count; $i++)
    {
        $line = $lines[$i].Trim()

        if ($line -match "^\[(.+)\]$")
        {
            $insideSection = ($Matches[1] -eq $Section)
            continue
        }

        if ($insideSection -and $line -match "^(.+?)=(.*)$")
        {
            if ($Matches[1].Trim() -eq $Key)
            {
                $lines[$i] = "$Key=$Value"
                Set-Content -Path $File -Value $lines
                return
            }
        }
    }
}