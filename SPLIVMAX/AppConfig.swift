import SwiftUI
import UIKit

enum AppConfig {
    static let homeURL = URL(string: "https://splivmax.ond-s.com/")!

    /// Dominios que se abren dentro de la app; el resto (WhatsApp, Facebook…) se abre fuera.
    static let internalHosts = ["splivmax.ond-s.com"]

    /// Ruta del reproductor del sitio: al entrar, la app pasa a pantalla completa horizontal.
    static let playerPathPrefix = "/ver/"

    /// Se añade al user agent de Safari para que el sitio pueda reconocer la app.
    static let userAgentSuffix = "Version/17.0 Mobile/15E148 Safari/604.1 SPLIVMAXApp/1.1"

    /// API del sitio con las notificaciones del usuario (la misma que usa la campana de la web).
    static let notificationsAPI = URL(string: "https://splivmax.ond-s.com/api/notifications")!
    static let notificationPollInterval: TimeInterval = 120
    static let refreshTaskID = "com.ondstudios.splivmax.refresh"

    /// Días que la sesión sigue iniciada en el iPhone sin volver a escribir la contraseña.
    static let sessionDays: Double = 30

    /// Nombre del canal JavaScript → app (window.webkit.messageHandlers.splivmax).
    static let bridgeName = "splivmax"

    static let background = Color(red: 7 / 255, green: 10 / 255, blue: 18 / 255)
    static let uiBackground = UIColor(red: 7 / 255, green: 10 / 255, blue: 18 / 255, alpha: 1)
    static let accent = Color(red: 109 / 255, green: 93 / 255, blue: 252 / 255)
    static let accent2 = Color(red: 0, green: 182 / 255, blue: 230 / 255)
    static let brandGradient = LinearGradient(colors: [accent, accent2], startPoint: .leading, endPoint: .trailing)

    static func isInternal(_ url: URL) -> Bool {
        guard let host = url.host else { return true }
        return isInternalHost(host)
    }

    static func isInternalHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")), !host.isEmpty else { return false }
        return internalHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func isPlayer(_ url: URL?) -> Bool {
        guard let url, isInternal(url) else { return false }
        return url.path.hasPrefix(playerPathPrefix)
    }

    /// Convierte el enlace de una notificación ("/titulo/…" o absoluto) en una URL del sitio.
    static func resolve(_ link: String?) -> URL? {
        guard let link, !link.isEmpty, let url = URL(string: link, relativeTo: homeURL)?.absoluteURL,
              isInternal(url) else { return nil }
        return url
    }

    /// Se inyecta antes que los scripts del sitio, en todos los marcos.
    /// - Avisa a la app cuando un vídeo entra o sale de pantalla completa (también dentro de iframes).
    /// - En la página principal, la "pantalla completa" del reproductor se hace dentro de la app,
    ///   que ya ocupa toda la pantalla y gira a horizontal; así se conservan los controles del sitio.
    /// - Expone window.SPLIVMAXApp para que la web envíe notificaciones al iPhone.
    static let documentStartScript = """
    (function () {
      if (window.__splivmaxApp) return;
      window.__splivmaxApp = true;
      var post = function (msg) {
        try { window.webkit.messageHandlers.\(bridgeName).postMessage(msg); } catch (e) {}
      };
      window.addEventListener('webkitbeginfullscreen', function () { post({ type: 'fullscreen', on: true }); }, true);
      window.addEventListener('webkitendfullscreen', function () { post({ type: 'fullscreen', on: false }); }, true);

      if (window !== window.top) {
        var frameFs = function () {
          post({ type: 'fullscreen', on: !!(document.fullscreenElement || document.webkitFullscreenElement) });
        };
        document.addEventListener('fullscreenchange', frameFs);
        document.addEventListener('webkitfullscreenchange', frameFs);
        return;
      }

      var current = null, style = null;
      var ensureStyle = function () {
        if (style) return;
        style = document.createElement('style');
        style.textContent = '.ios-fs{position:fixed!important;top:0!important;left:0!important;right:0!important;bottom:0!important;' +
          'width:100vw!important;height:100vh!important;max-width:none!important;max-height:none!important;margin:0!important;' +
          'border-radius:0!important;z-index:2147483646!important;background:#000!important}' +
          'html.ios-fs-on,html.ios-fs-on body{overflow:hidden!important}';
        (document.head || document.documentElement).appendChild(style);
      };
      var change = function (el) {
        if (current === el) return;
        if (current) current.classList.remove('ios-fs');
        current = el;
        ensureStyle();
        if (el) el.classList.add('ios-fs');
        document.documentElement.classList.toggle('ios-fs-on', !!el);
        post({ type: 'fullscreen', on: !!el });
        document.dispatchEvent(new Event('fullscreenchange'));
        document.dispatchEvent(new Event('webkitfullscreenchange'));
      };
      var enter = function () { change(this); return Promise.resolve(); };
      var exit = function () { change(null); return Promise.resolve(); };
      var EP = Element.prototype, DP = Document.prototype;
      EP.requestFullscreen = EP.webkitRequestFullscreen = EP.webkitRequestFullScreen = enter;
      DP.exitFullscreen = DP.webkitExitFullscreen = DP.webkitCancelFullScreen = exit;
      var define = function (name, get) {
        try { Object.defineProperty(DP, name, { configurable: true, get: get }); } catch (e) {}
      };
      ['fullscreenElement', 'webkitFullscreenElement', 'webkitCurrentFullScreenElement'].forEach(function (n) {
        define(n, function () { return current; });
      });
      ['fullscreenEnabled', 'webkitFullscreenEnabled', 'webkitIsFullScreen'].forEach(function (n) {
        define(n, n === 'webkitIsFullScreen' ? function () { return !!current; } : function () { return true; });
      });
      window.addEventListener('pagehide', function () { if (current) change(null); });

      var text = function (v) { return v == null ? '' : String(v); };
      window.SPLIVMAXApp = {
        isApp: true,
        platform: 'ios',
        notify: function (title, body, link) {
          post({ type: 'notify', title: text(title), body: text(body), link: text(link) });
        },
        schedule: function (id, title, body, at, link) {
          var ts = at instanceof Date ? at.getTime() / 1000 : Number(at);
          post({ type: 'schedule', id: text(id), title: text(title), body: text(body), at: ts, link: text(link) });
        },
        cancel: function (id) { post({ type: 'cancel', id: text(id) }); },
        requestPermission: function () { post({ type: 'permission' }); },
        checkNotifications: function () { post({ type: 'check' }); }
      };
      document.documentElement.classList.add('ios-app');
    })();
    """

    /// Ajustes de "app nativa" (sin resaltado gris ni vista previa al mantener pulsado, controles del
    /// reproductor fuera de la muesca) y la cuenta del usuario guardada en localStorage del iPhone.
    static let injectedScript = """
    (function () {
      document.documentElement.classList.add('ios-app');
      var s = document.createElement('style');
      s.textContent = [
        'html{-webkit-tap-highlight-color:transparent}',
        'a,img,button{-webkit-touch-callout:none}',
        '.player__top,.player__controls{padding-left:max(22px,env(safe-area-inset-left));padding-right:max(22px,env(safe-area-inset-right))}',
        '.player__controls{padding-bottom:max(16px,env(safe-area-inset-bottom))}'
      ].join('');
      document.head.appendChild(s);

      var KEY = 'splivmax.account';
      var read = function () {
        try { return JSON.parse(localStorage.getItem(KEY) || 'null') || {}; } catch (e) { return {}; }
      };
      var save = function (data) {
        try {
          var acc = read();
          for (var k in data) { if (data[k]) acc[k] = data[k]; }
          acc.savedAt = new Date().toISOString();
          localStorage.setItem(KEY, JSON.stringify(acc));
        } catch (e) {}
      };
      var forms = document.querySelectorAll('form[action$="/login"], form[action$="/registro"]');
      Array.prototype.forEach.call(forms, function (form) {
        var acc = read();
        var email = form.querySelector('input[name="email"]');
        var name = form.querySelector('input[name="name"]');
        if (email && !email.value && acc.email) email.value = acc.email;
        if (name && !name.value && acc.name) name.value = acc.name;
        var remember = form.querySelector('input[name="remember"]');
        if (remember) remember.checked = true;
        form.addEventListener('submit', function () {
          save({
            email: email ? email.value.trim().toLowerCase() : '',
            name: name ? name.value.trim() : '',
            registeredAt: /\\/registro$/.test(form.getAttribute('action') || '') ? new Date().toISOString() : ''
          });
        });
      });
    })();
    """
}
