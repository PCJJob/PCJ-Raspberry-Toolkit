# Privacidad

PCJ Raspberry se ejecuta localmente en la PC del usuario y administra únicamente las Raspberry Pi que el propio usuario registre.

## Datos que se guardan localmente

- Nombre local, IP y usuario de cada Raspberry registrada.
- Llaves SSH privadas y públicas para iniciar sesión sin volver a pedir la contraseña.
- Respaldos de Pi-hole, imágenes del sistema e informes de diagnóstico si el usuario decide crearlos.

Las contraseñas de la Raspberry, Wi-Fi y Pi-hole no se guardan como texto en el programa. Se solicitan solo cuando una operación las necesita.

## Datos que pueden contener los respaldos e informes

Un respaldo o informe puede contener direcciones IP, nombres de dispositivos, configuraciones, dominios consultados y otras partes de la información de red. No comparta esos archivos públicamente.

## Comunicación de red

El programa se conecta por SSH a la Raspberry registrada. Algunas funciones opcionales descargan software desde proveedores elegidos por el usuario, como Pi-hole, Tailscale, ZeroTier, Cloudflare o Raspberry Pi. PCJ Raspberry no incluye telemetría ni envía datos al creador del proyecto.

## Antes de compartir

Comparta únicamente una copia limpia del proyecto. Nunca incluya `PCJ-Raspberry.ini`, `Backups`, `Informes`, llaves SSH ni perfiles personales.
