import Foundation
import Combine
import SpoolworksCore

// MARK: - Observable state

/// What the reader hardware is doing right now.
///
/// Every case is a designed screen, not an error path — see `TagView`. In particular
/// `.subsystemUnavailable` and `.noReader` are distinct: the first means the PC/SC service itself
/// would not start, the second means it started and nothing is plugged in.
enum ReaderState: Equatable {
    /// Before the first poll completes.
    case starting
    /// `SCardEstablishContext` failed. PC/SC is broken, not merely empty.
    case subsystemUnavailable(String)
    /// PC/SC is up and reports zero readers.
    case noReader
    /// One or more reader **devices** are attached; none has a card. `note` carries an unusual
    /// connect failure (a sharing violation, say) so it is visible instead of looking like
    /// "no tag".
    case idle(devices: [String], note: String?)
    /// A card is on a reader.
    case cardPresent(CardIdentity)

    /// Physical devices, never PC/SC slots. See ``ReaderNaming``.
    var deviceNames: [String] {
        switch self {
        case let .idle(devices, _): return devices
        case let .cardPresent(identity): return [identity.deviceName]
        default: return []
        }
    }

    var card: CardIdentity? {
        if case let .cardPresent(identity) = self { return identity }
        return nil
    }

    var hasReader: Bool {
        switch self {
        case .idle, .cardPresent: return true
        case .starting, .noReader, .subsystemUnavailable: return false
        }
    }
}

/// Maps PC/SC slot names onto physical devices.
///
/// A single ACR1552 publishes two slots — `ACS ACR1552 1S CL Reader(1)` and `…(2)` — and a card
/// only ever lands on one of them. Presenting those as "2 readers" is simply wrong: the user owns
/// one device. Every slot is still polled; only the *presentation* is collapsed.
///
/// The Windows app sidesteps this by monitoring every slot and never showing a count at all
/// (`MainForm.cs:333`). This port shows the device name and, likewise, no slot count.
///
/// SpoolworksCore is growing a `ReaderDevice` type with the same grouping rule on `feat/macos-app`; when
/// it lands this enum becomes a thin forwarder and can be deleted.
enum ReaderNaming {

    /// Strips a trailing `(N)` slot suffix. Names without one are returned unchanged.
    static func deviceName(forSlot slot: String) -> String {
        var name = slot.trimmingCharacters(in: .whitespaces)
        guard name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { return name }
        let digits = name[name.index(after: open)..<name.index(before: name.endIndex)]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return name }
        name = String(name[name.startIndex..<open])
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Distinct device names, in the order their first slot appeared.
    static func devices(from slots: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for slot in slots {
            let device = deviceName(forSlot: slot)
            if seen.insert(device).inserted { out.append(device) }
        }
        return out
    }
}

/// What a single probe of a present card established, before any tag-level work.
struct CardIdentity: Equatable {
    /// The PC/SC slot the card was found on. Internal plumbing — do not show this to the user.
    let readerName: String
    let atr: [UInt8]
    let type: CardType
    let uid: [UInt8]
    /// Set when `FF CA` failed — a card is physically there but will not identify itself.
    let uidFailure: String?
    /// Reader firmware string, when the reader answers `FF 00 48`. Best-effort (D-004/D-005).
    /// Shown in the reader inspector, never in the window title — see the non-goals list.
    let firmware: String?

    /// The physical device the slot belongs to. This is the only reader name the UI shows.
    var deviceName: String { ReaderNaming.deviceName(forSlot: readerName) }

    /// A card this app can actually work with: a Classic 1K with the 4-byte UID the key
    /// derivation consumes.
    var isUsable: Bool { type.isSupported && uid.count == 4 }

    var uidHex: String { uid.hexString }
    /// `3A 63 33 03` — the exact spacing the Windows app renders (`MainForm.cs:248`).
    var uidSpaced: String { uid.hexStringSpaced }
}

// MARK: - Monitor

/// Polls PC/SC for reader presence and card insertion/removal, and hands out card sessions.
///
/// ## Why polling
///
/// `SCARD_SHARE_DIRECT` is unavailable on macOS (probe returned `SCARD_E_UNSUPPORTED_FEATURE`
/// on both ACR1552 slots — DECISIONS D-005), so there is no way to hold a handle on an empty
/// reader and wait for a card on it. Presence comes from `SCardGetStatusChange` with a **zero**
/// timeout (`PCSCContext.isCardPresent(reader:)`), which reports the reader's current state
/// without opening a card session.
///
/// ## Why the poll is fast
///
/// Sampling presence every 333 ms meant a tag tapped on the antenna and lifted again between two
/// samples was never seen at all — the user taps, nothing happens, and the only way to make it
/// work is to leave the tag sitting there. The sample interval is the miss window, so it is now
/// 75 ms: a deliberate tap is caught, and the tag still has to stay in the field long enough for
/// authentication plus three block reads (tens of milliseconds more) for the read itself to
/// finish, which no polling rate can shorten.
///
/// The cost is bounded deliberately. A tick is one zero-timeout `SCardGetStatusChange` per slot —
/// it touches no card and starts no transaction, which is exactly why a fast rate is safe here
/// while the old connect-to-probe scheme (which churned the RF field and made stationary tags
/// flicker) was not. The reader *list* is a separate, slower cadence — see `refreshNamesEvery` —
/// because enumerating readers is the expensive call and hardware does not appear and disappear at
/// 13 Hz.
///
/// The genuinely right answer is a **blocking** `SCardGetStatusChange`, which returns the instant
/// the reader reports a transition and costs nothing while it waits. `PCSCContext` already has it
/// (`waitForStateChange(reader:currentState:timeoutMs:)`, with `cancelPendingWaits()` to unblock
/// it), but both are `internal` to SpoolworksCore and SpoolworksCore is out of scope for this change. If they are
/// made `public`, this loop should become one blocking wait per slot on the engine queue.
///
/// ## Why unplug is handled explicitly
///
/// The Windows `Monitor` exposes a `StatusChanged` event that `MainForm` never subscribes to
/// (`Monitor.cs:16-32`, `SPEC/03-ui.md` §6), so pulling the USB reader out changes nothing on
/// screen and the only recovery affordance — `lblConnect` — is hidden while "connected". That is
/// a real defect and it is not reproduced. Here:
///
/// * The reader list is re-read on every tick, so an unplug becomes `.noReader` within ~333 ms.
/// * `PCSCContext.readerNames()` returns an empty list rather than throwing when the context has
///   gone stale, which is indistinguishable from "nothing plugged in". So while the list is
///   empty the context is torn down and re-established every ~2 s. That is what makes replug —
///   and a `pcscd` restart, which happens when the last reader is removed — recover on its own
///   with no user action.
/// * A card that disappears with its reader is cleared, not left on screen.
///
/// ## Threading
///
/// All PC/SC work runs on one serial queue owned by ``PCSCEngine``; the published state lives on
/// the main actor. Polls and card operations share that queue, so a read or write can never
/// interleave with a presence probe on the same card.
@MainActor
final class ReaderMonitor: ObservableObject {

    /// The current hardware state. Drives every empty state in `TagView`.
    @Published private(set) var state: ReaderState = .starting
    /// True while at least one card operation (read/write/dump) holds the reader.
    ///
    /// Derived from ``busyDepth`` rather than set directly. It used to be an independent `Bool`,
    /// which was wrong the moment two ``withCard(_:)`` calls overlapped — and they do overlap: the
    /// Tag Memory window auto-dumps on `insertionCount` while the Tag screen auto-writes the same
    /// arrival. Whichever finished first cleared the flag and let presence polling resume
    /// underneath the other, which is exactly the field churn `pollSync` documents as the thing to
    /// avoid.
    @Published private(set) var isBusy = false
    /// How many ``withCard(_:)`` calls are currently in flight. Zero means the reader is free.
    ///
    /// Exposed (read-only) because "is the reader held" and "by how many things" are different
    /// questions, and only the second one can be asserted in a test.
    @Published private(set) var busyDepth = 0
    /// When the state last changed. Used to show "as of" in the reader inspector.
    @Published private(set) var lastChange: Date = .now
    /// Rises each time a card is newly seen. Views observe it to auto-run "read on insert".
    @Published private(set) var insertionCount: Int = 0

    /// Every PC/SC slot name the last poll enumerated, ungrouped.
    ///
    /// Diagnostics only, and the *only* place raw slot names are published: an ACR1552 publishes
    /// two slots from one box, and presenting that as two readers is a lie about the user's
    /// hardware, so everything user-facing goes through ``ReaderState/deviceNames`` instead. The
    /// Reader screen shows these underneath the device name as secondary detail, because "which
    /// slot did the tag land on" is a real question when a reader misbehaves.
    @Published private(set) var slots: [String] = []

    /// Presence poll interval, and therefore the longest a tag can be on the reader without being
    /// noticed. ~13 polls per second.
    static let pollInterval: Duration = .milliseconds(75)

    /// Human-readable form of ``pollInterval``, for the reader inspector.
    static let pollIntervalDescription = "about 13 times a second (every 75 ms)"

    private let engine = PCSCEngine()
    private var loop: Task<Void, Never>?

    init() {}

    deinit { loop?.cancel() }

    // MARK: Lifecycle

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: ReaderMonitor.pollInterval)
            }
        }
    }

    /// Stops polling and releases the PC/SC context. Called from `applicationWillTerminate` and
    /// on scene teardown — the Windows app hard-exits with `Environment.Exit(0)` and never
    /// releases its context (`MainForm.cs:928-931`); that is one of the listed non-goals.
    ///
    /// The release is **synchronous**, and has to be. It used to be a fire-and-forget
    /// `Task { await engine.shutdown() }`, which is a promise made to a process that is about to
    /// stop existing: `applicationWillTerminate` returns, AppKit exits, and the task is never
    /// scheduled — so the `SCARDCONTEXT` was leaked on every quit, which is precisely the
    /// non-goal being avoided. Blocking the main thread here is bounded by whatever card operation
    /// is on the queue and is exactly what "release it before we go" costs.
    func stop() {
        loop?.cancel()
        loop = nil
        engine.shutdownSync()
    }

    /// Forces an immediate poll, and rebuilds the PC/SC context first.
    ///
    /// This is what the "Try Again" button in the no-reader empty state calls. Rebuilding the
    /// context is the part that matters: it recovers from a stopped `pcscd` that a plain re-poll
    /// would keep reporting as "no readers".
    func retry() async {
        await engine.invalidateContext()
        await tick()
    }

    // MARK: Polling

    private func tick() async {
        guard !isBusy else { return }
        let snapshot = await engine.poll()
        apply(snapshot.state)
        if slots != snapshot.slots { slots = snapshot.slots }
    }

    private func apply(_ snapshot: ReaderState) {
        guard snapshot != state else { return }
        let hadCard = state.card
        state = snapshot
        lastChange = .now
        if let now = snapshot.card, now.uid != hadCard?.uid {
            insertionCount &+= 1
        }
    }

    // MARK: Card operations

    /// Runs `body` against a freshly connected session for whichever reader currently holds a
    /// card, pausing presence polling for the duration.
    ///
    /// Throws ``PCSCError/noReader`` or ``PCSCError/noCard`` rather than silently doing nothing,
    /// so callers can present a real message. The session is disconnected on the way out whether
    /// `body` succeeded or threw.
    // `T` is deliberately unconstrained: the domain result types (`TagReadResult`,
    // `TagWriteResult`, `[SectorDump]`) are `public` structs in SpoolworksCore and so do not pick up
    // implicit `Sendable` across the module boundary. Confinement is structural here — the value
    // is produced on the engine queue and consumed on the main actor, never shared.
    /// How long to wait before the one retry below. Long enough for a card that was announced a
    /// moment too early to finish powering up, short enough not to read as a hang.
    private static let settleDelay: Duration = .milliseconds(120)

    func withCard<T>(
        _ body: @escaping (CardSession, CardIdentity) throws -> T
    ) async throws -> T {
        beginCardOperation()
        defer { endCardOperation() }
        let result = try await performWithRetry(body)
        // The probe inside `performOnCard` is authoritative and cheaper than waiting a tick.
        apply(.cardPresent(result.identity))
        return result.value
    }

    /// Runs one card operation, retrying once if the *connection* went stale rather than the tag.
    ///
    /// `SCARD_W_UNPOWERED_CARD` and `SCARD_W_RESET_CARD` both mean the handle is no longer valid
    /// while the tag itself is sitting there perfectly well. Both were surfaced to the user as
    /// failures — `cardReset` even carried a doc comment calling it "recoverable — reconnect and
    /// retry", and nothing ever did. What the user did instead was press the button again, which
    /// worked, which is the whole of this method.
    ///
    /// It became visible when writing started on presentation rather than on a button press: the
    /// operation now begins in the moment between the reader announcing a card and that card being
    /// ready to talk. Reported from the bench as "tag is unpowered" on the first attempt at each
    /// of a spool's two tags, and fine on the second.
    ///
    /// Retrying is safe for what this app does on a card. Both operations are idempotent with the
    /// same input — a read has no effect at all, and a write puts the same bytes in the same
    /// blocks and then verifies them by reading back. A partially completed first attempt is
    /// therefore corrected rather than compounded by the second.
    private func performWithRetry<T>(
        _ body: @escaping (CardSession, CardIdentity) throws -> T
    ) async throws -> PCSCEngine.CardOperation<T> {
        do {
            return try await engine.performOnCard(body)
        } catch let error as PCSCError where error.isRecoverableCardState {
            try? await Task.sleep(for: Self.settleDelay)
            return try await engine.performOnCard(body)
        }
    }

    /// Claims the reader for one card operation. Re-entrant: the count, not a flag, is what
    /// decides whether polling may resume.
    private func beginCardOperation() {
        busyDepth += 1
        isBusy = true
    }

    /// Releases one claim. Polling resumes only when the last one goes.
    private func endCardOperation() {
        busyDepth = max(0, busyDepth - 1)
        isBusy = busyDepth > 0
    }

#if DEBUG
    // MARK: Test seams
    //
    // Debug-only, so the shipped app (`Tools/make-app.sh` builds release) does not carry them.
    // Nothing in the app calls either one.

    /// Runs `body` with the reader claimed, exactly as ``withCard(_:)`` does, but without any
    /// PC/SC involvement — which is all the depth counter needs in order to be asserted.
    ///
    /// The alternative, making `withCard` itself fakeable, would put a protocol between the UI and
    /// the single place PC/SC serialisation is enforced. That is a worse trade than this.
    func withReaderClaimed<T>(_ body: () async throws -> T) async rethrows -> T {
        beginCardOperation()
        defer { endCardOperation() }
        return try await body()
    }

    /// Publishes `state` as though a poll had produced it, including the insertion bookkeeping.
    ///
    /// This is what lets the card lifecycle — arrival, removal, swap — be driven with no reader
    /// attached, which is exactly the lifecycle whose bookkeeping used to break.
    func injectStateForTesting(_ state: ReaderState) {
        apply(state)
    }
#endif
}

// MARK: - Engine

/// Owns the `SCARDCONTEXT` and serialises every PC/SC call onto one queue.
///
/// `PCSCContext` documents itself as not thread-safe; this is the confinement it asks for.
/// An actor would put blocking `SCardConnect` calls on the cooperative pool, so a dedicated
/// serial `DispatchQueue` is used instead and the async surface is continuation-based.
private final class PCSCEngine: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.obsidiang.spoolworks.pcsc", qos: .userInitiated)

    // Everything below is touched only on `queue`.
    private var context: PCSCContext?
    private var contextFailure: String?
    private var knownCard: CardIdentity?
    /// Consecutive polls that saw zero readers. Drives context rebuilding.
    private var emptyPolls = 0
    /// Rebuild the context every N empty polls (~2 s).
    private let rebuildAfterEmptyPolls = 27

    /// The reader list, refreshed on its own slower cadence.
    ///
    /// Presence is sampled ~13 times a second; enumerating readers that often would be pure waste,
    /// since `k2_list_readers` is the expensive call and a USB device appearing half a second late
    /// is imperceptible. Card *arrival* is the only thing that needs the fast path.
    private var cachedNames: [String] = []
    private var ticksSinceNameRefresh = Int.max
    /// ~500 ms at a 75 ms tick.
    private let refreshNamesEvery = 7

    struct CardOperation<T> {
        let value: T
        let identity: CardIdentity
    }

    // MARK: Async surface

    /// One poll's result: the rendered state, plus the raw slot list behind it.
    struct PollResult {
        let state: ReaderState
        let slots: [String]
    }

    func poll() async -> PollResult {
        await withCheckedContinuation { continuation in
            queue.async {
                let state = self.pollSync()
                continuation.resume(returning: PollResult(state: state, slots: self.cachedNames))
            }
        }
    }

    func invalidateContext() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.releaseSync()
                continuation.resume()
            }
        }
    }

    /// Releases the context and blocks until it is gone.
    ///
    /// The only correct shape for termination: an `async` shutdown at quit is a task that never
    /// runs. `queue.sync` cannot deadlock here because nothing on `queue` ever waits on the main
    /// thread — the continuations it resumes are enqueued, not awaited.
    func shutdownSync() {
        queue.sync { self.releaseSync() }
    }

    /// Must be called on `queue`.
    private func releaseSync() {
        context = nil
        contextFailure = nil
        knownCard = nil
        emptyPolls = 0
        cachedNames = []
        ticksSinceNameRefresh = .max
    }

    func performOnCard<T>(
        _ body: @escaping (CardSession, CardIdentity) throws -> T
    ) async throws -> CardOperation<T> {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.performOnCardSync(body) })
            }
        }
    }

    // MARK: Queue-confined implementation

    private func ensureContext() -> PCSCContext? {
        if let context { return context }
        do {
            let fresh = try PCSCContext()
            context = fresh
            contextFailure = nil
            return fresh
        } catch {
            context = nil
            contextFailure = error.localizedDescription
            return nil
        }
    }

    /// The reader list, re-enumerated at most every ``refreshNamesEvery`` ticks.
    ///
    /// Also refreshed immediately whenever the cache is empty *and* it is time to look again, so
    /// plugging a reader in still recovers on its own without paying for an enumeration on every
    /// presence sample.
    private func readerNames(_ context: PCSCContext) -> [String] {
        if ticksSinceNameRefresh >= refreshNamesEvery {
            cachedNames = (try? context.readerNames()) ?? []
            ticksSinceNameRefresh = 0
        } else {
            ticksSinceNameRefresh += 1
        }
        return cachedNames
    }

    private func pollSync() -> ReaderState {
        guard let context = ensureContext() else {
            return .subsystemUnavailable(contextFailure ?? "PC/SC is unavailable.")
        }

        let names = readerNames(context)

        guard !names.isEmpty else {
            knownCard = nil
            emptyPolls += 1
            // `readerNames()` reports a dead context as an empty list, so an empty list is
            // ambiguous: nothing plugged in, or a context that outlived `pcscd`. Rebuilding
            // periodically resolves both without a user-visible difference.
            if emptyPolls % rebuildAfterEmptyPolls == 0 {
                self.context = nil
            }
            return .noReader
        }
        emptyPolls = 0

        // Presence comes from SCardGetStatusChange, which reads the reader's state without
        // opening a card session. An older implementation proved presence by connecting and
        // disconnecting on every poll; even at 3 Hz that churned the contactless field enough that
        // the reader intermittently dropped a tag sitting perfectly still, so the UI flickered
        // between "tag present" and "no tag". Only asking for the state is what makes a 13 Hz
        // sample safe; a session is still opened only when there is something new to identify.
        let occupied = names.filter { context.isCardPresent(reader: $0) }

        guard !occupied.isEmpty else {
            knownCard = nil
            return .idle(devices: ReaderNaming.devices(from: names), note: nil)
        }

        // Fast path: the same tag is still on the same reader, so skip the ATR/UID APDUs
        // and, importantly, do not touch the card at all.
        if let known = knownCard, occupied.contains(known.readerName) {
            return .cardPresent(known)
        }
        knownCard = nil

        var note: String?
        for name in occupied {
            do {
                let session = try context.connect(reader: name)
                let identity = probe(session, readerName: name)
                session.disconnect()
                knownCard = identity
                return .cardPresent(identity)
            } catch let error as PCSCError {
                // A card is present but we could not open it — a sharing violation, or it was
                // lifted between the state check and the connect. Worth surfacing; not fatal.
                if error != .noCard { note = error.localizedDescription }
            } catch {
                note = error.localizedDescription
            }
        }
        // Grouped: one entry per physical device, not per PC/SC slot.
        return .idle(devices: ReaderNaming.devices(from: names), note: note)
    }

    private func performOnCardSync<T>(
        _ body: (CardSession, CardIdentity) throws -> T
    ) throws -> CardOperation<T> {
        guard let context = ensureContext() else {
            throw PCSCError.unsupported(contextFailure ?? "PC/SC is unavailable")
        }
        // A card operation always enumerates for real rather than trusting the presence cache;
        // the result then re-primes that cache.
        let names = (try? context.readerNames()) ?? []
        cachedNames = names
        ticksSinceNameRefresh = 0
        guard !names.isEmpty else {
            knownCard = nil
            throw PCSCError.noReader
        }

        // Prefer the reader that last held a card, so a two-slot reader does not swap mid-flow.
        // Built by partition rather than `sorted`, whose predicate must be a strict weak ordering.
        var ordered = names
        if let preferred = knownCard?.readerName, let index = ordered.firstIndex(of: preferred) {
            ordered.remove(at: index)
            ordered.insert(preferred, at: 0)
        }

        var lastError: Error = PCSCError.noCard
        for name in ordered {
            let session: CardSession
            do { session = try context.connect(reader: name) }
            catch { lastError = error; continue }
            defer { session.disconnect() }

            let identity = probe(session, readerName: name)
            knownCard = identity
            return CardOperation(value: try body(session, identity), identity: identity)
        }
        knownCard = nil
        throw lastError
    }

    /// Identifies a card that is known to be connected. Never throws: a card that will not answer
    /// `FF CA` is a state the UI has to render, not an exception.
    private func probe(_ session: CardSession, readerName: String) -> CardIdentity {
        let atr = (try? session.atr()) ?? []
        let card = MifareClassicCard(transport: session)
        var uid: [UInt8] = []
        var uidFailure: String?
        do { uid = try card.readUID() } catch { uidFailure = error.localizedDescription }
        return CardIdentity(readerName: readerName,
                            atr: atr,
                            type: CardType.from(atr: atr),
                            uid: uid,
                            uidFailure: uidFailure,
                            firmware: card.readerFirmware())
    }
}
