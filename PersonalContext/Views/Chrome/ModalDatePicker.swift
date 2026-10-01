import SwiftUI

struct ModalDateField: View {
    @Binding var date: Date
    var includesTime: Bool
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ModalCalendarPanel(date: $date, includesTime: includesTime) {
                isPresented = false
            }
        }
    }

    private var label: String {
        if includesTime {
            date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
        } else {
            date.formatted(.dateTime.month(.abbreviated).day().year())
        }
    }
}

struct ModalCalendarPanel: View {
    @Binding var date: Date
    var includesTime: Bool
    var onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var app
    @State private var month = Calendar.current.startOfMonth(for: .now)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            weekdayRow
            dayGrid
            if includesTime {
                timeRow
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            month = calendar.startOfMonth(for: date)
        }
        .onChange(of: date) { _, newDate in
            let next = calendar.startOfMonth(for: newDate)
            if next != month { month = next }
        }
        .onExitCommand(perform: onDismiss)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(CraftFont.section)
            Spacer(minLength: 8)
            headerButton("chevron.left", "Previous month") { moveMonth(-1) }
            headerButton("circle", "Today") { goToToday() }
            headerButton("chevron.right", "Next month") { moveMonth(1) }
        }
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(weekdays, id: \.self) { day in
                Text(day)
                    .font(CraftFont.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var dayGrid: some View {
        let cells = monthCells
        return VStack(spacing: 4) {
            ForEach(0..<6, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { column in
                        let index = row * 7 + column
                        if index < cells.count, let day = cells[index] {
                            dayButton(day)
                        } else {
                            Color.clear.frame(height: 32)
                        }
                    }
                }
            }
        }
        .id(month)
        .transition(reduceMotion ? .opacity : .push(from: .trailing))
    }

    private var timeRow: some View {
        HStack(spacing: 8) {
            Text(date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 15))
                .monospacedDigit()
            Spacer(minLength: 8)
            timeButton("minus", -15)
            timeButton("plus", 15)
        }
        .padding(.top, 4)
    }

    private func timeButton(_ systemImage: String, _ minutes: Int) -> some View {
        Button {
            date = date.addingTimeInterval(TimeInterval(minutes * 60))
        } label: {
            Image(systemName: systemImage)
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dayButton(_ day: Date) -> some View {
        let selected = calendar.isDate(day, inSameDayAs: date)
        let today = calendar.isDateInToday(day)
        return Button {
            pick(day)
        } label: {
            Text(day.formatted(.dateTime.day()))
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .monospacedDigit()
                .foregroundStyle(selected ? Color.white : (today ? app.accent(for: .calendar) : Color.primary))
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background {
                    if selected {
                        Circle().fill(app.accent(for: .calendar))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func headerButton(_ systemImage: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(CraftFont.body)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var calendar: Calendar { .current }

    private var weekdays: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...]) + Array(symbols[..<start])
    }

    private var monthCells: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let first = interval.start
        let weekday = calendar.component(.weekday, from: first)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let days = calendar.range(of: .day, in: .month, for: month)?.count ?? 0
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for day in 0..<days {
            cells.append(calendar.date(byAdding: .day, value: day, to: first))
        }
        return cells
    }

    private func pick(_ day: Date) {
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        if includesTime {
            let time = calendar.dateComponents([.hour, .minute, .second], from: date)
            parts.hour = time.hour
            parts.minute = time.minute
            parts.second = time.second
        }
        date = calendar.date(from: parts) ?? day
    }

    private func moveMonth(_ delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: month) else { return }
        withAnimation(reduceMotion ? Motion.quick : Motion.smooth) {
            month = calendar.startOfMonth(for: next)
        }
    }

    private func goToToday() {
        pick(.now)
        withAnimation(reduceMotion ? Motion.quick : Motion.smooth) {
            month = calendar.startOfMonth(for: .now)
        }
    }
}

private extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        dateInterval(of: .month, for: date)?.start ?? startOfDay(for: date)
    }
}
