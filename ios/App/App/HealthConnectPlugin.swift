import Foundation
import Capacitor
import HealthKit
import UIKit

/**
 The iOS half of IGNYT's health bridge.

 Registered as "HealthConnect" on purpose. The name is Android's, but renaming it would mean
 touching every call site in the web layer for no behavioural gain — the JS asks for health
 data, and this answers with HealthKit. The 29 methods, their arguments and their JSON shapes
 match android/.../HealthConnectPlugin.kt exactly, so www/health-connect.js runs unchanged.

 Like the Android plugin, no method ever rejects. Everything resolves either
 {"success": true, "data": ...} or {"success": false, "error": "..."} so the JS side always
 gets a normal resolved promise.

 Permissions are requested only from requestPermissions(), never as a side effect of a read.

 THREE METHODS CANNOT MEAN ON iOS WHAT THEY MEAN ON ANDROID. They are implemented honestly
 rather than faked; each says so in its own comment:
   getPermissionStatus   — iOS never reveals whether a READ was granted
   revokePermissions     — only the user can revoke, in Settings
   openHealthConnectInstall — nothing to install; Health is part of iOS
 */
@objc(HealthConnectPlugin)
public class HealthConnectPlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier = "HealthConnectPlugin"
    public let jsName = "HealthConnect"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "isAvailable", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openHealthConnectInstall", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getPermissionStatus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "revokePermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getTodaySteps", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getHeartRate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getLatestWeight", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getTodayActiveCalories", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getTodayDistance", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getTodayWorkoutCount", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getRespiratoryRate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getOxygenSaturation", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getBloodPressure", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getBodyTemperature", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getBodyFat", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getHeight", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getLeanBodyMass", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getBasalMetabolicRate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getTodayHydration", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getTodayNutrition", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getSleepSummary", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getHeartRateHistory", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getStepsHistory", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getWeightHistory", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "syncNow", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getInsights", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "saveWorkout", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "saveWeight", returnType: CAPPluginReturnPromise)
    ]

    private let manager = HealthKitManager()

    // MARK: - Envelope

    private func ok(_ call: CAPPluginCall, _ data: [String: Any]) {
        call.resolve(["success": true, "data": data])
    }

    private func fail(_ call: CAPPluginCall, _ message: String) {
        call.resolve(["success": false, "error": message])
    }

    /// Runs a read and resolves it in the standard envelope. The Android analogue of
    /// ensurePermissions() cannot exist here — iOS will not say whether reads are permitted —
    /// so what is checked instead is that the user has been through the sheet at least once.
    private func read(_ call: CAPPluginCall, _ work: @escaping () async throws -> [String: Any]) {
        guard manager.isAvailable else {
            fail(call, "HealthKit is not available on this device.")
            return
        }
        guard manager.hasRequestedAuthorization else {
            fail(call, "Health permissions have not been requested yet. Call requestPermissions() first.")
            return
        }
        Task {
            do { ok(call, try await work()) }
            catch { fail(call, "Read failed: \(error.localizedDescription)") }
        }
    }

    private func readList(_ call: CAPPluginCall, _ work: @escaping () async throws -> [[String: Any]]) {
        read(call) { ["items": try await work()] }
    }

    // MARK: - Availability and permissions

    @objc func isAvailable(_ call: CAPPluginCall) {
        let available = manager.isAvailable
        ok(call, ["available": available, "status": available ? "AVAILABLE" : "UNAVAILABLE"])
    }

    /// There is nothing to install — Health ships with iOS. Rather than silently succeeding,
    /// this opens the Health app, which is the nearest useful equivalent of the Android flow
    /// that sends the user to the Play Store listing.
    @objc func openHealthConnectInstall(_ call: CAPPluginCall) {
        guard let url = URL(string: "x-apple-health://") else {
            fail(call, "Could not open the Health app.")
            return
        }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { opened in
                self.ok(call, ["opened": opened])
            }
        }
    }

    @objc override public func requestPermissions(_ call: CAPPluginCall) {
        guard manager.isAvailable else {
            fail(call, "HealthKit is not available on this device.")
            return
        }
        Task {
            do {
                try await manager.requestAuthorization()
                // iOS reports nothing about reads, so `granted` here means the sheet completed
                // without error — not that any particular type was allowed.
                ok(call, ["granted": true, "partial": partialWrites(), "grantedPermissions": grantedList()])
            } catch {
                fail(call, "requestPermissions failed: \(error.localizedDescription)")
            }
        }
    }

    /**
     iOS will not tell an app whether a READ permission was granted. `authorizationStatus(for:)`
     answers only for types the app can write, and a denied read is indistinguishable from an
     empty data set — that is a deliberate privacy design, not a gap to work around.

     So `granted` reports whether the authorisation sheet has been completed, which is the only
     fact available, and `partial` is computed from the two write types where the answer is
     real. `readAuthorizationIsUnknowable` is added so the JS can tell the difference between
     this and Android's answer rather than assuming they mean the same thing.
     */
    @objc func getPermissionStatus(_ call: CAPPluginCall) {
        guard manager.isAvailable else {
            ok(call, ["granted": false, "available": false])
            return
        }
        ok(call, [
            "available": true,
            "granted": manager.hasRequestedAuthorization,
            "partial": partialWrites(),
            "grantedPermissions": grantedList(),
            "readAuthorizationIsUnknowable": true
        ])
    }

    /// No API exists for this on iOS; permissions are revoked by the user in
    /// Settings › Privacy & Security › Health › IGNYT. Reporting failure is the truthful
    /// answer — resolving success would tell the UI that data access had stopped when it had not.
    @objc func revokePermissions(_ call: CAPPluginCall) {
        fail(call, "iOS does not allow an app to revoke Health permissions. Open Settings › Privacy & Security › Health › IGNYT to change them.")
    }

    private func grantedList() -> [String] {
        manager.writeAuthorizationStatuses().filter { $0.value == "granted" }.map { $0.key }
    }

    private func partialWrites() -> Bool {
        manager.writeAuthorizationStatuses().values.contains { $0 != "granted" }
    }

    // MARK: - Reads

    @objc func getTodaySteps(_ call: CAPPluginCall)          { read(call) { try await self.manager.todaySteps() } }
    @objc func getHeartRate(_ call: CAPPluginCall)           { read(call) { try await self.manager.heartRate() } }
    @objc func getLatestWeight(_ call: CAPPluginCall)        { read(call) { try await self.manager.latestWeight() } }
    @objc func getTodayActiveCalories(_ call: CAPPluginCall) { read(call) { try await self.manager.todayActiveCalories() } }
    @objc func getTodayDistance(_ call: CAPPluginCall)       { read(call) { try await self.manager.todayDistance() } }
    @objc func getTodayWorkoutCount(_ call: CAPPluginCall)   { read(call) { try await self.manager.todayWorkoutCount() } }
    @objc func getRespiratoryRate(_ call: CAPPluginCall)     { read(call) { try await self.manager.latestRespiratoryRate() } }
    @objc func getOxygenSaturation(_ call: CAPPluginCall)    { read(call) { try await self.manager.latestOxygenSaturation() } }
    @objc func getBloodPressure(_ call: CAPPluginCall)       { read(call) { try await self.manager.latestBloodPressure() } }
    @objc func getBodyTemperature(_ call: CAPPluginCall)     { read(call) { try await self.manager.latestBodyTemperature() } }
    @objc func getBodyFat(_ call: CAPPluginCall)             { read(call) { try await self.manager.latestBodyFat() } }
    @objc func getHeight(_ call: CAPPluginCall)              { read(call) { try await self.manager.latestHeight() } }
    @objc func getLeanBodyMass(_ call: CAPPluginCall)        { read(call) { try await self.manager.latestLeanBodyMass() } }
    @objc func getBasalMetabolicRate(_ call: CAPPluginCall)  { read(call) { try await self.manager.latestBasalMetabolicRate() } }
    @objc func getTodayHydration(_ call: CAPPluginCall)      { read(call) { try await self.manager.todayHydration() } }
    @objc func getTodayNutrition(_ call: CAPPluginCall)      { read(call) { try await self.manager.todayNutrition() } }
    @objc func getSleepSummary(_ call: CAPPluginCall)        { read(call) { try await self.manager.latestSleepSession() } }

    @objc func getHeartRateHistory(_ call: CAPPluginCall)    { readList(call) { try await self.manager.heartRateSeries() } }
    @objc func getStepsHistory(_ call: CAPPluginCall)        { readList(call) { try await self.manager.stepsHistory() } }

    @objc func getWeightHistory(_ call: CAPPluginCall) {
        let days = call.getInt("days") ?? 90
        readList(call) { try await self.manager.weightHistory(days: days) }
    }

    // MARK: - Sync

    /// One call for the dashboard's Sync button. Every field is fetched independently, so one
    /// metric failing — a type the user declined, a transient error — leaves the rest intact
    /// rather than blanking the screen.
    @objc func syncNow(_ call: CAPPluginCall) {
        guard manager.isAvailable else {
            fail(call, "HealthKit is not available on this device.")
            return
        }
        Task {
            var data: [String: Any] = [
                "partialPermissions": self.partialWrites(),
                "grantedPermissions": self.grantedList(),
                "readAuthorizationIsUnknowable": true
            ]
            data["steps"]              = await self.orNull { try await self.manager.todaySteps() }
            data["heartRate"]          = await self.orNull { try await self.manager.heartRate() }
            data["weight"]             = await self.orNull { try await self.manager.latestWeight() }
            data["activeCalories"]     = await self.orNull { try await self.manager.todayActiveCalories() }
            data["distance"]           = await self.orNull { try await self.manager.todayDistance() }
            data["workouts"]           = await self.orNull { try await self.manager.todayWorkoutCount() }
            data["sleep"]              = await self.orNull { try await self.manager.latestSleepSession() }
            data["steps7Days"]         = await self.orNullList { try await self.manager.stepsHistory() }
            data["heartRateSeries"]    = await self.orNullList { try await self.manager.heartRateSeries() }
            data["weightHistory"]      = await self.orNullList { try await self.manager.weightHistory(days: 90) }
            data["respiratoryRate"]    = await self.orNull { try await self.manager.latestRespiratoryRate() }
            data["oxygenSaturation"]   = await self.orNull { try await self.manager.latestOxygenSaturation() }
            data["bloodPressure"]      = await self.orNull { try await self.manager.latestBloodPressure() }
            data["bodyTemperature"]    = await self.orNull { try await self.manager.latestBodyTemperature() }
            data["bodyFat"]            = await self.orNull { try await self.manager.latestBodyFat() }
            data["height"]             = await self.orNull { try await self.manager.latestHeight() }
            data["leanBodyMass"]       = await self.orNull { try await self.manager.latestLeanBodyMass() }
            data["basalMetabolicRate"] = await self.orNull { try await self.manager.latestBasalMetabolicRate() }
            data["hydration"]          = await self.orNull { try await self.manager.todayHydration() }
            data["nutrition"]          = await self.orNull { try await self.manager.todayNutrition() }
            data["syncedAt"] = Int(Date().timeIntervalSince1970 * 1000)
            self.ok(call, data)
        }
    }

    private func orNull(_ work: () async throws -> [String: Any]) async -> Any {
        (try? await work()) ?? NSNull()
    }

    private func orNullList(_ work: () async throws -> [[String: Any]]) async -> Any {
        (try? await work()) ?? NSNull()
    }

    // MARK: - Insights

    @objc func getInsights(_ call: CAPPluginCall) {
        guard manager.isAvailable else {
            fail(call, "HealthKit is not available on this device.")
            return
        }
        let requested = call.getString("period") ?? "day"
        let period = ["day", "week", "month", "year"].contains(requested) ? requested : "day"
        Task {
            let range = self.manager.periodRange(period)
            var data: [String: Any] = ["period": period, "grantedPermissions": self.grantedList()]
            data["steps"]              = await self.orNull { try await self.manager.stepsFor(range) }
            data["activeCalories"]     = await self.orNull { try await self.manager.activeCaloriesFor(range) }
            data["distance"]           = await self.orNull { try await self.manager.distanceFor(range) }
            data["workouts"]           = await self.orNull { try await self.manager.workoutCountFor(range) }
            data["heartRate"]          = await self.orNull { try await self.manager.heartRateFor(range) }
            data["sleep"]              = await self.orNull { try await self.manager.sleepSummary(from: range.0, to: range.1) }
            data["hydration"]          = await self.orNull { try await self.manager.hydrationFor(range) }
            data["nutrition"]          = await self.orNull { try await self.manager.nutritionFor(range) }
            data["weight"]             = await self.orNull { try await self.manager.weightPeriodFor(range) }
            data["respiratoryRate"]    = await self.orNull { try await self.manager.latestRespiratoryRate() }
            data["oxygenSaturation"]   = await self.orNull { try await self.manager.latestOxygenSaturation() }
            data["bloodPressure"]      = await self.orNull { try await self.manager.latestBloodPressure() }
            data["bodyTemperature"]    = await self.orNull { try await self.manager.latestBodyTemperature() }
            data["bodyFat"]            = await self.orNull { try await self.manager.latestBodyFat() }
            data["height"]             = await self.orNull { try await self.manager.latestHeight() }
            data["leanBodyMass"]       = await self.orNull { try await self.manager.latestLeanBodyMass() }
            data["basalMetabolicRate"] = await self.orNull { try await self.manager.latestBasalMetabolicRate() }
            self.ok(call, data)
        }
    }

    // MARK: - Writes

    /// ignytWorkoutId is required, not optional — it becomes the HealthKit sync identifier,
    /// which is what stops a re-exported workout appearing twice in Health.
    @objc func saveWorkout(_ call: CAPPluginCall) {
        // Sent as strings by the JS side because epoch millis exceed what a JS number carries
        // safely through the bridge as an int.
        guard let startMillis = Double(call.getString("startTime") ?? ""),
              let endMillis = Double(call.getString("endTime") ?? ""),
              let ignytWorkoutId = call.getString("ignytWorkoutId"), !ignytWorkoutId.isEmpty else {
            fail(call, "saveWorkout requires startTime, endTime, and ignytWorkoutId.")
            return
        }
        let title = call.getString("title") ?? "Workout"
        let activity = Self.activityType(call.getString("type"))
        Task {
            do {
                let id = try await self.manager.saveWorkout(
                    start: Date(timeIntervalSince1970: startMillis / 1000),
                    end: Date(timeIntervalSince1970: endMillis / 1000),
                    title: title, activity: activity, ignytWorkoutId: ignytWorkoutId)
                self.ok(call, ["recordId": id])
            } catch {
                self.fail(call, "saveWorkout failed: \(error.localizedDescription)")
            }
        }
    }

    @objc func saveWeight(_ call: CAPPluginCall) {
        guard let kg = call.getDouble("weightKg"),
              let ignytBodyLogId = call.getString("ignytBodyLogId"), !ignytBodyLogId.isEmpty else {
            fail(call, "saveWeight requires weightKg and ignytBodyLogId.")
            return
        }
        let millis = Double(call.getString("time") ?? "") ?? Date().timeIntervalSince1970 * 1000
        Task {
            do {
                let id = try await self.manager.saveWeight(
                    kg: kg, at: Date(timeIntervalSince1970: millis / 1000), ignytBodyLogId: ignytBodyLogId)
                self.ok(call, ["recordId": id])
            } catch {
                self.fail(call, "saveWeight failed: \(error.localizedDescription)")
            }
        }
    }

    /// Mirrors mapIgnytExerciseType on Android.
    private static func activityType(_ ignytType: String?) -> HKWorkoutActivityType {
        switch ignytType {
        case "race":   return .highIntensityIntervalTraining
        case "cardio": return .running
        default:       return .traditionalStrengthTraining
        }
    }
}
