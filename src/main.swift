import EventKit
import Foundation

// MARK: - 全局

let store = EKEventStore()

func skillRoot() -> URL {
    let raw = CommandLine.arguments[0]
    let path = raw.hasPrefix("/") ? raw : FileManager.default.currentDirectoryPath + "/" + raw
    let exe = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let parent = exe.deletingLastPathComponent()
    let grandParent = parent.deletingLastPathComponent()
    // 走 .app 启动时：…/CalendarHelper.app/Contents/MacOS/calendar → 跳出 .app
    if parent.lastPathComponent == "MacOS", grandParent.lastPathComponent == "Contents" {
        return grandParent.deletingLastPathComponent().deletingLastPathComponent()
    }
    return grandParent
}

func loadConfig() -> [String: Any] {
    let url = skillRoot().appendingPathComponent("config.json")
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return obj
}

let config = loadConfig()
let timeZone: TimeZone = (config["timezone"] as? String).flatMap { TimeZone(identifier: $0) } ?? TimeZone.current

// MARK: - 输出

/// 通过 `open` 启动时 stdout 拿不到，结果写到 --out 指定的文件里。
var outPath: String?

func emit(_ text: String) {
    let payload = text + "\n"
    if let outPath {
        try? Data(payload.utf8).write(to: URL(fileURLWithPath: outPath))
    } else {
        FileHandle.standardOutput.write(Data(payload.utf8))
    }
}

func jsonOut(_ object: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        emit("{\"ok\":false,\"error\":\"encode_failed\"}")
        return
    }
    emit(text)
}

func fail(_ code: String, _ message: String, extra: [String: Any] = [:], exitCode: Int32 = 2) -> Never {
    var payload: [String: Any] = ["ok": false, "error": code, "message": message]
    for (key, value) in extra { payload[key] = value }
    jsonOut(payload)
    exit(exitCode)
}

// MARK: - 时间

let isoParser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

let isoPrinter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = timeZone
    return f
}()

func parseDate(_ text: String) -> Date? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    if let date = isoParser.date(from: trimmed) { return date }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
        formatter.dateFormat = pattern
        if let date = formatter.date(from: trimmed) { return date }
    }
    return nil
}

func stamp(_ date: Date?) -> String {
    guard let date else { return "" }
    return isoPrinter.string(from: date)
}

// MARK: - 权限

func accessStatus() -> String {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess: return "fullAccess"
    case .writeOnly: return "writeOnly"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    case .authorized: return "authorized"
    @unknown default: return "unknown"
    }
}

func hasReadAccess() -> Bool {
    let status = accessStatus()
    return status == "fullAccess" || status == "authorized"
}

final class Flag: @unchecked Sendable {
    var value = false
}

func requestAccess(timeout: TimeInterval) -> Bool {
    let flag = Flag()
    let semaphore = DispatchSemaphore(value: 0)
    if #available(macOS 14.0, *) {
        store.requestFullAccessToEvents { granted, _ in
            flag.value = granted
            semaphore.signal()
        }
    } else {
        store.requestAccess(to: .event) { granted, _ in
            flag.value = granted
            semaphore.signal()
        }
    }
    if semaphore.wait(timeout: .now() + timeout) == .timedOut { return false }
    return flag.value
}

let permissionHint = "系统设置 → 隐私与安全性 → 日历 → 勾选 DeepSeek Harness；然后重新运行本命令"

func requireReadAccess() {
    if hasReadAccess() { return }
    let status = accessStatus()
    if status == "notDetermined" {
        if requestAccess(timeout: 120) && hasReadAccess() { return }
        fail("needs_permission", "尚未获得日历访问权限（授权弹窗未点『允许』或已超时）",
             extra: ["status": accessStatus(), "hint": permissionHint], exitCode: 3)
    }
    fail("no_permission", "日历访问被拒绝", extra: ["status": status, "hint": permissionHint], exitCode: 3)
}

// MARK: - 日历

func sourceKind(_ type: EKSourceType) -> String {
    switch type {
    case .local: return "Local"
    case .exchange: return "Exchange"
    case .calDAV: return "CalDAV"
    case .mobileMe: return "MobileMe"
    case .subscribed: return "Subscribed"
    case .birthdays: return "Birthdays"
    @unknown default: return "Unknown"
    }
}

func calendarJSON(_ calendar: EKCalendar, isDefault: Bool = false) -> [String: Any] {
    return [
        "id": calendar.calendarIdentifier,
        "title": calendar.title,
        "source": calendar.source?.title ?? "",
        "source_type": calendar.source.map { sourceKind($0.sourceType) } ?? "",
        "syncs_to_icloud": (calendar.source?.sourceType == .calDAV),
        "writable": calendar.allowsContentModifications,
        "is_default": isDefault,
    ]
}

func resolveCalendar(_ spec: String?) -> EKCalendar {
    let all = store.calendars(for: .event)
    let wanted = spec ?? (config["calendar"] as? String) ?? ""
    if !wanted.isEmpty {
        if let exact = all.first(where: { $0.calendarIdentifier == wanted }) { return exact }
        let byTitle = all.filter { $0.title == wanted }
        if byTitle.count == 1 { return byTitle[0] }
        if byTitle.count > 1 {
            fail("ambiguous_calendar", "有多个名为「\(wanted)」的日历，请改用日历 id",
                 extra: ["candidates": byTitle.map { calendarJSON($0) }])
        }
        fail("calendar_not_found", "找不到日历：\(wanted)",
             extra: ["available": all.map { calendarJSON($0) }])
    }
    guard let fallback = store.defaultCalendarForNewEvents else {
        fail("no_calendar", "系统里没有可用日历", extra: ["available": all.map { calendarJSON($0) }])
    }
    return fallback
}

// MARK: - 参数

struct Args {
    var flags: Set<String> = []
    var values: [String: String] = [:]
    var positional: [String] = []
}

func parseArgs(_ raw: [String]) -> Args {
    var args = Args()
    var index = 0
    while index < raw.count {
        let token = raw[index]
        if token.hasPrefix("--") {
            let key = String(token.dropFirst(2))
            if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                args.values[key] = raw[index + 1]
                index += 2
            } else {
                args.flags.insert(key)
                index += 1
            }
        } else {
            args.positional.append(token)
            index += 1
        }
    }
    return args
}

// MARK: - 事件构造

func makeRecurrence(_ spec: [String: Any]) -> EKRecurrenceRule? {
    guard let raw = (spec["freq"] as? String)?.uppercased() else { return nil }
    let frequency: EKRecurrenceFrequency
    switch raw {
    case "DAILY": frequency = .daily
    case "WEEKLY": frequency = .weekly
    case "MONTHLY": frequency = .monthly
    case "YEARLY": frequency = .yearly
    default: return nil
    }
    let interval = max(1, spec["interval"] as? Int ?? 1)
    var end: EKRecurrenceEnd?
    if let count = spec["count"] as? Int, count > 0 {
        end = EKRecurrenceEnd(occurrenceCount: count)
    } else if let untilText = spec["until"] as? String, let until = parseDate(untilText) {
        end = EKRecurrenceEnd(end: until)
    }
    var weekdays: [EKRecurrenceDayOfWeek] = []
    if let byday = spec["byday"] as? [String] {
        let map: [String: EKWeekday] = [
            "SU": .sunday, "MO": .monday, "TU": .tuesday, "WE": .wednesday,
            "TH": .thursday, "FR": .friday, "SA": .saturday,
        ]
        for day in byday {
            if let weekday = map[day.uppercased()] {
                weekdays.append(EKRecurrenceDayOfWeek(weekday))
            }
        }
    }
    return EKRecurrenceRule(
        recurrenceWith: frequency,
        interval: interval,
        daysOfTheWeek: weekdays.isEmpty ? nil : weekdays,
        daysOfTheMonth: nil,
        monthsOfTheYear: nil,
        weeksOfTheYear: nil,
        daysOfTheYear: nil,
        setPositions: nil,
        end: end
    )
}

func matchExisting(title: String, start: Date, end: Date, calendar: EKCalendar) -> EKEvent? {
    let predicate = store.predicateForEvents(
        withStart: start.addingTimeInterval(-3600),
        end: end.addingTimeInterval(3600),
        calendars: [calendar]
    )
    let normalized = title.lowercased()
    return store.events(matching: predicate).first { event in
        guard let eventTitle = event.title else { return false }
        let sameTitle = eventTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        guard let eventStart = event.startDate else { return false }
        return sameTitle && abs(eventStart.timeIntervalSince(start)) < 60
    }
}

// MARK: - 命令

var argv = Array(CommandLine.arguments.dropFirst())
if let outIndex = argv.firstIndex(of: "--out"), outIndex + 1 < argv.count {
    outPath = argv[outIndex + 1]
    argv.removeSubrange(outIndex...(outIndex + 1))
}
guard let command = argv.first else {
    fail("usage", "用法: calendar <status|calendars|add|list|delete> [选项]", exitCode: 0)
}
argv.removeFirst()

switch command {
case "status":
    jsonOut([
        "ok": true,
        "status": accessStatus(),
        "has_read_access": hasReadAccess(),
        "timezone": timeZone.identifier,
        "default_calendar": store.defaultCalendarForNewEvents.map { ["id": $0.calendarIdentifier, "title": $0.title, "source": $0.source?.title ?? ""] } ?? NSNull(),
    ])

case "calendars":
    requireReadAccess()
    let all = store.calendars(for: .event)
    let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier
    jsonOut([
        "ok": true,
        "count": all.count,
        "calendars": all.map { calendarJSON($0, isDefault: $0.calendarIdentifier == defaultID) },
    ])

case "add":
    let args = parseArgs(argv)
    guard let file = args.values["file"] else {
        fail("usage", "用法: calendar add --file plan.json [--calendar <id|名称>] [--dry-run]")
    }
    requireReadAccess()
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else {
        fail("bad_file", "读不到文件：\(file)")
    }
    let parsed = try? JSONSerialization.jsonObject(with: data)
    let root: [String: Any]
    var items: [[String: Any]] = []
    if let dict = parsed as? [String: Any] {
        root = dict
        items = dict["events"] as? [[String: Any]] ?? []
    } else if let array = parsed as? [[String: Any]] {
        root = [:]
        items = array
    } else {
        fail("bad_file", "文件既不是 JSON 对象也不是数组：\(file)")
    }
    guard !items.isEmpty else { fail("empty_plan", "plan 里没有 events") }

    let spec = args.values["calendar"] ?? (root["calendar"] as? String) ?? (config["calendar"] as? String)
    let calendar = resolveCalendar(spec)
    guard calendar.allowsContentModifications else {
        fail("readonly_calendar", "日历「\(calendar.title)」不可写", extra: ["calendar": calendarJSON(calendar)])
    }
    let dryRun = args.flags.contains("dry-run")

    var added: [[String: Any]] = []
    var skipped: [[String: Any]] = []
    var failed: [[String: Any]] = []

    for (index, item) in items.enumerated() {
        let title = (item["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            failed.append(["index": index, "error": "title 为空"])
            continue
        }
        guard let startText = item["start"] as? String, let start = parseDate(startText) else {
            failed.append(["index": index, "title": title, "error": "start 缺失或无法解析：\(item["start"] as? String ?? "nil")"])
            continue
        }
        let allDay = item["all_day"] as? Bool ?? false
        var end: Date
        if let endText = item["end"] as? String, let parsedEnd = parseDate(endText) {
            end = parsedEnd
        } else if allDay {
            end = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        } else {
            end = start.addingTimeInterval(3600)
        }
        if end <= start {
            end = start.addingTimeInterval(allDay ? 86400 : 3600)
        }

        let summary: [String: Any] = [
            "title": title,
            "start": stamp(start),
            "end": stamp(end),
            "all_day": allDay,
        ]

        if let existing = matchExisting(title: title, start: start, end: end, calendar: calendar) {
            var record = summary
            record["reason"] = "日历里已有同名同时间事件"
            record["existing_id"] = existing.eventIdentifier ?? ""
            skipped.append(record)
            continue
        }
        if dryRun {
            var record = summary
            record["would_add"] = true
            added.append(record)
            continue
        }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = allDay
        if let location = item["location"] as? String, !location.isEmpty { event.location = location }
        if let notes = item["notes"] as? String, !notes.isEmpty { event.notes = notes }
        if let alarms = item["alarms"] as? [Int] {
            for minutes in alarms {
                event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutes * 60)))
            }
        }
        if let repeatSpec = item["repeat"] as? [String: Any], let rule = makeRecurrence(repeatSpec) {
            event.addRecurrenceRule(rule)
        }

        do {
            try store.save(event, span: .thisEvent)
            var record = summary
            record["id"] = event.eventIdentifier ?? ""
            record["calendar"] = calendar.title
            added.append(record)
        } catch {
            var record = summary
            record["error"] = error.localizedDescription
            failed.append(record)
        }
    }

    jsonOut([
        "ok": failed.isEmpty,
        "dry_run": dryRun,
        "calendar": calendarJSON(calendar),
        "added": added,
        "skipped": skipped,
        "failed": failed,
    ])

case "list":
    let args = parseArgs(argv)
    requireReadAccess()
    let calendar = resolveCalendar(args.values["calendar"])
    let from = parseDate(args.values["from"] ?? "") ?? Date()
    let to = parseDate(args.values["to"] ?? "") ?? Calendar(identifier: .gregorian).date(byAdding: .day, value: 30, to: from) ?? from
    guard to > from else { fail("bad_range", "--to 必须晚于 --from") }
    let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [calendar])
    let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    jsonOut([
        "ok": true,
        "calendar": calendar.title,
        "from": stamp(from),
        "to": stamp(to),
        "count": events.count,
        "events": events.map { event -> [String: Any] in
            [
                "id": event.eventIdentifier ?? "",
                "title": event.title ?? "",
                "start": stamp(event.startDate),
                "end": stamp(event.endDate),
                "all_day": event.isAllDay,
                "location": event.location ?? "",
                "notes": event.notes ?? "",
                "recurring": event.hasRecurrenceRules,
            ]
        },
    ])

case "delete":
    let args = parseArgs(argv)
    guard let id = args.values["id"] else { fail("usage", "用法: calendar delete --id <事件ID>") }
    requireReadAccess()
    guard let event = store.event(withIdentifier: id) else {
        fail("not_found", "找不到事件：\(id)")
    }
    let summary: [String: Any] = [
        "id": id,
        "title": event.title ?? "",
        "start": stamp(event.startDate),
        "calendar": event.calendar?.title ?? "",
    ]
    do {
        try store.remove(event, span: .thisEvent)
        jsonOut(["ok": true, "deleted": summary])
    } catch {
        fail("delete_failed", error.localizedDescription, extra: ["event": summary])
    }

default:
    fail("unknown_command", "未知命令：\(command)，可用：status / calendars / add / list / delete")
}
