# SPLIVMAX para iPhone — compilación, TestFlight y App Store

App nativa en Swift/SwiftUI (iOS 16 o superior, solo iPhone) que usa la API privada
`https://splivmax.ond-s.com/v1`. **No es una WebView**: todas las pantallas son nativas.
El reproductor usa **AVPlayer** (HLS/MP4) y **MobileVLCKit** para archivos **MKV**.

> Estado: la app **no está publicada**. Solo lo estará cuando Apple apruebe la revisión
> en App Store Connect.

## 1. Estructura

| Carpeta | Contenido |
| --- | --- |
| `SPLIVMAX/App` | Arranque, orientación, sesión de audio, configuración (`AppConfig`) |
| `SPLIVMAX/Core` | Cliente de la API, modelos, Keychain, red, caché de imágenes, sesión |
| `SPLIVMAX/Design` | Colores y componentes con la identidad de la web |
| `SPLIVMAX/Features` | Pantallas: inicio, series, películas, búsqueda, ficha, perfil, planes, etc. |
| `SPLIVMAX/Features/Player` | Reproductor propio (HLS/MP4 con AVPlayer; MKV con VLCKit) |

## 2. Configuración antes de compilar

En Xcode › proyecto **SPLIVMAX** › target **SPLIVMAX** › *Signing & Capabilities* / *Build Settings*:

| Ajuste | Valor actual | Qué hacer |
| --- | --- | --- |
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.ondstudios.splivmax` | Debe coincidir con el identificador creado en developer.apple.com |
| `DEVELOPMENT_TEAM` | vacío | Elegir tu equipo (Team ID) en *Signing* |
| `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` | `2.0` / `5` | Subir el número de compilación en cada envío |
| `SPX_BILLING_MODE` | `reader` | **Dejar `reader` para el App Store** (ver punto 5) |

- La URL de la API está en `Info.plist` › `SPXAPIBaseURL` → `https://splivmax.ond-s.com/v1`.
- La clave de app (`onds_ios_…`) está en `AppConfig.swift`. Identifica a la app, no a un
  usuario. Si se filtra, se revoca y se crea otra en el panel › *Apps y API*.
- La app envía `X-Player-Capabilities: mkv,vlc` para que el servidor entregue fuentes MKV.
- En Xcode: *File › Packages › Resolve Package Versions* (descarga MobileVLCKit, ~200 MB).
- El icono es `Assets.xcassets/AppIcon` (1024×1024, sin transparencia). La pantalla de
  arranque usa el color `LaunchBackground` y el logotipo `LogoMark`.

## 3. Compilar

**Con un Mac (Xcode 16 o superior):** abrir `SPLIVMAX.xcodeproj`, elegir el equipo de
firma, conectar el iPhone y pulsar ▶. Para subir: *Product › Archive › Distribute App ›
App Store Connect*.

**Sin Mac:**

- **GitHub Actions** (`.github/workflows/build-ipa.yml`): compila **sin firma** en cada
  push. Sirve para comprobar que el código compila. Ese IPA no se puede instalar ni subir
  a Apple.
- **Codemagic** (`codemagic.yaml`): firma la app y la envía a **TestFlight**. Requiere:
  - una cuenta de Apple Developer;
  - la app creada en App Store Connect;
  - una clave API de App Store Connect llamada `SPLIVMAX ASC` en Codemagic.

## 4. App Store Connect

1. **Crear la app**:
   - plataforma iOS, nombre «SPLIVMAX», idioma principal español;
   - bundle `com.ondstudios.splivmax`, SKU libre;
   - categoría **Entretenimiento**.
2. **URLs**:
   - Privacidad: `https://splivmax.ond-s.com/public/privacidad`
   - Soporte: `https://splivmax.ond-s.com/public/contacto`
3. **Clasificación por edad**: responde el cuestionario según el catálogo real (violencia,
   lenguaje, etc.). Los perfiles infantiles limitan el contenido, pero la clasificación
   debe reflejar el contenido más alto disponible.
4. **Capturas**: iPhone de 6,9" y 6,5" (inicio, ficha, reproductor, perfil).
5. **Cifrado**: `ITSAppUsesNonExemptEncryption = NO` ya está en `Info.plist`, porque solo se
   usa HTTPS.

### Privacidad de la app (etiquetas «App Privacy»)

Nada se usa para rastreo (tracking) ni publicidad. No hace falta el permiso ATT.

| Tipo de dato | Para qué | ¿Vinculado al usuario? |
| --- | --- | --- |
| Nombre y correo electrónico | Funcionalidad (cuenta) | Sí |
| Identificador de dispositivo: UUID propio de la app, no el IDFA | Funcionalidad y seguridad (sesiones abiertas, evitar abuso de la prueba gratuita) | Sí |
| Interacción con el producto: historial, progreso, Mi lista | Funcionalidad (continuar viendo) | Sí |
| Contenido del usuario: comentarios, reportes, motivo de baja | Funcionalidad y soporte | Sí |
| Diagnóstico: errores de reproducción | Funcionalidad | Sí |
| Historial de compras | Solo si se usa el modo `direct` (no en App Store) | Sí |

**Permisos del sistema:** la app no pide ninguno. No usa cámara, fotos, ubicación,
contactos, seguimiento ni notificaciones push. El modo de fondo *audio* es solo para
Picture in Picture y AirPlay.

**Eliminación de cuenta (norma 5.1.1(v)):** *Perfil › Eliminar mi cuenta*. Pide la
contraseña. Luego cancela el plan, cierra todas las sesiones y registra la solicitud de
borrado en el soporte (`POST /me/delete`).

## 5. Cobros: modo lector y StoreKit

La app del App Store se compila en **modo lector** (`SPX_BILLING_MODE = reader`), según la
norma **3.1.3(a) «Reader apps»**:

- muestra los planes y sus beneficios **sin precios, sin botones de compra y sin enlaces**
  a pagos externos;
- el usuario inicia sesión con la cuenta que ya tiene y ve su plan, vencimiento y días
  restantes;
- se permite activar la **prueba gratuita** (no cuesta nada) y **cancelar** la suscripción;
- la suscripción siempre la valida el servidor: la app nunca concede acceso por su cuenta.

El modo `direct` (pago por Nequi/Bre-B/Llave, comprobante y saldo) existe para builds
**fuera del App Store**. Usarlo en el App Store provocaría el rechazo por la norma 3.1.1.

**StoreKit (compras dentro de la app) no está implementado**, porque requiere cosas que no
existen todavía:

1. productos de suscripción creados en App Store Connect;
2. un endpoint en el servidor que verifique las transacciones con la App Store Server API
   y reciba las notificaciones del servidor (v2);
3. relacionar cada producto con un plan de SPLIVMAX.

Hacerlo sin la verificación del servidor sería simular pagos. Apple cobra una comisión del
15 % al 30 % en esas ventas.

## 6. Descargas sin conexión

No se incluyen. El servidor solo entrega enlaces de reproducción firmados y temporales (HLS
o MP4), sin licencias de descarga (FairPlay offline). Además, los derechos del contenido no
autorizan copias en el dispositivo. La sección se podría añadir solo cuando existan ambas
cosas.

## 7. Notas para la revisión (pegar en App Store Connect › *App Review Information*)

> SPLIVMAX es un servicio de streaming de películas y series. La app funciona como «reader
> app» (norma 3.1.3(a)): los usuarios inician sesión con una cuenta existente para ver el
> contenido incluido en su plan. La app no vende suscripciones ni enlaza a compras externas.
>
> Cuenta de prueba (con plan activo): **usuario:** ______ **contraseña:** ______
>
> - Eliminar la cuenta: Perfil › Eliminar mi cuenta.
> - Los perfiles infantiles limitan el contenido según la clasificación por edades.
> - Contacto: ondstudions@gmail.com

Antes de enviar:

- [ ] Crear en la web una **cuenta de demostración con un plan premium activo** y ponerla
      arriba. Apple rechaza las apps sin cuenta de prueba funcional.
- [ ] Tener a mano la **documentación de los derechos del contenido** (licencias o
      autorizaciones). Apple la pide a las apps de streaming (normas 5.2.1 y 5.2.3).
- [ ] Probar en TestFlight: inicio de sesión, perfiles, reproducción con Wi-Fi y datos
      móviles, subtítulos, PiP, AirPlay, cierre de sesión y eliminación de cuenta.
- [ ] Revisar que `SPX_BILLING_MODE` sea `reader` en la configuración *Release*.
