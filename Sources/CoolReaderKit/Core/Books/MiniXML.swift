import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A tiny DOM built with `XMLParser`, enough for EPUB packages, ComicInfo.xml and NFO files.
/// Element names are stored without their namespace prefix (`dc:title` → `title`).
nonisolated final class XMLElementNode: @unchecked Sendable {
    let name: String
    let attributes: [String: String]
    fileprivate(set) var children: [XMLElementNode] = []
    fileprivate(set) var text: String = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func child(_ name: String) -> XMLElementNode? {
        children.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func children(_ name: String) -> [XMLElementNode] {
        children.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Depth-first search.
    func descendants(_ name: String) -> [XMLElementNode] {
        var found: [XMLElementNode] = []
        for child in children {
            if child.name.caseInsensitiveCompare(name) == .orderedSame { found.append(child) }
            found.append(contentsOf: child.descendants(name))
        }
        return found
    }

    func attribute(_ name: String) -> String? {
        if let value = attributes[name] { return value }
        // Match `opf:role` when asked for `role`, and any case.
        return attributes.first { key, _ in
            let local = key.split(separator: ":").last.map(String.init) ?? key
            return local.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

nonisolated enum MiniXML {
    static func parse(_ data: Data) -> XMLElementNode? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        parser.parse()
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLElementNode?
        private var stack: [XMLElementNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let node = XMLElementNode(name: local, attributes: attributeDict)
            if let parent = stack.last { parent.children.append(node) } else if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
        }
    }
}

nonisolated enum ArchivePath {
    /// Resolves `relative` (percent-encoded, possibly with `..`) against the folder of `base`.
    static func resolve(_ relative: String, against base: String) -> String {
        let withoutFragment = relative.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? relative
        let decoded = withoutFragment.removingPercentEncoding ?? withoutFragment
        if decoded.hasPrefix("/") { return normalize(String(decoded.dropFirst())) }
        let folder = (base as NSString).deletingLastPathComponent
        return normalize(folder.isEmpty ? decoded : folder + "/" + decoded)
    }

    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return parts.joined(separator: "/")
    }
}
