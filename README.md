# PCJ Raspberry Toolkit

Herramienta gratuita de PowerShell para administrar una Raspberry Pi desde Windows mediante una conexión SSH segura. Está creada para la comunidad de **Pensamiento Creativo #Job**.

PCJ Raspberry no sustituye al panel web de Pi-hole. Lo complementa con asistentes sencillos para mantenimiento de la Raspberry, respaldos, recuperación, red Wi-Fi, diagnósticos y accesos remotos.

## Funciones principales

- Consulta de estado: conexión, Pi-hole, DNS, temperatura, memoria y disco.
- Actualización manual y actualización automática de Raspberry Pi OS.
- Respaldos locales de configuración de Pi-hole, historial DNS e imagen completa del sistema.
- Restauración guiada y limpieza de respaldos locales.
- Herramientas de diagnóstico, espacio, servicios, hora y reportes.
- Administración de Pi-hole: instalación, Gravity, historial, dominios y acceso al panel web.
- Perfiles para administrar una o varias Raspberry Pi mediante llaves SSH.
- Asistentes opcionales para Tailscale, ZeroTier, Cloudflare Tunnel y Raspberry Pi Connect.

## Requisitos

- Windows 10 reciente o Windows 11.
- PowerShell 5.1 o superior.
- Cliente OpenSSH de Windows instalado.
- Raspberry Pi con Raspberry Pi OS y SSH habilitado.
- Conexión a la misma red local, o un acceso remoto que usted haya configurado.

Las funciones de Pi-hole están diseñadas para una instalación directa en Raspberry Pi OS. **Pi-hole en Docker no está soportado actualmente.**

## Inicio

1. Descargue la versión oficial desde la página de publicaciones del proyecto.
2. Extraiga el archivo ZIP en una carpeta de su elección.
3. Abra `PCJ Raspberry.bat`.
4. En el primer inicio, agregue la IP local, el usuario de la Raspberry y siga el asistente para registrar una llave SSH.

La contraseña de la Raspberry se usa durante el registro de la llave SSH. El programa no la guarda.

## Seguridad y privacidad

- No publique la carpeta personal de trabajo ni sus perfiles SSH.
- Los respaldos e informes pueden contener datos de su red, dominios consultados o configuración de Pi-hole.
- Lea [PRIVACIDAD.md](PRIVACIDAD.md) antes de compartir una copia.
- Lea [SECURITY.md](SECURITY.md) para conocer las recomendaciones y cómo informar un problema.

## Respaldos

Los respaldos se guardan en la carpeta `Backups` dentro de la carpeta del programa. Una imagen completa del sistema puede ocupar varios GB y contiene una copia de la microSD, incluidos datos sensibles que existan en ella.

La opción de imagen completa se realiza mientras la Raspberry está encendida. Es útil como respaldo de emergencia, pero no debe considerarse una imagen forense o absolutamente consistente si el sistema cambia mientras se está leyendo.

## Proyecto abierto

El código se publica para que la comunidad pueda revisarlo, aprender y proponer mejoras. Descargue siempre las versiones oficiales y verifique su SHA-256 cuando esté disponible.
