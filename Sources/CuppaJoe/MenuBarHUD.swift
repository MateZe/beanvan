import AppKit
import CoffeeProtocol
import Combine
import SwiftUI

@MainActor
enum CuppaJoeDesign {
    static let brandTeal = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.31, green: 0.78, blue: 0.65, alpha: 1)
            : NSColor(srgbRed: 0.07, green: 0.50, blue: 0.40, alpha: 1)
    })
    static let proposalTint = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.08, green: 0.25, blue: 0.21, alpha: 1)
            : NSColor(srgbRed: 0.84, green: 0.95, blue: 0.92, alpha: 1)
    })
    static let darkMenuBarTeal = Color(red: 0.35, green: 0.82, blue: 0.68)
    static let popoverWidth: CGFloat = 320
}

@MainActor
enum TruckTemplateImage {
    private static let idle = makeImage(steam: false)
    private static let steaming = makeImage(steam: true)

    static func image(steam: Bool) -> NSImage {
        steam ? steaming : idle
    }

    private static func makeImage(steam: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            let body = NSBezierPath()
            body.move(to: NSPoint(x: 1.2, y: 4.4))
            body.line(to: NSPoint(x: 1.2, y: 9.1))
            body.curve(
                to: NSPoint(x: 3.1, y: 11),
                controlPoint1: NSPoint(x: 1.2, y: 10.4),
                controlPoint2: NSPoint(x: 1.8, y: 11)
            )
            body.line(to: NSPoint(x: 13.4, y: 11))
            body.line(to: NSPoint(x: 15.7, y: 8.5))
            body.line(to: NSPoint(x: 19.3, y: 8.5))
            body.line(to: NSPoint(x: 21, y: 6.8))
            body.line(to: NSPoint(x: 21, y: 4.4))
            body.close()
            body.lineWidth = 1.7
            body.lineJoinStyle = .round
            body.stroke()

            for wheelRect in [
                NSRect(x: 3.1, y: 1.3, width: 4.2, height: 4.2),
                NSRect(x: 15.7, y: 1.3, width: 4.2, height: 4.2),
            ] {
                let wheel = NSBezierPath(ovalIn: wheelRect)
                wheel.lineWidth = 1.7
                wheel.stroke()
            }

            let cup = NSBezierPath()
            cup.move(to: NSPoint(x: 5, y: 10.7))
            cup.line(to: NSPoint(x: 5, y: 13.2))
            cup.curve(
                to: NSPoint(x: 11.4, y: 13.2),
                controlPoint1: NSPoint(x: 5, y: 16.2),
                controlPoint2: NSPoint(x: 11.4, y: 16.2)
            )
            cup.line(to: NSPoint(x: 11.4, y: 10.7))
            cup.lineWidth = 1.7
            cup.lineCapStyle = .square
            cup.stroke()
            let lid = NSBezierPath()
            lid.move(to: NSPoint(x: 4.5, y: 10.7))
            lid.line(to: NSPoint(x: 12, y: 10.7))
            lid.lineWidth = 1.7
            lid.stroke()
            let handle = NSBezierPath(ovalIn: NSRect(x: 10.8, y: 11, width: 3.4, height: 2.6))
            handle.lineWidth = 1.4
            handle.stroke()

            if steam {
                for x in [7.1, 9.7] {
                    let line = NSBezierPath()
                    line.move(to: NSPoint(x: x, y: 15.8))
                    line.curve(
                        to: NSPoint(x: x + 0.3, y: 15.8),
                        controlPoint1: NSPoint(x: x - 0.5, y: 14.5),
                        controlPoint2: NSPoint(x: x + 0.8, y: 15.1)
                    )
                    line.lineWidth = 1
                    line.lineCapStyle = .round
                    line.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

enum MenuBarIconState {
    static func showsSteam(
        at date: Date,
        nextFireDate: Date?,
        peerCount: Int,
        isSkippingToday: Bool
    ) -> Bool {
        guard !isSkippingToday, peerCount > 0, let nextFireDate else { return false }
        let remaining = nextFireDate.timeIntervalSince(date)
        return remaining > 0 && remaining <= 5 * 60
    }

    static func truckOpacity(isSkippingToday: Bool) -> Double {
        isSkippingToday ? 0.4 : 1
    }
}

enum TimeComponentInput {
    static func digits(from text: String) -> String {
        String(text.filter { $0 >= "0" && $0 <= "9" }.prefix(2))
    }

    static func normalized(
        _ text: String,
        maximum: Int,
        fallback: Int
    ) -> (value: Int, text: String) {
        let value = min(max(Int(text) ?? fallback, 0), maximum)
        return (value, String(format: "%02d", value))
    }
}

struct MenuBarTruckIcon: View {
    @ObservedObject var peerManager: PeerManager
    @ObservedObject var scheduler: ScheduleFiringScheduler
    @ObservedObject var proposalStore: ProposalStore
    @State private var bounceScale = 1.0
    @State private var currentDate = Date()
    @Environment(\.colorScheme) private var colorScheme

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: TruckTemplateImage.image(
                steam: shouldShowSteam(at: currentDate)
            ))
            .opacity(MenuBarIconState.truckOpacity(
                isSkippingToday: scheduler.isSkippingToday
            ))
            .scaleEffect(bounceScale)

            if !proposalStore.activeProposals.isEmpty {
                Circle()
                    .fill(colorScheme == .dark
                        ? CuppaJoeDesign.darkMenuBarTeal
                        : CuppaJoeDesign.brandTeal)
                    .frame(width: 5, height: 5)
                    .offset(x: 1, y: -1)
            }
        }
        .frame(width: 23, height: 18)
        .onReceive(clock) { currentDate = $0 }
        .onChange(of: proposalStore.hasIncomingProposalSignal) { wasActive, isActive in
            guard isActive, !wasActive else { return }
            bounceScale = 0.82
            withAnimation(.spring(duration: 0.4, bounce: 0.28)) {
                bounceScale = 1
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private func shouldShowSteam(at date: Date) -> Bool {
        MenuBarIconState.showsSteam(
            at: date,
            nextFireDate: scheduler.nextFireDate,
            peerCount: peerManager.presentPeers.count,
            isSkippingToday: scheduler.isSkippingToday
        )
    }

    private var accessibilityLabel: String {
        if scheduler.isSkippingToday { return "CuppaJoe, skipping today" }
        if !proposalStore.activeProposals.isEmpty { return "CuppaJoe, coffee proposal waiting" }
        return "CuppaJoe"
    }
}

struct CoffeePopover: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var peerManager: PeerManager
    @ObservedObject var scheduleStore: ScheduleStore
    @ObservedObject var scheduler: ScheduleFiringScheduler
    @ObservedObject var proposalStore: ProposalStore
    let previewAnimation: () -> Void
    @State private var isShowingSettings = false

    private var displayedProposal: ActiveCoffeeProposal? {
        proposalStore.activeProposals.first
    }

    var body: some View {
        Group {
            if isShowingSettings {
                PopoverSettingsView(
                    appModel: appModel,
                    proposalStore: proposalStore,
                    dismiss: { isShowingSettings = false }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let proposal = displayedProposal {
                            ProposalCard(proposal: proposal, proposalStore: proposalStore)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        StatusHeader(scheduler: scheduler)
                        PresenceSection(peers: peerManager.presentPeers)
                        Divider()
                        ScheduleEditor(scheduleStore: scheduleStore)

                        if let event = scheduleStore.latestChangeEvent {
                            AttributionLine(event: event)
                        }

                        Divider()
                        ActionsSection(scheduler: scheduler, proposalStore: proposalStore)
                        Divider()
                        UtilityFooter(
                            previewAnimation: previewAnimation,
                            showSettings: { isShowingSettings = true }
                        )
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: CuppaJoeDesign.popoverWidth)
        .background(.regularMaterial)
        .animation(.easeOut(duration: 0.2), value: displayedProposal?.id)
        .animation(.easeOut(duration: 0.18), value: isShowingSettings)
    }
}

private struct ProposalCard: View {
    let proposal: ActiveCoffeeProposal
    @ObservedObject var proposalStore: ProposalStore

    private var isMine: Bool {
        proposal.proposal.proposer == proposalStore.localInstanceID
    }

    private var hasAccepted: Bool {
        proposal.participantIDs.contains(proposalStore.localInstanceID)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 10) {
                if isMine {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your proposal")
                                .font(.system(size: 14, weight: .semibold))
                            Text("\(countText) · \(expiryText(at: context.date))")
                        }
                        Spacer(minLength: 4)
                        Button("Cancel") {
                            proposalStore.cancel(proposal.id)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(CuppaJoeDesign.brandTeal)
                    }
                } else {
                    Text("\(proposal.proposerName) proposes coffee")
                        .font(.system(size: 14, weight: .medium))
                    HStack {
                        Text(countText)
                        Spacer()
                        Text(expiryText(at: context.date))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if !isMine {
                    if hasAccepted {
                        Button("You're in ✓") {}
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .disabled(true)
                    } else {
                        Button {
                            proposalStore.accept(proposal.id)
                        } label: {
                            Text("I'm in")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(CuppaJoeDesign.brandTeal)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                CuppaJoeDesign.proposalTint,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .foregroundStyle(.primary)
        }
    }

    private var countText: String {
        "\(proposal.participantCount) of \(proposalStore.quorumThreshold) in"
    }

    private func expiryText(at date: Date) -> String {
        let expiry = Date(
            timeIntervalSince1970: TimeInterval(proposal.proposal.expiresAt) / 1_000
        )
        return "expires in \(CompactDuration.until(expiry, from: date))"
    }
}

private struct StatusHeader: View {
    @ObservedObject var scheduler: ScheduleFiringScheduler

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                        if scheduler.isSkippingToday {
                            Image(systemName: "moon")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    Spacer()
                    if let nextFireDate = scheduler.nextFireDate,
                       !scheduler.isSkippingToday {
                        Text("in \(CompactDuration.until(nextFireDate, from: context.date))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if scheduler.isSkippingToday {
                    Text("Back tomorrow · not visible to teammates")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var title: String {
        if scheduler.isSkippingToday { return "Skipping today" }
        guard let date = scheduler.nextFireDate else { return "No coffee scheduled" }
        return "Next coffee · \(date.formatted(date: .omitted, time: .shortened))"
    }
}

private struct PresenceSection: View {
    let peers: [PresentPeer]

    var body: some View {
        HStack(spacing: 9) {
            if !peers.isEmpty {
                HStack(spacing: -6) {
                    ForEach(Array(peers.prefix(5))) { peer in
                        InitialsCircle(peer: peer)
                    }
                    if peers.count > 5 {
                        Text("+\(peers.count - 5)")
                            .font(.system(size: 9, weight: .medium))
                            .frame(width: 22, height: 22)
                            .background(.quaternary, in: Circle())
                            .overlay(Circle().stroke(.background, lineWidth: 1.5))
                    }
                }
            }

            Text(peers.isEmpty ? "Nobody around" : "\(peers.count) around")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(peers.isEmpty ? .secondary : .primary)
        }
        .help(peers.isEmpty ? "Nobody is currently visible" : peerNames)
    }

    private var peerNames: String {
        peers.map(\.name).sorted().joined(separator: ", ")
    }
}

private struct InitialsCircle: View {
    let peer: PresentPeer
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(initials)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(avatarForeground)
            .frame(width: 22, height: 22)
            .background(avatarBackground, in: Circle())
            .overlay(Circle().stroke(.background, lineWidth: 1.5))
            .help(peer.name)
    }

    private var initials: String {
        let words = peer.name.split(whereSeparator: \.isWhitespace)
        guard let first = words.first?.first else { return "?" }
        let last = words.count > 1 ? words.last?.first : nil
        return String([first, last].compactMap { $0 }).uppercased()
    }

    private var avatarBaseColor: Color {
        let byte = withUnsafeBytes(of: peer.id.uuid) { Int($0[0]) }
        let palette: [Color] = [
            Color(nsColor: .systemBlue),
            Color(nsColor: .systemPurple),
            Color(nsColor: .systemPink),
            Color(nsColor: .systemOrange),
            Color(nsColor: .systemIndigo),
            Color(nsColor: .systemGreen),
        ]
        return palette[byte % palette.count]
    }

    private var avatarBackground: Color {
        avatarBaseColor.opacity(colorScheme == .dark ? 0.7 : 0.16)
    }

    private var avatarForeground: Color {
        colorScheme == .dark ? .white : avatarBaseColor
    }
}

private struct ScheduleEditor: View {
    @ObservedObject var scheduleStore: ScheduleStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Schedule")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if scheduleStore.schedule.entries.isEmpty {
                EmptyView()
            }

            ForEach(scheduleStore.schedule.entries) { entry in
                ScheduleEntryRow(
                    entry: entry,
                    updateTime: { newTime in
                        update(entry) { $0.time = newTime }
                    },
                    toggleWeekday: { toggle($0, for: entry) },
                    remove: { remove(entry) }
                )
            }

            if scheduleStore.schedule.entries.count < Schedule.maximumEntryCount {
                Button(action: addEntry) {
                    Label("Add time", systemImage: "plus")
                }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func toggle(_ weekday: Weekday, for entry: ScheduleEntry) {
        update(entry) {
            if $0.weekdays.contains(weekday) {
                $0.weekdays.remove(weekday)
            } else {
                $0.weekdays.insert(weekday)
            }
        }
    }

    private func update(_ entry: ScheduleEntry, change: (inout ScheduleEntry) -> Void) {
        var entries = scheduleStore.schedule.entries
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        change(&entries[index])
        try? scheduleStore.replaceEntries(entries)
    }

    private func addEntry() {
        var entries = scheduleStore.schedule.entries
        guard entries.count < Schedule.maximumEntryCount else { return }
        entries.append(ScheduleEntry(
            id: UUID(),
            time: ScheduleTime(hour: 10, minute: 30),
            weekdays: [.monday, .tuesday, .wednesday, .thursday, .friday],
            lastEditedBy: UUID(),
            lastEditedAt: 0
        ))
        try? scheduleStore.replaceEntries(entries)
    }

    private func remove(_ entry: ScheduleEntry) {
        try? scheduleStore.replaceEntries(
            scheduleStore.schedule.entries.filter { $0.id != entry.id }
        )
    }
}

private struct ScheduleEntryRow: View {
    let entry: ScheduleEntry
    let updateTime: (ScheduleTime) -> Void
    let toggleWeekday: (Weekday) -> Void
    let remove: () -> Void
    @State private var hourText: String
    @State private var minuteText: String
    @State private var hourIsFocused = false
    @State private var minuteIsFocused = false

    private let weekdays: [Weekday] = [
        .sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday,
    ]

    init(
        entry: ScheduleEntry,
        updateTime: @escaping (ScheduleTime) -> Void,
        toggleWeekday: @escaping (Weekday) -> Void,
        remove: @escaping () -> Void
    ) {
        self.entry = entry
        self.updateTime = updateTime
        self.toggleWeekday = toggleWeekday
        self.remove = remove
        _hourText = State(initialValue: String(format: "%02d", entry.time.hour))
        _minuteText = State(initialValue: String(format: "%02d", entry.time.minute))
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 1) {
                TimeComponentField(
                    text: $hourText,
                    isFocused: $hourIsFocused,
                    maximum: 23,
                    accessibilityLabel: "Hour",
                    onCommit: { update(hour: $0) },
                    onAdvance: {
                        hourIsFocused = false
                        minuteIsFocused = true
                    }
                )
                Text(":")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                TimeComponentField(
                    text: $minuteText,
                    isFocused: $minuteIsFocused,
                    maximum: 59,
                    accessibilityLabel: "Minute",
                    onCommit: { update(minute: $0) },
                    onAdvance: { minuteIsFocused = false }
                )
            }
            .padding(.horizontal, 5)
            .frame(width: 66, height: 24)
            .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(.quaternary, lineWidth: 1)
            )

            HStack(spacing: 4) {
                ForEach(weekdays, id: \.self) { weekday in
                    WeekdayToggle(
                        weekday: weekday,
                        isOn: entry.weekdays.contains(weekday),
                        action: { toggleWeekday(weekday) }
                    )
                }
            }

            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 14, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove time")
        }
        .onChange(of: entry.time) { _, newTime in
            if !hourIsFocused { hourText = String(format: "%02d", newTime.hour) }
            if !minuteIsFocused { minuteText = String(format: "%02d", newTime.minute) }
        }
    }

    private func update(hour: Int? = nil, minute: Int? = nil) {
        updateTime(ScheduleTime(
            hour: hour ?? Int(hourText) ?? entry.time.hour,
            minute: minute ?? Int(minuteText) ?? entry.time.minute
        ))
    }
}

private struct TimeComponentField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let maximum: Int
    let accessibilityLabel: String
    let onCommit: (Int) -> Void
    let onAdvance: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        field.maximumNumberOfLines = 1
        field.setAccessibilityLabel(accessibilityLabel)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if !isFocused {
            context.coordinator.syncValidText(text)
        }
        if field.stringValue != text {
            field.stringValue = text
        }

        if isFocused, field.window?.firstResponder !== field.currentEditor() {
            field.window?.makeFirstResponder(field)
        } else if !isFocused, field.window?.firstResponder === field.currentEditor() {
            field.window?.makeFirstResponder(nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TimeComponentField
        private var lastValidText: String
        private var isAdvancing = false

        init(parent: TimeComponentField) {
            self.parent = parent
            lastValidText = parent.text
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
            guard let field = notification.object as? NSTextField else { return }
            DispatchQueue.main.async {
                field.currentEditor()?.selectAll(nil)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let digits = TimeComponentInput.digits(from: field.stringValue)
            if field.stringValue != digits {
                field.stringValue = digits
            }
            parent.text = digits

            guard digits.count == 2, !isAdvancing else { return }
            commit(field)
            isAdvancing = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.onAdvance()
                self.isAdvancing = false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
            guard let field = notification.object as? NSTextField else { return }
            commit(field)
        }

        @objc func submit(_ sender: NSTextField) {
            commit(sender)
            parent.onAdvance()
        }

        func syncValidText(_ text: String) {
            lastValidText = text
        }

        private func commit(_ field: NSTextField) {
            let fallback = Int(lastValidText) ?? 0
            let result = TimeComponentInput.normalized(
                field.stringValue,
                maximum: parent.maximum,
                fallback: fallback
            )
            let hasChanged = result.text != lastValidText
            lastValidText = result.text
            field.stringValue = result.text
            parent.text = result.text
            if hasChanged {
                parent.onCommit(result.value)
            }
        }
    }
}

private struct WeekdayToggle: View {
    let weekday: Weekday
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(WeekdayLabels.short(weekday))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : .secondary)
                .frame(width: 19, height: 19)
                .background(isOn ? CuppaJoeDesign.brandTeal : Color.clear, in: Circle())
                .overlay {
                    if !isOn {
                        Circle().stroke(.quaternary)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(WeekdayLabels.full(weekday))
        .accessibilityValue(isOn ? "Selected" : "Not selected")
    }
}

private struct ActionsSection: View {
    @ObservedObject var scheduler: ScheduleFiringScheduler
    @ObservedObject var proposalStore: ProposalStore

    private var hasLocalProposal: Bool {
        proposalStore.activeProposals.contains {
            $0.proposal.proposer == proposalStore.localInstanceID
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !hasLocalProposal {
                Button {
                    _ = try? proposalStore.proposeCoffeeNow()
                } label: {
                    Text("Propose coffee now")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
                .buttonStyle(.bordered)
                .disabled(!proposalStore.canPropose)

                if let cooldownEnd = proposalStore.nextProposalDate {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("again in \(CompactDuration.until(cooldownEnd, from: context.date))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            Toggle(
                "Skip today",
                isOn: Binding(
                    get: { scheduler.isSkippingToday },
                    set: { scheduler.setSkippingToday($0) }
                )
            )
            .font(.system(size: 14, weight: .semibold))
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(CuppaJoeDesign.brandTeal)
        }
    }
}

private struct AttributionLine: View {
    let event: ScheduleChangeEvent

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text("\(event.message) · \(CompactDuration.ago(event.changedAt, from: context.date))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

private struct UtilityFooter: View {
    let previewAnimation: () -> Void
    let showSettings: () -> Void

    var body: some View {
        HStack {
            Button("Preview", action: previewAnimation)
            Spacer()
            Button(action: showSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
            }
                .help("Settings")
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
    }
}

private struct PopoverSettingsView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var proposalStore: ProposalStore
    let dismiss: () -> Void
    @State private var displayName: String
    @State private var teamPhrase: String

    init(appModel: AppModel, proposalStore: ProposalStore, dismiss: @escaping () -> Void) {
        self.appModel = appModel
        self.proposalStore = proposalStore
        self.dismiss = dismiss
        _displayName = State(initialValue: appModel.displayName)
        _teamPhrase = State(initialValue: appModel.teamPhrase)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    applySettings()
                    return
                }
                applySettings()
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(.secondary)
                    Text("Settings")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
            .buttonStyle(.plain)

            SettingsFields(
                appModel: appModel,
                proposalStore: proposalStore,
                displayName: $displayName,
                teamPhrase: $teamPhrase,
                applySettings: applySettings
            )
        }
        .padding(16)
        .frame(width: CuppaJoeDesign.popoverWidth, alignment: .topLeading)
        .onDisappear(perform: applySettings)
    }

    private func applySettings() {
        appModel.applySettings(displayName: displayName, teamPhrase: teamPhrase)
    }
}

private struct SettingsFields: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var proposalStore: ProposalStore
    @Binding var displayName: String
    @Binding var teamPhrase: String
    let applySettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Display name")
                    .font(.system(size: 13, weight: .semibold))
                TextField("Display name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14, weight: .medium))
                    .controlSize(.large)
                    .onSubmit(applySettings)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Team phrase")
                    .font(.system(size: 13, weight: .semibold))
                SecureField("Leave empty for open network", text: $teamPhrase)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14, weight: .medium))
                    .controlSize(.large)
                    .onSubmit(applySettings)
                Text("Only Macs with the same phrase see each other.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Quorum")
                        .font(.system(size: 14, weight: .semibold))
                    Text("People needed for ‘coffee now’")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                QuorumControl(
                    value: proposalStore.quorumThreshold,
                    decrement: {
                        proposalStore.setQuorumThreshold(proposalStore.quorumThreshold - 1)
                    },
                    increment: {
                        proposalStore.setQuorumThreshold(proposalStore.quorumThreshold + 1)
                    }
                )
            }

            Divider()

            Toggle("Don't interrupt full-screen apps", isOn: Binding(
                get: { appModel.avoidsFullScreenApps },
                set: { value in
                    appModel.setInterruptionPreferences(
                        avoidsFullScreenApps: value,
                        avoidsCalls: appModel.avoidsCalls
                    )
                }
            ))
            .toggleStyle(.switch)

            Toggle("Don't interrupt calls", isOn: Binding(
                get: { appModel.avoidsCalls },
                set: { value in
                    appModel.setInterruptionPreferences(
                        avoidsFullScreenApps: appModel.avoidsFullScreenApps,
                        avoidsCalls: value
                    )
                }
            ))
            .toggleStyle(.switch)

            if let error = appModel.settingsError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct QuorumControl: View {
    let value: Int
    let decrement: () -> Void
    let increment: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            quorumButton(systemImage: "minus", action: decrement)
                .disabled(value <= 1)

            Divider().frame(height: 16)

            Text("\(value)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 30)
                .accessibilityLabel("Quorum")
                .accessibilityValue("\(value) people")

            Divider().frame(height: 16)

            quorumButton(systemImage: "plus", action: increment)
                .disabled(value >= 10)
        }
        .frame(height: 26)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        )
    }

    private func quorumButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(systemImage == "minus" ? "Decrease quorum" : "Increase quorum")
    }
}

struct CuppaJoeSettingsView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var proposalStore: ProposalStore
    @State private var displayName: String
    @State private var teamPhrase: String

    init(appModel: AppModel, proposalStore: ProposalStore) {
        self.appModel = appModel
        self.proposalStore = proposalStore
        _displayName = State(initialValue: appModel.displayName)
        _teamPhrase = State(initialValue: appModel.teamPhrase)
    }

    var body: some View {
        SettingsFields(
            appModel: appModel,
            proposalStore: proposalStore,
            displayName: $displayName,
            teamPhrase: $teamPhrase,
            applySettings: {
                appModel.applySettings(displayName: displayName, teamPhrase: teamPhrase)
            }
        )
        .padding(20)
        .frame(width: 340)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Apply") {
                    appModel.applySettings(displayName: displayName, teamPhrase: teamPhrase)
                }
                .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .onChange(of: appModel.displayName) { _, value in displayName = value }
        .onChange(of: appModel.teamPhrase) { _, value in teamPhrase = value }
    }
}

enum WeekdayLabels {
    static func short(_ weekday: Weekday) -> String {
        switch weekday {
        case .monday: "M"
        case .tuesday: "T"
        case .wednesday: "W"
        case .thursday: "T"
        case .friday: "F"
        case .saturday: "S"
        case .sunday: "S"
        }
    }

    static func full(_ weekday: Weekday) -> String {
        switch weekday {
        case .monday: "Monday"
        case .tuesday: "Tuesday"
        case .wednesday: "Wednesday"
        case .thursday: "Thursday"
        case .friday: "Friday"
        case .saturday: "Saturday"
        case .sunday: "Sunday"
        }
    }

    static func summary(_ weekdays: Set<Weekday>) -> String {
        let ordered = Weekday.allCases
        guard !weekdays.isEmpty else { return "No active days" }
        if weekdays == Set(ordered) { return "Every day" }

        var runs: [[Weekday]] = []
        for weekday in ordered where weekdays.contains(weekday) {
            if let last = runs.last?.last, weekday.rawValue == last.rawValue + 1 {
                runs[runs.count - 1].append(weekday)
            } else {
                runs.append([weekday])
            }
        }
        return runs.map { run in
            let first = abbreviation(run[0])
            guard run.count > 1, let last = run.last else { return first }
            return "\(first)–\(abbreviation(last))"
        }.joined(separator: ", ")
    }

    private static func abbreviation(_ weekday: Weekday) -> String {
        String(full(weekday).prefix(3))
    }
}

enum CompactDuration {
    static func until(_ date: Date, from now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = Int(ceil(Double(seconds) / 60))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    static func ago(_ date: Date, from now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}
