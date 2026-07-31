# Seguridad

## Recomendaciones

- Descargue PCJ Raspberry solamente desde la publicación oficial del proyecto.
- Verifique el SHA-256 del ZIP cuando se publique una versión oficial.
- No comparta llaves SSH, respaldos, informes ni el archivo de configuración personal.
- Revise con cuidado las acciones que instalan software o modifican Wi-Fi, DNS, Pi-hole o accesos remotos.

## Alcance

PCJ Raspberry ejecuta comandos administrativos en la Raspberry mediante SSH. Algunas tareas usan `sudo` y pueden cambiar configuraciones o instalar programas. Cada persona es responsable de revisar las confirmaciones antes de continuar.

Los instaladores opcionales de Tailscale, ZeroTier y Cloudflare dependen de sus proveedores oficiales. Antes de ejecutarlos, el programa debe explicar su procedencia y solicitar confirmación.

## Reportar un problema

No publique en un comentario público contraseñas, llaves privadas, IP públicas, respaldos ni informes. Cuando se cree el repositorio oficial, aquí se añadirá un medio privado de contacto para reportar vulnerabilidades.
