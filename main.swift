import AppKit
import ImageIO
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Capture (Continuity Camera)

// One received photo or scan. Only the best format is kept (the iPhone sends several, some of them huge).
struct Capture {
    let type: NSPasteboard.PasteboardType
    let data: Data

    private static let preferred: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
        .png, .pdf, .tiff,
    ]

    init?(_ item: NSPasteboardItem) {
        guard let type = Capture.preferred.first(where: { item.types.contains($0) }) ?? item.types.first,
              let data = item.data(forType: type) else { return nil }
        self.type = type
        self.data = data
    }
}

// Receives the photo or scan from Continuity Camera and hands it to the app.
final class RequestorView: NSView, NSServicesMenuRequestor {
    var onReceive: (([Capture]) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let returnType, NSImage.imageTypes.contains(returnType.rawValue) || returnType == .pdf {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pboard: NSPasteboard) -> Bool {
        let captured = (pboard.pasteboardItems ?? []).compactMap(Capture.init)
        guard !captured.isEmpty else { return false }
        onReceive?(captured)
        return true
    }
}

// Nearly invisible window: Continuity Camera delivers the photo to the key window.
final class HiddenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Panel model

struct DeviceAction { let menuIndex: Int; let title: String }

struct Device: Identifiable {
    let id: String  // device name
    let actions: [DeviceAction]
    var isIPad: Bool { id.localizedCaseInsensitiveContains("iPad") }
}

struct Thumb: Identifiable {
    let id = UUID()
    let image: NSImage
    let url: URL?
}

enum Option: String, CaseIterable {
    case photo, multi, scan, sketch

    var title: String {
        switch self {
        case .photo: return "Photo"
        case .multi: return "Multiple"
        case .scan: return "Scan"
        case .sketch: return "Sketch"
        }
    }
    var settingsTitle: String { self == .multi ? "Multiple photos" : title }
    var symbol: String {
        switch self {
        case .photo: return "camera"
        case .multi: return "photo.stack"
        case .scan: return "doc.viewfinder"
        case .sketch: return "pencil.and.scribble"
        }
    }
    var defaultOn: Bool { self != .sketch }
    var key: String { "show.\(rawValue)" }
    // Position of the action inside the device's block (Take Photo, Scan Documents, Add Sketch).
    var actionPosition: Int {
        switch self {
        case .photo, .multi: return 0
        case .scan: return 1
        case .sketch: return 2
        }
    }
}

final class PanelModel: ObservableObject {
    @Published var devices: [Device] = []
    @Published var selectedName: String?
    @Published var showingSettings = false
    @Published var launchAtLogin = false
    @Published var enabled: Set<Option> = []

    @Published var thumbs: [Thumb] = []
    @Published var multiSessionActive = false

    var run: (_ menuIndex: Int, _ multi: Bool) -> Void = { _, _ in }
    var stop: () -> Void = {}
    var setLaunchAtLogin: (Bool) -> Void = { _ in }
    var resize: (CGSize) -> Void = { _ in }

    init() {
        let defaults = UserDefaults.standard
        enabled = Set(Option.allCases.filter { defaults.object(forKey: $0.key) as? Bool ?? $0.defaultOn })
    }

    var selected: Device? { devices.first { $0.id == selectedName } ?? devices.first }

    func toggle(_ option: Option, _ on: Bool) {
        if on { enabled.insert(option) } else { enabled.remove(option) }
        UserDefaults.standard.set(on, forKey: option.key)
    }
}

// MARK: - Views

// Control Center style round button: monochrome glyph on a translucent circle.
struct RoundButtonStyle: ButtonStyle {
    var hovering: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.26 : hovering ? 0.17 : 0.11))
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ActionButton: View {
    let option: Option
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: option.symbol)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundColor(.primary)
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .buttonStyle(RoundButtonStyle(hovering: hovering))
            .onHover { hovering = $0 }

            Text(option.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(hovering ? .primary : .secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct SizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.showingSettings {
                settings
            } else {
                main
            }
        }
        .padding(16)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { Color.clear.preference(key: SizeKey.self, value: $0.size) })
        .onPreferenceChange(SizeKey.self) { model.resize($0) }
        .animation(.easeOut(duration: 0.18), value: model.thumbs.count)
    }

    // MARK: Main

    @ViewBuilder
    private var main: some View {
        HStack(spacing: 8) {
            Image(systemName: model.selected?.isIPad == true ? "ipad" : "iphone")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            if model.devices.count > 1, let current = model.selected {
                Menu {
                    ForEach(model.devices) { device in
                        Button(device.id) { model.selectedName = device.id }
                    }
                } label: {
                    Text(current.id).font(.system(size: 13, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Text(model.selected?.id ?? "Continuity Camera")
                    .font(.system(size: 13, weight: .semibold))
            }
            Spacer()
            IconButton(symbol: "gearshape", help: "Settings") { model.showingSettings = true }
        }

        if let device = model.selected {
            let options = Option.allCases.filter {
                model.enabled.contains($0) && device.actions.count > $0.actionPosition
            }
            if options.isEmpty {
                Text("Turn on an option in Settings.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
            } else {
                HStack(alignment: .top, spacing: 4) {
                    ForEach(options, id: \.self) { option in
                        ActionButton(option: option) {
                            model.run(device.actions[option.actionPosition].menuIndex, option == .multi)
                        }
                    }
                }
            }
        } else {
            emptyState
        }

        if !model.thumbs.isEmpty || model.multiSessionActive {
            Divider()
            previews
        }
    }

    // MARK: Preview

    @ViewBuilder
    private var previews: some View {
        HStack {
            Text(previewTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
            if model.multiSessionActive {
                Button("Done") { model.stop() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.11)))
            }
        }

        if model.thumbs.count == 1 && !model.multiSessionActive, let thumb = model.thumbs.first {
            thumbView(thumb)
                .frame(maxWidth: .infinity, maxHeight: 190)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.thumbs) { thumb in
                            thumbView(thumb, square: 56)
                                .id(thumb.id)
                                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        }
                        if model.multiSessionActive {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .frame(width: 56, height: 56)
                                .overlay(Image(systemName: "iphone").foregroundColor(.secondary))
                                .id("next")
                        }
                    }
                }
                .onChange(of: model.thumbs.count) { _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("next", anchor: .trailing) }
                }
            }
        }
    }

    private var previewTitle: String {
        if model.multiSessionActive {
            return model.thumbs.isEmpty ? "Take the first photo on your iPhone"
                : "Copied to clipboard: \(model.thumbs.count)"
        }
        return "Copied to clipboard: \(model.thumbs.count)"
    }

    @ViewBuilder
    private func thumbView(_ thumb: Thumb, square: CGFloat? = nil) -> some View {
        let image = Image(nsImage: thumb.image).resizable()
        Group {
            if let square {
                image.scaledToFill().frame(width: square, height: square)
            } else {
                image.scaledToFit()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: square == nil ? 12 : 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: square == nil ? 12 : 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
        .onTapGesture { if let url = thumb.url { NSWorkspace.shared.open(url) } }
        .onDrag { thumb.url.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
        .help("Click to open · drag into another app")
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 24, weight: .light)).foregroundColor(.secondary)
            Text("No iPhone nearby").font(.system(size: 13, weight: .semibold))
            Text("Unlock it and make sure Wi‑Fi and Bluetooth are on.")
                .font(.system(size: 11)).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: Settings

    @ViewBuilder
    private var settings: some View {
        HStack(spacing: 6) {
            IconButton(symbol: "chevron.left", help: "Back") { model.showingSettings = false }
            Text("Settings").font(.system(size: 13, weight: .semibold))
            Spacer()
        }

        VStack(alignment: .leading, spacing: 2) {
            Text("Show in panel")
                .font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                .padding(.bottom, 4)
            ForEach(Option.allCases, id: \.self) { option in
                settingRow(option.settingsTitle, symbol: option.symbol, isOn: Binding(
                    get: { model.enabled.contains(option) },
                    set: { model.toggle(option, $0) }))
            }
        }

        Divider()

        settingRow("Open at login", symbol: "power.circle", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }))

        Divider()

        Button { NSApp.terminate(nil) } label: {
            Text("Quit iPhone Photo").font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
    }

    private func settingRow(_ title: String, symbol: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12)).foregroundColor(.secondary).frame(width: 18)
            Text(title).font(.system(size: 13))
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Small toast shown after copying

final class ToastModel: ObservableObject {
    @Published var thumbs: [Thumb] = []
    @Published var title = ""
    @Published var version = 0
}

struct ToastView: View {
    @ObservedObject var model: ToastModel
    @State private var appeared = false
    private let maxShown = 6

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(Array(model.thumbs.prefix(maxShown).enumerated()), id: \.element.id) { offset, thumb in
                    thumbnail(thumb)
                        .scaleEffect(appeared ? 1 : 0.6)
                        .opacity(appeared ? 1 : 0)
                        // In the summary they come in one after another.
                        .animation(.spring(response: 0.32, dampingFraction: 0.72).delay(Double(offset) * 0.04),
                                   value: appeared)
                }
                if model.thumbs.count > maxShown {
                    Text("+\(model.thumbs.count - maxShown)")
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                        .padding(.leading, 2)
                }
            }
            Text(model.title)
                .font(.system(size: 12, weight: .semibold))
                .fixedSize()
        }
        .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 8)
        .id(model.version)
        .onAppear { appeared = true }
    }

    private func thumbnail(_ thumb: Thumb) -> some View {
        Image(nsImage: thumb.image)
            .resizable()
            .scaledToFill()
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
    }
}

// MARK: - Apple-style floating panel (no arrow, glass, shows instantly)

final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let importItem = NSMenuItem(title: "Import from iPhone", action: nil, keyEquivalent: "")
    private var window: HiddenWindow!
    private let requestor = RequestorView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))

    private let model = PanelModel()
    private let panel = FloatingPanel()
    private var panelSize = CGSize(width: 300, height: 200)
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var panelHost: NSHostingView<PanelView>!
    private var panelAnimation = 0   // stops an old fade-out from hiding a panel that was just reopened
    private var toastAnimation = 0

    private let toastModel = ToastModel()
    private let toastPanel = FloatingPanel()
    private var toastHost: NSHostingView<ToastView>!
    private var toastHide: DispatchWorkItem?

    // Current session: everything captured is collected and copied to the clipboard together.
    private var captures: [Capture] = []
    private var captureFiles: [URL?] = []
    private var multiMode = false
    private var activeIndex = 0
    private var capturedSinceFire = false
    private var sessionActive = false
    private var fireGeneration = 0
    private var toastAnchor: NSRect?   // icon position, frozen for the session
    private let saveDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("iPhonePhoto", isDirectory: true)

    func applicationWillFinishLaunching(_ notification: Notification) {
        // macOS only fills in the iPhone submenu when the item lives in the main menu
        // (which is never shown, since this is a menu bar only app).
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "iPhone Photo")
        mainMenu.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        importItem.identifier = NSMenuItem.importFromDeviceIdentifier
        fileMenu.addItem(importItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let returnTypes = NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) } + [.pdf]
        NSApp.registerServicesMenuSendTypes([], returnTypes: returnTypes)

        window = HiddenWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.02
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = requestor
        requestor.onReceive = { [weak self] items in self?.received(items) }


        setUpStatusItem()
        setUpPanel()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Same size and weight as the system icons (Wi‑Fi, Bluetooth, etc.).
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let symbol = NSImage(systemSymbolName: "camera", accessibilityDescription: "iPhone Photo")?
            .withSymbolConfiguration(config)
        // The camera symbol has extra space at the bottom and sits too high, so it is moved down 1 pt.
        let icon = symbol.map { s in
            NSImage(size: s.size, flipped: false) { rect in
                s.draw(in: rect.offsetBy(dx: 0, dy: -1))
                return true
            }
        }
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
    }

    private func setUpPanel() {
        model.run = { [weak self] index, multi in self?.start(menuIndex: index, multi: multi) }
        model.stop = { [weak self] in self?.endSession() }
        model.setLaunchAtLogin = { [weak self] on in self?.setLaunchAtLogin(on) }
        model.resize = { [weak self] size in self?.resizePanel(to: size) }

        panelHost = NSHostingView(rootView: PanelView(model: model))
        panel.contentView = glass(around: panelHost, radius: 20)

        toastHost = NSHostingView(rootView: ToastView(model: toastModel))
        toastPanel.contentView = glass(around: toastHost, radius: 16)
        toastPanel.ignoresMouseEvents = true
    }

    // System glass background (Liquid Glass on macOS 26, blur on older versions).
    private func glass(around host: NSView, radius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.contentView = host
            return glass
        }
        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = radius
        blur.layer?.masksToBounds = true
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
        return blur
    }

    // MARK: Toast

    private func showToast(_ thumbs: [Thumb], title: String, duration: Double) {
        toastModel.thumbs = thumbs
        toastModel.title = title
        toastModel.version += 1

        toastHost.layoutSubtreeIfNeeded()
        let size = toastHost.fittingSize
        guard let button = statusItem.button, let buttonWindow = button.window, size.width > 0 else { return }
        let anchor = toastAnchor ?? buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let final = NSRect(x: x, y: anchor.minY - 6 - size.height, width: size.width, height: size.height)

        toastHide?.cancel()
        toastAnimation += 1
        if toastPanel.isVisible && toastPanel.alphaValue > 0.99 {
            toastPanel.setFrame(final, display: true)
        } else {
            // Slides in 6 pt from above while fading in.
            toastPanel.setFrame(final.offsetBy(dx: 0, dy: 6), display: false)
            toastPanel.alphaValue = 0
            toastPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = Self.settle
                toastPanel.animator().setFrame(final, display: true)
                toastPanel.animator().alphaValue = 1
            }
        }

        let work = DispatchWorkItem { [weak self] in self?.hideToast() }
        toastHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func hideToast() {
        guard toastPanel.isVisible else { return }
        let animation = toastAnimation
        let frame = toastPanel.frame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            toastPanel.animator().setFrame(frame.offsetBy(dx: 0, dy: 4), display: true)
            toastPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.toastAnimation == animation else { return }
            self.toastPanel.orderOut(nil)
            self.toastPanel.alphaValue = 1
        })
    }

    // MARK: Show / hide

    // Apple-like curve: starts fast and settles softly.
    private static let settle = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

    @objc private func togglePanel() {
        if panel.isVisible { return hidePanel() }
        refreshDevices()
        model.showingSettings = false
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
        // Compute the final size before showing it, so it never resizes while visible.
        panelHost.layoutSubtreeIfNeeded()
        let fitting = panelHost.fittingSize
        if fitting.width > 0, fitting.height > 0 { panelSize = fitting }
        showPanel()
    }

    private func showPanel() {
        panelAnimation += 1
        let final = panelFrame()
        panel.setFrame(final.offsetBy(dx: 0, dy: 6), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = Self.settle
            panel.animator().setFrame(final, display: true)
            panel.animator().alphaValue = 1
        }
        installMonitors()
    }

    private func hidePanel() {
        removeMonitors()
        guard panel.isVisible else { return }
        panelAnimation += 1
        let animation = panelAnimation
        let frame = panel.frame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(frame.offsetBy(dx: 0, dy: 3), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.panelAnimation == animation else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        })
    }

    // Below the icon, centered, kept on screen.
    private func panelFrame() -> NSRect {
        guard let button = statusItem.button, let buttonWindow = button.window else { return panel.frame }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = anchor.midX - panelSize.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - panelSize.width - 8)
        return NSRect(x: x, y: anchor.minY - 6 - panelSize.height, width: panelSize.width, height: panelSize.height)
    }

    // The panel grows downward and stays under the icon (Settings, carousel).
    private func resizePanel(to size: CGSize) {
        guard size.width > 0, size.height > 0,
              abs(size.width - panelSize.width) > 0.5 || abs(size.height - panelSize.height) > 0.5 else { return }
        panelSize = size
        if panel.isVisible { panel.setFrame(panelFrame(), display: true) }
    }

    private func installMonitors() {
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.hidePanel()
            }
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { self?.hidePanel(); return nil }  // Esc
                return event
            }
        }
    }

    private func removeMonitors() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
    }

    // Reads what macOS put in the hidden submenu: one header per device plus its actions.
    private func refreshDevices() {
        guard let deviceMenu = importItem.submenu else { model.devices = []; return }
        deviceMenu.update()
        let cameraAction = NSSelectorFromString("importFromDevice:")
        var devices: [Device] = []
        var name: String?
        var actions: [DeviceAction] = []
        func flush() {
            if let name, !actions.isEmpty { devices.append(Device(id: name, actions: actions)) }
            name = nil
            actions = []
        }
        for (index, item) in deviceMenu.items.enumerated() {
            if item.isSeparatorItem { flush(); continue }
            if item.action == cameraAction {
                actions.append(DeviceAction(menuIndex: index, title: item.title))
            } else if !item.title.isEmpty {
                flush()
                name = item.title
            }
        }
        flush()
        model.devices = devices
    }

    // MARK: Capture session

    private func start(menuIndex: Int, multi: Bool) {
        hidePanel()
        captures = []
        captureFiles = []
        model.thumbs = []
        multiMode = multi
        activeIndex = menuIndex
        sessionActive = true
        model.multiSessionActive = multi
        if let button = statusItem.button, let buttonWindow = button.window {
            toastAnchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        }
        updateBadge()
        fire()
    }

    private func fire() {
        guard let deviceMenu = importItem.submenu else { return endSession() }
        capturedSinceFire = false
        fireGeneration += 1
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(requestor)
        // Short wait so activation finishes before asking for the photo.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.sessionActive else { return }
            deviceMenu.update()
            guard self.activeIndex < deviceMenu.items.count,
                  deviceMenu.items[self.activeIndex].action == NSSelectorFromString("importFromDevice:") else {
                NSSound(named: "Basso")?.play()
                return self.endSession()
            }
            // This opens the "Take a photo with…" alert and only returns once it closes.
            let generation = self.fireGeneration
            deviceMenu.performActionForItem(at: self.activeIndex)
            // If it closed without a photo, it was cancelled (on the iPhone or on the Mac).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.sessionActive, self.fireGeneration == generation,
                      !self.capturedSinceFire else { return }
                self.endSession()
            }
        }
    }

    private func received(_ items: [Capture]) {
        guard sessionActive else { return }
        capturedSinceFire = true
        // The folder is only cleared once the first new photo arrives, so cancelling a session
        // keeps whatever is already on the clipboard working.
        if captures.isEmpty {
            try? FileManager.default.removeItem(at: saveDir)
            try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        }
        for capture in items {
            captures.append(capture)
            let file = saveFile(capture, number: captures.count)
            captureFiles.append(file)
            if let image = thumbnail(capture) { model.thumbs.append(Thumb(image: image, url: file)) }
        }
        writeClipboard()
        updateBadge()

        // If the panel is open it updates there; otherwise the toast shows.
        // In multiple mode each photo shows on its own, and the summary shows at the end.
        if !panel.isVisible, let last = model.thumbs.last {
            let title = multiMode ? "Copied to clipboard: \(model.thumbs.count)" : "Copied to clipboard"
            showToast([last], title: title, duration: multiMode ? 1.6 : 2.2)
        }

        if multiMode {
            // Wait for the previous alert to close, then open the camera again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.sessionActive else { return }
                self.fire()
            }
        } else {
            endSession()
        }
    }

    private func endSession() {
        let endedMulti = sessionActive && multiMode
        sessionActive = false
        multiMode = false
        model.multiSessionActive = false
        window.orderOut(nil)
        updateBadge()
        if endedMulti && !panel.isVisible && model.thumbs.count > 1 {
            showToast(model.thumbs, title: "Copied to clipboard: \(model.thumbs.count)", duration: 3)
        }
        toastAnchor = nil
    }

    private func updateBadge() {
        // Only leave room for text when there is a count; otherwise keep the icon centered like the system ones.
        let showCount = sessionActive && multiMode && !captures.isEmpty
        statusItem.button?.title = showCount ? " \(captures.count)" : ""
        statusItem.button?.imagePosition = showCount ? .imageLeading : .imageOnly
    }

    // MARK: Files and clipboard

    // Lightweight thumbnail for the preview (the full photo is never decoded).
    private func thumbnail(_ capture: Capture) -> NSImage? {
        if capture.type != .pdf, let source = CGImageSourceCreateWithData(capture.data as CFData, nil),
           let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: 600,
           ] as CFDictionary) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        return NSImage(data: capture.data)
    }

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    // Saves the capture to a file (once) so it can also be pasted in Finder.
    private func saveFile(_ capture: Capture, number: Int) -> URL? {
        let ext = UTType(capture.type.rawValue)?.preferredFilenameExtension ?? "jpg"
        let name = "\(ext == "pdf" ? "Scan" : "IMG")_\(Self.fileStamp.string(from: Date()))_\(number)"
        let url = saveDir.appendingPathComponent(name).appendingPathExtension(ext)
        return (try? capture.data.write(to: url)) != nil ? url : nil
    }

    // Each photo goes on the clipboard as image data and as a file, so it pastes in chats and in Finder.
    private func writeClipboard() {
        let items: [NSPasteboardItem] = zip(captures, captureFiles).map { capture, file in
            let item = NSPasteboardItem()
            item.setData(capture.data, forType: capture.type)
            if let file { item.setString(file.absoluteString, forType: .fileURL) }
            return item
        }
        let general = NSPasteboard.general
        general.clearContents()
        general.writeObjects(items)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSSound.beep()
        }
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
