import SwiftUI

/// Main browsing screen. Controls are system toolbar items; on the iPhone Duo outer screen the
/// system lays the navigation bar out vertically on the right edge, below the status bar.
/// In landscape on a phone, tabs move from the side bar into a titled column on the left.
struct BrowserView: View {
    @Environment(TabStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var isMinimized = false
    @State private var isEditingAddress = false
    @State private var isShowingAllTabs = false
    /// Hides the tab column and address bar so the page gets the room; the side controls stay so
    /// it can be turned off again.
    @State private var isFullScreen = false
    /// "system", "light" or "dark".
    @AppStorage("appearance") private var appearance = "system"
    /// Keep tabs between launches. Turning it off forgets the saved ones too.
    @AppStorage(TabStore.remembersTabsKey) private var remembersTabs = true
    @State private var safeArea = EdgeInsets()
    /// Height of the floating address bubble and its margin, which the page scrolls clear of.
    @State private var addressBarHeight: CGFloat = 0
    /// Safe area of the whole window, which tells which side the control strip (and camera) is on.
    @State private var windowInsets = EdgeInsets()
    /// Bottom safe area with the keyboard down, so the keyboard's own height can be told apart.
    @State private var restingBottomInset: CGFloat = 0
    /// How far the floating address bubble is raised above its resting place.
    @State private var bubbleLift: CGFloat = 0
    @State private var windowWidth: CGFloat = 0
    /// The tab column's width as the user last dragged it.
    @AppStorage("tabColumnWidth") private var tabColumnWidth: Double = 220
    @State private var dragStartWidth: Double?
    /// The width while a resize drag is under way.
    @State private var liveColumnWidth: Double?
    /// Half-folded (hinge partly open): the tab column takes half the screen.
    @State private var isHalfFolded = false

    private static let minColumnWidth: Double = 180
    /// With the strip on the trailing side the camera sits at its foot, its cutout ending about
    /// 30 points above the window's bottom edge. The column's address bubble lines up with that
    /// rather than with New Tab higher up, so it sits low instead of floating.
    private static let cameraBottomInset: CGFloat = 30
    /// The pin and options glyphs fill more of their box than the chevrons, so at the bar's default
    /// size they look heavier; this brings them in line.
    private static let sideBarSymbolSize: CGFloat = 18

    /// A symbol drawn at `sideBarSymbolSize` into a plain template image. Bar buttons redraw SF
    /// Symbols at their own size whatever font they're given, but keep a bitmap's size, and a
    /// template still takes the bar's tint in light and dark.
    private func sideBarIcon(_ name: String) -> Image {
        let config = UIImage.SymbolConfiguration(pointSize: Self.sideBarSymbolSize, weight: .regular)
        guard let symbol = UIImage(systemName: name, withConfiguration: config) else {
            return Image(systemName: name)
        }
        let bitmap = UIGraphicsImageRenderer(size: symbol.size).image { _ in
            symbol.draw(at: .zero)
        }
        return Image(uiImage: bitmap.withRenderingMode(.alwaysTemplate))
    }

    /// How the side bar fits the height it has (less with the keyboard up, or in landscape full
    /// screen). New Tab must always stay on screen, so when items run out of room the system
    /// would fold it into its own overflow; instead the pin and then Options move into "…".
    private struct SideBarFit {
        var showsPinMenu = true
        var showsOptions = true
    }

    /// Bottom of the area the side bar can use, in window points.
    @State private var barBottom: CGFloat = 0
    /// Gap from New Tab's bottom edge to the window's, for lining the column's address bubble up
    /// with it. Toolbar buttons are UIKit items that SwiftUI can't measure, so they're found in
    /// the window instead.
    @State private var newTabBottomInset: CGFloat?
    /// The empty stretch of the strip between the bar's top and bottom buttons, in window points,
    /// where the tabs capsule is drawn.
    @State private var barGap: CGRect?

    private var sideBarFit: SideBarFit {
        // Measured on the outer screen: the status bar, back, pin, Options and New Tab with their
        // gaps take about 430 points, Options and New Tab alone about 370; landscape has no time
        // and battery above them, which frees about 89.
        let extra: CGFloat = verticalSizeClass == .compact ? -89 : 0
        if barBottom >= 430 + extra { return SideBarFit() }
        if barBottom >= 370 + extra { return SideBarFit(showsPinMenu: false) }
        return SideBarFit(showsPinMenu: false, showsOptions: false)
    }

    /// Height of one tab in the capsule. The system spaces its bar buttons 52 points apart; the
    /// capsule is drawn by hand so its tabs can sit at 40: the 34-point highlight with 3 points
    /// either side, close enough to fit an extra tab or two, still clear enough to hit.
    static let tabPitch: CGFloat = 40
    /// Space between the capsule and the bar buttons above and below it, as the bar leaves
    /// between its own groups.
    private static let capsuleMargin: CGFloat = 12
    private static let capsulePadding: CGFloat = 3

    /// Rows the capsule can hold in the gap: tabs plus "…".
    private var capsuleRows: Int {
        guard let barGap, !showsTabColumn else { return 0 }
        let room = barGap.height - 2 * Self.capsuleMargin - 2 * Self.capsulePadding
        // At least "…", which always fits: with only back and New Tab left there's plenty of gap.
        return max(1, Int(room / Self.tabPitch))
    }

    private var showsTabsCapsule: Bool { barGap != nil && !showsTabColumn }

    private var maxCapsuleTabs: Int {
        let rows = capsuleRows
        let tabCount = store.unpinnedTabs.count
        let needsMenu = tabCount > rows || !sideBarFit.showsPinMenu || !sideBarFit.showsOptions
        return max(0, needsMenu ? rows - 1 : rows)
    }

    /// The current page's sampled edge colors, top to bottom; empty until the first sample.
    private var stripColors: [Color] {
        (store.current?.edgeColors ?? []).map(Color.init(uiColor:))
    }

    /// The side strip's tint: a top-to-bottom gradient of the page edge beside it, or the system
    /// background until there's a sample.
    private var stripFill: AnyShapeStyle {
        stripColors.isEmpty
            ? AnyShapeStyle(Color(.systemBackground))
            : AnyShapeStyle(LinearGradient(colors: stripColors, startPoint: .top, endPoint: .bottom))
    }

    /// The strip behind the side bar is mostly dark: the status bar and the side bar's glass switch
    /// to their dark look so they stay readable, and the current tab is marked in white.
    private var stripIsDark: Bool {
        guard !showsTabColumn else { return false }
        let colors = store.current?.edgeColors ?? []
        // Before the first sample, go by the chosen appearance; the environment's own scheme may
        // be this override and would keep it dark.
        guard !colors.isEmpty else { return appearance == "dark" }
        let darkBands = colors.filter { $0.relativeLuminance < 0.2 }.count
        return darkBands * 2 >= colors.count
    }

    /// The appearance picked in Options; nil follows the system.
    private var chosenScheme: ColorScheme? {
        appearance == "light" ? .light : appearance == "dark" ? .dark : nil
    }

    /// Fill behind the current tab's favicon. On a dark strip the side bar's glass is dark too, so
    /// the highlight is white. Otherwise a very dark gray where much of the strip behind the tabs
    /// capsule is near white, and a neutral ash gray on colored strips.
    private var activeTabFill: Color {
        if stripIsDark { return .white }
        let colors = store.current?.edgeColors ?? []
        let isLight: Bool
        if colors.isEmpty {
            isLight = true
        } else {
            // The capsule sits in roughly the middle third of the side bar.
            let middle = colors[colors.count / 3 ..< colors.count * 2 / 3]
            let lightBands = middle.filter { $0.relativeLuminance > 0.75 }.count
            isLight = lightBands * 3 >= middle.count
        }
        return isLight ? Color(red: 0x3C / 255, green: 0x3C / 255, blue: 0x3C / 255)
                       : Color(red: 0xBD / 255, green: 0xBD / 255, blue: 0xB7 / 255)
    }

    /// Narrowest window side, in points, that counts as unfolded. The folded screen is 466 points
    /// across and the open one 669.
    private static let unfoldedMinWidth: CGFloat = 560

    /// Landscape on a phone: wide enough for titles, so tabs get a column of their own.
    /// Unfolded (any orientation) there's room for it too, so it shows there as well.
    /// Full screen drops back to the folded portrait layout: tabs in the strip's capsule.
    private var showsTabColumn: Bool {
        (verticalSizeClass == .compact || store.prefersDesktop) && !isFullScreen
    }

    /// The strip (and camera) on the leading side, as in landscape with the camera on the left.
    /// The tab column always sits on the strip's side so the two read as one panel.
    private var stripIsLeading: Bool { windowInsets.leading > windowInsets.trailing + 8 }

    /// Column width: half the screen when half-folded, otherwise the dragged width, kept between
    /// a minimum and most of the window.
    private var columnWidth: CGFloat {
        if isHalfFolded { return max(Self.minColumnWidth, windowWidth / 2) }
        let maxWidth = max(Self.minColumnWidth, Double(windowWidth) * 0.6)
        return min(max(liveColumnWidth ?? tabColumnWidth, Self.minColumnWidth), maxWidth)
    }

    /// Bars the page should keep clear of. When the toolbar is a vertical side bar (a wide trailing
    /// inset), the top inset is only the empty navigation bar, so it is dropped.
    private var obscuredInsets: EdgeInsets {
        // Beside the tab column the bars are vertical too, even though they don't touch the page.
        let isSideBar = safeArea.trailing > 44 || showsTabColumn
        return EdgeInsets(top: isSideBar ? 0 : safeArea.top, leading: 0,
                          bottom: safeArea.bottom + (showsTabColumn ? 0 : addressBarHeight), trailing: 0)
    }

    /// Unpinned tabs in the capsule, in order; pinned ones live in the pin menu above it. The
    /// current tab, when unpinned, is always one of them, taking the last slot when it would
    /// otherwise be behind "…".
    private var capsuleTabs: [BrowserTab] {
        let tabs = store.unpinnedTabs
        guard tabs.count > maxCapsuleTabs else { return tabs }
        guard maxCapsuleTabs > 0 else { return [] }
        var shown = Array(tabs.prefix(maxCapsuleTabs))
        if let current = store.current, !current.isPinned, !shown.contains(where: { $0.id == current.id }) {
            shown[maxCapsuleTabs - 1] = current
        }
        return shown
    }

    private var menuTabs: [BrowserTab] {
        let shown = Set(capsuleTabs.map(\.id))
        return store.unpinnedTabs.filter { !shown.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                if showsTabColumn {
                    // The column sits beside the control strip, whichever side that is, so tabs and
                    // controls read as one panel. A drag handle between page and column resizes it.
                    if stripIsLeading { tabColumn; resizeHandle }
                    page
                    if !stripIsLeading { resizeHandle; tabColumn }
                } else {
                    page
                }
            }
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: {
                windowInsets = $0
                if $0.bottom < 100 { restingBottomInset = $0.bottom }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { barBottom = $0 }
            // One timing for everything that follows the current tab or layout: the page crossfade,
            // the highlight in the capsule, the column moving sides.
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: store.currentID)
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: stripIsLeading)
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: showsTabColumn)
            .onChange(of: remembersTabs) {
                if remembersTabs { store.save() } else { TabStore.forgetSavedTabs() }
            }
            .onChange(of: stripIsLeading, initial: true) {
                store.tabs.forEach { $0.stripIsLeading = stripIsLeading }
            }
            .background(HingeObserver { isHalfFolded = $0 })
            .background(BarButtonLocator(trigger: [barBottom, windowWidth, showsTabColumn ? 1 : 0,
                                                   sideBarFit.showsPinMenu ? 1 : 0,
                                                   sideBarFit.showsOptions ? 1 : 0,
                                                   isMinimized ? 1 : 0,
                                                   showsTabsCapsule ? 1 : 0]) { buttons, window in
                // New Tab is the lowest button; measured with the keyboard down only, since it
                // moves with it and the column's bubble sits on the keyboard instead.
                if window.safeAreaInsets.bottom < 100, let newTab = buttons.last {
                    newTabBottomInset = max(0, window.bounds.height - newTab.maxY)
                }
                barGap = Self.widestGap(between: buttons)
            })
            .background {
                if showsTabColumn {
                    Color(.systemGroupedBackground).ignoresSafeArea()
                } else {
                    // Behind the side bar: the colors of the page edge beside it, band by band,
                    // updated as it scrolls.
                    // A long, gentle blend, so it drifts after the page rather than flickering.
                    Rectangle().fill(stripFill).ignoresSafeArea()
                        .animation(reduceMotion ? nil : .easeInOut(duration: 1.2), value: stripColors)
                }
            }
            // Unfolded, the shorter side of the window is far wider than the folded screen's.
            .onGeometryChange(for: Bool.self) { proxy in
                let size = proxy.size
                return min(size.width, size.height) > Self.unfoldedMinWidth
            } action: { store.prefersDesktop = $0 }
            .overlay(alignment: .bottom) {
                if !showsTabColumn {
                    // The overlay already rides up with the keyboard; this holds the bubble back
                    // by however much it hasn't caught up yet, so it can travel only part of the
                    // way: see `followKeyboard`.
                    addressBar
                        .offset(y: keyboardLift - bubbleLift)
                }
            }
            .onChange(of: keyboardLift) { followKeyboard(to: keyboardLift) }
            .toolbar { sideBar }
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar, .bottomBar)
        }
        // Over a dark strip the app goes dark so the status bar text turns white and the side bar's
        // glass darkens; toolbar items take no color scheme of their own. The page keeps the
        // chosen appearance regardless (see WebViewContainer).
        // Over everything, bars included, in window coordinates.
        .overlay {
            ZStack { tabsCapsule }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
        }
        .preferredColorScheme(stripIsDark ? .dark : chosenScheme)
        .sheet(isPresented: $isShowingAllTabs) {
            AllTabsView(onNewTab: openNewTab)
        }
    }

    @ViewBuilder
    private var page: some View {
        if let tab = store.current {
            WebViewContainer(tab: tab, obscuredInsets: obscuredInsets, appearance: appearance) { scrollingDown in
                setMinimized(scrollingDown)
            }
            .id(tab.id)
            // Switching tabs crossfades instead of cutting.
            .transition(.opacity)
            // Under the top and bottom bars; beside, not under, a side bar.
            .ignoresSafeArea(edges: .vertical)
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { safeArea = $0 }
        } else {
            ContentUnavailableView("No Tab", systemImage: "square.on.square")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var tabColumn: some View {
        TabColumn(onNewTab: openNewTab, isEditingAddress: $isEditingAddress,
                  bottomInset: stripIsLeading ? newTabBottomInset : Self.cameraBottomInset)
            .frame(width: columnWidth)
    }

    /// A thin grip between page and column. Dragging toward the page widens the column.
    /// The grip between page and column that resizes the column when dragged. It swells while
    /// held, and the column follows the finger on a soft spring rather than rigidly.
    private var resizeHandle: some View {
        let isDragging = liveColumnWidth != nil
        return Capsule()
            .fill(.secondary.opacity(isDragging ? 0.8 : 0.45))
            .frame(width: isDragging ? 6 : 4, height: isDragging ? 56 : 36)
            // Centered in the gap between the page and the column's contents, which have 8
            // points of their own padding, rather than in this strip alone.
            .offset(x: stripIsLeading ? -4 : 4)
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            // A wider touch target than the strip it takes up.
            .contentShape(.rect.inset(by: -8))
            .gesture(
                // Global coordinates: the handle moves with the column, and measuring the drag in
                // its own moving frame fed that motion back into the width, which made it jitter.
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? Double(columnWidth)
                        dragStartWidth = start
                        let delta = Double(value.translation.width)
                        withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.3, dampingFraction: 0.75)) {
                            liveColumnWidth = max(Self.minColumnWidth, stripIsLeading ? start + delta : start - delta)
                        }
                    }
                    .onEnded { _ in
                        // Saved once at the end rather than on every frame of the drag; the grip
                        // settles back with a little bounce.
                        withAnimation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.3)) {
                            if let liveColumnWidth { tabColumnWidth = liveColumnWidth }
                            liveColumnWidth = nil
                        }
                        dragStartWidth = nil
                    }
            )
            .sensoryFeedback(.selection, trigger: isDragging)
            .opacity(isHalfFolded ? 0 : 1)
            .allowsHitTesting(!isHalfFolded)
            .accessibilityElement()
            .accessibilityLabel("Resize tab list")
            .accessibilityAdjustableAction { direction in
                tabColumnWidth = max(Self.minColumnWidth, tabColumnWidth + (direction == .increment ? 20 : -20))
            }
    }

    private func openNewTab() {
        withAnimation(reduceMotion ? nil : .addressMorph) {
            store.newTab()
            isEditingAddress = true
        }
    }

    // MARK: Side bar

    /// The "…" at the foot of the capsule: tabs that don't fit, and the pin menu and Options when
    /// those don't either. Nil when there's nothing to put in it.
    private var capsuleMenu: AnyView? {
        let fit = sideBarFit
        guard !menuTabs.isEmpty || !fit.showsPinMenu || !fit.showsOptions else { return nil }
        return AnyView(Menu {
            if !fit.showsPinMenu, !store.pinnedTabs.isEmpty {
                Section("Pinned") {
                    ForEach(store.pinnedTabs) { pinnedTab in
                        Button { store.select(pinnedTab) } label: { TabLabel(tab: pinnedTab) }
                    }
                }
            }
            Section {
                ForEach(menuTabs) { menuTab in
                    Button { store.select(menuTab) } label: { TabLabel(tab: menuTab) }
                }
            }
            Divider()
            Button("All Tabs", systemImage: "square.on.square") { isShowingAllTabs = true }
            if !fit.showsOptions {
                Divider()
                optionsMenuContent
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        })
    }

    /// The side bar's tabs, drawn by hand in the gap between the bar's buttons so they can sit
    /// closer than bar items do. Same glass and width as the buttons around it.
    @ViewBuilder
    private var tabsCapsule: some View {
        if showsTabsCapsule, let barGap {
            let tabs = capsuleTabs
            let menu = capsuleMenu
            let rows = tabs.count + (menu == nil ? 0 : 1)
            let height = CGFloat(rows) * Self.tabPitch + 2 * Self.capsulePadding
            VStack(spacing: 0) {
                ForEach(tabs) { capsuleTab in
                    capsuleButton(for: capsuleTab)
                }
                if let menu {
                    menu
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: Self.tabPitch)
                        .contentShape(.rect)
                }
            }
            .padding(.vertical, Self.capsulePadding)
            .frame(width: 48, height: height)
            .glassEffect(.regular.interactive(), in: .capsule)
            // Top of the gap, the way the bar stacks its own groups from the top down.
            .position(x: barGap.midX, y: barGap.minY + Self.capsuleMargin + height / 2)
            .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.25), value: rows)
            .transition(.opacity)
        }
    }

    private func capsuleButton(for capsuleTab: BrowserTab) -> some View {
        let isCurrent = capsuleTab.id == store.currentID
        return Button {
            store.select(capsuleTab)
        } label: {
            FaviconView(tab: capsuleTab, isCurrent: isCurrent)
                .background {
                    // The current tab's circle pops in with a bounce as it shrinks away from the
                    // old one, like the "on" state of Mail's filter button.
                    Circle()
                        .fill(activeTabFill)
                        .scaleEffect(isCurrent ? 1 : 0.1)
                        .opacity(isCurrent ? 1 : 0)
                        .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.5), value: isCurrent)
                }
                .frame(width: 48, height: Self.tabPitch)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityLabel(capsuleTab.title.isEmpty ? capsuleTab.displayHost : capsuleTab.title)
        .tabContextMenu(capsuleTab)
        .draggable(capsuleTab.id.uuidString) {
            FaviconView(tab: capsuleTab)
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first.flatMap(UUID.init(uuidString:)),
                  let dragged = store.tab(withID: id) else { return false }
            withAnimation(reduceMotion ? nil : .snappy) { store.move(dragged, to: capsuleTab) }
            return true
        }
    }

    private var pinnedTabsMenu: some View {
        Menu {
            let pinned = store.pinnedTabs
            if pinned.isEmpty {
                Text("Touch and hold a tab to pin it")
            }
            ForEach(pinned) { pinnedTab in
                Button { store.select(pinnedTab) } label: { TabLabel(tab: pinnedTab) }
            }
        } label: {
            Label {
                Text("Pinned Tabs")
            } icon: {
                sideBarIcon(store.current?.isPinned == true ? "pin.fill" : "pin")
            }
        }
    }

    @ViewBuilder
    private var optionsMenuContent: some View {
        Toggle("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right",
               isOn: $isFullScreen.animation(reduceMotion ? nil : .snappy))
        Picker("Appearance", systemImage: "circle.lefthalf.filled", selection: $appearance) {
            Label("System", systemImage: "iphone").tag("system")
            Label("Light", systemImage: "sun.max").tag("light")
            Label("Dark", systemImage: "moon").tag("dark")
        }
        .pickerStyle(.menu)
        Menu("Settings", systemImage: "gearshape") {
            Toggle("Remember Open Tabs", systemImage: "clock.arrow.circlepath", isOn: $remembersTabs)
        }
    }

    @ToolbarContentBuilder
    private var sideBar: some ToolbarContent {
        let tab = store.current

        // Back first; forward joins the same capsule only when there is forward history.
        ToolbarItemGroup(placement: .topBarLeading) {
            Button("Back", systemImage: "chevron.backward") { tab?.webView.goBack() }
                .disabled(tab?.canGoBack != true)
            if tab?.canGoForward == true {
                Button("Forward", systemImage: "chevron.forward") { tab?.webView.goForward() }
            }
        }
        .axisBehavior(.verticalPreferred)

        // The tab column replaces the capsule in landscape. The capsule itself is drawn over the
        // strip, below the pin (see `tabsCapsule`). It never joins the bar: an extra bar item is
        // what pushes New Tab into the system's overflow.
        if !showsTabColumn {
            if sideBarFit.showsPinMenu {
                ToolbarSpacer(.fixed, placement: .topBarLeading)
                // Pinned tabs, in a button of their own above the tabs. A filled pin says the
                // current tab is one of them.
                ToolbarItem(placement: .topBarLeading) { pinnedTabsMenu }
                    .axisBehavior(.verticalPreferred)
            }
        }

        // Bottom bar placement keeps full screen and New tab at the bottom of the vertical side bar.
        if sideBarFit.showsOptions || showsTabColumn {
            ToolbarItemGroup(placement: .bottomBar) {
                Menu {
                    optionsMenuContent
                } label: {
                    Label {
                        Text("Options")
                    } icon: {
                        sideBarIcon("slider.horizontal.3")
                    }
                }
            }
            .axisBehavior(.verticalPreferred)

            ToolbarSpacer(.fixed, placement: .bottomBar)
        }

        ToolbarItem(placement: .bottomBar) {
            Button("New Tab", systemImage: "plus", action: openNewTab)
                .buttonStyle(.glassProminent)
                .controlSize(isMinimized ? .regular : .large)
                // Where the bar put it, so the column's address bubble can line up with it.
        }
        .axisBehavior(.verticalPreferred)
    }

    // MARK: Address bar

    @ToolbarContentBuilder
    /// The floating address bubble over the page. It's our own view rather than a toolbar item
    /// so it can morph as Safari's does: tapped, it stretches to the page's full width and rides up
    /// with the keyboard; done, it shrinks back to the domain.
    private var addressBar: some View {
        let isSmall = isMinimized && !isEditingAddress
        return AddressField(tab: store.current, isEditing: $isEditingAddress,
                            isMinimized: isSmall, onTapMinimized: { setMinimized(false) })
            .padding(.horizontal, isSmall ? 12 : 20)
            .padding(.vertical, isSmall ? 4 : isEditingAddress ? 12 : 7)
            .frame(maxWidth: isEditingAddress ? .infinity : nil)
            // The whole capsule responds, not just the domain text inside it.
            .contentShape(.capsule)
            .onTapGesture {
                if isSmall {
                    setMinimized(false)
                } else if !isEditingAddress {
                    withAnimation(reduceMotion ? nil : .addressMorph) { isEditingAddress = true }
                }
            }
            .glassEffect(.regular.interactive(), in: .capsule)
            .padding(.horizontal, isEditingAddress ? 12 : 24)
            .padding(.bottom, isEditingAddress ? 8 : 4)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { addressBarHeight = $0 }
    }

    /// How far the keyboard reaches above the bubble's resting place; 0 with it down.
    private var keyboardLift: CGFloat {
        windowInsets.bottom > 100 ? windowInsets.bottom - restingBottomInset : 0
    }

    /// Moves the bubble onto the keyboard or back down. It starts halfway there, hidden by the
    /// crossfade between the domain and the text field, and springs the remaining half, so it
    /// travels half as far as the keyboard does.
    private func followKeyboard(to lift: CGFloat) {
        guard !reduceMotion else { bubbleLift = lift; return }
        var jump = Transaction()
        jump.disablesAnimations = true
        withTransaction(jump) { bubbleLift = (bubbleLift + lift) / 2 }
        // The next turn of the run loop, or SwiftUI merges the jump into the animation.
        DispatchQueue.main.async {
            withAnimation(.addressMorph) { bubbleLift = lift }
        }
    }

    /// The tallest empty stretch between consecutive bar buttons, top to bottom: between the top
    /// group (back, pin) and the bottom one (Options, New Tab).
    private static func widestGap(between buttons: [CGRect]) -> CGRect? {
        zip(buttons, buttons.dropFirst())
            .map { above, below in
                CGRect(x: above.minX, y: above.maxY, width: above.width, height: below.minY - above.maxY)
            }
            .max { $0.height < $1.height }
    }

    private func setMinimized(_ minimized: Bool) {
        guard minimized != isMinimized else { return }
        withAnimation(reduceMotion ? nil : .snappy) { isMinimized = minimized }
    }
}

// MARK: - Pieces

/// Horizontal and vertical scale for a favicon's selection hop.
private struct Squash {
    var x: CGFloat = 1
    var y: CGFloat = 1
}

struct FaviconView: View {
    let tab: BrowserTab
    /// The current tab hops when it's picked; the circle behind it is drawn by the tab capsule.
    var isCurrent = false
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 20
    /// The same for every tab, current or not, so selecting one doesn't shift the others.
    @ScaledMetric(relativeTo: .body) private var padding: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AsyncImage(url: tab.faviconURL) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
        // Selected: the icon hops, squashing and stretching like it's been poked.
        .keyframeAnimator(initialValue: Squash(), trigger: isCurrent) { content, squash in
            content.scaleEffect(x: squash.x, y: squash.y)
        } keyframes: { _ in
            KeyframeTrack(\Squash.x) {
                SpringKeyframe(isCurrent && !reduceMotion ? 1.25 : 1, duration: 0.12)
                SpringKeyframe(isCurrent && !reduceMotion ? 0.9 : 1, duration: 0.14)
                SpringKeyframe(1, duration: 0.3, spring: .bouncy)
            }
            KeyframeTrack(\Squash.y) {
                SpringKeyframe(isCurrent && !reduceMotion ? 0.8 : 1, duration: 0.12)
                SpringKeyframe(isCurrent && !reduceMotion ? 1.15 : 1, duration: 0.14)
                SpringKeyframe(1, duration: 0.3, spring: .bouncy)
            }
        }
        .padding(padding)
    }
}

/// Favicon and title, for menus and lists.
struct TabLabel: View {
    let tab: BrowserTab

    var body: some View {
        Label {
            Text(tab.title.isEmpty ? tab.displayHost : tab.title)
        } icon: {
            if let favicon = tab.favicon {
                Image(uiImage: favicon)
            } else {
                Image(systemName: "globe")
            }
        }
    }
}

#Preview {
    BrowserView().environment(TabStore.withSampleTabs())
}

/// Reports whether the hinge is partly open (half-folded) through UIKit's hinge interaction.
private struct HingeObserver: UIViewRepresentable {
    var onChange: (Bool) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.addInteraction(UIHingeInteraction { _, update in
            onChange(update.hinge?.status == .partiallyOpen)
        })
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}



/// Finds the side bar's buttons in the window and reports their frames, top to bottom, whenever
/// `trigger` changes (the bar's size or contents).
private struct BarButtonLocator: UIViewRepresentable {
    let trigger: [CGFloat]
    let onFind: ([CGRect], UIWindow) -> Void

    func makeUIView(context: Context) -> UIView { UIView() }

    func updateUIView(_ view: UIView, context: Context) {
        // The bar lays its items out some time after this view, so look a few times.
        for delay in [0.15, 0.5, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let window = view.window else { return }
                let frames = Self.buttonFrames(in: window)
                if !frames.isEmpty { onFind(frames, window) }
            }
        }
    }

    /// The bar's buttons carry no labels in UIKit, but each sits on a glass view 48 points
    /// across. The address bubble is glass too but wide, and the drawn tabs capsule is in a
    /// hosting view of its own, not a bar.
    private static func buttonFrames(in window: UIWindow) -> [CGRect] {
        var frames: [CGRect] = []
        func visit(_ view: UIView, inBar: Bool) {
            let inBar = inBar || view is UINavigationBar || view is UIToolbar
                || String(describing: type(of: view)).contains("Bar")
            if inBar, String(describing: type(of: view)).contains("GlassInteractionView"),
               !view.isHidden, view.window != nil, abs(view.bounds.width - 48) < 6 {
                frames.append(view.convert(view.bounds, to: window))
            }
            view.subviews.forEach { visit($0, inBar: inBar) }
        }
        visit(window, inBar: false)
        return frames.sorted { $0.minY < $1.minY }
    }
}

