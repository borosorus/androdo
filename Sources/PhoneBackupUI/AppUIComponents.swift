import SwiftUI

struct AppPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let trailing: Trailing

    init(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    init(title: String, subtitle: String = "") where Trailing == EmptyView {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }
}

struct ReviewSheetLayout<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    let minimumWidth: CGFloat
    let minimumHeight: CGFloat
    let content: Content
    let footer: Footer

    init(title: String, subtitle: String, minimumWidth: CGFloat, minimumHeight: CGFloat,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.subtitle = subtitle
        self.minimumWidth = minimumWidth
        self.minimumHeight = minimumHeight
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.weight(.semibold))
                    if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            Divider()

            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }

            Divider()

            HStack(spacing: 10) {
                Spacer()
                footer
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(minWidth: minimumWidth, minHeight: minimumHeight)
    }
}

struct SummaryMetric: View {
    let title: String
    let value: String
    let symbol: String

    init(_ title: String, value: String, symbol: String) {
        self.title = title
        self.value = value
        self.symbol = symbol
    }

    init(_ title: String, value: Int, symbol: String) {
        self.init(title, value: value.formatted(), symbol: symbol)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label { Text(title) } icon: {
                Image(systemName: symbol).foregroundStyle(AppIdentity.teal)
            }.font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct MessageBanner: View {
    let text: String
    var symbol = "info.circle"
    var isWarning = false

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(isWarning ? Color.orange : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background((isWarning ? Color.orange : Color.secondary).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
