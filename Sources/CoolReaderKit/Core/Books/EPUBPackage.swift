import Foundation

/// The OPF package of an EPUB: metadata, manifest, spine, cover.
nonisolated struct EPUBPackage: Sendable {
    nonisolated struct Item: Sendable, Hashable {
        let id: String
        let path: String
        let mediaType: String
        let properties: String
    }

    let opfPath: String
    let manifest: [String: Item]
    let spine: [Item]
    let metadata: EmbeddedMetadata
    let isFixedLayout: Bool
    let coverImagePath: String?
    private let archive: any ArchiveReader

    init(archive: any ArchiveReader) throws {
        self.archive = archive
        guard let containerData = try? archive.data(atPath: "META-INF/container.xml"),
              let container = MiniXML.parse(containerData),
              let opfPath = container.descendants("rootfile").first?.attribute("full-path"),
              let opfData = try? archive.data(atPath: opfPath),
              let opf = MiniXML.parse(opfData) else { throw BookOpenError.unreadable }
        self.opfPath = opfPath

        var manifest: [String: Item] = [:]
        for node in opf.child("manifest")?.children("item") ?? [] {
            guard let id = node.attribute("id"), let href = node.attribute("href") else { continue }
            manifest[id] = Item(id: id, path: ArchivePath.resolve(href, against: opfPath),
                                mediaType: node.attribute("media-type") ?? "", properties: node.attribute("properties") ?? "")
        }
        self.manifest = manifest

        let spineNode = opf.child("spine")
        self.spine = (spineNode?.children("itemref") ?? []).compactMap { ref in
            ref.attribute("idref").flatMap { manifest[$0] }
        }

        let metadataNode = opf.child("metadata")
        let metas = metadataNode?.children("meta") ?? []
        var metadata = EmbeddedMetadata()
        metadata.title = metadataNode?.child("title")?.trimmedText
        metadata.writers = (metadataNode?.children("creator") ?? []).map(\.trimmedText).filter { !$0.isEmpty }
        metadata.language = metadataNode?.child("language")?.trimmedText
        if let description = metadataNode?.child("description")?.trimmedText, !description.isEmpty {
            metadata.summary = EPUBText.plainText(fromHTML: description)
        }
        metadata.genres = (metadataNode?.children("subject") ?? []).map(\.trimmedText).filter { !$0.isEmpty }
        if let date = metadataNode?.child("date")?.trimmedText, date.count >= 4 { metadata.year = Int(date.prefix(4)) }
        if let series = metas.first(where: { $0.attribute("property") == "belongs-to-collection" })?.trimmedText
            ?? metas.first(where: { $0.attribute("name") == "calibre:series" })?.attribute("content") {
            metadata.series = series
        }
        if let index = metas.first(where: { $0.attribute("property") == "group-position" })?.trimmedText
            ?? metas.first(where: { $0.attribute("name") == "calibre:series_index" })?.attribute("content") {
            metadata.number = Double(index)
        }
        let direction = spineNode?.attribute("page-progression-direction")?.lowercased()
        metadata.isRightToLeft = direction == "rtl" ? true : (direction == "ltr" ? false : nil)
        self.metadata = metadata

        self.isFixedLayout = metas.contains { $0.attribute("property") == "rendition:layout" && $0.trimmedText == "pre-paginated" }
            || metas.contains { $0.attribute("name") == "fixed-layout" && $0.attribute("content") == "true" }

        let coverByProperty = manifest.values.first { $0.properties.split(separator: " ").contains("cover-image") }
        // EPUB 2 names the cover's manifest id; some books put its path there instead.
        let coverMeta = metas.first { $0.attribute("name") == "cover" }?.attribute("content")
        let coverByMeta = coverMeta.flatMap { content in
            manifest[content] ?? manifest.values.first { $0.mediaType.hasPrefix("image/") && $0.path.hasSuffix(content) }
        }
        // Else an image called so: "cover.jpg", "couverture.png", or the id "cover".
        let coverByName = manifest.values.sorted { $0.path < $1.path }.first { item in
            let name = ((item.path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
            return item.mediaType.hasPrefix("image/")
                && (["cover", "couverture"].contains(name) || ["cover", "cover-image", "coverimage"].contains(item.id.lowercased()))
        }
        self.coverImagePath = (coverByProperty ?? coverByMeta ?? coverByName)?.path
    }

    /// When nearly every spine document is a single full-page image (manga, comics), the paths of those
    /// images in reading order; nil for a text book.
    func imagePagePaths() -> [String]? {
        var paths: [String] = []
        var textDocuments = 0
        for item in spine {
            if item.mediaType.hasPrefix("image/") {
                paths.append(item.path)
                continue
            }
            guard let data = try? archive.data(atPath: item.path) else { continue }
            let html = String(decoding: data, as: UTF8.self)
            let images = EPUBText.imageReferences(in: html)
            let textLength = EPUBText.visibleTextLength(html)
            if images.count == 1, textLength < 60 {
                paths.append(ArchivePath.resolve(images[0], against: item.path))
            } else if images.isEmpty, textLength < 5 {
                continue
            } else {
                textDocuments += 1
            }
        }
        guard !paths.isEmpty else { return nil }
        let ratio = Double(paths.count) / Double(max(1, paths.count + textDocuments))
        return ratio >= 0.85 || (isFixedLayout && ratio >= 0.5) ? paths : nil
    }
}

nonisolated enum EPUBText {
    static func imageReferences(in html: String) -> [String] {
        let patterns = [
            #"<img\b[^>]*?\bsrc\s*=\s*["']([^"']+)["']"#,
            #"<image\b[^>]*?\b(?:xlink:)?href\s*=\s*["']([^"']+)["']"#,
        ]
        var references: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            for match in regex.matches(in: html, range: range) {
                if let r = Range(match.range(at: 1), in: html) { references.append(String(html[r])) }
            }
        }
        return references
    }

    static func visibleTextLength(_ html: String) -> Int {
        plainText(fromHTML: html).filter { !$0.isWhitespace }.count
    }

    static func plainText(fromHTML html: String) -> String {
        var text = html
        for block in ["head", "style", "script"] {
            text = text.replacingOccurrences(of: "<\(block)\\b[\\s\\S]*?</\(block)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</p>", with: "\n", options: [.caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&rsquo;": "’", "&hellip;": "…"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        return text
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
