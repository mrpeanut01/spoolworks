import Foundation
import CPCSC

/// Owns an `SCARDCONTEXT` and enumerates readers.
///
/// Not thread-safe by itself; callers should confine a context to one queue, or use
/// `ReaderMonitor`, which owns its own context on a dedicated thread.
public final class PCSCContext {
    private var handle: UnsafeMutableRawPointer?

    public init() throws {
        var ctx: UnsafeMutableRawPointer?
        let rv = k2_establish(&ctx)
        if let err = PCSCError.from(rv) { throw err }
        self.handle = ctx
    }

    deinit {
        if let h = handle { _ = k2_release(h) }
    }

    /// Names of all connected readers. Empty if none are attached.
    ///
    /// A missing PC/SC service or an unplugged reader surfaces as an empty list rather than
    /// an error, because "no reader" is a normal UI state, not a failure.
    public func readerNames() throws -> [String] {
        var len: UInt32 = 0
        let sizeRv = k2_list_readers(handle, nil, &len)
        // No readers attached: the stack reports this as an error code, but it is a normal state.
        if sizeRv != 0 || len == 0 { return [] }

        var buf = [CChar](repeating: 0, count: Int(len))
        let rv = k2_list_readers(handle, &buf, &len)
        if rv != 0 { return [] }
        return Self.parseReaderNames(buf, length: Int(len))
    }

    /// Splits a PC/SC multi-string — NUL-separated names, double-NUL terminated — into names.
    ///
    /// Deliberately avoids `String(cString:)`, which was wrong here twice over:
    ///
    /// 1. It walks to the next NUL with no upper bound. The old `while offset < len` loop bounded
    ///    only where each name *started*, not how far the strlen walk ran, so a buffer a driver
    ///    forgot to terminate read straight off the end of the allocation.
    /// 2. It substitutes U+FFFD for invalid UTF-8, which makes the returned string's `utf8.count`
    ///    larger than the bytes it came from. Advancing the cursor by it desynchronised the parse
    ///    from the buffer for every name after a non-UTF-8 one.
    ///
    /// Both terminators and the cursor are therefore computed from byte offsets only; decoding is
    /// lossy but can no longer move the cursor.
    static func parseReaderNames(_ buf: [CChar], length: Int) -> [String] {
        let limit = min(max(length, 0), buf.count)
        var names: [String] = []
        var offset = 0
        while offset < limit {
            // Bounded search for this name's terminator.
            var end = offset
            while end < limit && buf[end] != 0 { end += 1 }
            // A zero-length name is the second NUL that ends the multi-string.
            if end == offset { break }
            names.append(String(decoding: buf[offset..<end].map { UInt8(bitPattern: $0) },
                                as: UTF8.self))
            // If `end == limit` the final name was unterminated; it is still returned, and this
            // pushes the cursor past the limit so the loop ends.
            offset = end + 1
        }
        return names
    }

    /// Connects to the first reader that currently has a card on it.
    ///
    /// The ACR1552 exposes two contactless slots, so scanning all readers rather than
    /// assuming index 0 is required for reliable detection: an ACR1552 exposes two slots and a
    /// card appears on only one of them.
    public func connectToAnyCard() throws -> CardSession {
        let names = try readerNames()
        guard !names.isEmpty else { throw PCSCError.noReader }
        var lastError: PCSCError = .noCard
        for name in names {
            do { return try connect(reader: name) }
            catch let e as PCSCError { lastError = e; continue }
        }
        throw lastError
    }

    /// Connects to a card on a specific reader.
    public func connect(reader: String) throws -> CardSession {
        var card: UnsafeMutableRawPointer?
        var proto: UInt32 = 0
        let rv = k2_connect(handle, reader, 0, &card, &proto)
        if let err = PCSCError.from(rv) { throw err }
        return CardSession(handle: card, protocolID: proto, readerName: reader)
    }

    /// True if the named reader currently has a card on it.
    ///
    /// Uses `SCardGetStatusChange` with a zero timeout, which reports the current state without
    /// opening a card session. That distinction matters: proving presence by connecting and
    /// disconnecting several times a second churns the contactless field enough that the reader
    /// intermittently drops the card, so a tag sitting still on the antenna flickers in and out
    /// of view. Asking the reader for its state instead touches nothing.
    public func isCardPresent(reader: String) -> Bool {
        let (rv, state) = waitForStateChange(reader: reader,
                                             currentState: Self.stateUnaware,
                                             timeoutMs: 0)
        guard rv == 0 else { return false }
        return (state & Self.statePresent) != 0
    }

    /// Names of every attached reader that currently has a card on it.
    public func readersWithCard() -> [String] {
        guard let names = try? readerNames() else { return [] }
        return names.filter { isCardPresent(reader: $0) }
    }

    /// True if any attached reader currently has a card on it.
    public func isCardPresent() -> Bool {
        !readersWithCard().isEmpty
    }

    /// Blocks until the card state on `reader` changes, or the timeout elapses.
    ///
    /// Public so a UI-layer monitor can wait on a reader event instead of sampling on a timer:
    /// a blocking wait reports an arrival the moment the reader sees it, which is what makes a
    /// brief tap register. Call from a background thread, and use `cancelPendingWaits()` to
    /// unblock it during shutdown or when the reader list changes.
    public func waitForStateChange(reader: String, currentState: UInt32, timeoutMs: UInt32) -> (rv: Int32, newState: UInt32) {
        var newState: UInt32 = 0
        let rv = k2_status_change(handle, reader, currentState, &newState, timeoutMs)
        return (rv, newState)
    }

    /// Unblocks a pending `waitForStateChange` from another thread.
    public func cancelPendingWaits() { _ = k2_cancel(handle) }

    // Raw state masks, re-exported from the C side so Swift never hardcodes them.
    public static let stateUnaware = k2_state_unaware()
    public static let stateChanged = k2_state_changed()
    public static let statePresent = k2_state_present()
    public static let stateEmpty = k2_state_empty()
    public static let infinite = k2_infinite()
}

/// A connected card. Disconnects on deinit.
public final class CardSession {
    private var handle: UnsafeMutableRawPointer?
    fileprivate var protocolID: UInt32
    public let readerName: String

    init(handle: UnsafeMutableRawPointer?, protocolID: UInt32, readerName: String) {
        self.handle = handle
        self.protocolID = protocolID
        self.readerName = readerName
    }

    deinit { disconnect() }

    public func disconnect() {
        if let h = handle { _ = k2_disconnect(h); handle = nil }
    }

    /// The card's ATR, which identifies the card type.
    public func atr() throws -> [UInt8] {
        var atr = [UInt8](repeating: 0, count: 64)
        var len: UInt32 = 64
        var state: UInt32 = 0
        var proto: UInt32 = 0
        let rv = k2_atr(handle, &atr, &len, &state, &proto)
        if let err = PCSCError.from(rv) { throw err }
        // Clamp: the length is an out-parameter written by the driver, and slicing on a value
        // larger than the buffer is a trap, not an error we could report.
        return Array(atr[0..<min(Int(len), atr.count)])
    }
}

extension CardSession: APDUTransport {
    /// Resets the card, clearing poisoned crypto state left by a failed MIFARE authentication.
    public func reset() throws {
        var proto: UInt32 = 0
        let rv = k2_reconnect(handle, &proto)
        if let err = PCSCError.from(rv) { throw err }
        protocolID = proto
    }

    /// Sends a raw APDU and returns the response including status bytes.
    public func transmit(_ apdu: [UInt8]) throws -> APDUResponse {
        var rx = [UInt8](repeating: 0, count: 264)
        var rxLen: UInt32 = 264
        let rv = k2_transmit(handle, protocolID, apdu, UInt32(apdu.count), &rx, &rxLen)
        if let err = PCSCError.from(rv) { throw err }
        // Clamp for the same reason as `atr()`: a driver that over-reports the response length
        // would otherwise turn a bad reply into a range trap instead of a handled error.
        return try APDUResponse(raw: Array(rx[0..<min(Int(rxLen), rx.count)]))
    }
}
