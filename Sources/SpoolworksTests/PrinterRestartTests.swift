import Foundation
@testable import SpoolworksCore
@testable import SpoolworksUI

// Never restart a printer that is printing (D-006): the service's guard, what Moonraker's answer
// decodes to, and the scheduler that waits for a print to finish.

// MARK: - Bridging

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func mutate(_ change: (inout T) -> Void) {
        lock.withLock { change(&stored) }
    }
}

/// Drives async Core work from the synchronous harness, as `PrinterServiceTests` does.
private func runSync<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = Box<Result<T, Error>?>(nil)
    let done = DispatchSemaphore(value: 0)
    Task {
        do { box.value = .success(try await body()) } catch { box.value = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.value!.get()
}

private func errorFrom<T>(_ body: @escaping @Sendable () async throws -> T) -> Error? {
    do { _ = try runSync(body); return nil } catch { return error }
}

/// Pumps the main run loop until `body` finishes, because the scheduler is `@MainActor`.
private func runOnMain(timeout: TimeInterval = 20, _ body: @escaping @MainActor () async -> Void) {
    let done = Box(false)
    Task { @MainActor in
        await body()
        done.value = true
    }
    let deadline = Date().addingTimeInterval(timeout)
    while !done.value && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
    }
}

// MARK: - Fixtures

private let printerHost = "192.168.10.19"

/// What a K2 Plus answered mid-print, 2026-09-11.
private let midPrintReply = Data(#"{"result":{"eventtime":3974575.28,"status":{"print_stats":{"state":"printing","filename":"obj_1_.gcode"},"idle_timeout":{"state":"Printing","printing_time":14731.88}}}}"#.utf8)

private func activityReply(printStats state: String?, idle: String?) -> Data {
    var status: [String: Any] = [:]
    if let state { status["print_stats"] = ["state": state] }
    if let idle { status["idle_timeout"] = ["state": idle] }
    return (try? JSONSerialization.data(withJSONObject: ["result": ["status": status]])) ?? Data()
}

// MARK: - The guard

let printerRestartTests = TestSuite(name: "Never restart during a print (D-006)", cases: [

    test("the printer's state is read before the restart is sent") { t in
        let mock = MockPrinterTransport()
        let sentBeforeRead = Box<[String]?>(nil)
        let reader = PrinterActivityStub { _ in
            sentBeforeRead.value = mock.commands
            return .idle
        }
        try runSync { try await PrinterService(transport: mock).restartIfIdle(host: printerHost, checkingWith: reader) }
        t.equal(sentBeforeRead.value, [], "nothing had been sent when the state was read")
        t.equal(mock.commands, [PrinterCommand.reboot], "then exactly one restart")
    },

    test("a printing printer is never restarted") { t in
        let mock = MockPrinterTransport()
        let error = errorFrom { try await PrinterService(transport: mock)
            .restartIfIdle(host: printerHost, checkingWith: PrinterActivityStub(.printing(paused: false))) }
        t.equal(error as? RestartRefusal, .printing(paused: false))
        t.equal(mock.commands, [], "nothing sent")
    },

    test("a paused print is never restarted either") { t in
        let mock = MockPrinterTransport()
        let error = errorFrom { try await PrinterService(transport: mock)
            .restartIfIdle(host: printerHost, checkingWith: PrinterActivityStub(.printing(paused: true))) }
        t.equal(error as? RestartRefusal, .printing(paused: true))
        t.equal(mock.commands, [], "nothing sent")
    },

    test("a printer running a command is not restarted") { t in
        let mock = MockPrinterTransport()
        let error = errorFrom { try await PrinterService(transport: mock)
            .restartIfIdle(host: printerHost, checkingWith: PrinterActivityStub(.busy)) }
        t.equal(error as? RestartRefusal, .busy)
        t.equal(mock.commands, [], "nothing sent")
    },

    test("a printer whose state cannot be read is not restarted") { t in
        let mock = MockPrinterTransport()
        let unreadable = PrinterActivityStub { _ in throw MoonrakerError.badResponse(status: 503) }
        let error = errorFrom { try await PrinterService(transport: mock)
            .restartIfIdle(host: printerHost, checkingWith: unreadable) }
        if case .unconfirmed? = error as? RestartRefusal {} else {
            t.expect(false, "expected unconfirmed, got \(String(describing: error))")
        }
        t.equal(mock.commands, [], "nothing sent")
    },

    test("the connection dropping after the restart counts as success") { t in
        let mock = MockPrinterTransport()
        mock.failRun = .remoteCommandFailed(exitStatus: 255,
                                            message: "Connection to 192.168.10.19 closed by remote host.")
        let error = errorFrom { try await PrinterService(transport: mock)
            .restartIfIdle(host: printerHost, checkingWith: PrinterActivityStub(.idle)) }
        t.expect(error == nil, "a torn-down connection is what a restart looks like: \(String(describing: error))")
    },

    test("a real failure sending the restart still propagates") { t in
        let mock = MockPrinterTransport()
        mock.failRun = .authenticationFailed
        let error = errorFrom { try await PrinterService(transport: mock)
            .restartIfIdle(host: printerHost, checkingWith: PrinterActivityStub(.idle)) }
        t.equal(error as? PrinterTransportError, .authenticationFailed)
    },

    test("the reply a K2 Plus gave mid-print decodes as printing") { t in
        t.equal(try MoonrakerClient.decodeActivity(midPrintReply), .printing(paused: false))
    },

    test("a paused job is still a print in progress") { t in
        t.equal(try MoonrakerClient.decodeActivity(activityReply(printStats: "paused", idle: "Ready")),
                .printing(paused: true))
    },

    test("a finished, cancelled or failed job with nothing running is idle") { t in
        for state in ["standby", "complete", "cancelled", "error"] {
            for idle in ["Ready", "Idle"] {
                t.equal(try MoonrakerClient.decodeActivity(activityReply(printStats: state, idle: idle)),
                        .idle, "\(state) / \(idle)")
            }
        }
    },

    test("no job, but Klipper executing commands, is busy") { t in
        t.equal(try MoonrakerClient.decodeActivity(activityReply(printStats: "standby", idle: "Printing")), .busy)
    },

    test("a missing or unknown job state is an error, never idle") { t in
        t.throwsError("no print_stats") {
            _ = try MoonrakerClient.decodeActivity(activityReply(printStats: nil, idle: "Ready"))
        }
        t.throwsError("unknown state") {
            _ = try MoonrakerClient.decodeActivity(activityReply(printStats: "warming_up", idle: "Ready"))
        }
        t.throwsError("not JSON") { _ = try MoonrakerClient.decodeActivity(Data("<html>".utf8)) }
    },
])

// MARK: - Restarting once the print finishes

/// A printer that answers from a script — the last answer repeats — and counts restarts.
private final class ScriptedPrinter: PrinterTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<PrinterActivity, Error>]
    private var refusals: [RestartRefusal]
    private var readCount = 0
    private var restartCount = 0

    init(_ script: [Result<PrinterActivity, Error>], refusals: [RestartRefusal] = []) {
        self.script = script
        self.refusals = refusals
    }

    var reads: Int { lock.withLock { readCount } }
    var restarts: Int { lock.withLock { restartCount } }

    func activity(host _: String) async throws -> PrinterActivity {
        try lock.withLock {
            readCount += 1
            let answer = script.count > 1 ? script.removeFirst() : script[0]
            return try answer.get()
        }
    }

    func restartIfIdle(_: PrinterCredentials, family _: PrinterType) async throws {
        try lock.withLock {
            if !refusals.isEmpty { throw refusals.removeFirst() }
            restartCount += 1
        }
    }

    func remoteDatabaseVersion(_: PrinterCredentials, family _: PrinterType) async throws -> String {
        throw PrinterUIError.notImplemented
    }

    func downloadDatabase(_: PrinterCredentials, family _: PrinterType) async throws -> Data {
        throw PrinterUIError.notImplemented
    }

    func uploadDatabase(_: Data, credentials _: PrinterCredentials, family _: PrinterType,
                        options _: UploadOptions,
                        progress _: @escaping @Sendable (PrinterProgress) -> Void) async throws -> String {
        throw PrinterUIError.notImplemented
    }

    func resetDatabase(_: Data, credentials _: PrinterCredentials, family _: PrinterType,
                       progress _: @escaping @Sendable (PrinterProgress) -> Void) async throws {
        throw PrinterUIError.notImplemented
    }

    func downloadBoxInfo(_: PrinterCredentials, family _: PrinterType) async throws -> MaterialBoxInfo {
        throw PrinterUIError.notImplemented
    }
}

@MainActor
private struct SchedulerHarness {
    let scheduler: PrinterRestartScheduler
    let events: Box<[PrinterRestartScheduler.Event]>
}

/// A scheduler on a fake clock: each poll moves time on by `pollInterval`, and a watch that would
/// otherwise go on forever is stopped after `maxPolls`.
@MainActor
private func makeScheduler(_ printer: ScriptedPrinter,
                           quietPeriod: TimeInterval = 0,
                           pollInterval: TimeInterval = 15,
                           maxPolls: Int = 50,
                           hasPassword: Bool = true) -> SchedulerHarness {
    let clock = Box(Date(timeIntervalSince1970: 1_800_000_000))
    let polls = Box(0)
    let scheduler = PrinterRestartScheduler(
        transport: printer,
        pollInterval: pollInterval,
        quietPeriod: quietPeriod,
        now: { clock.value },
        sleep: { seconds in
            polls.mutate { $0 += 1 }
            if polls.value > maxPolls { throw CancellationError() }
            clock.mutate { $0 = $0.addingTimeInterval(seconds) }
            await Task.yield()
        })
    scheduler.credentials = { _ in
        hasPassword ? PrinterCredentials(host: printerHost, password: "secret") : nil
    }
    let events = Box<[PrinterRestartScheduler.Event]>([])
    scheduler.onEvent = { event in events.mutate { $0.append(event) } }
    return SchedulerHarness(scheduler: scheduler, events: events)
}

let printerRestartSchedulerTests = TestSuite(name: "Restart automatically when the print finishes (D-006)", cases: [

    test("waits out a running print, then restarts once the printer is idle") { t in
        runOnMain {
            let printer = ScriptedPrinter([.success(.printing(paused: false)),
                                           .success(.printing(paused: false)),
                                           .success(.idle)])
            let h = makeScheduler(printer)
            h.scheduler.schedule(family: .k2, printerName: "K2 Plus", host: printerHost)
            await h.scheduler.settle(.k2)
            t.equal(printer.restarts, 1, "restarted once")
            t.equal(printer.reads, 3, "and not before the print was over")
            t.equal(h.events.value, [.restarted(printerName: "K2 Plus")])
            t.equal(h.scheduler.pending[.k2], nil, "nothing left pending")
        }
    },

    test("never restarts while the print keeps running") { t in
        runOnMain {
            let printer = ScriptedPrinter([.success(.printing(paused: false))])
            let h = makeScheduler(printer, maxPolls: 20)
            h.scheduler.schedule(family: .k2, printerName: "K2 Plus", host: printerHost)
            await h.scheduler.settle(.k2)
            t.equal(printer.restarts, 0, "no restart")
            t.expect(printer.reads > 10, "it kept checking (\(printer.reads) reads)")
            t.equal(h.events.value, [])
            t.equal(h.scheduler.pending[.k2]?.status, .waitingForPrint)
        }
    },

    test("a paused print or a busy printer is waited out the same way") { t in
        runOnMain {
            let printer = ScriptedPrinter([.success(.printing(paused: true)), .success(.busy), .success(.idle)])
            let h = makeScheduler(printer)
            h.scheduler.schedule(family: .k2, printerName: "K2 Plus", host: printerHost)
            await h.scheduler.settle(.k2)
            t.equal(printer.reads, 3)
            t.equal(printer.restarts, 1)
        }
    },

    test("restarts only once the printer has stayed idle for the quiet period") { t in
        runOnMain {
            let printer = ScriptedPrinter([.success(.printing(paused: false)), .success(.idle)])
            let h = makeScheduler(printer, quietPeriod: 60, pollInterval: 15)
            h.scheduler.schedule(family: .k2, printerName: "K2 Plus", host: printerHost)
            await h.scheduler.settle(.k2)
            // Printing at 0 s, idle from 15 s: 60 s of idle is reached at the check at 75 s.
            t.equal(printer.reads, 6)
            t.equal(printer.restarts, 1)
        }
    },

    test("a print that starts during the quiet period starts the wait again") { t in
        runOnMain {
            let printer = ScriptedPrinter([.success(.idle), .success(.printing(paused: false)), .success(.idle)])
            let h = makeScheduler(printer, quietPeriod: 30, pollInterval: 15)
            h.scheduler.schedule(family: .k2, printerName: "K2 Plus", host: printerHost)
            await h.scheduler.settle(.k2)
            // Idle at 0 s, printing at 15 s, idle again from 30 s: 30 s of idle is reached at 60 s,
            // not at 30 s as it would be if the first idle reading still counted.
            t.equal(printer.reads, 5)
            t.equal(printer.restarts, 1)
        }
    },

    test("a restart refused at the last moment keeps waiting instead") { t in
        runOnMain {
            let printer = ScriptedPrinter([.success(.idle)], refusals: [.printing(paused: false)])
            let h = makeScheduler(printer)
            h.scheduler.schedule(family: .k2, printerName: "K2 Plus", host: printerHost)
            await h.scheduler.settle(.k2)
            t.equal(printer.restarts, 1, "restarted at the next idle check, not the refused one")
            t.equal(printer.reads, 2)
            t.equal(h.events.value, [.restarted(printerName: "K2 Plus")])
        }
    },

    test("a printer that cannot be read is never taken to be idle") { t in
        runOnMain {
            let printer = ScriptedPrinter([.failure(MoonrakerError.badResponse(status: 503))])
            let h = makeScheduler(printer, maxPolls: 10)
            h.scheduler.schedule(family: .k2, printerName: "K2 Plus", host: printerHost)
            await h.scheduler.settle(.k2)
            t.equal(printer.restarts, 0)
            t.equal(h.events.value, [])
            if case .unreachable? = h.scheduler.pending[.k2]?.status {} else {
                t.expect(false, "expected unreachable, got \(String(describing: h.scheduler.pending[.k2]?.status))")
            }
        }
    },

    test("with no saved password it gives up rather than restart") { t in
        runOnMain {
            let printer = ScriptedPrinter([.success(.idle)])
            let h = makeScheduler(printer, hasPassword: false)
            h.scheduler.schedule(family: .k2, printerName: "K2 Plus", host: printerHost)
            await h.scheduler.settle(.k2)
            t.equal(printer.restarts, 0)
            t.equal(h.events.value, [.gaveUp(printerName: "K2 Plus", reason: "it has no saved password")])
            t.equal(h.scheduler.pending[.k2], nil)
        }
    },

    test("cancelling stops the wait and sends nothing") { t in
        runOnMain {
            let printer = ScriptedPrinter([.success(.idle)])
            let h = makeScheduler(printer)
            h.scheduler.schedule(family: .k2, printerName: "K2 Plus", host: printerHost)
            h.scheduler.cancel(family: .k2)
            for _ in 0..<50 { await Task.yield() }
            t.equal(printer.restarts, 0)
            t.equal(h.scheduler.pending[.k2], nil)
            t.equal(h.events.value, [])
        }
    },

    test("the pending restart says what it is waiting for") { t in
        runOnMain {
            let scheduler = PrinterRestartScheduler(transport: ScriptedPrinter([.success(.idle)]))
            let waiting = PrinterRestartScheduler.Pending(family: .k2, printerName: "K2 Plus",
                                                          host: printerHost, status: .waitingForPrint)
            let text = scheduler.statusText(for: waiting)
            t.expect(text.contains("once its print has finished"), text)
            t.expect(text.contains("2 minutes"), "names the quiet period: \(text)")
            t.equal(PrinterRestartScheduler.describe(60), "a minute")
            t.equal(PrinterRestartScheduler.describe(30), "30 seconds")
        }
    },
])
