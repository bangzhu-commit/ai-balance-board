import SwiftUI
import BalanceCore

struct DashboardView: View {
    let cards: [ServiceCard]
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onConnect: (ServiceID) -> Void
    let onHide: () -> Void
    var onSettings: () -> Void = {}

    private let ink = Color(red: 0.16, green: 0.20, blue: 0.24)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(red: 0.28, green: 0.43, blue: 0.39))
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI 额度").font(.system(size: 15, weight: .semibold))
                        Text("桌面看板").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
                .frame(maxWidth: .infinity, minHeight: 34)
                .overlay(WindowDragArea())
                Button(action: onSettings) {
                    Image(systemName: "gearshape").frame(width: 25, height: 25)
                }
                .buttonStyle(.plain)
                .help("选择服务、连接与设置")
                .accessibilityLabel("服务与设置")
                Button(action: onRefresh) {
                    if isRefreshing {
                        ProgressView().controlSize(.small).frame(width: 25, height: 25)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium)).frame(width: 25, height: 25)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .help("刷新全部额度")
                .accessibilityLabel("刷新全部额度")
                Button(action: onHide) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                        .frame(width: 25, height: 25)
                }
                .buttonStyle(.plain)
                .help("收起到菜单栏")
                .accessibilityLabel("收起到菜单栏")
            }
            .padding(.horizontal, 17)
            .padding(.top, 16)
            .padding(.bottom, 13)

            ScrollView(.vertical) {
                VStack(spacing: 9) {
                    if cards.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "square.stack.3d.up").font(.title)
                            Text("选择要监控的 AI 服务").font(.headline)
                            Text("只查询你开启的服务，后台零模型调用。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("开始设置", action: onSettings).buttonStyle(.borderedProminent)
                        }.frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                    ForEach(cards) { card in
                        QuotaCardView(card: card, onConnect: { onConnect(card.id) })
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: cardAreaHeight)

            HStack(spacing: 5) {
                Image(systemName: "clock").font(.system(size: 9))
                Text(cards.isEmpty ? "启用服务后开始监控 · 拖动标题栏移动" : "每 5 分钟刷新 · 拖动标题栏移动")
                    .font(.system(size: 9))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .foregroundStyle(ink)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(red: 0.94, green: 0.95, blue: 0.94).opacity(0.98))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.85), lineWidth: 1))
        .environment(\.colorScheme, .light)
    }

    private var cardAreaHeight: CGFloat {
        if cards.isEmpty { return 180 }
        let natural = cards.reduce(CGFloat(0)) { sum, card in
            guard let reading = card.reading else { return sum + 130 }
            let rows = reading.metrics.enumerated().reduce(CGFloat(0)) { height, item in
                height + (item.offset == 0 ? 35 : 25) + (item.element.remainingFraction == nil ? 0 : 11) + (item.element.resetsAt == nil ? 0 : 17)
            }
            return sum + 106 + rows
        } + CGFloat(max(0, cards.count - 1)) * 9
        return min(natural, max(220, (NSScreen.main?.visibleFrame.height ?? 800) - 150), 620)
    }
}

private struct QuotaCardView: View {
    let card: ServiceCard
    let onConnect: () -> Void

    private var accent: Color {
        switch card.id {
        case .foxcode: return Color(red: 0.76, green: 0.39, blue: 0.27)
        case .codex: return Color(red: 0.22, green: 0.48, blue: 0.41)
        case .grok: return Color(red: 0.33, green: 0.38, blue: 0.49)
        }
    }

    private var symbol: String {
        switch card.id {
        case .foxcode: return "bolt.fill"
        case .codex: return "terminal"
        case .grok: return "sparkle"
        }
    }

    private var statusColor: Color {
        card.needsConnection || card.isStale ? Color(red: 0.62, green: 0.43, blue: 0.19) : .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 27, height: 27)
                    .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).font(.system(size: 12, weight: .semibold))
                    Text(card.subtitle).font(.system(size: 9)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if card.isRefreshing {
                    ProgressView().controlSize(.mini)
                }
                if card.needsConnection {
                    Button(card.id == .codex ? "设置" : (card.id == .grok ? "连接" : "登录"), action: onConnect)
                        .font(.system(size: 10, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(accent.opacity(0.08), in: Capsule())
                        .help("连接 \(card.title)")
                }
            }

            if let reading = card.reading, !reading.metrics.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(reading.metrics.enumerated()), id: \.element.id) { index, metric in
                        metricView(metric, primary: index == 0)
                    }
                }
                .opacity(card.isStale || card.needsConnection ? 0.7 : 1)

                HStack(spacing: 4) {
                    if card.isStale || card.needsConnection {
                        Image(systemName: "clock.badge.exclamationmark")
                        Text("上次读取")
                    } else {
                        Image(systemName: "clock")
                        Text("更新于")
                    }
                    Text(reading.fetchedAt, format: .dateTime.month().day().hour().minute())
                    Spacer(minLength: 0)
                }
                .font(.system(size: 9))
                .foregroundStyle(statusColor)
                .help(reading.source)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("—").font(.system(size: 27, weight: .medium, design: .rounded))
                        .foregroundStyle(accent.opacity(0.55))
                    Text("尚未读取额度").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }

            if !card.status.isEmpty {
                Text(card.status)
                    .font(.system(size: 10))
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
                    .help(card.status)
            }
        }
        .padding(13)
        .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Color.black.opacity(0.035), lineWidth: 1))
    }

    @ViewBuilder
    private func metricView(_ metric: BalanceMetric, primary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.label).font(.system(size: primary ? 11 : 10)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(metric.value)
                    .font(.system(size: primary ? 24 : 13, weight: primary ? .semibold : .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(primary ? accent : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            if let fraction = metric.remainingFraction, fraction.isFinite {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(accent.opacity(0.09))
                        Capsule().fill(fraction <= 0.1 ? Color(red: 0.76, green: 0.39, blue: 0.27) : accent.opacity(0.8))
                            .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                    }
                }
                .frame(height: 5)
                .accessibilityLabel("剩余比例")
                .accessibilityValue("\(Int(min(max(fraction, 0), 1) * 100))%")
            }
            if let reset = metric.resetsAt {
                HStack(spacing: 3) {
                    Text("重置")
                    Text(reset, format: .dateTime.month().day().hour().minute())
                }
                .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}
