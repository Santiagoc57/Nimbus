# Arquitectura de Nimbo

## Piezas

| Componente | Archivo(s) | Qué hace |
|---|---|---|
| **Nimbo.app** | `main.swift`, `NimboTheme.swift`, `NimboComponents.swift`, `*Controller.swift` | Nubecita de la barra de menús, ventana (Inicio, cuentas, Configuración, Actividad, Sincronizaciones, Conflictos), avisos, atajo global y límite de espacio. |
| **NimboDrive.appex** | `NativeProvider.swift`, `NativeStore.swift`, `NativeWriteStore.swift`, `DriveAPI.swift`, `DriveWriteAPI.swift`, `DriveSplitUpload.swift` | Extensión File Provider replicada: un dominio por cuenta, catálogo cifrado, descargas, subidas con diario, decoraciones de estado, miniaturas y acciones del clic derecho. |
| **NimboActions.appex** | `ProviderActionUI.swift`, `ProviderWebLinks.swift` | Acciones opcionales con interfaz: copiar enlace y abrir la vista web. |
| **NimboFinderHelper** | `FinderSync.swift` | Extensión Finder Sync en una app auxiliar. Finder desactiva una Finder Sync que viva en la misma app que un File Provider activo. |
| **Motor de sincronización** | `SyncCore.swift`, `SyncSplit.swift`, `SyncFolderPlan.swift`, `SyncFilters.swift` | Carpetas vinculadas con `rclone bisync`, revisión de borrados, copias de conflicto, backups y documentos divididos. |
| **Seguridad** | `SecureLocalStore.swift`, `SecureConfig.swift` | Sobres AES-GCM para la configuración OAuth y los catálogos. Opcionalmente, clave en el Llavero. |
| **CLI** | `NimboCLI.swift` | `nimbo doctor`, `nimbo refresh` y otras órdenes de diagnóstico. |

## Comunicación app ↔ extensión
- **XPC** (`NSFileProviderServicing`, protocolo `NimboNativeConnection` en `NativeProtocol.swift`): configurar la cuenta, conservar o liberar, conflictos, límites, acciones opcionales.
- **Notificaciones Darwin** (`notify_post`): la extensión pide a la app que materialice una descarga o que muestre un error de liberación.

## Estados de un archivo en Finder

| Estado | Decoración | Cuándo |
|---|---|---|
| Sólo en la nube | `decoration.cloud` | Placeholder sin contenido. |
| Disponible sin conexión | `decoration.synced` | El contenido está en el Mac. En una carpeta, cuando todos sus archivos lo están. |
| Subiendo | `decoration.uploading` | Una edición local está viajando a Drive. |
| No se pudo subir | `decoration.failed` | La última subida falló; macOS la reintenta. |

La versión de metadatos incluye estos estados. La comparación de conflictos acepta todas sus combinaciones, así un cambio de ícono nunca se confunde con un conflicto.

## Subidas sin duplicados
1. Se reserva el ID de Drive antes de enviar contenido (`files.generateIds`).
2. Se congela una copia del contenido y se guarda el diario de la operación.
3. La edición se confirma con `If-Match` (ETag). Si Drive cambió, se conserva una copia «(conflicto Mac …)».
4. Si el proceso muere, macOS reenvía el elemento y Nimbo retoma la operación con el mismo ID.

## Documentos divididos
- En Drive son una carpeta con propiedades `nimboSplit`, `nimboBytes`, `nimboPartBytes` y `nimboMD5`, que contiene las partes `part-000001…`.
- Finder y el catálogo los muestran como un único archivo con su tamaño y su MD5.
- Una edición sube una generación nueva dentro de la carpeta y la publica con un commit que conserva el ID.
- En carpetas vinculadas, bisync los excluye por ruta exacta y `SyncSplitCoordinator` decide con el Mac, Drive y el último estado acordado.

## Pausa y límite de espacio
- **Pausa:** `NSFileProviderManager.disconnect(reason:options: .temporary)`. Finder muestra el motivo y las transferencias esperan hasta `reconnect`.
- **Límite:** se mide lo materializado por cuenta y se expulsa primero lo menos usado (`evictItem`). Nunca se tocan los elementos con política «conservar».
