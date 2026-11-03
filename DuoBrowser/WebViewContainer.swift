import SwiftUI
import WebKit

/// Hosts a tab's WKWebView and reports user-driven scroll direction.
/// WKWebView owns its scroll view's delegate, so scrolling is observed via KVO instead.
struct WebViewContainer: UIViewRepresentable {
    let tab: BrowserTab
    /// Edges covered by bars. The web view lays out under them, scrolls its content clear of them,
    /// and tells the page so fixed elements avoid them too.
    var obscuredInsets: EdgeInsets = EdgeInsets()
    /// "system", "light" or "dark". The page follows this rather than the app, which goes dark
    /// over dark strips; otherwise sites with a dark theme would flip to it.
    var appearance = "system"
    var onScroll: (_ scrollingDown: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let webView = tab.webView
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
        context.coordinator.tab = tab
        context.coordinator.attach(to: webView.scrollView)
        // The address bubble floats over the page on its own; no blur band under it.
        webView.scrollView.bottomEdgeEffect.isHidden = true
        // Pull down to reload. Each tab's web view gets its own control the first time it's shown.
        if webView.scrollView.refreshControl == nil {
            let refresh = UIRefreshControl()
            refresh.addAction(UIAction { [weak webView, weak refresh] _ in
                webView?.reload()
                // WebKit gives no reliable "reload finished" hook here, so let the spinner show
                // briefly as acknowledgement and get out of the way.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { refresh?.endRefreshing() }
            }, for: .valueChanged)
            webView.scrollView.refreshControl = refresh
        }
        tab.loadIfNeeded()
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        context.coordinator.onScroll = onScroll
        let insets = UIEdgeInsets(top: obscuredInsets.top, left: obscuredInsets.leading,
                                  bottom: obscuredInsets.bottom, right: obscuredInsets.trailing)
        let webView = tab.webView
        webView.overrideUserInterfaceStyle = switch appearance {
        case "light": .light
        case "dark": .dark
        // The screen's traits are the system setting, untouched by the app's override.
        default: container.window?.windowScene?.screen.traitCollection.userInterfaceStyle ?? .light
        }
        if webView.obscuredContentInsets != insets {
            webView.obscuredContentInsets = insets
            webView.scrollView.verticalScrollIndicatorInsets = insets
        }
    }

    static func dismantleUIView(_ container: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var onScroll: ((Bool) -> Void)?
        weak var tab: BrowserTab?
        private var observation: NSKeyValueObservation?
        private var lastOffset: CGFloat = 0

        func attach(to scrollView: UIScrollView) {
            lastOffset = scrollView.contentOffset.y
            observation = scrollView.observe(\.contentOffset) { [weak self] scrollView, _ in
                MainActor.assumeIsolated { self?.scrolled(scrollView) }
            }
        }

        func detach() { observation = nil }

        private func scrolled(_ scrollView: UIScrollView) {
            let offset = scrollView.contentOffset.y
            defer { lastOffset = offset }
            // Whatever moved the page, the edge beside the side strip may have changed color.
            tab?.scheduleEdgeSample()
            // Only react to the user's own drags, and ignore rubber-banding at the top.
            guard scrollView.isTracking || scrollView.isDecelerating else { return }
            let top = -scrollView.adjustedContentInset.top
            if offset <= top { onScroll?(false); return }
            let delta = offset - lastOffset
            guard abs(delta) > 4 else { return }
            onScroll?(delta > 0)
        }
    }
}
