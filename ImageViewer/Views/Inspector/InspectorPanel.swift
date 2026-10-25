import MapKit
import SwiftUI

struct InspectorPanel: View {
    @Environment(ViewerModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: Binding(get: { model.inspectorTab }, set: { model.inspectorTab = $0 })) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            Group {
                switch model.inspectorTab {
                case .info: InfoPanel()
                case .adjust: AdjustPanel()
                case .intelligence: IntelligencePanel()
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// Section header + content used across the inspector panels.
struct PanelSection<Content: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let systemImage {
                Label(title, systemImage: systemImage).font(.headline)
            } else {
                Text(title).font(.headline)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Info

struct InfoPanel: View {
    @Environment(ViewerModel.self) private var model
    @State private var showAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let item = model.currentItem {
                    HistogramView(image: model.display?.isPlaceholder == false ? model.display?.image : nil,
                                  key: model.display?.contentKey ?? 0)

                    if !PhotosRoundTrip.isFromPhotos(item.url) {
                        HStack {
                            Text("Rating").foregroundStyle(.secondary)
                            Spacer()
                            RatingControl(rating: item.rating ?? 0) { model.setRating($0, for: [item.url]) }
                        }
                        .font(.callout)
                    }

                    if let description = model.intelligence.descriptions[item.url] {
                        PanelSection(title: description.title, systemImage: "apple.intelligence") {
                            Text(description.caption)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }

                    ForEach(MetadataFormatting.sections(for: model.decoded?.url == item.url ? model.decoded : nil, item: item)) { section in
                        PanelSection(title: section.title) {
                            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
                                ForEach(section.rows) { row in
                                    GridRow {
                                        Text(row.label)
                                            .foregroundStyle(.secondary)
                                            .gridColumnAlignment(.trailing)
                                        Text(row.value)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .font(.callout)
                        }
                    }

                    if let props = model.decoded?.properties, let coordinate = MetadataFormatting.gpsCoordinate(props) {
                        LocationSection(coordinate: coordinate)
                    }

                    if let props = model.decoded?.properties, !props.isEmpty {
                        DisclosureGroup("All Metadata", isExpanded: $showAll) {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(MetadataFormatting.allRows(props)) { row in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(row.label).foregroundStyle(.secondary)
                                        Spacer(minLength: 8)
                                        Text(row.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                                    }
                                    .font(.caption)
                                }
                            }
                            .padding(.top, 6)
                        }
                    }

                    FolderStats()
                } else {
                    ContentUnavailableView("No Image", systemImage: "photo")
                }
            }
            .padding(14)
        }
    }
}

struct LocationSection: View {
    let coordinate: CLLocationCoordinate2D

    var body: some View {
        PanelSection(title: "Location", systemImage: "location") {
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000))) {
                Marker("", coordinate: coordinate)
            }
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .id("\(coordinate.latitude),\(coordinate.longitude)")
            HStack {
                Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button("Open in Maps") {
                    if let url = URL(string: "maps://?ll=\(coordinate.latitude),\(coordinate.longitude)&q=Photo") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
    }
}

struct FolderStats: View {
    @Environment(ViewerModel.self) private var model

    var body: some View {
        let all = model.allItems
        let picks = all.filter { $0.flag == .pick }.count
        let rejects = all.filter { $0.flag == .reject }.count
        let rated = all.filter { ($0.rating ?? 0) > 0 }.count
        let size = all.reduce(Int64(0)) { $0 + $1.fileSize }
        PanelSection(title: "Folder", systemImage: "folder") {
            Text("\(all.count) images · \(MetadataFormatting.fileSize(size))")
                .font(.callout)
            HStack(spacing: 14) {
                Label("\(picks) picks", systemImage: "flag.fill").foregroundStyle(.green)
                Label("\(rejects) rejects", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                Label("\(rated) rated", systemImage: "star.fill").foregroundStyle(.yellow)
            }
            .font(.callout)
            if rejects > 0 {
                Button("Move Rejects to Trash…") { model.trashRejects() }
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Histogram

nonisolated struct Histogram: Sendable {
    var red: [Float]
    var green: [Float]
    var blue: [Float]
    var luma: [Float]

    @concurrent
    static func compute(_ image: CGImage) async -> Histogram? {
        let maxSide = 256.0
        let scale = min(1, maxSide / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var r = [Float](repeating: 0, count: 256), g = r, b = r, l = r
        for i in 0..<(w * h) {
            let o = i * 4
            guard px[o + 3] > 0 else { continue }
            let rv = Int(px[o]), gv = Int(px[o + 1]), bv = Int(px[o + 2])
            r[rv] += 1; g[gv] += 1; b[bv] += 1
            l[min(255, (rv * 54 + gv * 183 + bv * 19) >> 8)] += 1
        }
        let peak = max(1, [r, g, b, l].map { Array($0[2..<254]).max() ?? 1 }.max() ?? 1)
        func norm(_ a: [Float]) -> [Float] { a.map { min(1, $0 / peak) } }
        return Histogram(red: norm(r), green: norm(g), blue: norm(b), luma: norm(l))
    }
}

struct HistogramView: View {
    let image: CGImage?
    let key: Int
    @State private var histogram: Histogram?

    var body: some View {
        Canvas { context, size in
            guard let histogram else { return }
            func path(_ bins: [Float]) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height))
                for (i, v) in bins.enumerated() {
                    p.addLine(to: CGPoint(x: CGFloat(i) / 255 * size.width, y: size.height - CGFloat(v) * size.height))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                return p
            }
            context.blendMode = .screen
            context.fill(path(histogram.red), with: .color(.red.opacity(0.7)))
            context.fill(path(histogram.green), with: .color(.green.opacity(0.7)))
            context.fill(path(histogram.blue), with: .color(.blue.opacity(0.75)))
            context.blendMode = .normal
            context.stroke(path(histogram.luma), with: .color(.white.opacity(0.6)), lineWidth: 1)
        }
        .frame(height: 86)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.88)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: key) {
            guard let image else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            histogram = await Histogram.compute(image)
        }
    }
}
