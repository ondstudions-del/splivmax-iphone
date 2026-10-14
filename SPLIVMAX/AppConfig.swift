import SwiftUI
import UIKit

enum AppConfig {
    static let homeURL = URL(string: "https://splivmax.ond-s.com/")!

    /// Dominios que se abren dentro de la app; el resto (WhatsApp, Facebook…) se abre fuera.
    static let internalHosts = ["splivmax.ond-s.com"]

    /// Ruta del reproductor del sitio: al entrar, la app pasa a pantalla completa horizontal.
    static let playerPathPrefix = "/ver/"

    /// Se añade al user agent de Safari para que el sitio pueda reconocer la app.
    static let userAgentSuffix = "Version/17.0 Mobile/15E148 Safari/604.1 SPLIVMAXApp/1.0"

    static let background = Color(red: 7 / 255, green: 10 / 255, blue: 18 / 255)
    static let uiBackground = UIColor(red: 7 / 255, green: 10 / 255, blue: 18 / 255, alpha: 1)
    static let accent = Color(red: 109 / 255, green: 93 / 255, blue: 252 / 255)
    static let accent2 = Color(red: 0, green: 182 / 255, blue: 230 / 255)
    static let brandGradient = LinearGradient(colors: [accent, accent2], startPoint: .leading, endPoint: .trailing)

    static func isInternal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        return internalHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func isPlayer(_ url: URL?) -> Bool {
        guard let url, isInternal(url) else { return false }
        return url.path.hasPrefix(playerPathPrefix)
    }

    /// Ajustes de "app nativa": sin resaltado gris al tocar ni menú de vista previa al mantener pulsado,
    /// y controles del reproductor fuera de la muesca cuando el iPhone está en horizontal.
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
    })();
    """
}
