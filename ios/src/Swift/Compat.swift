import SwiftUI
import UIKit

// Back-deployment shims.
//
// The app targets iOS 16.3 but was written against newer SwiftUI: iOS 17
// (`onChange` with old/new values, `sensoryFeedback`, `symbolEffect`, the
// scroll-position APIs, `Animation.snappy`) and iOS 26 (Liquid Glass). Every
// call to one of those goes through this file, so the availability decision is
// made in exactly one place and the rest of the UI reads the same on every OS.
//
// Rule of thumb for the fallbacks: newer systems get the real API unchanged;
// iOS 16 gets the closest thing that exists there (system materials for glass,
// a UIKit haptic for `sensoryFeedback`, no-op for decorative symbol effects).

// MARK: - onChange

/// iOS 16 `onChange` only reports the new value. This keeps the old one in
/// state so call sites can use the two-value form on every system.
private struct LegacyOnChange<Value: Equatable>: ViewModifier {
    let value: Value
    let initial: Bool
    let action: (Value, Value) -> Void

    @State private var previous: Value
    @State private var didRunInitial = false

    init(value: Value, initial: Bool, action: @escaping (Value, Value) -> Void) {
        self.value = value
        self.initial = initial
        self.action = action
        _previous = State(initialValue: value)
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                // `initial: true` fires once, when the view first appears, with
                // old and new equal - the same as the iOS 17 behaviour.
                guard initial, !didRunInitial else { return }
                didRunInitial = true
                action(value, value)
            }
            .onChange(of: value) { newValue in
                let oldValue = previous
                previous = newValue
                action(oldValue, newValue)
            }
    }
}

extension View {
    /// `onChange(of:initial:_:)` with the iOS 17 signature, usable from iOS 16.
    @ViewBuilder
    func compatOnChange<Value: Equatable>(
        of value: Value,
        initial: Bool = false,
        _ action: @escaping (_ oldValue: Value, _ newValue: Value) -> Void
    ) -> some View {
        if #available(iOS 17.0, *) {
            onChange(of: value, initial: initial, action)
        } else {
            modifier(LegacyOnChange(value: value, initial: initial, action: action))
        }
    }
}

// MARK: - Animation

extension Animation {
    /// `Animation.snappy(duration:)` on iOS 17+, a short ease on iOS 16.
    static func compatSnappy(duration: Double = 0.5) -> Animation {
        if #available(iOS 17.0, *) {
            return .snappy(duration: duration)
        }
        return .easeInOut(duration: duration)
    }
}

// MARK: - Haptics and symbols

private struct LegacySelectionHaptic<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger

    func body(content: Content) -> some View {
        content.onChange(of: trigger) { _ in
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}

extension View {
    /// `sensoryFeedback(.selection, trigger:)` on iOS 17+, the equivalent
    /// UIKit selection haptic on iOS 16.
    @ViewBuilder
    func compatSelectionHaptic<Trigger: Equatable>(trigger: Trigger) -> some View {
        if #available(iOS 17.0, *) {
            sensoryFeedback(.selection, trigger: trigger)
        } else {
            modifier(LegacySelectionHaptic(trigger: trigger))
        }
    }

    /// A bounce on `value` change where symbol effects exist; nothing on
    /// iOS 16, where it is purely decorative.
    @ViewBuilder
    func compatBounceSymbol<Value: Equatable>(value: Value) -> some View {
        if #available(iOS 17.0, *) {
            symbolEffect(.bounce, value: value)
        } else {
            self
        }
    }
}

// MARK: - Presentation

extension View {
    /// `presentationBackground` arrived in iOS 16.4. On 16.0-16.3 the sheet
    /// keeps its default background.
    @ViewBuilder
    func compatPresentationBackground<S: ShapeStyle>(_ style: S) -> some View {
        if #available(iOS 16.4, *) {
            presentationBackground(style)
        } else {
            self
        }
    }
}

// MARK: - Liquid Glass

extension View {
    /// Liquid Glass on iOS 26+; a system material (plus an optional tint wash)
    /// on earlier systems.
    @ViewBuilder
    func adaptiveGlass<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                glassEffect(.regular.tint(tint), in: shape)
            } else {
                glassEffect(.regular, in: shape)
            }
        } else {
            background {
                ZStack {
                    shape.fill(.regularMaterial)
                    if let tint {
                        shape.fill(tint.opacity(0.35))
                    }
                }
            }
        }
    }

    /// `.glass` / `.glassProminent` on iOS 26+; `.bordered` /
    /// `.borderedProminent` on earlier systems.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }
}

/// `GlassEffectContainer` on iOS 26+; a passthrough on earlier systems, where
/// there are no glass highlights to merge.
struct AdaptiveGlassContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

// MARK: - Layout helpers

private struct CompatWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

extension View {
    /// Reports this view's width as it changes, without taking part in layout.
    ///
    /// `onGeometryChange` needs iOS 18; a background `GeometryReader` feeding a
    /// preference works on every system and, being a background, does not
    /// claim space or ignore the safe area.
    func compatOnWidthChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: CompatWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(CompatWidthKey.self, perform: action)
    }
}

// MARK: - Empty state

/// `ContentUnavailableView` on iOS 17+; the same idea built by hand on iOS 16.
struct CompatEmptyState: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(message)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title2.weight(.bold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .accessibilityElement(children: .combine)
        }
    }
}
