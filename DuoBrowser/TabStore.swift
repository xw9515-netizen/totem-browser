import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Observation
import UIKit
import WebKit

/// One open tab. Owns its WKWebView so history survives switching tabs.
/// Saved between launches by `TabStore.save()`, as addresses only; pages reload when shown.
@Observable
final class BrowserTab: Identifiable {
    let id = UUID()
    var url: URL?
    var title = ""
    var canGoBack = false
    var canGoForward = false
    var hasOnlySecureContent = false
    var lastActive = Date.now
    /// Pinned tabs sit in the tiles at the top of the tab column and come first in the capsule.
    var isPinned = false
    /// Colors of the page's trailing edge as currently scrolled, top to bottom in equal bands, for
    /// tinting the side strip next to it. Empty until the first sample.
    var edgeColors: [UIColor] = []
    /// Ask sites for their desktop layout. Applies to the next navigation (a reload or a new page),
    /// not to the page already showing.
    @ObservationIgnored var prefersDesktop = false
    /// Site icon as a ready-sized image, for places that need an `Image` rather than a URL (tab bar items).
    var favicon: UIImage?

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var faviconHost: String?
    @ObservationIgnored private var edgeSampleTask: Task<Void, Never>?
    @ObservationIgnored private var needsEdgeSample = false
    @ObservationIgnored private let navigationPolicy = NavigationPolicy()

    init(url: URL?) {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        // Insets come from obscuredContentInsets instead, so an empty navigation bar doesn't leave a gap.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        self.url = url
        navigationPolicy.tab = self
        webView.navigationDelegate = navigationPolicy

        observations = [
            webView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            webView.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            webView.observe(\.hasOnlySecureContent) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            webView.observe(\.isLoading) { [weak self] webView, _ in
                MainActor.assumeIsolated { if !webView.isLoading { self?.scheduleEdgeSample() } }
            },
        ]
        loadFaviconIfNeeded()
    }

    /// Loads the tab's URL the first time it is shown, so background tabs don't all load at launch.
    func loadIfNeeded() {
        guard webView.url == nil, !webView.isLoading, let url else { return }
        webView.load(URLRequest(url: url))
    }

    private func sync() {
        url = webView.url ?? url
        title = webView.title ?? ""
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        hasOnlySecureContent = webView.hasOnlySecureContent
        loadFaviconIfNeeded()
    }

    /// Samples the page edge at most every 400 ms while requests keep coming (a scroll), and once
    /// more after the last one. Slow on purpose: the strip drifts after the page rather than
    /// chasing it, and snapshots stay rare enough not to slow scrolling.
    func scheduleEdgeSample() {
        needsEdgeSample = true
        guard edgeSampleTask == nil else { return }
        edgeSampleTask = Task { [weak self] in
            while let self, self.needsEdgeSample {
                self.needsEdgeSample = false
                try? await Task.sleep(for: .milliseconds(400))
                await self.sampleEdgeColor()
            }
            self?.edgeSampleTask = nil
        }
    }

    /// Which page edge the side strip sits beside. The strip follows the camera, so it can be on
    /// either side.
    @ObservationIgnored var stripIsLeading = false

    private func sampleEdgeColor() async {
        let bounds = webView.bounds
        guard bounds.width > 24, bounds.height > 0 else { return }
        // A few points in from the edge, clear of the scroll indicator, which would otherwise
        // show up in the strip as a bar moving with the scroll.
        let inset: CGFloat = 10, width: CGFloat = 6
        let x = stripIsLeading ? bounds.minX + inset : bounds.maxX - inset - width
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: x, y: bounds.minY, width: width, height: bounds.height)
        configuration.snapshotWidth = NSNumber(value: Double(width))
        configuration.afterScreenUpdates = true
        guard let snapshot = try? await webView.takeSnapshot(configuration: configuration) else { return }
        // Eight bands is plenty for a gradient that blends between them.
        let colors = snapshot.bandColors(count: 8)
        if !colors.isEmpty { edgeColors = colors }
    }

    /// Fetches the site's favicon once per host and redraws it at tab bar icon size, keeping its colors.
    private func loadFaviconIfNeeded() {
        guard let faviconURL, faviconURL.host() != faviconHost else { return }
        faviconHost = faviconURL.host()
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: faviconURL),
                  let image = UIImage(data: data) else { return }
            let size = CGSize(width: 24, height: 24)
            let sized = UIGraphicsImageRenderer(size: size).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            self?.favicon = sized.withRenderingMode(.alwaysOriginal)
        }
    }

    var displayHost: String {
        guard let host = url?.host() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var faviconURL: URL? {
        guard let url, let scheme = url.scheme, let host = url.host() else { return nil }
        return URL(string: "\(scheme)://\(host)/favicon.ico")
    }

    func load(_ url: URL) {
        self.url = url
        webView.load(URLRequest(url: url))
    }
}

/// Picks mobile or desktop layout per navigation, so a reload or new page follows the fold.
private final class NavigationPolicy: NSObject, WKNavigationDelegate {
    weak var tab: BrowserTab?

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        preferences.preferredContentMode = tab?.prefersDesktop == true ? .desktop : .mobile
        return (.allow, preferences)
    }
}

@Observable
final class TabStore {
    /// Most pinned tabs: three rows of four tiles.
    static let maxPinned = 12

    /// True while the phone is unfolded. New pages and reloads then ask for desktop sites; pages
    /// already showing keep their layout until reloaded.
    var prefersDesktop = false {
        didSet { tabs.forEach { $0.prefersDesktop = prefersDesktop } }
    }

    var canPinMore: Bool { pinnedTabs.count < Self.maxPinned }

    private(set) var tabs: [BrowserTab] = []
    private(set) var currentID: BrowserTab.ID?

    var current: BrowserTab? { tabs.first { $0.id == currentID } }

    // `tabs` keeps pinned tabs first, so the capsule and lists show them first too.
    var pinnedTabs: [BrowserTab] { tabs.filter(\.isPinned) }
    var unpinnedTabs: [BrowserTab] { tabs.filter { !$0.isPinned } }

    /// Where pinned tabs end and unpinned ones begin.
    private var pinBoundary: Int { tabs.firstIndex { !$0.isPinned } ?? tabs.count }

    @discardableResult
    func newTab(url: URL? = nil) -> BrowserTab {
        let tab = BrowserTab(url: url)
        tab.prefersDesktop = prefersDesktop
        tab.stripIsLeading = tabs.first?.stripIsLeading ?? false
        // New tabs go first among unpinned tabs, right after the pinned ones.
        tabs.insert(tab, at: pinBoundary)
        select(tab)
        return tab
    }

    /// Moves `tab` to where `target` is, shifting the tabs between them by one. Used by drag to reorder.
    func move(_ tab: BrowserTab, to target: BrowserTab) {
        guard tab.id != target.id,
              let from = tabs.firstIndex(where: { $0.id == tab.id }),
              let to = tabs.firstIndex(where: { $0.id == target.id }) else { return }
        tabs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    /// List-style reorder within one section (pinned or unpinned), for `onMove`. Offsets are
    /// positions in `section`; the other section's tabs stay where they are.
    func move(in section: [BrowserTab], fromOffsets source: IndexSet, toOffset destination: Int) {
        var reordered = section
        reordered.move(fromOffsets: source, toOffset: destination)
        let ids = Set(section.map(\.id))
        var next = reordered.makeIterator()
        tabs = tabs.map { ids.contains($0.id) ? next.next()! : $0 }
    }

    /// Pins a tab to the end of the pinned tabs, or unpins it to the top of the rest.
    func setPinned(_ tab: BrowserTab, _ pinned: Bool) {
        guard tab.isPinned != pinned, !pinned || canPinMore, let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        tab.isPinned = pinned
        tabs.insert(tab, at: pinBoundary)
    }

    /// Closes a tab. Closing the current tab selects the one now in its place, or the one before it.
    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if tab.id == currentID {
            if tabs.isEmpty { currentID = nil } else { select(tabs[min(index, tabs.count - 1)]) }
        }
    }

    func tab(withID id: BrowserTab.ID) -> BrowserTab? {
        tabs.first { $0.id == id }
    }

    func select(id: BrowserTab.ID) {
        if let tab = tab(withID: id) { select(tab) }
    }

    func select(_ tab: BrowserTab) {
        tab.lastActive = .now
        currentID = tab.id
    }

    /// Turns address-bar input into a URL: a bare domain gets https, anything else becomes a search.
    static func url(forInput input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("://"), let url = URL(string: text) { return url }
        if !text.contains(" "), text.contains("."), let url = URL(string: "https://\(text)") { return url }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        return components?.url
    }

    /// Test-build seed so the tabs capsule and its overflow have something to show.
    static func withSampleTabs() -> TabStore {
        let store = TabStore()
        let sites = [
            "https://news.ycombinator.com",
            "https://developer.apple.com",
            "https://github.com",
            "https://en.wikipedia.org/wiki/Foldable_smartphone",
            "https://www.apple.com",
            "https://webkit.org",
            "https://www.swift.org",
            "https://www.w3.org",
        ]
        for site in sites {
            store.newTab(url: URL(string: site))
        }
        // Two pinned tabs so the pinned tiles have something to show.
        for tab in store.tabs.filter({ ["github.com", "en.wikipedia.org"].contains($0.displayHost) }) {
            store.setPinned(tab, true)
        }
        return store
    }
}

extension UIImage {
    private static let averagingContext = CIContext(options: [.workingColorSpace: NSNull()])

    /// Average colors of `count` equal horizontal bands, top to bottom. Empty if it can't be read.
    func bandColors(count: Int) -> [UIColor] {
        guard let input = CIImage(image: self), count > 0 else { return [] }
        let extent = input.extent
        let bandHeight = extent.height / CGFloat(count)
        // Core Image's origin is bottom-left, so the top band has the highest y.
        return (0..<count).compactMap { index in
            let band = CGRect(x: extent.minX, y: extent.maxY - CGFloat(index + 1) * bandHeight,
                              width: extent.width, height: bandHeight)
            let filter = CIFilter.areaAverage()
            filter.inputImage = input
            filter.extent = band
            guard let output = filter.outputImage else { return nil }
            var pixel = [UInt8](repeating: 0, count: 4)
            Self.averagingContext.render(output, toBitmap: &pixel, rowBytes: 4,
                                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                         format: .RGBA8, colorSpace: nil)
            return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                           blue: CGFloat(pixel[2]) / 255, alpha: 1)
        }
    }
}

extension UIColor {
    /// WCAG relative luminance, from 0 (black) to 1 (white).
    var relativeLuminance: CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

// MARK: - Remembering tabs

extension TabStore {
    /// The Settings switch for remembering tabs between launches.
    static let remembersTabsKey = "remembersTabs"
    private static let savedTabsKey = "savedTabs"

    private struct SavedTab: Codable {
        var url: URL?
        var title: String
        var isPinned: Bool
    }

    private struct SavedTabs: Codable {
        var tabs: [SavedTab]
        var currentIndex: Int?
    }

    static var remembersTabs: Bool {
        UserDefaults.standard.object(forKey: remembersTabsKey) as? Bool ?? true
    }

    /// Writes the open tabs (address, title, pinned) and which one is current. Cheap enough to
    /// call whenever the app leaves the foreground.
    func save() {
        guard Self.remembersTabs else { return }
        let saved = SavedTabs(
            tabs: tabs.map { SavedTab(url: $0.url, title: $0.title, isPinned: $0.isPinned) },
            currentIndex: tabs.firstIndex { $0.id == currentID }
        )
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.savedTabsKey)
        }
    }

    static func forgetSavedTabs() {
        UserDefaults.standard.removeObject(forKey: savedTabsKey)
    }

    /// The tabs from last time, or nil when there are none or remembering is off. Only the
    /// current tab loads right away; the others load when first shown.
    static func restored() -> TabStore? {
        guard remembersTabs,
              let data = UserDefaults.standard.data(forKey: savedTabsKey),
              let saved = try? JSONDecoder().decode(SavedTabs.self, from: data),
              !saved.tabs.isEmpty else { return nil }
        let store = TabStore()
        for entry in saved.tabs {
            let tab = BrowserTab(url: entry.url)
            tab.title = entry.title
            tab.isPinned = entry.isPinned
            store.tabs.append(tab)
        }
        let index = min(saved.currentIndex ?? 0, store.tabs.count - 1)
        store.select(store.tabs[index])
        return store
    }
}
