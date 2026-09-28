import SwiftUI

private let panel = Color(red: 0.09, green: 0.105, blue: 0.14)
private let muted = Color(red: 0.55, green: 0.60, blue: 0.68)

struct Dashboard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var weather: WeatherService
    @ObservedObject var codex: CodexUsageService

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            touchBarPreview
            HStack(spacing: 14) {
                metricCard(.temperature, caption: model.sample?.temperatureCelsius == nil ? "传感器暂不可用" : "芯片内部 · 最高温度")
                metricCard(.cpu, caption: "全部核心 · 每 2 秒更新")
                metricCard(.memory, caption: model.memoryDescription)
            }
            HStack(alignment: .top, spacing: 14) {
                weatherCard
                batteryCard.frame(width: 250)
            }
            if let selected = model.selectedMetric {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: selected.symbol).foregroundColor(selected.color)
                    Text(model.detail(selected)).font(.system(size: 11)).foregroundColor(muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.returnToOverview?() } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundColor(muted)
                }
                .padding(12).background(panel.opacity(0.7)).cornerRadius(10)
            }
            footer
        }
        .padding(26)
        .frame(minWidth: 850, maxWidth: .infinity, minHeight: 640, alignment: .top)
        .background(
            ZStack {
                Color(red: 0.045, green: 0.055, blue: 0.078)
                RadialGradient(colors: [Color.blue.opacity(0.10), .clear], center: .topTrailing, startRadius: 0, endRadius: 520)
            }
        )
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center) {
            ZStack {
                RoundedRectangle(cornerRadius: 13).fill(LinearGradient(colors: [Color(red: 0.34, green: 0.46, blue: 0.98), Color(red: 0.58, green: 0.40, blue: 0.84)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "waveform.path.ecg").font(.system(size: 24, weight: .medium)).foregroundColor(.white)
            }.frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text("PulseBar").font(.system(size: 25, weight: .semibold, design: .rounded)).foregroundColor(.white)
                    Text("TOUCH BAR").font(.system(size: 9, weight: .bold)).tracking(2).foregroundColor(muted)
                }
                Text("Mac 的状态，一触即知。").font(.system(size: 12)).foregroundColor(muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 6) {
                    Circle().fill(model.isPaused ? Color.gray : Color.green).frame(width: 5, height: 5)
                    Text(model.isPaused ? "已暂停采样" : "实时监测").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.85))
                }
                Text("Apple M2  /  \(model.sample.map { "\($0.memoryTotalBytes / 1_073_741_824) GB" } ?? "—")").font(.system(size: 10, design: .monospaced)).foregroundColor(muted)
            }
        }
    }

    private var touchBarPreview: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("你的 Touch Bar").font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.9))
                Text("点击指标，查看详情").font(.system(size: 10)).foregroundColor(muted)
                Spacer()
                Button {
                    if model.touchBarVisible { model.hideBar?() } else { model.showBar?() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.touchBarVisible ? "rectangle.slash" : "rectangle.bottomthird.inset.filled")
                        Text(model.touchBarVisible ? "恢复系统触控栏" : "显示到 Touch Bar")
                    }.font(.system(size: 10, weight: .medium))
                }.buttonStyle(.plain).foregroundColor(Color(red: 0.65, green: 0.75, blue: 1))
            }
            HStack {
                Spacer(minLength: 0)
                TouchBarPreview(model: model)
                    .frame(width: TouchBarLayout.width, height: 30)
                Spacer(minLength: 0)
            }.padding(.vertical, 12).padding(.horizontal, 10).background(Color.black).cornerRadius(13)
            HStack(spacing: 5) {
                Circle().fill(model.touchBarVisible ? Color.green.opacity(0.7) : muted).frame(width: 4, height: 4)
                Text(model.touchBarMessage).font(.system(size: 10)).foregroundColor(muted)
            }
        }.padding(16).background(panel).cornerRadius(16)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.055), lineWidth: 1))
    }

    private func metricCard(_ kind: MetricKind, caption: String) -> some View {
        Button { if model.selectedMetric == kind { model.returnToOverview?() } else { model.selectMetric(kind) } } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(kind.title, systemImage: kind.symbol).font(.system(size: 11, weight: .medium)).foregroundColor(kind.color)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundColor(muted)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(model.value(kind)).font(.system(size: 39, weight: .medium, design: .rounded)).monospacedDigit().foregroundColor(.white)
                    Text(kind == .temperature ? "°C" : "%").font(.system(size: 16)).foregroundColor(muted)
                    Spacer()
                    if kind == .temperature {
                        Text(model.sample?.thermalState ?? "读取中")
                            .font(.system(size: 9, weight: .medium)).foregroundColor(kind.color)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(kind.color.opacity(0.09)).cornerRadius(6)
                    }
                }
                Sparkline(values: model.history[kind, default: []], color: kind.color, fixedMaximum: kind == .temperature ? nil : 100)
                    .frame(height: 29)
                Text(caption).font(.system(size: 10)).foregroundColor(muted).lineLimit(1)
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading).background(panel).cornerRadius(15)
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(model.selectedMetric == kind ? kind.color.opacity(0.6) : .white.opacity(0.055), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private var weatherCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.weatherRegion, systemImage: "location").font(.system(size: 11, weight: .medium)).foregroundColor(MetricKind.weather.color)
                Spacer()
                Text("自动定位 · 每 5 分钟更新").font(.system(size: 10)).foregroundColor(muted)
            }
            HStack(spacing: 16) {
                Image(systemName: weather.snapshot?.symbol ?? "location.circle")
                    .symbolRenderingMode(.hierarchical).font(.system(size: 39, weight: .light))
                    .foregroundColor(MetricKind.weather.color).frame(width: 53)
                if let w = weather.snapshot {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(model.value(.weather)).font(.system(size: 34, weight: .medium, design: .rounded)).monospacedDigit()
                        Text("°C").font(.system(size: 14)).foregroundColor(muted)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(w.city.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(w.summary).font(.system(size: 11)).foregroundColor(muted)
                        if let feel = w.apparentTemperatureCelsius {
                            Text(String(format: "体感 %.0f°", feel) + (w.humidity.map { String(format: " · 湿度 %.0f%%", $0) } ?? "")).font(.system(size: 10)).foregroundColor(muted)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(weather.isLoading ? "正在自动获取天气" : "等待自动更新天气").font(.system(size: 15, weight: .medium))
                        Text("自动获取系统位置，无需点击刷新")
                            .font(.system(size: 11)).foregroundColor(MetricKind.weather.color)
                    }
                }
                Spacer(minLength: 0)
            }.frame(height: 55)
            HStack {
                Text(weather.status).font(.system(size: 9)).foregroundColor(weather.isStale ? Color.orange.opacity(0.85) : muted).lineLimit(2)
                Spacer()
                Link("Open-Meteo", destination: URL(string: "https://open-meteo.com/")!).font(.system(size: 9)).foregroundColor(muted)
            }.frame(height: 24, alignment: .bottom)
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading).background(panel).cornerRadius(15)
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.055), lineWidth: 1))
    }

    private var batteryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("电量", systemImage: model.batteryState.symbol)
                    .font(.system(size: 11, weight: .medium)).foregroundColor(MetricKind.battery.color)
                Spacer()
                Text((model.batterySample?.onACPower ?? model.sample?.onACPower) == true ? "AC" : "BAT")
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(muted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(model.value(.battery)).font(.system(size: 34, weight: .medium, design: .rounded)).monospacedDigit()
                Text("%").font(.system(size: 14)).foregroundColor(muted)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.batteryEstimate.caption).font(.system(size: 9)).foregroundColor(muted)
                    if case .restored = model.batteryEstimate {
                        BoltMark().fill(MetricKind.battery.color)
                            .frame(width: 15, height: 20)
                            .accessibilityLabel("电量已经恢复")
                    } else {
                        Text(model.batteryEstimate.text).font(.system(size: 20, weight: .medium, design: .rounded))
                            .monospacedDigit().foregroundColor(MetricKind.battery.color)
                    }
                }.help(model.batteryEstimate.accessibilityDescription)
            }.frame(height: 38)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.06))
                    Capsule().fill(MetricKind.battery.color).frame(width: geo.size.width * min(1, max(0, (model.number(.battery) ?? 0) / 100)))
                }
            }.frame(height: 4)
            Text(model.batteryDescription).font(.system(size: 9.5)).foregroundColor(muted).lineLimit(2)
                .frame(height: 26, alignment: .bottom)
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading).background(panel).cornerRadius(15)
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.055), lineWidth: 1))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("登录时启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) }))
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10)).foregroundColor(muted)
                Spacer()
                Text("关闭窗口后仍在菜单栏运行").font(.system(size: 10)).foregroundColor(muted)
                Text("·").foregroundColor(muted)
                Text("v2.9.1").font(.system(size: 10, design: .monospaced)).foregroundColor(muted)
            }
            if !model.loginMessage.isEmpty { Text(model.loginMessage).font(.system(size: 10)).foregroundColor(.orange) }
        }
    }
}

private struct BoltMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.58, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.57))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.57))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.29, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.82, y: rect.minY + rect.height * 0.42))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.55, y: rect.minY + rect.height * 0.42))
        path.closeSubpath()
        return path
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color
    var fixedMaximum: Double?
    var body: some View {
        GeometryReader { geo in
            let minValue = fixedMaximum == nil ? max(0, (values.min() ?? 0) - 5) : 0
            let maxValue = fixedMaximum ?? max(minValue + 10, (values.max() ?? 10) + 5)
            let pts = values.enumerated().map { i, value in
                CGPoint(x: geo.size.width * Double(i) / Double(max(values.count - 1, 1)),
                        y: geo.size.height * (1 - min(1, max(0, (value - minValue) / (maxValue - minValue)))))
            }
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: geo.size.height - 1))
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height - 1))
                }.stroke(.white.opacity(0.04), lineWidth: 1)
                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: geo.size.height))
                        p.closeSubpath()
                    }.fill(LinearGradient(colors: [color.opacity(0.2), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { p in p.addLines(pts) }.stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}
