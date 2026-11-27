import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var model = ViewerModel()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme
    @State private var headerBottom: CGFloat = 0
    @State private var sheetTop: CGFloat = 0
    @State private var shareItem: ShareItem?

    private var compact: Bool { sizeClass != .regular }
    /// `-hideUI YES`: render the product alone (used to make the app icon).
    private let hideUI = UserDefaults.standard.bool(forKey: "hideUI")

    private var stageBackground: UIColor {
        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        return (UIColor(named: "StageBackground") ?? .systemBackground)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    var body: some View {
        ZStack(alignment: .top) {
            StageView(model: model, compact: compact, background: stageBackground)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                TopBar(model: model, onSnapshot: takeSnapshot)
                StoryHeader(compact: compact)
                    .padding(.top, compact ? 14 : 28)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: HeaderBottomKey.self, value: g.frame(in: .global).maxY)
                    })
                Text("拖动旋转 · 双指缩放 · 双击复位")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .opacity(model.isReady && !model.hasInteracted ? 1 : 0)
                    .animation(.easeOut(duration: 0.6), value: model.hasInteracted)
                Spacer(minLength: 0)
                FeatureSheet(model: model, compact: compact)
                    .frame(maxWidth: compact ? .infinity : 620)
                    .frame(maxWidth: .infinity)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: SheetTopKey.self, value: g.frame(in: .global).minY)
                    })
            }
            .padding(.horizontal, compact ? 12 : 28)
            .padding(.bottom, compact ? 4 : 16)
            .opacity(model.isReady && !hideUI ? 1 : 0)
            .animation(.easeOut(duration: 0.8), value: model.isReady)

            if !model.isReady {
                LoadingView(model: model)
                    .transition(.opacity)
            }
        }
        .onPreferenceChange(HeaderBottomKey.self) { headerBottom = $0; pushBand() }
        .onPreferenceChange(SheetTopKey.self) { sheetTop = $0; pushBand() }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.image])
                .presentationDetents([.medium, .large])
        }
    }

    /// The free vertical band between the header and the sheet, in window coordinates.
    private func pushBand() {
        guard sheetTop > 0, !hideUI else { return }
        model.setBand(top: headerBottom + 8, bottom: sheetTop - 8)
    }

    private func takeSnapshot() {
        model.snapshot { image in
            if let image { shareItem = ShareItem(image: image) }
        }
    }
}

// MARK: - Pieces

private struct TopBar: View {
    @ObservedObject var model: ViewerModel
    var onSnapshot: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("OneKey Pro 2")
                .font(.system(size: 17, weight: .semibold))
            Text("3D")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Spacer()
            CircleButton(systemName: model.autoRotate ? "rotate.3d.fill" : "rotate.3d",
                         label: model.autoRotate ? "停止自动旋转" : "自动旋转") {
                model.autoRotate.toggle()
            }
            CircleButton(systemName: "camera", label: "截图分享", action: onSnapshot)
        }
        .padding(.top, 6)
    }
}

private struct CircleButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct StoryHeader: View {
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 12) {
            Text(ProductConfig.eyebrow)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(red: 0.91, green: 0.45, blue: 0.05))
            Text(ProductConfig.title)
                .font(.system(size: compact ? 26 : 38, weight: .semibold))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if !compact {
                Text(ProductConfig.summary)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 360, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FeatureSheet: View {
    @ObservedObject var model: ViewerModel
    let compact: Bool

    private var caption: String {
        model.activeFeature?.description ?? ProductConfig.summary
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(ProductConfig.closerLook)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(ProductConfig.features) { feature in
                            FeatureChip(title: feature.label, selected: model.feature == feature.id) {
                                model.toggleFeature(feature.id)
                            }
                            .id(feature.id)
                        }
                    }
                    .padding(3)
                }
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onChange(of: model.feature) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
                }
            }

            Text(caption)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 40)
                .animation(.easeOut(duration: 0.25), value: caption)
                .id(caption)
                .transition(.opacity)

            HStack(spacing: 16) {
                ForEach(ProductConfig.swatches) { swatch in
                    SwatchButton(swatch: swatch, selected: model.color == swatch.id) {
                        model.selectColor(swatch.id)
                    }
                }
            }
            Text("\(model.swatch.zh) · \(model.swatch.label)")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

private struct FeatureChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Explicit opaque colours: semantic `.primary` turns translucent (vibrant) on materials.
        let ink: Color = colorScheme == .dark ? .white : .black
        let paper: Color = colorScheme == .dark ? .black : .white
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? paper : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(selected ? ink : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.25), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SwatchButton: View {
    let swatch: Swatch
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(uiColor: swatch.fill))
                .overlay(Circle().strokeBorder(Color(uiColor: swatch.stroke), lineWidth: 1.5))
                .frame(width: 26, height: 26)
                .padding(4)
                .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.85 : 0), lineWidth: 1.5))
                .animation(.easeOut(duration: 0.25), value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(swatch.zh) \(swatch.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct LoadingView: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        ZStack {
            Color("StageBackground").ignoresSafeArea()
            VStack(spacing: 14) {
                if let error = model.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                } else {
                    Text("\(Int((model.progress * 100).rounded()))%")
                        .font(.system(size: 44, weight: .ultraLight))
                        .monospacedDigit()
                    ProgressView(value: Double(model.progress))
                        .progressViewStyle(.linear)
                        .tint(.primary)
                        .frame(width: 160)
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Helpers

private struct HeaderBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct SheetTopKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ShareItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
