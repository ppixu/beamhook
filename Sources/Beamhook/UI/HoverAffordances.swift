import SwiftUI
import AppKit

/// Makes the view it overlays behave like a link: a pointing-hand cursor, and
/// the click itself.
///
/// Cursor and click have to live in the same AppKit view. A cursor rect only
/// takes effect if its view is hit-testable — an overlay that returns `nil` from
/// `hitTest` never changes the pointer — but a hit-testable overlay swallows the
/// SwiftUI tap underneath. Both halves were measured; owning the click here is
/// what removes the conflict.
struct ClickableName: NSViewRepresentable {
    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> NSView { HandView(action: action) }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? HandView)?.action = action
    }

    private final class HandView: NSView {
        var action: @MainActor () -> Void

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("never loaded from a nib") }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }

        /// The popover is reachable while another app is frontmost, so the first
        /// click on a name should act rather than only raising the window.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {}

        /// Act on mouse-up inside the name, so dragging off it cancels — the same
        /// escape hatch every button on the row gives.
        override func mouseUp(with event: NSEvent) {
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            action()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.invalidateCursorRects(for: self)
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            window?.invalidateCursorRects(for: self)
        }
    }
}

extension View {
    /// A slight wash while the pointer is over the control.
    ///
    /// macOS gives a small bordered button inside a popover no hover feedback of
    /// its own, which leaves a row of them looking inert. `behind` puts the wash
    /// underneath instead of over the top: right for a bare label like the target
    /// menu, which would otherwise have its own text tinted.
    func hoverHighlight(cornerRadius: CGFloat, behind: Bool = false) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, behind: behind))
    }
}

private struct HoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    let behind: Bool
    @State private var hovering = false

    /// 0.08 by measurement: 0.05 is indistinguishable from the resting state and
    /// 0.12 reads as pressed rather than hovered.
    private var wash: Double { hovering ? 0.08 : 0 }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.primary.opacity(behind ? wash : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.primary.opacity(behind ? 0 : wash))
                    .allowsHitTesting(false)
            )
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}
