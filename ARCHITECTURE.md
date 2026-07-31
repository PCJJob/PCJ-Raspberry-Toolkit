# Arquitectura de PCJ Raspberry

## Entrada

- `PCJ Raspberry.bat`: inicia PowerShell.
- `Scripts/menu.ps1`: panel principal y menús de navegación.
- `Setup/Setup.ps1`: asistente de primera configuración.

## Módulos

- `Config.ps1`: lectura de archivos INI.
- `Profiles.ps1`: perfiles, llaves SSH y Wi-Fi.
- `SSH.ps1`: comandos y transferencias SSH/SCP.
- `Status.ps1`: estado y datos del panel principal.
- `Update.ps1`: actualizaciones manuales y automáticas.
- `Backup.ps1`, `Restore.ps1`, `Cleanup.ps1`: respaldo, recuperación y limpieza local.
- `Tools.ps1`, `Enhancements.ps1`: Pi-hole, diagnósticos, accesos remotos y herramientas del sistema.
- `UI.ps1`: encabezados, colores, entradas y barras de avance.

## Datos locales

Los perfiles y sus llaves SSH se almacenan por usuario de Windows en `%USERPROFILE%\.pcj-raspberry\profiles`. Los respaldos e informes se guardan dentro de la carpeta del programa y no deben publicarse.

## Principios

1. Las operaciones de riesgo requieren explicación y confirmación.
2. Las contraseñas no se guardan.
3. Las tareas de Raspberry se realizan mediante SSH con llave privada.
4. La interfaz debe explicar qué hace cada acción y cómo cancelarla cuando sea seguro hacerlo.
5. Las funciones destinadas a Pi-hole en Docker no se ofrecen como compatibles hasta contar con una implementación específica.
