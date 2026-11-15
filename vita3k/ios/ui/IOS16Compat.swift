import SwiftUI

// iOS 16 compatibility shims (this build also supports iOS 16.3; the two-value onChange and the
// scroll-position APIs came with iOS 17).

private struct OnChangeCompat<V: Equatable>: ViewModifier {
    let value: V
    let action: (V, V) -> Void
    @State private var previous: V

    init(value: V, action: @escaping (V, V) -> Void) {
        self.value = value
        self.action = action
        _previous = State(initialValue: value)
    }

    func body(content: Content) -> some View {
        content.onChange(of: value) { new in
            let old = previous
            previous = new
            action(old, new)
        }
    }
}

extension View {
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, _ action: @escaping (V, V) -> Void) -> some View {
        if #available(iOS 17.0, *) {
            self.onChange(of: value, action)
        } else {
            self.modifier(OnChangeCompat(value: value, action: action))
        }
    }

    // Paging scroll of the home pages: snapping and the page binding need iOS 17. Older systems get a
    // plain sideways scroll.
    @ViewBuilder
    func homePagingCompat(page: Binding<Int>) -> some View {
        if #available(iOS 17.0, *) {
            self.scrollTargetBehavior(.paging)
                .scrollPosition(id: Binding<Int?>(get: { page.wrappedValue }, set: { page.wrappedValue = $0 ?? 0 }))
        } else {
            self
        }
    }

    @ViewBuilder
    func scrollTargetLayoutCompat() -> some View {
        if #available(iOS 17.0, *) {
            self.scrollTargetLayout()
        } else {
            self
        }
    }
}
