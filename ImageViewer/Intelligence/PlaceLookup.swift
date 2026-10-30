import CoreLocation
import Foundation
import MapKit

/// Where a photo was taken, from its GPS: the place's name, and what's near it.
nonisolated struct PlaceInfo: Equatable, Sendable {
    /// "Getxo, Bizkaia, Spain"
    var name: String
    /// The address there.
    var address: String?
    /// "Getxo", "Spain" (by default, the first and last parts of the name).
    var town: String?
    var country: String?
    /// Sights near it (see `PlaceLookup.inView`), nearest first.
    var nearby: [Nearby] = []

    struct Nearby: Equatable, Sendable {
        var name: String
        /// "landmark", "museum"…; nil for a Wikipedia article.
        var kind: String?
        var meters: Int
        /// Which way it is from the camera, degrees from north.
        var bearing: Double
        /// Wikipedia's first sentences about it.
        var summary: String?
    }

    init(name: String, address: String? = nil, town: String? = nil, country: String? = nil, nearby: [Nearby] = []) {
        let parts = name.components(separatedBy: ", ")
        self.name = name
        self.address = address
        self.town = town ?? (parts.count > 1 ? parts.first : nil)
        self.country = country ?? parts.last
        self.nearby = nearby
    }

    /// What Describe tells the model about it.
    var promptContext: String {
        var text = "This photo was taken in \(name) (from its GPS; it may show something farther away)."
        if !nearby.isEmpty {
            text += "\nPlaces near the camera, in the direction it faced when the photo records that:"
            for n in nearby {
                let about = [n.kind, n.meters < 1000 ? "\(n.meters) m" : String(format: "%.1f km", Double(n.meters) / 1000)].compactMap { $0 }
                text += "\n- \(n.name) (\(about.joined(separator: ", ")))" + (n.summary.map { ": \($0)" } ?? "")
            }
        }
        return text
    }
}

/// Names where photos were taken: Apple Maps for the place and the sights near it, and Wikipedia (when that's
/// on, in Settings) for its first lines about places nearby. Only the coordinates leave the Mac. Answers are
/// kept for the session, by spot (about 10 m).
enum PlaceLookup {
    private static var places: [String: PlaceInfo] = [:]
    private static var sights: [String: [PlaceInfo.Nearby]] = [:]

    /// The place's name and address.
    static func place(at c: CLLocationCoordinate2D) async -> PlaceInfo? {
        let key = spot(c)
        if let hit = places[key] { return hit }
        guard let found = await reverseGeocode(c) else { return nil }
        if places.count > 500 { places.removeAll() }
        places[key] = found
        return found
    }

    /// The place with the sights the camera may have seen (`heading`: which way it faced, degrees from north,
    /// when the photo records it): Apple Maps' landmarks, museums, parks…, and with `wikipedia`, its articles.
    static func surroundings(at c: CLLocationCoordinate2D, heading: Double?, wikipedia: Bool) async -> PlaceInfo? {
        guard var place = await place(at: c) else { return nil }
        let key = spot(c) + "|\(heading.map { Int($0.rounded()) } ?? -1)|\(wikipedia)"
        if let hit = sights[key] {
            place.nearby = hit
            return place
        }
        let reach = heading == nil ? nearReach : farReach
        async let maps = mapsSights(near: c, within: reach)
        async let articles: [PlaceInfo.Nearby] = wikipedia ? wikipediaArticles(near: c, within: reach) : []
        let found = inView(await articles + maps, heading: heading)
        if sights.count > 500 { sights.removeAll() }
        sights[key] = found
        place.nearby = found
        return place
    }

    // MARK: Choosing

    /// Close enough to be in any photo taken there, whichever way.
    nonisolated static let aroundReach = 150
    /// How far a sight may be when the photo doesn't say which way it faced.
    nonisolated static let nearReach = 600
    /// How far, in front of the camera.
    nonisolated static let farReach = 1500

    /// Of `found`, what the camera may have seen: anything close by; farther, only what's within 45° of
    /// `heading` (or, without one, within `nearReach`). One of each name (a Wikipedia article over Apple
    /// Maps' entry, for its summary), nearest first, at most five.
    nonisolated static func inView(_ found: [PlaceInfo.Nearby], heading: Double?) -> [PlaceInfo.Nearby] {
        var seen: Set<String> = []
        let kept = found.filter { n in
            let seeable: Bool
            if n.meters <= aroundReach {
                seeable = true
            } else if let heading {
                // (How far off the camera's direction, 0...180°.)
                let off = abs((n.bearing - heading + 540).truncatingRemainder(dividingBy: 360) - 180)
                seeable = off <= 45 && n.meters <= farReach
            } else {
                seeable = n.meters <= nearReach
            }
            return seeable && seen.insert(n.name.lowercased()).inserted
        }
        return Array(kept.sorted { $0.meters < $1.meters }.prefix(5))
    }

    nonisolated static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180, Δλ = (b.longitude - a.longitude) * .pi / 180
        let y = sin(Δλ) * cos(φ2), x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func spot(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.4f,%.4f", c.latitude, c.longitude)
    }

    // MARK: Apple Maps

    private static func reverseGeocode(_ c: CLLocationCoordinate2D) async -> PlaceInfo? {
        let location = CLLocation(latitude: c.latitude, longitude: c.longitude)
        if #available(macOS 26, *) {
            guard let request = MKReverseGeocodingRequest(location: location),
                  let item = try? await request.mapItems.first else { return nil }
            let forms = item.addressRepresentations
            guard let name = forms?.cityWithContext(.full) ?? forms?.regionName ?? item.name else { return nil }
            return PlaceInfo(name: name, address: item.address?.fullAddress, town: forms?.cityName, country: forms?.regionName)
        }
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        var parts: [String] = []
        for part in [mark.locality ?? mark.subAdministrativeArea, mark.administrativeArea, mark.country, mark.ocean].compactMap({ $0 })
            where parts.last != part { parts.append(part) }
        guard !parts.isEmpty else { return nil }
        let street = [mark.thoroughfare, mark.subThoroughfare].compactMap { $0 }.joined(separator: " ")
        return PlaceInfo(name: parts.joined(separator: ", "), address: ([street] + parts).filter { !$0.isEmpty }.joined(separator: ", "),
                         town: mark.locality, country: mark.country)
    }

    /// The kinds of place worth naming in a photo's description (not its cafés and shops).
    private static let sightKinds: [MKPointOfInterestCategory] = [
        .landmark, .nationalMonument, .castle, .fortress, .museum, .park, .nationalPark, .beach, .marina, .stadium,
        .university, .zoo, .aquarium, .amusementPark, .planetarium, .theater,
    ]

    private static func mapsSights(near c: CLLocationCoordinate2D, within reach: Int) async -> [PlaceInfo.Nearby] {
        let request = MKLocalPointsOfInterestRequest(center: c, radius: CLLocationDistance(reach))
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: sightKinds)
        guard let found = try? await MKLocalSearch(request: request).start() else { return [] }
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        return found.mapItems.compactMap { item in
            guard let name = item.name else { return nil }
            let at: CLLocation
            if #available(macOS 26, *) { at = item.location } else { at = item.placemark.location ?? here }
            let kind = item.pointOfInterestCategory.map { kindName($0.rawValue) }
            return PlaceInfo.Nearby(name: name, kind: kind, meters: Int(at.distance(from: here)), bearing: bearing(from: c, to: at.coordinate))
        }
    }

    /// "MKPOICategoryNationalPark" → "national park".
    nonisolated static func kindName(_ raw: String) -> String {
        let words = raw.replacingOccurrences(of: "MKPOICategory", with: "")
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        return words.lowercased()
    }

    // MARK: Wikipedia

    /// Articles about places near `c`, in the language of this Mac when Wikipedia has some there, else English.
    private static func wikipediaArticles(near c: CLLocationCoordinate2D, within reach: Int) async -> [PlaceInfo.Nearby] {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        if language != "en", language.allSatisfy(\.isLetter), language.count <= 3 {
            let local = await wikipedia(language, near: c, within: reach)
            if !local.isEmpty { return local }
        }
        return await wikipedia("en", near: c, within: reach)
    }

    private static func wikipedia(_ language: String, near c: CLLocationCoordinate2D, within reach: Int) async -> [PlaceInfo.Nearby] {
        var query = URLComponents(string: "https://\(language).wikipedia.org/w/api.php")!
        let point = "\(c.latitude)|\(c.longitude)"
        query.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "generator", value: "geosearch"), .init(name: "ggscoord", value: point),
            .init(name: "ggsradius", value: "\(min(reach, 10_000))"), .init(name: "ggslimit", value: "12"),
            .init(name: "prop", value: "extracts|coordinates"), .init(name: "codistancefrompoint", value: point),
            .init(name: "exintro", value: "1"), .init(name: "explaintext", value: "1"), .init(name: "exsentences", value: "2"),
            .init(name: "exlimit", value: "12"),
        ]
        guard let url = query.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 8)
        // (Wikipedia asks programs to say who they are.)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        request.setValue("AOK-ImageTool/\(version) (https://github.com/emkey1/AOK-ImageTool)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parseWikipedia(data, from: c)
    }

    /// The articles in a Wikipedia geosearch answer (with their extracts and coordinates). Not events ("2008
    /// … bombing") or lists, which aren't things a photo shows.
    nonisolated static func parseWikipedia(_ data: Data, from c: CLLocationCoordinate2D) -> [PlaceInfo.Nearby] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = (json["query"] as? [String: Any])?["pages"] as? [String: Any] else { return [] }
        return pages.values.compactMap { value -> PlaceInfo.Nearby? in
            guard let page = value as? [String: Any], let title = page["title"] as? String,
                  let at = (page["coordinates"] as? [[String: Any]])?.first,
                  let lat = at["lat"] as? Double, let lon = at["lon"] as? Double else { return nil }
            if title.range(of: #"^\d{3,4}\b"#, options: .regularExpression) != nil || title.hasPrefix("List of") { return nil }
            let meters = (at["dist"] as? Double).map { Int($0) }
                ?? Int(CLLocation(latitude: lat, longitude: lon).distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)))
            var summary = (page["extract"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let s = summary, s.count > 320 { summary = String(s.prefix(320)) + "…" }
            return PlaceInfo.Nearby(name: title, kind: nil, meters: meters, bearing: bearing(from: c, to: CLLocationCoordinate2D(latitude: lat, longitude: lon)),
                                    summary: summary?.isEmpty == false ? summary : nil)
        }
    }
}
