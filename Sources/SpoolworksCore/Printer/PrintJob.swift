import Foundation

// MARK: - What the printer reports

/// A snapshot of the printer's job state, as Moonraker reports it.
///
/// The K2 Plus runs Klipper behind Moonraker on port 7125. `print_stats` carries the job's name,
/// its state and how much filament the extruder has pulled; `box.T<n>.filament` names the CFS slot
/// currently feeding. Those two together are what makes per-job consumption attributable to a
/// specific spool rather than to "whatever was loaded, probably".
public struct PrintJobSnapshot: Equatable, Sendable {

    public enum State: String, Equatable, Sendable {
        case standby, printing, paused, complete, cancelled, error

        public var isActive: Bool { self == .printing || self == .paused }
    }

    /// The gcode file, e.g. `lid.stl_PLA_29m0s.gcode`. Empty when idle.
    public let filename: String
    public let state: State
    /// Millimetres of filament the extruder has pulled **for this job**. Resets to 0 on a new job.
    ///
    /// **Not monotonic.** It counts retractions, so it dips by a millimetre or two constantly —
    /// observed live as `102.20 → 104.00 → 102.00`. Anything differencing consecutive readings has
    /// to cope with that, or it will record filament flowing back onto the spool.
    public let filamentUsedMillimetres: Double
    /// `"T1A"` when a CFS slot is feeding, `nil` while the printer is purging or running from the
    /// external holder.
    ///
    /// Appears **late**: on the observed print it stayed `nil` for 65 s after the state became
    /// `printing`, by which point 14 mm had already gone through the extruder.
    public let feedingSlot: String?

    public init(filename: String,
                state: State,
                filamentUsedMillimetres: Double,
                feedingSlot: String?) {
        self.filename = filename
        self.state = state
        self.filamentUsedMillimetres = filamentUsedMillimetres
        self.feedingSlot = feedingSlot
    }

    /// Identifies one run of one file. `filament_used` resets when this changes.
    public var jobKey: String? {
        guard state.isActive, !filename.isEmpty else { return nil }
        return filename
    }
}

// MARK: - Millimetres to grams

/// Converts extruded length into mass.
///
/// `filament_used` is a **length**, and a spool is bought and weighed by **mass**, so every figure
/// the user sees needs this. Both inputs come from the CFS slot itself (`diameter`, `density`)
/// rather than being assumed, because they differ by material: PLA is 1.24 g/cm³ and PLA-CF is
/// not, and a 2.85 mm spool would be out by a factor of 2.65 on area alone.
public enum FilamentGeometry {

    /// Grams of filament in `millimetres` of stock.
    ///
    /// Volume is `π r² L` with everything in millimetres, giving mm³; density is g/cm³, and there
    /// are 1000 mm³ to the cm³.
    public static func grams(forMillimetres millimetres: Double,
                             diameterMillimetres: Double,
                             densityGramsPerCubicCentimetre: Double) -> Double {
        guard millimetres > 0, diameterMillimetres > 0, densityGramsPerCubicCentimetre > 0 else {
            return 0
        }
        let radius = diameterMillimetres / 2
        let cubicMillimetres = .pi * radius * radius * millimetres
        return cubicMillimetres / 1000 * densityGramsPerCubicCentimetre
    }

    /// The defaults used when a slot reports neither: 1.75 mm stock and PLA's density. Both are
    /// what every consumer FDM printer in this family ships with, and being explicit about the
    /// fallback beats silently producing zero.
    public static let defaultDiameter = 1.75
    public static let defaultDensity = 1.24
}

// MARK: - Tracking one job

/// Turns a stream of ``PrintJobSnapshot`` into "this spool just lost N grams".
///
/// A value type with no I/O, because every hard part of this is bookkeeping that has to be right:
///
/// * **Retraction.** `filament_used` goes down as well as up. The tracker follows the *high-water
///   mark*, so a retraction is not consumption and the un-retraction that follows is not counted
///   twice.
/// * **A late slot.** The feeding slot is unknown for the first minute or so. Consumption in that
///   window is held rather than dropped, and attributed to whichever slot appears — that filament
///   really did leave a spool, and on the observed print it was 14 mm of purge from the slot about
///   to feed.
/// * **A new job.** `filament_used` resets to zero. Differencing across that boundary would report
///   a large negative, so a change of job key restarts the high-water mark.
/// * **A slot change mid-job.** Auto-refill hands over to a partner slot. Consumption accrued
///   before the handover belongs to the old slot, so it is flushed before the new one starts.
public struct PrintJobTracker: Equatable, Sendable {

    /// Consumption that is ready to be charged to a spool.
    public struct Charge: Equatable, Sendable {
        public let slot: String
        public let millimetres: Double
        public let jobName: String
    }

    /// The job the counters below belong to.
    private(set) public var jobKey: String?
    /// The furthest `filament_used` has got in this job. Immune to retraction.
    private(set) public var highWaterMillimetres: Double = 0
    /// Consumed while no slot was named yet.
    private(set) public var unattributedMillimetres: Double = 0
    private(set) public var currentSlot: String?

    public init() {}

    /// Folds in one reading and returns anything now chargeable.
    public mutating func accept(_ snapshot: PrintJobSnapshot) -> Charge? {
        // -- job boundary ----------------------------------------------------------------------
        guard let key = snapshot.jobKey else {
            // Idle, complete or cancelled: the job is over. Nothing further can be attributed,
            // and holding the counters would corrupt the next job's first delta.
            reset()
            return nil
        }
        if key != jobKey {
            reset()
            jobKey = key
        }

        // -- consumption, against the high-water mark --------------------------------------------
        var advanced = 0.0
        if snapshot.filamentUsedMillimetres > highWaterMillimetres {
            advanced = snapshot.filamentUsedMillimetres - highWaterMillimetres
            highWaterMillimetres = snapshot.filamentUsedMillimetres
        }
        unattributedMillimetres += advanced

        // -- slot handover -----------------------------------------------------------------------
        //
        // Everything accrued so far was drawn while `currentSlot` was the known feeder — including
        // the advance in *this* reading, because a handover is only ever observed after the fact.
        // Charging it to the incoming slot would credit the fresh spool with filament the outgoing
        // one actually gave up, which is precisely the mis-attribution auto-refill would cause
        // most often.
        let owner = currentSlot
        if let slot = snapshot.feedingSlot, slot != currentSlot {
            currentSlot = slot
            if let owner, unattributedMillimetres > 0 {
                let charge = Charge(slot: owner,
                                    millimetres: unattributedMillimetres,
                                    jobName: key)
                unattributedMillimetres = 0
                return charge
            }
            // No previous owner: this is the slot appearing for the first time, so the held purge
            // belongs to it.
        }

        // -- charge, once a slot is known --------------------------------------------------------
        guard let slot = currentSlot, unattributedMillimetres > 0 else { return nil }
        let charge = Charge(slot: slot, millimetres: unattributedMillimetres, jobName: key)
        unattributedMillimetres = 0
        return charge
    }

    public mutating func reset() {
        jobKey = nil
        highWaterMillimetres = 0
        unattributedMillimetres = 0
        currentSlot = nil
    }
}
