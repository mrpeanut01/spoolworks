import Foundation

// Test entry point. Add new suites here.
let exitCode = TestDriver.run([
    // Reader / PC/SC layer
    hexTests,
    mifareKeyTests,
    cardTypeTests,
    mifareGeometryTests,
    mifareCardTests,
    apduResponseTests,
    readerDeviceTests,

    // Tag codec
    crealityCryptoTests,
    spoolRecordTests,
    spoolRecordValidationTests,
    spoolRecordGoldenTests,
    tagServiceTests,
    writeSafetyTests,
    integrityTests,
    sshInvocationSafetyTests,

    // Material database
    materialDatabaseTests,
    realPrinterDatabaseTests,

    // Colour matching
    colorTableTests,
    colorMatcherTests,
    colorHexTests,
    colorTableIntegrityTests,

    // Printer transport / upload
    printerModelTests,
    sshInvocationTests,
    sshSecretHandlingTests,
    sshErrorClassificationTests,
    processRunnerTests,
    printerUploadTests,
    materialDatabaseDocumentTests,
    printerUpdateTests,
    crealityCloudTests,
    credentialStoreTests,
    integrityFixTests,

    // Reader robustness (code-review fixes)
    readerRobustnessTests,

    // Print jobs and consumption
    filamentGeometryTests,
    printJobTrackerTests,
    moonrakerTests,
    spoolConsumptionTests,
    serialAllocationTests,
    filamentSwatchLibraryTests,
    smallSpoolLengthTests,
    cfsVersusJobTests,

    // Spool inventory
    spoolModelTests,
    spoolIdentityTests,
    spoolInventoryTests,
    inventoryReconcileTests,
    inventoryStoreTests,
    materialBoxInfoTests,
    cfsIdentityAmbiguityTests,
    liveCFSFixtureTests,

    // UI state machine (code-review fixes)
    spoolDraftTests,
    tagCascadeTests,
    tagAutoWriteStateTests,
    tagArrivalTests,
    readerMonitorBusyTests,

    // Spool management UI
    inventoryViewModelTests,
    intakeViewModelTests,
    cfsViewModelTests,
    keychainCredentialAdapterTests,
    writtenSpoolLoggingTests,
    uploadDefaultsTests,
    writeFormDefaultsTests,
    intakeAutoReadTests,
    intakeReaderContentionTests,
    intakeSlotStateTests,
])
exit(exitCode)
