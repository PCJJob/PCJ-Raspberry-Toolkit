function Initialize-PCJDesktopIntegration
{
    param([string]$ProgramRoot)

    try
    {
        $iconFile = Join-Path $ProgramRoot "Assets\pcj-raspberry-red.ico"
        $launcherFile = Join-Path $ProgramRoot "PCJ Raspberry.bat"
        $desktopIni = Join-Path $ProgramRoot "desktop.ini"

        if ((Test-Path -LiteralPath $iconFile) -and
            (Test-Path -LiteralPath $launcherFile))
        {
            $desktopPath = [Environment]::GetFolderPath("Desktop")
            $shortcutFile = Join-Path $desktopPath "PCJ Raspberry.lnk"

            # No se reemplaza un acceso directo que el usuario ya tenga.
            if (-not (Test-Path -LiteralPath $shortcutFile))
            {
                $shell = New-Object -ComObject WScript.Shell
                $shortcut = $shell.CreateShortcut($shortcutFile)
                $shortcut.TargetPath = $launcherFile
                $shortcut.WorkingDirectory = $ProgramRoot
                $shortcut.IconLocation = "$iconFile,0"
                $shortcut.Description = "PCJ Raspberry Toolkit"
                $shortcut.Save()
            }
        }

        # Windows usa desktop.ini y estos atributos para mostrar el icono
        # personalizado de la carpeta, incluso despues de extraer el ZIP.
        if (-not (Test-Path -LiteralPath $desktopIni))
        {
@"
[.ShellClassInfo]
IconResource=.\Assets\pcj-raspberry-red.ico,0
InfoTip=PCJ Raspberry Toolkit - Pensamiento Creativo #Job
"@ | Set-Content -LiteralPath $desktopIni -Encoding ASCII
        }

        attrib +s +r "$ProgramRoot" 2>$null
        attrib +h +s "$desktopIni" 2>$null
    }
    catch
    {
        # El acceso directo es una mejora visual; no debe impedir abrir el programa.
    }
}
