//
//  WorkspaceMinimapView.swift
//  iTerm2SharedARC
//
//  A thin strip over the terminal's right edge with one tick per submitted prompt. It only shows
//  prompts that iTerm2 has marks for, so it stays hidden rather than guess.
//

import AppKit

private final class MinimapTickElement: NSAccessibilityElement {
    var onPress: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

final class WorkspaceMinimapView: NSView, NSViewToolTipOwner {
    private(set) var prompts = [MinimapPrompt]()
    private var currentIndex: Int?
    private var ticks = [MinimapTick]()
    private let verticalInset: CGFloat = 6

    var onJump: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.list)
        setAccessibilityLabel(String(localized: "Workspace.Minimap.Container.A11y",
                                     defaultValue: "Prompts in this session",
                                     comment: "VoiceOver label of the minimap strip"))
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    func update(prompts newPrompts: [MinimapPrompt], currentIndex newCurrent: Int?) {
        guard newPrompts != prompts || newCurrent != currentIndex else { return }
        prompts = newPrompts
        currentIndex = newCurrent
        rebuildTicks()
        needsDisplay = true
    }

    private func rebuildTicks() {
        ticks = MinimapModel.ticks(for: prompts, availableHeight: max(0, bounds.height - verticalInset * 2))
        removeAllToolTips()
        for (index, tick) in ticks.enumerated() {
            addToolTip(rect(for: tick), owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
        }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    private func rect(for tick: MinimapTick) -> NSRect {
        let pitch = max(MinimapModel.minimumPitch, min(MinimapModel.preferredPitch, (bounds.height - verticalInset * 2) / CGFloat(max(1, prompts.count))))
        // The hit area is the full pitch so ticks are easy to hit.
        return NSRect(x: bounds.width - tick.width - 2,
                      y: verticalInset + tick.y,
                      width: tick.width + 2,
                      height: pitch)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let raw = data else { return "" }
        let index = Int(bitPattern: raw) - 1
        guard ticks.indices.contains(index) else { return "" }
        let tick = ticks[index]
        if tick.isBucket {
            return String(localized: "Workspace.Minimap.Tooltip", defaultValue: "One tick per prompt. Click to jump.", comment: "Tooltip of the minimap strip")
        }
        return prompts[tick.promptRange.lowerBound].preview
    }

    override func layout() {
        super.layout()
        rebuildTicks()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return ticks.contains { rect(for: $0).contains(local) } ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if let tick = ticks.first(where: { rect(for: $0).contains(local) }) {
            onJump?(tick.promptRange.lowerBound)
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        for tick in ticks {
            let r = rect(for: tick)
            let drawn = NSRect(x: bounds.width - tick.width - 2, y: r.minY + (r.height - 3) / 2, width: tick.width, height: 3)
            let isCurrent = currentIndex.map { tick.promptRange.contains($0) } ?? false
            (isCurrent ? WorkspaceColor.accent : WorkspaceColor.textSecondary.withAlphaComponent(0.55)).setFill()
            NSBezierPath(roundedRect: drawn, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func accessibilityChildren() -> [Any]? {
        return ticks.map { tick in
            let element = MinimapTickElement()
            let first = tick.promptRange.lowerBound
            let prompt = prompts[first]
            element.setAccessibilityRole(.row)
            element.setAccessibilityParent(self)
            element.setAccessibilityLabel(MinimapModel.accessibilityLabel(index: first, count: prompts.count, preview: prompt.preview))
            element.setAccessibilityFrameInParentSpace(rect(for: tick))
            element.onPress = { [weak self] in self?.onJump?(first) }
            return element
        }
    }
}
