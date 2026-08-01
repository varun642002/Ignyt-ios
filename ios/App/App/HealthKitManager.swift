import Foundation
import HealthKit

/**
 HealthKit reads and writes for IGNYT, shaped to match what the Android HealthConnectManager
 returns so the web layer needs no changes.

 WHERE HEALTHKIT AND HEALTH CONNECT GENUINELY DIFFER

 1. Read authorisation is unknowable. iOS deliberately never tells an app whether the user
    granted a READ permission — `authorizationStatus(for:)` reports sharing (write) status
    only. A denied read type simply returns no samples, indistinguishable from "the user has
    no data". Health Connect answers this question directly, so `granted` cannot mean the
    same thing here; see HealthConnectPlugin.getPermissionStatus for exactly what it reports
    instead. Nothing in this file guesses.

 2. Permissions cannot be revoked programmatically. Health Connect exposes revokeAllPermissions;
    on iOS only the user can, in Settings › Privacy › Health. revokePermissions therefore
    reports failure rather than pretending.

 3. Basal metabolic rate is not a rate. Health Connect stores BasalMetabolicRate in kcal/day.
    HealthKit stores basalEnergyBurned as cumulative kilocalories, so what this returns is
    today's accumulated basal burn, not a projected daily figure. It is reported under the
    same `kcalPerDay` key so the UI keeps working, but the two platforms are not measuring
    the same thing and a full day must elapse before they are comparable.

 Everything else maps cleanly. Units are converted at the boundary so the JSON matches
 Android exactly: percentages come out of HealthKit as 0–1 and leave here as 0–100,
 distances are metres, mass is kilograms, temperature is Celsius.
 */
final class HealthKitManager {

    private let store = HKHealthStore()

    /// Set once the authorisation sheet has completed. iOS gives no other signal for reads.
    private static let requestedKey = "ignyt.healthkit.authorizationRequested"

    var hasRequestedAuthorization: Bool {
        get { UserDefaults.standard.bool(forKey: Self.requestedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.requestedKey) }
    }

    // MARK: - Types

    /// Read types, one per metric the Android side reads.
    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        ]
        let quantities: [HKQuantityTypeIdentifier] = [
            .stepCount, .heartRate, .bodyMass, .activeEnergyBurned, .distanceWalkingRunning,
            .respiratoryRate, .oxygenSaturation, .bloodPressureSystolic, .bloodPressureDiastolic,
            .bodyTemperature, .bodyFatPercentage, .height, .leanBodyMass, .basalEnergyBurned,
            .dietaryWater, .dietaryEnergyConsumed, .dietaryProtein, .dietaryCarbohydrates,
            .dietaryFatTotal, .dietaryFiber, .dietarySugar, .dietarySodium
        ]
        for id in quantities {
            if let t = HKObjectType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        return types
    }

    /// IGNYT writes exactly two things, matching Android: exercise sessions and weight.
    private var writeTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKObjectType.workoutType()]
        if let mass = HKObjectType.quantityType(forIdentifier: .bodyMass) { types.insert(mass) }
        return types
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: - Authorisation

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
        hasRequestedAuthorization = true
    }

    /// Write types whose status we CAN read. Reads are deliberately absent — see the header.
    func writeAuthorizationStatuses() -> [String: String] {
        var out: [String: String] = [:]
        for type in writeTypes {
            let status: String
            switch store.authorizationStatus(for: type) {
            case .sharingAuthorized: status = "granted"
            case .sharingDenied:     status = "denied"
            default:                 status = "notDetermined"
            }
            out[type.identifier] = status
        }
        return out
    }

    // MARK: - Shared helpers

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        // Matches Kotlin's Instant.toString(): UTC, fractional seconds, trailing Z.
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private func stamp(_ date: Date) -> String { Self.iso.string(from: date) }

    /// Local-timezone day boundaries, matching Health Connect's day range.
    private func todayRange() -> (Date, Date) {
        let start = Calendar.current.startOfDay(for: Date())
        return (start, Date())
    }

    private func predicate(_ from: Date, _ to: Date) -> NSPredicate {
        HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
    }

    /// Friendly producer name, the analogue of Android's friendlySourceName(packageName).
    private func source(_ sample: HKSample) -> Any {
        let name = sample.sourceRevision.source.name
        return name.isEmpty ? NSNull() : name
    }

    /// Sum of a cumulative quantity over a range. nil when HealthKit has no samples at all,
    /// which the JSON turns into null — deliberately distinct from a real zero.
    private func sum(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from: Date, to: Date) async throws -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: id) else { return nil }
        return try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsQuery(quantityType: type,
                                      quantitySamplePredicate: predicate(from, to),
                                      options: .cumulativeSum) { _, stats, error in
                if let error = error { cont.resume(throwing: error); return }
                cont.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(q)
        }
    }

    /// Most recent sample of a discrete quantity type.
    private func latest(_ id: HKQuantityTypeIdentifier) async throws -> HKQuantitySample? {
        guard let type = HKObjectType.quantityType(forIdentifier: id) else { return nil }
        return try await withCheckedThrowingContinuation { cont in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let q = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, error in
                if let error = error { cont.resume(throwing: error); return }
                cont.resume(returning: samples?.first as? HKQuantitySample)
            }
            store.execute(q)
        }
    }

    private func samples(_ type: HKSampleType, from: Date, to: Date, limit: Int = HKObjectQueryNoLimit,
                         ascending: Bool = true) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { cont in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: ascending)
            let q = HKSampleQuery(sampleType: type, predicate: predicate(from, to),
                                  limit: limit, sortDescriptors: [sort]) { _, samples, error in
                if let error = error { cont.resume(throwing: error); return }
                cont.resume(returning: samples ?? [])
            }
            store.execute(q)
        }
    }

    /// The {value, time, source} shape every "latest reading" method returns on Android.
    private func latestPayload(_ id: HKQuantityTypeIdentifier, key: String, unit: HKUnit,
                               scale: Double = 1) async throws -> [String: Any] {
        guard let s = try await latest(id) else { return [key: NSNull()] }
        return [
            key: s.quantity.doubleValue(for: unit) * scale,
            "time": stamp(s.endDate),
            "source": source(s)
        ]
    }

    // MARK: - Today totals

    func todaySteps() async throws -> [String: Any] {
        let (from, to) = todayRange()
        let total = try await sum(.stepCount, unit: .count(), from: from, to: to)
        return ["steps": total.map { Int($0) } ?? NSNull()]
    }

    func todayActiveCalories() async throws -> [String: Any] {
        let (from, to) = todayRange()
        let kcal = try await sum(.activeEnergyBurned, unit: .kilocalorie(), from: from, to: to)
        return ["kcal": kcal ?? NSNull()]
    }

    func todayDistance() async throws -> [String: Any] {
        let (from, to) = todayRange()
        let meters = try await sum(.distanceWalkingRunning, unit: .meter(), from: from, to: to)
        return ["meters": meters ?? NSNull(), "km": meters.map { $0 / 1000.0 } ?? NSNull()]
    }

    func todayHydration() async throws -> [String: Any] {
        let (from, to) = todayRange()
        let liters = try await sum(.dietaryWater, unit: .liter(), from: from, to: to)
        return ["liters": liters ?? NSNull()]
    }

    func todayNutrition() async throws -> [String: Any] {
        let (from, to) = todayRange()
        let kcal = try await sum(.dietaryEnergyConsumed, unit: .kilocalorie(), from: from, to: to)
        guard let kcal = kcal else { return ["kcal": NSNull()] }
        let g = HKUnit.gram()
        async let protein = sum(.dietaryProtein, unit: g, from: from, to: to)
        async let carbs   = sum(.dietaryCarbohydrates, unit: g, from: from, to: to)
        async let fat     = sum(.dietaryFatTotal, unit: g, from: from, to: to)
        async let fiber   = sum(.dietaryFiber, unit: g, from: from, to: to)
        async let sugar   = sum(.dietarySugar, unit: g, from: from, to: to)
        async let sodium  = sum(.dietarySodium, unit: .gramUnit(with: .milli), from: from, to: to)
        let entries = try await samples(HKObjectType.quantityType(forIdentifier: .dietaryEnergyConsumed)!,
                                        from: from, to: to)
        return [
            "kcal": kcal,
            "proteinG": (try await protein) ?? 0,
            "carbsG": (try await carbs) ?? 0,
            "fatG": (try await fat) ?? 0,
            "fiberG": (try await fiber) ?? 0,
            "sugarG": (try await sugar) ?? 0,
            "sodiumMg": (try await sodium) ?? 0,
            "entryCount": entries.count
        ]
    }

    func todayWorkoutCount() async throws -> [String: Any] {
        let (from, to) = todayRange()
        let workouts = try await samples(HKObjectType.workoutType(), from: from, to: to)
        return ["count": workouts.count]
    }

    // MARK: - Heart rate

    func heartRate() async throws -> [String: Any] {
        let (from, to) = todayRange()
        guard let type = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            return ["latestBpm": NSNull()]
        }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let todays = try await samples(type, from: from, to: to) as? [HKQuantitySample] ?? []
        let latestSample = try await latest(.heartRate)

        var payload: [String: Any] = [
            "latestBpm": latestSample.map { $0.quantity.doubleValue(for: unit) } ?? NSNull(),
            "latestTime": latestSample.map { stamp($0.endDate) } ?? NSNull(),
            "source": latestSample.map { source($0) } ?? NSNull(),
            "sampleCount": todays.count
        ]
        let values = todays.map { $0.quantity.doubleValue(for: unit) }
        payload["minBpm"] = values.min() ?? NSNull()
        payload["maxBpm"] = values.max() ?? NSNull()
        payload["averageBpm"] = values.isEmpty ? NSNull() : values.reduce(0, +) / Double(values.count)
        return payload
    }

    /// Recent samples for the Home sparkline. Capped like the Android side so a watch wearer
    /// with thousands of readings does not push a megabyte of JSON through the bridge.
    func heartRateSeries(limit: Int = 100) async throws -> [[String: Any]] {
        guard let type = HKObjectType.quantityType(forIdentifier: .heartRate) else { return [] }
        let from = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let recent = try await samples(type, from: from, to: Date(), limit: limit, ascending: false)
        return recent.compactMap { $0 as? HKQuantitySample }
            .reversed()
            .map { ["timestamp": stamp($0.endDate),
                    "bpm": $0.quantity.doubleValue(for: .count().unitDivided(by: .minute()))] }
    }

    // MARK: - Body measurements

    func latestWeight() async throws -> [String: Any] {
        try await latestPayload(.bodyMass, key: "weightKg", unit: .gramUnit(with: .kilo))
    }

    func latestRespiratoryRate() async throws -> [String: Any] {
        try await latestPayload(.respiratoryRate, key: "rpm", unit: .count().unitDivided(by: .minute()))
    }

    /// HealthKit reports saturation as a fraction; Health Connect reports 0–100.
    func latestOxygenSaturation() async throws -> [String: Any] {
        try await latestPayload(.oxygenSaturation, key: "percentage", unit: .percent(), scale: 100)
    }

    func latestBodyTemperature() async throws -> [String: Any] {
        try await latestPayload(.bodyTemperature, key: "celsius", unit: .degreeCelsius())
    }

    func latestBodyFat() async throws -> [String: Any] {
        try await latestPayload(.bodyFatPercentage, key: "percentage", unit: .percent(), scale: 100)
    }

    func latestHeight() async throws -> [String: Any] {
        try await latestPayload(.height, key: "meters", unit: .meter())
    }

    func latestLeanBodyMass() async throws -> [String: Any] {
        try await latestPayload(.leanBodyMass, key: "kg", unit: .gramUnit(with: .kilo))
    }

    /// See the header: this is today's accumulated basal burn, not a kcal/day rate.
    func latestBasalMetabolicRate() async throws -> [String: Any] {
        let (from, to) = todayRange()
        guard let kcal = try await sum(.basalEnergyBurned, unit: .kilocalorie(), from: from, to: to) else {
            return ["kcalPerDay": NSNull()]
        }
        return ["kcalPerDay": kcal, "time": stamp(Date()), "source": "HealthKit"]
    }

    /// Read as a correlation so the two halves come from the same reading. Querying systolic
    /// and diastolic separately can pair numbers from different measurements.
    func latestBloodPressure() async throws -> [String: Any] {
        guard let correlation = HKObjectType.correlationType(forIdentifier: .bloodPressure),
              let systolicType = HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic),
              let diastolicType = HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic) else {
            return ["systolic": NSNull(), "diastolic": NSNull()]
        }
        let latest: HKCorrelation? = try await withCheckedThrowingContinuation { cont in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let q = HKSampleQuery(sampleType: correlation, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, error in
                if let error = error { cont.resume(throwing: error); return }
                cont.resume(returning: samples?.first as? HKCorrelation)
            }
            store.execute(q)
        }
        guard let reading = latest,
              let systolic = reading.objects(for: systolicType).first as? HKQuantitySample,
              let diastolic = reading.objects(for: diastolicType).first as? HKQuantitySample else {
            return ["systolic": NSNull(), "diastolic": NSNull()]
        }
        let mmHg = HKUnit.millimeterOfMercury()
        return [
            "systolic": systolic.quantity.doubleValue(for: mmHg),
            "diastolic": diastolic.quantity.doubleValue(for: mmHg),
            "time": stamp(reading.endDate),
            "source": source(reading)
        ]
    }

    // MARK: - History series

    func stepsHistory(days: Int = 7) async throws -> [[String: Any]] {
        guard let type = HKObjectType.quantityType(forIdentifier: .stepCount) else { return [] }
        let cal = Calendar.current
        let end = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -(days - 1), to: end) else { return [] }

        return try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate(start, Date()),
                options: .cumulativeSum,
                anchorDate: start,
                intervalComponents: DateComponents(day: 1)
            )
            q.initialResultsHandler = { _, collection, error in
                if let error = error { cont.resume(throwing: error); return }
                var out: [[String: Any]] = []
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"   // matches Android's LocalDate.toString()
                collection?.enumerateStatistics(from: start, to: Date()) { stats, _ in
                    let value = stats.sumQuantity()?.doubleValue(for: .count()) ?? 0
                    out.append(["date": fmt.string(from: stats.startDate), "value": Int(value)])
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }

    func weightHistory(days: Int) async throws -> [[String: Any]] {
        guard let type = HKObjectType.quantityType(forIdentifier: .bodyMass) else { return [] }
        let from = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let records = try await samples(type, from: from, to: Date())
        return records.compactMap { $0 as? HKQuantitySample }
            .map { ["timestamp": stamp($0.endDate),
                    "kg": $0.quantity.doubleValue(for: .gramUnit(with: .kilo))] }
    }

    // MARK: - Sleep

    func latestSleepSession() async throws -> [String: Any] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return ["totalMinutes": NSNull()]
        }
        // A night is assembled from many category samples, so take a 48h window and group by
        // the contiguous run that ends most recently.
        let from = Calendar.current.date(byAdding: .hour, value: -48, to: Date()) ?? Date()
        let all = try await samples(type, from: from, to: Date()).compactMap { $0 as? HKCategorySample }
        let asleep = all.filter { isAsleep($0) }
        guard let last = asleep.last else { return ["totalMinutes": NSNull()] }

        // Everything within 4 hours of the final sample counts as the same night.
        let cutoff = last.endDate.addingTimeInterval(-4 * 3600 - 12 * 3600)
        let night = asleep.filter { $0.endDate >= cutoff }
        guard let start = night.map({ $0.startDate }).min(),
              let end = night.map({ $0.endDate }).max() else { return ["totalMinutes": NSNull()] }

        var byStage: [String: Int] = [:]
        var total = 0
        for s in night {
            let minutes = Int(s.endDate.timeIntervalSince(s.startDate) / 60)
            total += minutes
            byStage[stageName(s), default: 0] += minutes
        }
        let stages = byStage.map { ["stage": $0.key, "minutes": $0.value] }
        return [
            "totalMinutes": total,
            "startTime": stamp(start),
            "endTime": stamp(end),
            "stages": stages,
            "title": NSNull()
        ]
    }

    private func isAsleep(_ sample: HKCategorySample) -> Bool {
        if #available(iOS 16.0, *) {
            return [HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue].contains(sample.value)
        }
        return sample.value == HKCategoryValueSleepAnalysis.asleep.rawValue
    }

    private func stageName(_ sample: HKCategorySample) -> String {
        if #available(iOS 16.0, *) {
            switch sample.value {
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue: return "LIGHT"
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: return "DEEP"
            case HKCategoryValueSleepAnalysis.asleepREM.rawValue:  return "REM"
            case HKCategoryValueSleepAnalysis.awake.rawValue:      return "AWAKE"
            default: return "SLEEPING"
            }
        }
        return "SLEEPING"
    }

    /// Period totals for the Insights tabs, mirroring Android's sleepPeriodFor.
    func sleepSummary(from: Date, to: Date) async throws -> [String: Any] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return ["totalMinutes": NSNull(), "avgMinutesPerNight": NSNull(), "nights": 0]
        }
        let asleep = try await samples(type, from: from, to: to)
            .compactMap { $0 as? HKCategorySample }
            .filter { isAsleep($0) }
        if asleep.isEmpty {
            return ["totalMinutes": NSNull(), "avgMinutesPerNight": NSNull(), "nights": 0]
        }
        let total = asleep.reduce(0) { $0 + Int($1.endDate.timeIntervalSince($1.startDate) / 60) }
        let nights = Set(asleep.map { Calendar.current.startOfDay(for: $0.endDate) }).count
        return ["totalMinutes": total,
                "avgMinutesPerNight": nights > 0 ? total / nights : total,
                "nights": nights]
    }

    // MARK: - Writes

    /// Sync identifier is HealthKit's equivalent of Health Connect's clientRecordId: saving
    /// twice with the same identifier updates the record instead of creating a duplicate,
    /// which is what makes re-exporting a workout safe.
    func saveWorkout(start: Date, end: Date, title: String, activity: HKWorkoutActivityType,
                     ignytWorkoutId: String) async throws -> String {
        let config = HKWorkoutConfiguration()
        config.activityType = activity

        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        try await builder.beginCollection(at: start)
        try await builder.addMetadata([
            HKMetadataKeySyncIdentifier: ignytWorkoutId,
            HKMetadataKeySyncVersion: 1,
            HKMetadataKeyWorkoutBrandName: title
        ])
        try await builder.endCollection(at: end)
        guard let workout = try await builder.finishWorkout() else {
            throw NSError(domain: "IgnytHealthKit", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "HealthKit returned no workout."])
        }
        return workout.uuid.uuidString
    }

    func saveWeight(kg: Double, at date: Date, ignytBodyLogId: String) async throws -> String {
        guard let type = HKObjectType.quantityType(forIdentifier: .bodyMass) else {
            throw NSError(domain: "IgnytHealthKit", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Body mass type unavailable."])
        }
        let sample = HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kg),
            start: date, end: date,
            metadata: [HKMetadataKeySyncIdentifier: ignytBodyLogId, HKMetadataKeySyncVersion: 1]
        )
        try await store.save(sample)
        return sample.uuid.uuidString
    }

    // MARK: - Insights

    func periodRange(_ period: String) -> (Date, Date) {
        let cal = Calendar.current
        let now = Date()
        let start: Date
        switch period {
        case "week":  start = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now)) ?? now
        case "month": start = cal.date(byAdding: .month, value: -1, to: cal.startOfDay(for: now)) ?? now
        case "year":  start = cal.date(byAdding: .year, value: -1, to: cal.startOfDay(for: now)) ?? now
        default:      start = cal.startOfDay(for: now)
        }
        return (start, now)
    }

    func stepsFor(_ range: (Date, Date)) async throws -> [String: Any] {
        let total = try await sum(.stepCount, unit: .count(), from: range.0, to: range.1)
        return ["steps": total.map { Int($0) } ?? NSNull()]
    }

    func activeCaloriesFor(_ range: (Date, Date)) async throws -> [String: Any] {
        ["kcal": try await sum(.activeEnergyBurned, unit: .kilocalorie(), from: range.0, to: range.1) ?? NSNull()]
    }

    func distanceFor(_ range: (Date, Date)) async throws -> [String: Any] {
        let meters = try await sum(.distanceWalkingRunning, unit: .meter(), from: range.0, to: range.1)
        return ["meters": meters ?? NSNull(), "km": meters.map { $0 / 1000.0 } ?? NSNull()]
    }

    func workoutCountFor(_ range: (Date, Date)) async throws -> [String: Any] {
        ["count": try await samples(HKObjectType.workoutType(), from: range.0, to: range.1).count]
    }

    func hydrationFor(_ range: (Date, Date)) async throws -> [String: Any] {
        ["liters": try await sum(.dietaryWater, unit: .liter(), from: range.0, to: range.1) ?? NSNull()]
    }

    func heartRateFor(_ range: (Date, Date)) async throws -> [String: Any] {
        guard let type = HKObjectType.quantityType(forIdentifier: .heartRate) else { return ["averageBpm": NSNull()] }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let values = try await samples(type, from: range.0, to: range.1)
            .compactMap { ($0 as? HKQuantitySample)?.quantity.doubleValue(for: unit) }
        if values.isEmpty { return ["averageBpm": NSNull(), "minBpm": NSNull(), "maxBpm": NSNull(), "sampleCount": 0] }
        return ["averageBpm": values.reduce(0, +) / Double(values.count),
                "minBpm": values.min()!, "maxBpm": values.max()!, "sampleCount": values.count]
    }

    func nutritionFor(_ range: (Date, Date)) async throws -> [String: Any] {
        let kcal = try await sum(.dietaryEnergyConsumed, unit: .kilocalorie(), from: range.0, to: range.1)
        return ["kcal": kcal ?? NSNull()]
    }

    func weightPeriodFor(_ range: (Date, Date)) async throws -> [String: Any] {
        guard let type = HKObjectType.quantityType(forIdentifier: .bodyMass) else {
            return ["latestKg": NSNull(), "earliestKg": NSNull(), "changeKg": NSNull(), "readingCount": 0]
        }
        let kg = HKUnit.gramUnit(with: .kilo)
        let records = try await samples(type, from: range.0, to: range.1).compactMap { $0 as? HKQuantitySample }
        guard let first = records.first, let last = records.last else {
            return ["latestKg": NSNull(), "earliestKg": NSNull(), "changeKg": NSNull(), "readingCount": 0]
        }
        let latest = last.quantity.doubleValue(for: kg)
        let earliest = first.quantity.doubleValue(for: kg)
        return ["latestKg": latest, "earliestKg": earliest,
                "changeKg": latest - earliest, "readingCount": records.count]
    }
}
