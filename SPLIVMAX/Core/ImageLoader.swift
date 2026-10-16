import SwiftUI
import ImageIO

/// Descarga y reduce las imágenes al tamaño en pantalla (menos memoria y datos) con caché en memoria y disco.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let lock = NSLock()
    private var _lowData = false

    /// En ahorro de datos las imágenes se piden más pequeñas y no se precargan.
    var lowData: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _lowData }
        set { lock.lock(); _lowData = newValue; lock.unlock() }
    }

    private init() {
        memory.totalCostLimit = 96 * 1024 * 1024
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 250 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 25
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)
    }

    private func key(_ url: URL, _ maxPixel: CGFloat) -> NSString {
        "\(url.absoluteString)#\(Int(maxPixel))" as NSString
    }

    private func effective(_ maxPixel: CGFloat) -> CGFloat {
        lowData ? (maxPixel * 0.6).rounded() : maxPixel
    }

    /// UIImage no decodifica SVG: los avatares de la web vienen incluidos en la app con el mismo nombre.
    private static func bundled(_ url: URL) -> UIImage? {
        guard url.pathExtension.lowercased() == "svg" else { return nil }
        return UIImage(named: url.deletingPathExtension().lastPathComponent)
    }

    func cached(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        if let image = Self.bundled(url) { return image }
        return memory.object(forKey: key(url, maxPixel)) ?? memory.object(forKey: key(url, effective(maxPixel)))
    }

    func load(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        if let image = cached(url, maxPixel: maxPixel) { return image }
        if url.pathExtension.lowercased() == "svg" { return nil }
        let target = effective(maxPixel)
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 { return nil }
            guard let image = Self.downsample(data, maxPixel: target) ?? UIImage(data: data) else { return nil }
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            memory.setObject(image, forKey: key(url, target), cost: cost)
            return image
        } catch {
            return nil
        }
    }

    func prefetch(_ urls: [URL], maxPixel: CGFloat) {
        guard !lowData else { return }
        for url in urls.prefix(12) where cached(url, maxPixel: maxPixel) == nil {
            Task.detached(priority: .utility) { _ = await self.load(url, maxPixel: maxPixel) }
        }
    }

    func clearMemory() {
        memory.removeAllObjects()
    }

    private static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Imagen remota que ocupa todo el espacio que le da su contenedor (recortada, como object-fit: cover).
struct RemoteImage: View {
    let url: URL?
    var maxPixel: CGFloat = 500
    var contentMode: ContentMode = .fill
    var placeholderIcon: String = "film"

    @State private var image: UIImage?
    @State private var loadedURL: URL?

    init(_ url: URL?, maxPixel: CGFloat = 500, contentMode: ContentMode = .fill, placeholderIcon: String = "film") {
        self.url = url
        self.maxPixel = maxPixel
        self.contentMode = contentMode
        self.placeholderIcon = placeholderIcon
        let cached = url.flatMap { ImagePipeline.shared.cached($0, maxPixel: maxPixel) }
        _image = State(initialValue: cached)
        _loadedURL = State(initialValue: cached != nil ? url : nil)
    }

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                } else {
                    placeholder
                }
            }
            .clipped()
            .task(id: url) {
                guard let url else { image = nil; return }
                if loadedURL == url, image != nil { return }
                let result = await ImagePipeline.shared.load(url, maxPixel: maxPixel)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    image = result
                    loadedURL = url
                }
            }
    }

    private var placeholder: some View {
        LinearGradient(colors: [Theme.surface2, Theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Image(systemName: placeholderIcon)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(Theme.muted.opacity(0.5))
            }
    }
}
