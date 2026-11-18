# Instalar Nimbo en otro Mac

## Lo que necesitás
- Un Mac **Intel** con **macOS 13 Ventura o posterior**.
- `Nimbo.app`, ya sea compilado o copiado de un Mac donde funcione.
- El **archivo JSON del cliente de Google** que ya usás (`client_secret_….json`). Si no lo tenés a mano, se vuelve a descargar desde Google Cloud → APIs y servicios → Credenciales.

## Opción A: copiar la app ya compilada (lo más rápido)

1. **En tu Mac:** comprimí la app.
   ```bash
   ditto -c -k --keepParent ~/Applications/Nimbo.app ~/Desktop/Nimbo.zip
   ```
2. Pasá `Nimbo.zip` al otro Mac (AirDrop, pendrive o Drive).
3. **En el otro Mac:** descomprimilo y mové `Nimbo.app` a **Aplicaciones** o a `~/Applications`. File Provider no funciona si la app queda en Descargas o en el Escritorio.
4. **Primera apertura.** Nimbo no está notarizado por Apple, así que macOS lo bloquea la primera vez. Hacé clic derecho sobre Nimbo → **Abrir** → **Abrir**. Si no aparece esa opción, andá a Ajustes del Sistema → Privacidad y seguridad y elegí **Abrir igualmente**.

   También se puede quitar la marca de descarga desde la Terminal:
   ```bash
   xattr -dr com.apple.quarantine ~/Applications/Nimbo.app
   ```

## Opción B: compilar en el otro Mac

```bash
xcode-select --install                   # una sola vez
git clone <URL del repositorio> Nimbo && cd Nimbo
./scripts/fetch-rclone.sh
zsh source/build.sh
ditto Nimbo.app ~/Applications/Nimbo.app && open ~/Applications/Nimbo.app
```

## Conectar la cuenta

1. Hacé clic en la nubecita de la barra de menús → **Agregar una cuenta de Google…**.
2. La primera vez Nimbo pide el cliente de Google. Arrastrá el JSON a la ventana o pulsá **Elegir JSON…**.
3. Se abre Google en el navegador. Elegí la cuenta y tocá **Permitir**.
   - Si querés subir y editar archivos, dejá marcado el permiso de escritura.
   - Si el proyecto de Google está «en pruebas», el correo de esa cuenta tiene que figurar como **usuario de prueba**.
4. **Habilitar la extensión de Finder.** macOS puede preguntarlo; si no lo hace, andá a Ajustes del Sistema → Privacidad y seguridad → Extensiones → **Finder** / **Proveedores de archivos** y activá Nimbo.
5. La cuenta aparece en la barra lateral de Finder.

## Qué no se copia entre Macs
- **Las sesiones de Google:** cada Mac autoriza sus cuentas. Las credenciales se cifran con una clave propia de cada equipo.
- **Lo descargado y lo «conservado sin conexión»:** se vuelve a elegir en cada Mac.
- **Los ajustes de Configuración:** son locales.

## Desinstalar
1. Salí de Nimbo (nubecita → **Salir de Nimbo**).
2. Borrá `Nimbo.app`. macOS quita sus ubicaciones de Finder.
3. Opcional: borrá `~/Library/Application Support/Nimbo`.

Tus archivos en Google Drive no se tocan.
