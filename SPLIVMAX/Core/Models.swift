import Foundation

// Modelos de la API /api/v1. Las claves llegan en snake_case y se convierten a camelCase
// (JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase).

// MARK: - Envoltorios

struct Envelope<T: Decodable>: Decodable {
    let data: T
    let meta: PageMeta?

    enum CodingKeys: String, CodingKey { case data, meta }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decode(T.self, forKey: .data)
        meta = try? c.decodeIfPresent(PageMeta.self, forKey: .meta)
    }
}

struct PageMeta: Decodable {
    let page: Int?
    let pages: Int?
    let perPage: Int?
    let total: Int?
    let unread: Int?
    let enabled: Bool?
}

struct ErrorEnvelope: Decodable {
    struct Body: Decodable {
        let code: String
        let message: String
        let fields: [String: String]

        enum CodingKeys: String, CodingKey { case code, message, fields }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = (try? c.decode(String.self, forKey: .code)) ?? "error"
            message = (try? c.decode(String.self, forKey: .message)) ?? "No se pudo completar la solicitud."
            fields = (try? c.decodeIfPresent([String: String].self, forKey: .fields)) ?? [:]
        }
    }
    let error: Body
}

/// Cualquier valor JSON; sirve para leer listas cuyo formato puede variar.
enum JSONValue: Decodable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .object(let o): return o["name"]?.string
        default: return nil
        }
    }
}

extension KeyedDecodingContainer {
    func lossyStrings(_ key: Key) -> [String] {
        guard let list = try? decodeIfPresent([JSONValue].self, forKey: key) else { return [] }
        return list.compactMap { $0.string }.filter { !$0.isEmpty }
    }

    func flexInt(_ key: Key) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int(s) }
        return nil
    }
}

enum ISODate {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return formatter.date(from: value)
    }

    static func display(_ value: String?, time: Bool = false) -> String? {
        guard let date = parse(value) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_CO")
        f.dateStyle = .medium
        f.timeStyle = time ? .short : .none
        return f.string(from: date)
    }

    static func relative(_ value: String?) -> String? {
        guard let date = parse(value) else { return nil }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es_CO")
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Catálogo

struct Genre: Codable, Hashable, Identifiable {
    let slug: String
    let name: String
    var id: String { slug }
}

struct TitleCard: Codable, Hashable, Identifiable {
    let id: String
    let type: String
    let title: String
    let year: Int?
    let ageRating: String?
    let durationMin: Int?
    let seasons: Int?
    let episodes: Int?
    let synopsis: String?
    let genres: [Genre]
    let poster: URL?
    let banner: URL?
    let backdrop: URL?
    let access: String
    let playable: Bool
    let imdbRating: Double?
    let releaseAt: String?

    var isSeries: Bool { type == "series" }
    var isPremium: Bool { access == "premium" }
    var isUpcoming: Bool { releaseAt != nil }
    var wideImage: URL? { backdrop ?? banner ?? poster }
    var tallImage: URL? { poster ?? backdrop ?? banner }

    var durationText: String? { Format.duration(minutes: durationMin) }

    var seasonsText: String? {
        guard let s = seasons, s > 0 else { return nil }
        return s == 1 ? "1 temporada" : "\(s) temporadas"
    }

    var ratingText: String? {
        guard let r = imdbRating, r > 0 else { return nil }
        return String(format: "%.1f", r)
    }

    var releaseText: String? {
        guard let date = ISODate.parse(releaseAt) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_CO")
        f.dateFormat = "d 'de' MMMM"
        return "Se estrena el \(f.string(from: date))"
    }

    enum CodingKeys: String, CodingKey {
        case id, type, title, year, ageRating, durationMin, seasons, episodes, synopsis
        case genres, poster, banner, backdrop, access, playable, imdbRating, releaseAt, rating, duration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = (try? c.decode(String.self, forKey: .type)) ?? "movie"
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        year = c.flexInt(.year)
        ageRating = (try? c.decode(String.self, forKey: .ageRating))
            ?? (try? c.decode(String.self, forKey: .rating))
        if let min = c.flexInt(.durationMin) {
            durationMin = min
        } else if let n = c.flexInt(.duration) {
            durationMin = n
        } else {
            durationMin = nil
        }
        seasons = c.flexInt(.seasons)
        episodes = c.flexInt(.episodes)
        synopsis = try? c.decodeIfPresent(String.self, forKey: .synopsis)
        if let g = try? c.decode([Genre].self, forKey: .genres) {
            genres = g
        } else if let names = try? c.decode([String].self, forKey: .genres) {
            genres = names.map { Genre(slug: $0.lowercased().replacingOccurrences(of: " ", with: "-"), name: $0) }
        } else {
            genres = []
        }
        poster = Self.absURL(try? c.decodeIfPresent(String.self, forKey: .poster))
        banner = Self.absURL(try? c.decodeIfPresent(String.self, forKey: .banner))
        backdrop = Self.absURL(try? c.decodeIfPresent(String.self, forKey: .backdrop))
        access = (try? c.decode(String.self, forKey: .access)) ?? "free"
        playable = (try? c.decode(Bool.self, forKey: .playable)) ?? true
        imdbRating = try? c.decodeIfPresent(Double.self, forKey: .imdbRating)
        releaseAt = try? c.decodeIfPresent(String.self, forKey: .releaseAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(year, forKey: .year)
        try c.encodeIfPresent(ageRating, forKey: .ageRating)
        try c.encodeIfPresent(durationMin, forKey: .durationMin)
        try c.encodeIfPresent(seasons, forKey: .seasons)
        try c.encodeIfPresent(episodes, forKey: .episodes)
        try c.encodeIfPresent(synopsis, forKey: .synopsis)
        try c.encode(genres, forKey: .genres)
        try c.encodeIfPresent(poster, forKey: .poster)
        try c.encodeIfPresent(banner, forKey: .banner)
        try c.encodeIfPresent(backdrop, forKey: .backdrop)
        try c.encode(access, forKey: .access)
        try c.encode(playable, forKey: .playable)
        try c.encodeIfPresent(imdbRating, forKey: .imdbRating)
        try c.encodeIfPresent(releaseAt, forKey: .releaseAt)
    }

    private static func absURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if let u = URL(string: raw), u.scheme != nil { return u }
        return URL(string: "https://splivmax.ond-s.com" + (raw.hasPrefix("/") ? raw : "/" + raw))
    }
}

struct WatchProgress: Codable, Hashable {
    let position: Int
    let duration: Int
    let percent: Int
    let completed: Bool
    let updatedAt: String?

    enum CodingKeys: String, CodingKey { case position, duration, percent, completed, updatedAt }

    init(position: Int = 0, duration: Int = 0, percent: Int = 0, completed: Bool = false, updatedAt: String? = nil) {
        self.position = position
        self.duration = duration
        self.percent = percent
        self.completed = completed
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = c.flexInt(.position) ?? 0
        duration = c.flexInt(.duration) ?? 0
        if let p = c.flexInt(.percent) {
            percent = min(100, max(0, p))
        } else if duration > 0 {
            percent = min(100, max(0, Int((Double(position) / Double(duration)) * 100)))
        } else {
            percent = 0
        }
        completed = (try? c.decode(Bool.self, forKey: .completed)) ?? (percent >= 95)
        updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(position, forKey: .position)
        try c.encode(duration, forKey: .duration)
        try c.encode(percent, forKey: .percent)
        try c.encode(completed, forKey: .completed)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}

struct Episode: Codable, Hashable, Identifiable {
    let id: String
    let season: Int?
    let number: Int?
    let title: String
    let synopsis: String
    let durationMin: Int?
    let thumbnail: URL?
    let playable: Bool
    let releaseAt: String?
    let progress: WatchProgress?

    var code: String { "T\(season ?? 0):E\(number ?? 0)" }

    enum CodingKeys: String, CodingKey {
        case id, season, number, title, synopsis, durationMin, thumbnail, playable, releaseAt, progress
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        season = c.flexInt(.season)
        number = c.flexInt(.number)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        synopsis = (try? c.decode(String.self, forKey: .synopsis)) ?? ""
        durationMin = c.flexInt(.durationMin)
        if let s = try? c.decodeIfPresent(String.self, forKey: .thumbnail) {
            thumbnail = URL(string: s)
        } else {
            thumbnail = nil
        }
        playable = (try? c.decode(Bool.self, forKey: .playable)) ?? true
        releaseAt = try? c.decodeIfPresent(String.self, forKey: .releaseAt)
        progress = try? c.decodeIfPresent(WatchProgress.self, forKey: .progress)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(season, forKey: .season)
        try c.encodeIfPresent(number, forKey: .number)
        try c.encode(title, forKey: .title)
        try c.encode(synopsis, forKey: .synopsis)
        try c.encodeIfPresent(durationMin, forKey: .durationMin)
        try c.encodeIfPresent(thumbnail, forKey: .thumbnail)
        try c.encode(playable, forKey: .playable)
        try c.encodeIfPresent(releaseAt, forKey: .releaseAt)
        try c.encodeIfPresent(progress, forKey: .progress)
    }
}

struct Season: Codable, Hashable, Identifiable {
    let id: String
    let number: Int
    let title: String
    let episodes: [Episode]
}

struct ResumeTarget: Codable, Hashable {
    let episodeId: String
    let position: Int
    let label: String
}

struct CastMember: Codable, Hashable {
    let name: String
    let character: String
}

struct LanguageItem: Codable, Hashable, Identifiable {
    let code: String
    let name: String
    var id: String { code }
}

/// Ficha completa: los campos de la tarjeta más los del detalle (mismo objeto JSON).
struct TitleDetail: Decodable {
    let card: TitleCard
    let synopsisFull: String
    let originalTitle: String
    let cast: [CastMember]
    let directors: [String]
    let languages: [LanguageItem]
    let subtitleLanguages: [LanguageItem]
    let rightsHolder: String
    let commentsEnabled: Bool
    let commentsCount: Int
    var favorite: Bool
    let canWatch: Bool
    let progress: WatchProgress?
    let seasonList: [Season]
    let resume: ResumeTarget?
    let similar: [TitleCard]

    enum CodingKeys: String, CodingKey {
        case synopsisFull, originalTitle, cast, directors, languages, subtitleLanguages, rightsHolder
        case commentsEnabled, commentsCount, favorite, canWatch, progress, seasonList, resume, similar
    }

    init(from decoder: Decoder) throws {
        card = try TitleCard(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        synopsisFull = (try? c.decode(String.self, forKey: .synopsisFull)) ?? ""
        originalTitle = (try? c.decode(String.self, forKey: .originalTitle)) ?? ""
        cast = (try? c.decode([CastMember].self, forKey: .cast)) ?? []
        directors = c.lossyStrings(.directors)
        languages = (try? c.decode([LanguageItem].self, forKey: .languages)) ?? []
        subtitleLanguages = (try? c.decode([LanguageItem].self, forKey: .subtitleLanguages)) ?? []
        rightsHolder = (try? c.decode(String.self, forKey: .rightsHolder)) ?? ""
        commentsEnabled = (try? c.decode(Bool.self, forKey: .commentsEnabled)) ?? false
        commentsCount = (try? c.decode(Int.self, forKey: .commentsCount)) ?? 0
        favorite = (try? c.decode(Bool.self, forKey: .favorite)) ?? false
        canWatch = (try? c.decode(Bool.self, forKey: .canWatch)) ?? false
        progress = try? c.decodeIfPresent(WatchProgress.self, forKey: .progress)
        seasonList = try c.decodeIfPresent([Season].self, forKey: .seasonList) ?? []
        resume = try? c.decodeIfPresent(ResumeTarget.self, forKey: .resume)
        similar = (try? c.decode([TitleCard].self, forKey: .similar)) ?? []
    }
}

struct HeroItem: Decodable {
    let card: TitleCard
    let synopsisFull: String

    enum CodingKeys: String, CodingKey { case synopsisFull }

    init(from decoder: Decoder) throws {
        card = try TitleCard(from: decoder)
        synopsisFull = (try? decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .synopsisFull)) ?? ""
    }
}

struct HomeSection: Decodable, Identifiable {
    let key: String
    let title: String
    let genre: String?
    let items: [TitleCard]
    var id: String { key }
}

struct ContinueItem: Decodable, Identifiable, Hashable {
    let title: TitleCard
    let episode: Episode?
    let progress: WatchProgress?
    let upNext: Bool
    var id: String { title.id }

    enum CodingKeys: String, CodingKey { case title, episode, progress, upNext }

    init(from decoder: Decoder) throws {
        // Formato anidado { title, episode, progress, up_next }
        if let c = try? decoder.container(keyedBy: CodingKeys.self),
           let nested = try? c.decode(TitleCard.self, forKey: .title) {
            title = nested
            episode = try? c.decodeIfPresent(Episode.self, forKey: .episode)
            progress = try? c.decodeIfPresent(WatchProgress.self, forKey: .progress)
            upNext = (try? c.decode(Bool.self, forKey: .upNext)) ?? false
            return
        }
        // Formato plano (card) — compatibilidad
        title = try TitleCard(from: decoder)
        episode = nil
        progress = nil
        upNext = false
    }
}

struct HomeData: Decodable {
    let hero: HeroItem?
    let continueItems: [ContinueItem]
    let sections: [HomeSection]

    enum CodingKeys: String, CodingKey {
        case hero, sections
        case continueItems = "continue"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hero = try? c.decodeIfPresent(HeroItem.self, forKey: .hero)
        continueItems = (try? c.decode([ContinueItem].self, forKey: .continueItems)) ?? []
        sections = (try? c.decode([HomeSection].self, forKey: .sections)) ?? []
    }
}

struct FilterOption: Decodable, Hashable, Identifiable {
    let id: String
    let label: String
}

struct GenreCount: Decodable, Hashable, Identifiable {
    let slug: String
    let name: String
    let count: Int
    var id: String { slug }
}

struct FilterData: Decodable {
    let genres: [GenreCount]
    let years: [Int]
    let languages: [LanguageItem]
    let sorts: [FilterOption]

    enum CodingKeys: String, CodingKey { case genres, years, languages, sorts }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        genres = (try? c.decode([GenreCount].self, forKey: .genres)) ?? []
        years = c.lossyStrings(.years).compactMap { Int($0) }
        languages = (try? c.decode([LanguageItem].self, forKey: .languages)) ?? []
        sorts = (try? c.decode([FilterOption].self, forKey: .sorts)) ?? []
    }
}

struct HistoryItem: Decodable, Identifiable {
    let title: TitleCard
    let episode: Episode?
    let watchedAt: String?
    var id: String { title.id + (episode?.id ?? "") + (watchedAt ?? "") }
}

struct AppNotification: Decodable, Identifiable {
    let id: String
    let title: String
    let body: String
    let link: String?
    let titleId: String?
    var read: Bool
    let createdAt: String?
}

struct Comment: Decodable, Identifiable {
    let id: String
    let author: String
    let avatarUrl: URL?
    let body: String
    let createdAt: String?
    let mine: Bool
    let canDelete: Bool
}

// MARK: - Cuenta y perfiles

struct User: Codable, Hashable {
    let id: String
    let name: String
    let email: String
    let emailVerified: Bool
    let avatar: String
    let avatarUrl: URL?
    let language: String
    let subtitleLanguage: String
    let staff: Bool
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, email, emailVerified, avatar, avatarUrl, language, subtitleLanguage, staff, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        email = (try? c.decode(String.self, forKey: .email)) ?? ""
        emailVerified = (try? c.decode(Bool.self, forKey: .emailVerified)) ?? true
        avatar = (try? c.decode(String.self, forKey: .avatar)) ?? "1"
        avatarUrl = try? c.decodeIfPresent(URL.self, forKey: .avatarUrl)
        language = (try? c.decode(String.self, forKey: .language)) ?? "es"
        subtitleLanguage = (try? c.decode(String.self, forKey: .subtitleLanguage)) ?? "off"
        staff = (try? c.decode(Bool.self, forKey: .staff)) ?? false
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(email, forKey: .email)
        try c.encode(emailVerified, forKey: .emailVerified)
        try c.encode(avatar, forKey: .avatar)
        try c.encodeIfPresent(avatarUrl, forKey: .avatarUrl)
        try c.encode(language, forKey: .language)
        try c.encode(subtitleLanguage, forKey: .subtitleLanguage)
        try c.encode(staff, forKey: .staff)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}

struct Profile: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let avatar: String
    let locked: Bool
    let main: Bool
    let kids: Bool
    let maxRating: String
    let subtitles: String
    let autoplayNext: Bool
    let autoplayPreviews: Bool
    let avatarUrl: URL?
    let available: Bool
}

struct Avatar: Decodable, Hashable, Identifiable {
    let id: String
    let label: String
    let url: URL?
}

struct ItemsList<T: Decodable>: Decodable {
    let items: [T]
}

struct ProfilesData: Decodable {
    let items: [Profile]
    let current: String?
    let limit: Int
    let canCreate: Bool
    let limitMessage: String?
    let setupPending: Bool
}

struct ProfileResponse: Decodable {
    let profile: Profile
}

struct Plan: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let description: String
    let price: Double
    let currency: String
    let durationDays: Int
    let tier: String
    let ads: Bool
    let maxStreams: Int
    let maxProfiles: Int
    let maxQuality: Int
    let dailyPlayLimit: Int
    let history: Bool
    let promoLabel: String
    let benefits: [String]
    var current: Bool?

    var isFree: Bool { price <= 0 }
    var priceText: String { Format.money(price, currency: currency) }

    var periodText: String {
        switch durationDays {
        case 0: return ""
        case 1: return "por día"
        case 7: return "por semana"
        case 28...31: return "al mes"
        case 85...95: return "cada 3 meses"
        case 175...185: return "cada 6 meses"
        case 360...370: return "al año"
        default: return "cada \(durationDays) días"
        }
    }

    var qualityText: String {
        switch maxQuality {
        case 2160...: return "4K"
        case 1080...: return "Full HD 1080p"
        case 720...: return "HD 720p"
        default: return "SD \(maxQuality)p"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, price, currency, durationDays, tier, ads
        case maxStreams, maxProfiles, maxQuality, dailyPlayLimit, history, promoLabel, benefits, current
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        price = (try? c.decode(Double.self, forKey: .price)) ?? 0
        currency = (try? c.decode(String.self, forKey: .currency)) ?? "USD"
        durationDays = c.flexInt(.durationDays) ?? 0
        tier = (try? c.decode(String.self, forKey: .tier)) ?? "free"
        ads = (try? c.decode(Bool.self, forKey: .ads)) ?? false
        maxStreams = c.flexInt(.maxStreams) ?? 1
        maxProfiles = c.flexInt(.maxProfiles) ?? 5
        maxQuality = c.flexInt(.maxQuality) ?? 720
        dailyPlayLimit = c.flexInt(.dailyPlayLimit) ?? 0
        history = (try? c.decode(Bool.self, forKey: .history)) ?? true
        promoLabel = (try? c.decode(String.self, forKey: .promoLabel)) ?? ""
        benefits = c.lossyStrings(.benefits)
        current = try? c.decodeIfPresent(Bool.self, forKey: .current)
    }
}

struct TrialState: Codable, Hashable {
    let enabled: Bool
    let eligible: Bool
    let days: Int
    let remaining: String?
    let ended: Bool
}

struct Subscription: Codable, Hashable {
    let status: String
    let statusLabel: String
    let premium: Bool
    let plan: Plan
    let expiresAt: String?
    let canCancel: Bool
    let trial: TrialState

    var expiresDate: Date? { ISODate.parse(expiresAt) }

    /// Días que faltan para el vencimiento (redondeado hacia arriba); nil si no vence.
    var daysRemaining: Int? {
        guard let date = expiresDate else { return nil }
        let left = date.timeIntervalSinceNow
        return left <= 0 ? 0 : Int((left / 86_400).rounded(.up))
    }
}

struct MeData: Codable {
    let user: User
    let profile: Profile?
    let subscription: Subscription
    let unreadNotifications: Int
}

struct AuthSession: Decodable {
    let token: String?
    let user: User?
    let profileSetup: Bool?
    let profileRequired: Bool?
    let profile: Profile?
    let profiles: [Profile]?
    let verificationRequired: Bool?
    let trialDays: Int?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case token, user, profileSetup, profileRequired, profile, profiles
        case verificationRequired, trialDays, message, accessToken
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .token) {
            token = s
        } else if let nested = try? c.decode([String: JSONValue].self, forKey: .token),
                  let access = nested["access_token"]?.string ?? nested["accessToken"]?.string {
            token = access
        } else {
            token = try? c.decodeIfPresent(String.self, forKey: .accessToken)
        }
        user = try? c.decodeIfPresent(User.self, forKey: .user)
        profileSetup = try? c.decodeIfPresent(Bool.self, forKey: .profileSetup)
        profileRequired = try? c.decodeIfPresent(Bool.self, forKey: .profileRequired)
        profile = try? c.decodeIfPresent(Profile.self, forKey: .profile)
        profiles = try? c.decodeIfPresent([Profile].self, forKey: .profiles)
        verificationRequired = try? c.decodeIfPresent(Bool.self, forKey: .verificationRequired)
        trialDays = c.flexInt(.trialDays)
        message = try? c.decodeIfPresent(String.self, forKey: .message)
    }
}

struct MessageResponse: Decodable {
    let message: String?
}

struct UserResponse: Decodable {
    let user: User
}

struct Device: Decodable, Identifiable {
    let id: String
    let current: Bool
    let app: Bool
    let platform: String
    let name: String
    let ip: String
    let createdAt: String?
    let lastSeenAt: String?
}

struct FavoriteResponse: Decodable {
    let id: String
    let favorite: Bool
}

// MARK: - Planes y pagos

struct QualityOption: Decodable, Hashable {
    let value: Int
    let label: String
}

struct PlansData: Decodable {
    struct Trial: Decodable {
        let enabled: Bool
        let eligible: Bool
        let days: Int
        let plan: Plan?
    }
    let items: [Plan]
    let currentPlanId: String?
    let trial: Trial
}

struct SubscriptionMessage: Decodable {
    let message: String?
    let subscription: Subscription?
}

struct Payment: Decodable, Identifiable, Hashable {
    let id: String
    let reference: String
    let planId: String?
    let planName: String
    let amount: Double
    let currency: String
    let status: String
    let statusLabel: String
    let gateway: String
    let method: String?
    let proofRef: String?
    let proofAt: String?
    let createdAt: String?
    let verifiedAt: String?

    var amountText: String { Format.money(amount, currency: currency) }
}

struct PaymentMethod: Decodable, Hashable, Identifiable {
    let id: String
    let label: String
    let field: String
    let account: String
    let holder: String

    enum CodingKeys: String, CodingKey { case id, label, field, account, holder }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = (try? c.decode(String.self, forKey: .label)) ?? id
        field = (try? c.decode(String.self, forKey: .field)) ?? ""
        account = (try? c.decode(String.self, forKey: .account)) ?? ""
        holder = (try? c.decode(String.self, forKey: .holder)) ?? ""
    }
}

struct PaymentDetail: Decodable {
    struct Checkout: Decodable {
        let type: String
        let text: String?
        let url: String?
    }
    struct WalletInfo: Decodable {
        let available: Bool
        let balance: Double?
        let enough: Bool
    }
    let payment: Payment
    let checkout: Checkout?
    let wallet: WalletInfo
    let methods: [PaymentMethod]
    let qr: URL?
    let notes: String
}

struct PaymentUpdate: Decodable {
    let message: String?
    let payment: Payment?
    let subscription: Subscription?
}

// MARK: - Reproducción

struct PlaybackSource: Decodable, Hashable {
    let url: URL
    let type: String
    let hls: Bool
    let quality: Int
    let label: String

    var isMatroska: Bool {
        let t = type.lowercased()
        if t.contains("matroska") || t.contains("mkv") { return true }
        let path = url.path.lowercased()
        if path.hasSuffix(".mkv") { return true }
        return url.absoluteString.lowercased().contains(".mkv")
    }

    enum CodingKeys: String, CodingKey { case url, src, type, hls, quality, label }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decode(String.self, forKey: .url))
            ?? (try? c.decode(String.self, forKey: .src))
            ?? ""
        guard let parsed = URL(string: raw), parsed.scheme != nil else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "URL de fuente inválida")
        }
        url = parsed
        type = (try? c.decode(String.self, forKey: .type)) ?? "video/mp4"
        hls = (try? c.decode(Bool.self, forKey: .hls))
            ?? type.contains("mpegurl")
            || parsed.pathExtension.lowercased() == "m3u8"
        quality = c.flexInt(.quality) ?? 720
        label = (try? c.decode(String.self, forKey: .label)) ?? "\(quality)p"
    }
}

struct PlaybackSubtitle: Decodable, Hashable, Identifiable {
    let url: URL
    let lang: String
    let label: String
    var id: String { lang + label }
}

struct PlaybackEpisode: Decodable, Hashable {
    let id: String
    let title: String
    let number: Int?
    let season: Int?
    let label: String

    enum CodingKeys: String, CodingKey { case id, title, number, season, label }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        number = c.flexInt(.number)
        season = c.flexInt(.season)
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
    }
}

struct PlaybackNext: Decodable, Hashable {
    let id: String
    let title: String
    let label: String
    let thumbnail: URL?
}

struct PlaybackTitle: Decodable, Hashable {
    let id: String
    let type: String
    let title: String
    let backdrop: URL?
}

struct PlaybackSettings: Decodable, Hashable {
    let autoplayNext: Bool
    let countdown: Int
    let interval: Int
}

struct PlaybackData: Decodable {
    let streamId: String
    let title: PlaybackTitle
    let episode: PlaybackEpisode?
    let next: PlaybackNext?
    let sources: [PlaybackSource]
    let subtitles: [PlaybackSubtitle]
    let resume: Int
    let preferredSubtitle: String?
    let settings: PlaybackSettings
    let expiresIn: Int
}

struct HeartbeatResponse: Decodable {
    let credited: Int
    let completed: Bool
}

// MARK: - Configuración del servidor

struct ServerConfig: Decodable {
    struct Site: Decodable {
        let name: String
        let shortName: String
        let tagline: String
        let supportEmail: String
        let webUrl: String
    }
    struct Links: Decodable {
        let terms: String
        let privacy: String
        let help: String
        let contact: String
        let resetPassword: String
    }
    struct Features: Decodable {
        let registrationOpen: Bool
        let comments: Bool
        let wallet: Bool
        let trial: Bool
        let trialDays: Int
        let maintenance: Bool
        let maintenanceMessage: String?
    }
    struct Player: Decodable {
        let progressInterval: Int
        let nextCountdown: Int
        let completedRatio: Double
    }
    struct Reason: Decodable, Hashable, Identifiable {
        let id: String
        let label: String
    }

    let site: Site
    let links: Links
    let features: Features
    let player: Player
    let minPassword: Int
    let ageRatings: [String]
    let languages: [LanguageItem]
    let reportReasons: [Reason]
    let currency: String

    enum CodingKeys: String, CodingKey {
        case site, links, features, player, minPassword, ageRatings, languages, reportReasons, currency
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        site = try c.decode(Site.self, forKey: .site)
        links = try c.decode(Links.self, forKey: .links)
        features = try c.decode(Features.self, forKey: .features)
        player = try c.decode(Player.self, forKey: .player)
        minPassword = (try? c.decode(Int.self, forKey: .minPassword)) ?? 10
        ageRatings = c.lossyStrings(.ageRatings)
        languages = (try? c.decode([LanguageItem].self, forKey: .languages)) ?? []
        reportReasons = (try? c.decode([Reason].self, forKey: .reportReasons)) ?? []
        currency = (try? c.decode(String.self, forKey: .currency)) ?? "COP"
    }
}

// MARK: - Formatos

enum Format {
    static func duration(minutes: Int?) -> String? {
        guard let m = minutes, m > 0 else { return nil }
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func money(_ amount: Double, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.locale = Locale(identifier: "es_CO")
        f.maximumFractionDigits = amount == amount.rounded() ? 0 : 2
        return f.string(from: NSNumber(value: amount)) ?? "\(currency) \(amount)"
    }
}
