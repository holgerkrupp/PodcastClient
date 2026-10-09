import SwiftUI
import SwiftData
import ESADesignKit
import os
import WebKit
import CryptoKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Renders shownotes from the source document and promotes podcast links that
/// were already enriched during a feed refresh. The view never starts network
/// enrichment itself.
struct ShownoteContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.esaVisualStyle) private var visualStyle
    @Environment(\.esaThemePalette) private var themePalette
    private let html: String
    @State private var document: ShownoteDocument?
    @State private var enrichmentResults: [URL: ShownoteEnrichmentResult] = [:]

    init(html: String) {
        self.html = html
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let document {
                // The full document uses one WebKit surface. When native cards
                // are inserted, the surrounding fragments use native text.
                if ShownoteRenderingPolicy.needsEnrichedBlocks(
                    in: document,
                    enrichmentResults: enrichmentResults
                ) {
                    ForEach(document.blocks) { block in
                        switch block {
                        case .html(_, let value):
                            nativeHTMLText(value)
                        case .link(_, let candidate):
                            if let result = enrichmentResults[candidate.normalizedURL] {
                                enrichedLink(candidate: candidate, result: result)
                            } else {
                                plainLink(candidate)
                            }
                        }
                    }
                } else if document.linkifiedHTML.isEmpty == false {
                    stableHTML(document.linkifiedHTML)
                }
            } else if html.isEmpty == false {
                Label("Preparing shownotes", systemImage: "text.alignleft")
                    .font(.caption)
                    .esaForeground(.secondary)
                    .accessibilityLabel("Preparing shownotes")
            }
        }
        .onChange(of: html) { _, _ in
            document = nil
            enrichmentResults.removeAll()
        }
        .task(id: html) {
            guard html.isEmpty == false else {
                document = ShownoteDocument(html: "")
                return
            }
            let parsedDocument = await ShownoteParser.shared.parse(html)
            guard Task.isCancelled == false else { return }
            // Resolve cached cards before showing any HTML. Previously the
            // initial un-enriched fragments launched WebKit processes, then
            // the animated card substitution rebuilt most of them.
            var cachedResults: [URL: ShownoteEnrichmentResult] = [:]
            if parsedDocument.candidates.isEmpty == false {
                let results = await ShownoteEnrichmentService.shared.cachedResults(
                    for: parsedDocument.candidates
                )
                for result in results {
                    cachedResults[result.normalizedURL] = result
                }
            }
            guard Task.isCancelled == false else { return }
            enrichmentResults = cachedResults
            document = parsedDocument
        }
        .onAppear {
            os_signpost(.event, log: ShownoteViewPerformance.log, name: "Shownote visible")
        }
    }

    @ViewBuilder
    private func plainLink(_ candidate: ShownoteLinkCandidate) -> some View {
        Link(destination: candidate.originalURL) {
            Text(candidate.displayText.isEmpty
                 ? candidate.originalURL.absoluteString
                 : candidate.displayText)
                .underline()
                .esaForeground(.primary)
                .multilineTextAlignment(.leading)
        }
    }

    @ViewBuilder
    private func enrichedLink(
        candidate: ShownoteLinkCandidate,
        result: ShownoteEnrichmentResult
    ) -> some View {
        switch result.classification {
        case .podcast:
            if let feed = result.podcastFeed {
                SubscribeToPodcastView(newPodcastFeed: feed)
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Podcast recommendation: \(feed.title ?? candidate.displayText)")
            } else {
                plainLink(candidate)
            }
        case .web, .mastodon:
            Link(destination: result.finalURL ?? result.preview?.canonicalURL ?? candidate.originalURL) {
                ShownotePreviewCard(
                    metadata: result.preview,
                    destination: result.finalURL ?? candidate.originalURL,
                    fallbackTitle: candidate.publisherAnchorText ?? candidate.displayText,
                    isMastodon: result.classification == .mastodon
                )
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
        case .unknown, .podcastCandidate, .unsupported:
            plainLink(candidate)
        }
    }

    @ViewBuilder
    private func stableHTML(_ value: String) -> some View {
        StableShownoteHTML(html: value, foreground: htmlForeground, linkColor: htmlLinkColor)
    }

    private func nativeHTMLText(_ value: String) -> some View {
        ShownoteHTMLFragment(html: value, foreground: htmlForeground, linkColor: htmlLinkColor)
    }

    private var htmlForeground: Color {
        if visualStyle == .artwork {
            // WebKit converts SwiftUI colors to CSS before its own trait
            // environment is available. Resolve the system semantic color
            // explicitly so it cannot fall back to black in dark mode.
            return colorScheme == .dark ? .white : .black
        }
        return themePalette.primaryForeground
    }

    private var htmlLinkColor: Color {
        visualStyle == .artwork ? htmlForeground : (themePalette.accent ?? themePalette.controlForeground)
    }
}

/// Renders the supported inline HTML tags natively around promoted cards.
/// Parsing is deliberately local and bounded; Foundation's HTML attributed
/// string importer can invoke WebKit internally on Apple platforms.
private struct ShownoteHTMLFragment: View {
    let html: String
    let foreground: Color
    let linkColor: Color
    @State private var elements: [ShownoteNativeHTMLElement]

    init(html: String, foreground: Color, linkColor: Color) {
        self.html = html
        self.foreground = foreground
        self.linkColor = linkColor
        _elements = State(initialValue: ShownoteNativeHTMLParser.elements(in: html))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(elements) { element in
                switch element.content {
                case .text(let value):
                    Text(value)
                        .foregroundStyle(foreground)
                        .tint(linkColor)
                        .textSelection(.enabled)
                case .image(let url, let alt):
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 320)
                        } else if phase.error != nil {
                            Text(alt.isEmpty ? url.absoluteString : alt)
                                .font(.caption)
                                .esaForeground(.secondary)
                        } else {
                            ProgressView()
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(alt)
                }
            }
        }
        .id(html)
    }
}

struct ShownoteNativeHTMLElement: Identifiable {
    enum Content {
        case text(AttributedString)
        case image(URL, String)
    }

    let id: Int
    let content: Content
}

enum ShownoteNativeHTMLParser {
    private struct Style {
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var code = false
        var headingLevel: Int?
        var link: URL?
    }

    static func elements(in html: String) -> [ShownoteNativeHTMLElement] {
        guard html.isEmpty == false else { return [] }
        let regex = try? NSRegularExpression(pattern: #"(?is)<[^>]*>|[^<]+|<"#)
        let tokens = regex?.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range, in: html).map { String(html[$0]) }
        } ?? [html]
        var output: [ShownoteNativeHTMLElement] = []
        var text = AttributedString()
        var style = Style()
        var stack: [(tag: String, previous: Style)] = []
        var lists: [(tag: String, counter: Int)] = []
        var nextID = 0

        func flushText() {
            guard text.characters.isEmpty == false else { return }
            output.append(ShownoteNativeHTMLElement(id: nextID, content: .text(text)))
            nextID += 1
            text = AttributedString()
        }

        func append(_ rawText: String) {
            guard let decoded = rawText.plainTextFromHTML(), decoded.isEmpty == false else { return }
            var run = AttributedString(decoded)
            if style.bold { run.font = .system(size: style.headingLevel.map { max(14, 25 - CGFloat($0 * 2)) } ?? 17, weight: .bold) }
            else if let level = style.headingLevel { run.font = .system(size: max(14, 25 - CGFloat(level * 2)), weight: .semibold) }
            else if style.code { run.font = .system(.body, design: .monospaced) }
            if style.italic { run.font = (run.font ?? .body).italic() }
            if style.underline { run.underlineStyle = .single }
            if style.strike { run.strikethroughStyle = .single }
            if let link = style.link {
                run.link = link
                run.underlineStyle = .single
            }
            text.append(run)
        }

        for token in tokens {
            guard token.hasPrefix("<"), token.hasSuffix(">") else {
                append(token)
                continue
            }
            let trimmed = token.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("!") || trimmed.hasPrefix("?") { continue }

            let closing = trimmed.hasPrefix("/")
            let tag = String(trimmed.dropFirst(closing ? 1 : 0).prefix { $0.isLetter || $0.isNumber }).lowercased()
            guard tag.isEmpty == false else { append(token); continue }

            if closing {
                if tag == "ul" || tag == "ol",
                   let index = lists.lastIndex(where: { $0.tag == tag }) {
                    lists.removeSubrange(index...)
                }
                if let index = stack.lastIndex(where: { $0.tag == tag }) {
                    style = stack[index].previous
                    stack.removeSubrange(index...)
                }
                if ["p", "div", "li", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6"].contains(tag),
                   text.characters.last != "\n" {
                    text.append(AttributedString("\n"))
                }
                continue
            }

            if tag == "br" {
                text.append(AttributedString("\n"))
                continue
            }
            if tag == "img" {
                let source = attribute("src", in: token)
                let alt = attribute("alt", in: token) ?? ""
                if let source, let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    flushText()
                    output.append(ShownoteNativeHTMLElement(id: nextID, content: .image(url, alt)))
                    nextID += 1
                }
                continue
            }
            if tag == "ul" || tag == "ol" {
                lists.append((tag, 0))
                continue
            }
            if ["p", "div", "li", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6"].contains(tag),
               text.characters.isEmpty == false, text.characters.last != "\n" {
                text.append(AttributedString("\n"))
            }
            if tag == "li" {
                if let index = lists.lastIndex(where: { $0.tag == "ol" }) {
                    lists[index].counter += 1
                    text.append(AttributedString("\(lists[index].counter). "))
                } else {
                    text.append(AttributedString("• "))
                }
            }

            var next = style
            switch tag {
            case "b", "strong": next.bold = true
            case "i", "em": next.italic = true
            case "u": next.underline = true
            case "s", "strike", "del": next.strike = true
            case "code", "pre": next.code = true
            case "h1": next.headingLevel = 1
            case "h2": next.headingLevel = 2
            case "h3": next.headingLevel = 3
            case "h4": next.headingLevel = 4
            case "h5": next.headingLevel = 5
            case "h6": next.headingLevel = 6
            case "a":
                if let href = attribute("href", in: token) { next.link = URL(string: href) }
            default: break
            }
            if next.bold != style.bold || next.italic != style.italic || next.underline != style.underline
                || next.strike != style.strike || next.code != style.code
                || next.headingLevel != style.headingLevel || next.link != style.link {
                stack.append((tag, style))
                style = next
            }
        }
        flushText()
        return output
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "(?is)\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(['\\\"])(.*?)\\1"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 2), in: tag) else { return nil }
        return String(tag[range]).replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// A single, stable WebKit surface for full shownotes. Unlike RichText's
/// representable, this only loads when the HTML or effective styling changes,
/// and it deduplicates height notifications before writing SwiftUI state.
private struct StableShownoteHTML: View {
    let html: String
    let foreground: Color
    let linkColor: Color
    @State private var height: CGFloat = 1

    var body: some View {
        ShownoteHTMLWebView(
            html: html,
            foreground: foreground,
            linkColor: linkColor,
            height: $height
        )
        .frame(height: max(1, height))
    }
}

#if canImport(UIKit)
private struct ShownoteHTMLWebView: UIViewRepresentable {
    let html: String
    let foreground: Color
    let linkColor: Color
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "shownoteHeight")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.update(html: html, foreground: foreground, linkColor: linkColor, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(html: html, foreground: foreground, linkColor: linkColor, in: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "shownoteHeight")
        webView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: ShownoteHTMLWebView
        private var loadedRevision: String?

        init(_ parent: ShownoteHTMLWebView) { self.parent = parent }

        func update(html: String, foreground: Color, linkColor: Color, in webView: WKWebView) {
            let foregroundHex = Self.hex(UIColor(foreground))
            let linkHex = Self.hex(UIColor(linkColor))
            let revision = Self.revision(html: html, foreground: foregroundHex, link: linkHex)
            guard loadedRevision != revision else { return }
            loadedRevision = revision
            let source = """
            <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
            <style>html,body{margin:0;padding:0;background:transparent;color:\(foregroundHex);font: -apple-system-body;line-height:1.35;overflow-wrap:anywhere} img,video{max-width:100%;height:auto} a{color:\(linkHex);text-decoration:underline}</style>
            </head><body>\(html)<script>
            const sendHeight=()=>window.webkit.messageHandlers.shownoteHeight.postMessage(Math.ceil(document.documentElement.scrollHeight));
            new ResizeObserver(sendHeight).observe(document.body);window.addEventListener('load',sendHeight);document.querySelectorAll('img').forEach(i=>i.addEventListener('load',sendHeight));sendHeight();
            </script></body></html>
            """
            webView.loadHTMLString(source, baseURL: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "shownoteHeight", let value = message.body as? NSNumber else { return }
            let measured = CGFloat(value.doubleValue)
            DispatchQueue.main.async { [weak self] in
                guard let self, measured.isFinite, measured > 0,
                      abs(self.parent.height - measured) >= 1 else { return }
                self.parent.height = measured
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                return .allow
            }
            await UIApplication.shared.open(url)
            return .cancel
        }

        private static func hex(_ color: UIColor) -> String {
            let value = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .unspecified))
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            value.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
        }

        private static func revision(html: String, foreground: String, link: String) -> String {
            let content = "\(html)\u{0}\(foreground)\u{0}\(link)"
            return SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
}
#else
private struct ShownoteHTMLWebView: NSViewRepresentable {
    let html: String
    let foreground: Color
    let linkColor: Color
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "shownoteHeight")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.update(html: html, foreground: foreground, linkColor: linkColor, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(html: html, foreground: foreground, linkColor: linkColor, in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "shownoteHeight")
        webView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: ShownoteHTMLWebView
        private var loadedRevision: String?

        init(_ parent: ShownoteHTMLWebView) { self.parent = parent }

        func update(html: String, foreground: Color, linkColor: Color, in webView: WKWebView) {
            let foregroundHex = Self.hex(NSColor(foreground))
            let linkHex = Self.hex(NSColor(linkColor))
            let revision = Self.revision(html: html, foreground: foregroundHex, link: linkHex)
            guard loadedRevision != revision else { return }
            loadedRevision = revision
            let css = "body{margin:0;padding:0;background:transparent;color:\(foregroundHex);font: -apple-system-body;line-height:1.35;overflow-wrap:anywhere}img,video{max-width:100%;height:auto}a{color:\(linkHex);text-decoration:underline}"
            let source = """
            <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><style>\(css)</style></head><body>\(html)<script>const sendHeight=()=>window.webkit.messageHandlers.shownoteHeight.postMessage(Math.ceil(document.documentElement.scrollHeight));new ResizeObserver(sendHeight).observe(document.body);window.addEventListener('load',sendHeight);document.querySelectorAll('img').forEach(i=>i.addEventListener('load',sendHeight));sendHeight();</script></body></html>
            """
            webView.loadHTMLString(source, baseURL: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "shownoteHeight", let value = message.body as? NSNumber else { return }
            let measured = CGFloat(value.doubleValue)
            DispatchQueue.main.async { [weak self] in
                guard let self, measured.isFinite, measured > 0,
                      abs(self.parent.height - measured) >= 1 else { return }
                self.parent.height = measured
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                return .allow
            }
            NSWorkspace.shared.open(url)
            return .cancel
        }

        private static func hex(_ color: NSColor) -> String {
            let value = color.usingColorSpace(.deviceRGB) ?? color
            return String(
                format: "#%02X%02X%02X",
                Int(value.redComponent * 255),
                Int(value.greenComponent * 255),
                Int(value.blueComponent * 255)
            )
        }

        private static func revision(html: String, foreground: String, link: String) -> String {
            let content = "\(html)\u{0}\(foreground)\u{0}\(link)"
            return SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
}
#endif

enum ShownoteRenderingPolicy {
    /// A full HTML document uses one WebKit view unless the cached enrichment
    /// actually needs an inline native card.
    static func needsEnrichedBlocks(
        in document: ShownoteDocument,
        enrichmentResults: [URL: ShownoteEnrichmentResult]
    ) -> Bool {
        return document.blocks.contains { block in
            guard case .link(_, let candidate) = block,
                  let result = enrichmentResults[candidate.normalizedURL] else {
                return false
            }
            switch result.classification {
            case .web, .mastodon:
                return true
            case .podcast:
                return result.podcastFeed != nil
            case .unknown, .podcastCandidate, .unsupported:
                return false
            }
        }
    }
}

private enum ShownoteViewPerformance {
    static let log = OSLog(subsystem: "de.holgerkrupp.PodcastClient", category: "Shownotes")
}

private struct ShownotePreviewCard: View {
    let metadata: ShownotePreviewMetadata?
    let destination: URL
    let fallbackTitle: String
    let isMastodon: Bool

    private var title: String {
        if let metadataTitle = metadata?.title, metadataTitle.isEmpty == false {
            return metadataTitle
        }
        if fallbackTitle.isEmpty == false,
           fallbackTitle != destination.absoluteString {
            return fallbackTitle
        }
        return destination.host ?? destination.absoluteString
    }

    private var siteLabel: String {
        metadata?.handle
            ?? metadata?.siteName
            ?? destination.host
            ?? destination.absoluteString
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PreviewArtwork(url: metadata?.imageURL, isMastodon: isMastodon)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .esaForeground(.primary)
                    .lineLimit(2)

                if let handle = metadata?.handle, handle != title {
                    Text(handle)
                        .font(.subheadline)
                        .esaForeground(.secondary)
                        .lineLimit(1)
                }

                if let description = metadata?.description, description.isEmpty == false {
                    Text(description)
                        .font(.subheadline)
                        .esaForeground(.secondary)
                        .lineLimit(3)
                }

                Text(siteLabel)
                    .font(.caption)
                    .esaForeground(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.semibold))
                .esaForeground(.control)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Open \(title)")
        .accessibilityHint("Opens the original web page")
    }
}

private struct PreviewArtwork: View {
    let url: URL?
    let isMastodon: Bool

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: isMastodon ? 32 : 10, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: isMastodon ? 32 : 10, style: .continuous)
                .fill(Color.secondary.opacity(0.14))
            Image(systemName: isMastodon ? "mastodon.fill" : "globe")
                .esaForeground(.secondary)
        }
    }
}
