import AVFoundation
import Combine
import XCTest
@testable import WhisperTranscriptionApp

private actor ReviewGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private final class ReviewContext: WhisperContextManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var loadedPath: String?
    private var loads = 0
    private var unloads = 0
    private var chunks = 0
    let loadGate = ReviewGate()
    let chunkGate = ReviewGate()
    var counts: (loads: Int, unloads: Int, chunks: Int) { lock.withLock { (loads, unloads, chunks) } }

    func isLoaded(path: String, useFlashAttention: Bool, useCoreML: Bool) -> Bool {
        lock.withLock { loadedPath == path }
    }
    func loadModel(path: String, useFlashAttention: Bool, useCoreML: Bool) async throws {
        lock.withLock { loads += 1 }
        await loadGate.wait()
        lock.withLock { loadedPath = path }
    }
    func unloadModel() { lock.withLock { loadedPath = nil; unloads += 1 } }
    func unloadModelAndWait() async { unloadModel() }
    func transcribeChunk(samples: [Float], startOffset: TimeInterval, segmentIDOffset: Int,
                         language: String, translate: Bool, prompt: String, useVAD: Bool,
                         vadModelPath: String?, cancellationToken: WhisperCancellationToken?,
                         onProgress: ((Double) -> Void)?) async throws -> TranscriptionResult {
        lock.withLock { chunks += 1 }
        await chunkGate.wait()
        guard lock.withLock({ loadedPath != nil }) else { throw WhisperModelServiceError.modelLoadFailed }
        return TranscriptionResult(text: "recognized", segments: [.init(id: 0, start: 0, end: 1, text: "recognized")], language: "en")
    }
}

final class ReviewRegressionTests: XCTestCase {
    private func temporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for the controlled operation")
    }

    func testConcurrentRequestsLoadSameModelOnce() async throws {
        let file = try temporaryFile()
        let context = ReviewContext()
        let service = WhisperModelService(context: context)
        let first = Task { try await service.ensureModelLoaded(path: file.path, useFlashAttention: false) }
        try await eventually { context.counts.loads == 1 }
        let second = Task { try await service.ensureModelLoaded(path: file.path, useFlashAttention: false) }
        await context.loadGate.open()
        try await first.value
        try await second.value
        XCTAssertEqual(context.counts.loads, 1)
    }

    func testCancelledCallerDoesNotCancelNextCaller() async throws {
        let file = try temporaryFile()
        let context = ReviewContext()
        let service = WhisperModelService(context: context)
        let first = Task { try await service.ensureModelLoaded(path: file.path, useFlashAttention: false) }
        try await eventually { context.counts.loads == 1 }
        first.cancel()
        let second = Task { try await service.ensureModelLoaded(path: file.path, useFlashAttention: false) }
        await context.loadGate.open()
        do { try await first.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        try await second.value
        XCTAssertEqual(context.counts.loads, 1)
    }

    func testDifferentModelLoadsAfterFirstModelCompletes() async throws {
        let firstFile = try temporaryFile()
        let secondFile = try temporaryFile()
        let context = ReviewContext()
        let service = WhisperModelService(context: context)
        let first = Task { try await service.ensureModelLoaded(path: firstFile.path, useFlashAttention: false) }
        try await eventually { context.counts.loads == 1 }
        let second = Task { try await service.ensureModelLoaded(path: secondFile.path, useFlashAttention: false) }
        await context.loadGate.open()
        try await first.value
        try await second.value
        XCTAssertEqual(context.counts.loads, 2)
        XCTAssertTrue(context.isLoaded(path: secondFile.path, useFlashAttention: false, useCoreML: false))
    }

    func testRecordingReleaseWaitsUntilTranscriptionCompletes() async throws {
        let model = try temporaryFile()
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: audio) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        for i in 0..<16_000 { buffer.floatChannelData![0][i] = 0.1 }
        try AVAudioFile(forWriting: audio, settings: format.settings).write(from: buffer)
        let context = ReviewContext()
        let service = WhisperModelService(context: context)
        await context.loadGate.open()
        let recognition = Task {
            try await service.transcribe(modelPath: model.path, useFlashAttention: false, inputURL: audio,
                language: "en", translate: false, prompt: "", useVAD: false, vadModelPath: nil,
                preprocessAudio: false, onChunkProgress: { _, _ in })
        }
        try await eventually { context.counts.chunks == 1 }
        await service.releaseForRecording()
        XCTAssertEqual(context.counts.unloads, 0)
        await context.chunkGate.open()
        let result = try await recognition.value
        XCTAssertEqual(result.text, "recognized")
        XCTAssertEqual(context.counts.unloads, 1)
    }

    func testProgressStorageReleasesCapturedObjectsOnEveryExit() {
        final class Sentinel {}
        enum Exit: Error { case failed }
        for shouldThrow in [false, true] {
            weak var captured: Sentinel?
            func run() throws {
                let sentinel = Sentinel()
                captured = sentinel
                let storage = WhisperProgressCallbackStorage { [sentinel] _ in _ = sentinel }
                defer { withExtendedLifetime(storage) {} }
                storage.pointer.pointee.callback?(0.5)
                if shouldThrow { throw Exit.failed }
            }
            do { try run() } catch {}
            XCTAssertNil(captured)
        }
    }

    func testTimelineNeverPlacesLaterMarkerBeforeEarlierSpeech() {
        for (start, end) in [(29.0, 32.0), (0, 30), (0, 120), (20, 32)] {
            let segment = TranscriptionSegment(id: 0, start: start, end: end, text: "speech")
            XCTAssertEqual(TranscriptionTimelineItem.items(from: [segment]), [.segment(segment)])
        }
    }

    func testInvalidVADFilesAreRejected() throws {
        let url = try temporaryFile()
        for data in [Data("<html>503 unavailable</html>".utf8), Data(repeating: 0, count: 885_098), Data(repeating: 0, count: 20)] {
            try data.write(to: url)
            XCTAssertThrowsError(try ModelManager.validateVADModel(at: url))
        }
    }

    func testModelBackupExclusionDoesNotApplyToSiblingRecording() throws {
        let model = try temporaryFile()
        let recording = try temporaryFile()
        try ModelManager.excludeModelFromBackup(at: model)
        XCTAssertEqual(try model.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertNotEqual(try recording.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testPacketizedWhisperConversionMatchesContinuousConversion() async throws {
        for rate in [44_100.0, 48_000.0] {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
            let output = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            let samples = (0..<Int(rate * 2)).map { Float(sin(Double($0) * 2 * .pi * 997 / rate) * 0.5) }
            func convert(packetSize: Int) async throws -> [Float] {
                let converter = try XCTUnwrap(AVAudioConverter(from: format, to: output))
                converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
                converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
                var result: [Float] = []
                for start in stride(from: 0, to: samples.count, by: packetSize) {
                    let count = min(packetSize, samples.count - start)
                    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
                    buffer.frameLength = AVAudioFrameCount(count)
                    for i in 0..<count { buffer.floatChannelData![0][i] = samples[start + i] }
                    try AudioConverter.shared.appendConvertedSamples(from: buffer, converter: converter, to: &result)
                }
                try AudioConverter.shared.appendConvertedSamples(from: nil, converter: converter, to: &result)
                return result
            }
            let continuous = try await convert(packetSize: samples.count)
            let packetized = try await convert(packetSize: 1024)
            XCTAssertEqual(packetized.count, continuous.count)
            XCTAssertEqual(packetized.count, 32_000)
            let maxDifference = zip(packetized, continuous).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThan(maxDifference, 0.00001)
        }
    }
}

private final class SuspendedDownloadProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

extension ReviewRegressionTests {
    @MainActor
    func testOldDownloadCallbacksCannotClearReplacementTask() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuspendedDownloadProtocol.self]
        let manager = ModelManager(storageDirectory: directory, downloadConfiguration: configuration)
        let session = URLSession(configuration: configuration)
        defer { manager.cancelDownload(); manager.cancelVADDownload(); session.invalidateAndCancel() }
        manager.downloadWhisperModel(size: .smallQ5_1)
        let old = try XCTUnwrap(manager.downloadTask)
        manager.cancelDownload()
        manager.downloadWhisperModel(size: .largeV3TurboQ5_0)
        let replacement = try XCTUnwrap(manager.downloadTask)
        manager.urlSession(session, downloadTask: old, didWriteData: 50, totalBytesWritten: 50, totalBytesExpectedToWrite: 100)
        manager.urlSession(session, task: old, didCompleteWithError: URLError(.cancelled))
        manager.urlSession(session, downloadTask: old, didFinishDownloadingTo: directory.appendingPathComponent("stale"))
        XCTAssertTrue(manager.downloadTask === replacement)
        XCTAssertEqual(manager.activeWhisperDownloadSize, .largeV3TurboQ5_0)
        XCTAssertTrue(manager.isDownloading)
        XCTAssertEqual(manager.downloadProgress, 0)
        XCTAssertNil(manager.downloadError)

        manager.downloadVADModel()
        let oldVAD = try XCTUnwrap(manager.vadDownloadTask)
        manager.cancelVADDownload()
        manager.downloadVADModel()
        let newVAD = try XCTUnwrap(manager.vadDownloadTask)
        manager.urlSession(session, task: oldVAD, didCompleteWithError: URLError(.cancelled))
        manager.urlSession(session, downloadTask: oldVAD, didWriteData: 50, totalBytesWritten: 50, totalBytesExpectedToWrite: 100)
        XCTAssertTrue(manager.vadDownloadTask === newVAD)
        XCTAssertTrue(manager.isVADDownloading)
        XCTAssertEqual(manager.vadDownloadProgress, 0)
    }
}

private final class ReviewRecorder: RecordingAudioCapturing {
    var microphoneInputsPublisher: AnyPublisher<[RecordingMicrophone], Never> { Just([]).eraseToAnyPublisher() }
    var selectedMicrophonePublisher: AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
    var switchGate: ReviewGate?
    var selectedInput: String?
    var switchError: Error?
    func switchMicrophone(to id: String) async throws {
        selectedInput = id
        if let switchGate { await switchGate.wait() }
        if let switchError { throw switchError }
    }
    let recording = CurrentValueSubject<Bool, Never>(true)
    var recordingPublisher: AnyPublisher<Bool, Never> { recording.eraseToAnyPublisher() }
    var timePublisher: AnyPublisher<TimeInterval, Never> { Just(0).eraseToAnyPublisher() }
    var levelPublisher: AnyPublisher<Float, Never> { Just(0).eraseToAnyPublisher() }
    var interruptionPublisher: AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
    var interruptedURLPublisher: AnyPublisher<URL?, Never> { Just(nil).eraseToAnyPublisher() }
    var errorPublisher: AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
    var currentInputFormat: AVAudioFormat? { AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) }
    var currentRecordingURL: URL? = URL(fileURLWithPath: "/saved-recording.caf")
    var handler: AudioRecorder.AudioBufferHandler?
    var didStop = false
    func requestPermission() async -> Bool { true }
    func startRecording(context: RecordingStartContext) async throws { recording.send(true) }
    func stopRecording() async throws -> URL {
        didStop = true
        recording.send(false)
        return currentRecordingURL!
    }
    func setAudioBufferHandler(_ handler: AudioRecorder.AudioBufferHandler?) { self.handler = handler }
}

private final class ReviewLiveRecognizer: RecordingLiveRecognizing {
    var didStart = false
    var didStop = false
    var didCancel = false
    var stopGate: ReviewGate?
    var startGate: ReviewGate?
    func start(inputFormat: AVAudioFormat, recordingURL: URL?) async throws {
        didStart = true
        if let startGate { await startGate.wait() }
    }
    func stop(recordingURL: URL?) async throws -> LiveTranscriptionSnapshot {
        didStop = true
        if let stopGate { await stopGate.wait() }
        var result = LiveTranscriptionSnapshot()
        result.recordingURL = recordingURL
        return result
    }
    func cancel() async { didCancel = true }
    func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, at audioTime: AVAudioTime) {}
}

extension ReviewRegressionTests {
    @MainActor
    func testMicrophoneSwitchBlocksDuplicateSwitchAndStop() async throws {
        let recorder = ReviewRecorder()
        let gate = ReviewGate()
        recorder.switchGate = gate
        let service = RecordingService(audioRecorder: recorder)
        service.isRecording = true
        let switching = Task { await service.switchMicrophone(to: "built-in") }
        try await eventually { recorder.selectedInput != nil }
        XCTAssertTrue(service.isChangingRecordingState)
        await service.switchMicrophone(to: "bluetooth")
        XCTAssertEqual(recorder.selectedInput, "built-in")
        do {
            _ = try await service.stopRecording()
            XCTFail("Stop must not race microphone reconfiguration")
        } catch {
            XCTAssertFalse(recorder.didStop)
        }
        await gate.open()
        await switching.value
        XCTAssertFalse(service.isSwitchingMicrophone)
        XCTAssertTrue(service.isRecording)
        XCTAssertFalse(recorder.didStop)
    }

    @MainActor
    func testMicrophoneSwitchFailureIsVisibleAndClearsBusyState() async {
        let recorder = ReviewRecorder()
        recorder.switchError = AudioRecorderError.microphoneSwitchFailed("Disconnected")
        let service = RecordingService(audioRecorder: recorder)
        service.isRecording = true
        await service.switchMicrophone(to: "bluetooth")
        XCTAssertTrue(service.errorMessage?.contains("Disconnected") == true)
        XCTAssertFalse(service.isSwitchingMicrophone)
    }

    @MainActor
    func testRecordingStopsBeforeRecognitionFinalization() async throws {
        let recorder = ReviewRecorder()
        let live = ReviewLiveRecognizer()
        let gate = ReviewGate()
        live.stopGate = gate
        let service = RecordingService(audioRecorder: recorder, supportsLiveRecognition: { true },
            resolveLiveLocale: { .jaJP }, liveServiceFactory: { _, _ in live })
        service.isRecording = true
        service.startLiveTranscription()
        try await eventually { recorder.handler != nil }
        let stop = Task { try await service.stopRecording() }
        try await eventually { live.didStop }
        XCTAssertTrue(recorder.didStop)
        XCTAssertFalse(service.isRecording)
        XCTAssertNil(recorder.handler)
        await gate.open()
        let url = try await stop.value
        XCTAssertEqual(url, recorder.currentRecordingURL)
    }

    @MainActor
    func testStopDuringLocaleResolutionCannotInstallOldHandler() async throws {
        let recorder = ReviewRecorder()
        let live = ReviewLiveRecognizer()
        let gate = ReviewGate()
        var resolving = false
        let service = RecordingService(audioRecorder: recorder, supportsLiveRecognition: { true },
            resolveLiveLocale: { resolving = true; await gate.wait(); return .jaJP },
            liveServiceFactory: { _, _ in live })
        service.isRecording = true
        service.startLiveTranscription()
        try await eventually { resolving }
        _ = try await service.stopRecording()
        await gate.open()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(recorder.didStop)
        XCTAssertFalse(live.didStart)
        XCTAssertNil(recorder.handler)
        XCTAssertEqual(service.liveState, .idle)
    }

    @MainActor
    func testCancelledStartCannotRemoveReplacementHandler() async throws {
        let recorder = ReviewRecorder()
        let old = ReviewLiveRecognizer()
        let replacement = ReviewLiveRecognizer()
        let gate = ReviewGate()
        old.startGate = gate
        var creations = 0
        let service = RecordingService(audioRecorder: recorder, supportsLiveRecognition: { true },
            resolveLiveLocale: { .jaJP }, liveServiceFactory: { _, _ in
                creations += 1
                return creations == 1 ? old : replacement
            })
        service.isRecording = true
        service.startLiveTranscription()
        try await eventually { old.didStart }
        await service.cancelLiveTranscription()
        service.startLiveTranscription()
        try await eventually { recorder.handler != nil }
        await gate.open()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(replacement.didStart)
        XCTAssertFalse(replacement.didCancel)
        XCTAssertNotNil(recorder.handler)
        await service.cancelLiveTranscription()
    }
}

@available(iOS 18.0, *)
private actor ReviewSearchIndex: TranscriptionSearchIndex {
    var ids: Set<UUID> = []
    var failDeletion = true
    func indexEntities(_ entities: [TranscriptionEntity]) async throws { ids.formUnion(entities.map(\.id)) }
    func deleteEntities(_ identifiers: [UUID]) async throws {
        if failDeletion { throw URLError(.unknown) }
        ids.subtract(identifiers)
    }
    func deleteAll() async throws { ids.removeAll() }
}

extension ReviewRegressionTests {
    func testStartupRebuildRemovesDeletedSpotlightTextEvenWithEmptyDatabase() async throws {
        guard #available(iOS 18.0, *) else { return }
        let index = ReviewSearchIndex()
        let id = UUID()
        let entity = TranscriptionEntity(id: id, title: "private", text: "deleted text", createdAt: Date(),
            tags: [], duration: 1, language: "en", isFavorite: false)
        let beforeRestart = TranscriptionSpotlightIndexer(index: index)
        await beforeRestart.index(entity)
        await beforeRestart.delete(identifiers: [id])
        let stale = await index.ids
        XCTAssertEqual(stale, [id])
        let afterRestart = TranscriptionSpotlightIndexer(index: index)
        await afterRestart.indexAll([])
        let rebuilt = await index.ids
        XCTAssertTrue(rebuilt.isEmpty)
    }

    func testModelDownloadsRejectHTTPFailures() throws {
        let url = URL(string: "https://example.com/model.bin")!
        for status in [404, 503] {
            XCTAssertThrowsError(try ModelManager.validateDownloadResponse(
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
        }
        XCTAssertNoThrow(try ModelManager.validateDownloadResponse(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        XCTAssertThrowsError(try ModelManager.validateDownloadResponse(nil))
    }
}

extension ReviewRegressionTests {
    func testRecognitionResultCannotOverwriteManualEdit() throws {
        let record = TranscriptionRecord(title: "test", text: "original", sourceType: .file,
            audioFilePath: nil, duration: 1)
        let revision = record.transcriptionRevision
        record.updateTranscription(text: "saved edit", duration: 1,
            segments: [.init(id: 0, start: 0, end: 1, text: "saved edit")], language: "en")
        XCTAssertThrowsError(try record.updateTranscription(text: "late recognition", duration: 1,
            segments: [], language: "en", ifUnchangedSince: revision))
        XCTAssertEqual(record.text, "saved edit")
        XCTAssertEqual(record.segments.first?.text, "saved edit")
    }

    func testPlaybackIsRejectedWhileRecorderOwnsSession() throws {
        let ownership = AudioSessionOwnership()
        ownership.beginRecording()
        defer { ownership.endRecording {} }
        XCTAssertThrowsError(try ownership.startPlayback(AVAudioPlayer())) { error in
            XCTAssertEqual((error as NSError).domain, "AudioSessionOwnership")
            XCTAssertEqual((error as NSError).code, 1)
        }
    }
}

extension ReviewRegressionTests {
    @MainActor
    func testWhisperManagementDoesNotUseSelectedSpeechReadinessOrChangeSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ModelManager(storageDirectory: directory, downloadConfiguration: .ephemeral)
        let selected = TranscriptionModel.appleSpeech(.jaJP)
        manager.currentTranscriptionModel = selected
        manager.isModelReady = true
        let viewModel = DownloadViewModel(modelManager: manager)
        viewModel.manageWhisper(.smallQ5_1)
        XCTAssertFalse(viewModel.isComplete)
        XCTAssertFalse(viewModel.isModelAvailable)
        XCTAssertEqual(manager.currentTranscriptionModel, selected)
        XCTAssertTrue(manager.isModelReady)
    }

    func testSpeechIntentLanguageOverrideIsNormalizedAndUnsupportedIsRejected() async throws {
        var requested: String?
        let resolved = try await IntentSpeechLanguage.resolve(override: "fr", selected: .jaJP) { locale in
            requested = locale.language.languageCode?.identifier
            return Locale(identifier: "fr_FR")
        }
        XCTAssertEqual(requested, "fr")
        XCTAssertEqual(resolved.localeIdentifier, "fr_FR")
        let selected = try await IntentSpeechLanguage.resolve(override: nil, selected: .jaJP) { _ in
            XCTFail("Absent override must retain selected locale")
            return nil
        }
        XCTAssertEqual(selected, .jaJP)
        for value in ["auto", "", "zz"] {
            do {
                _ = try await IntentSpeechLanguage.resolve(override: value, selected: .jaJP) { _ in nil }
                XCTFail("Expected unsupported language error")
            } catch {
                guard case IntentError.speechLocaleNotSupported = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }
}

extension ReviewRegressionTests {
    func testLiveInputBacklogHasBoundedDurationAndRecoversCapacity() throws {
        guard #available(iOS 26.0, *) else { return }
        let service = LiveTranscriptionService(locale: .jaJP, onSnapshot: { _ in })
        XCTAssertTrue(service.reserveQueuedAudio(3))
        XCTAssertTrue(service.reserveQueuedAudio(2))
        XCTAssertFalse(service.reserveQueuedAudio(0.01))
        service.releaseQueuedAudio(3)
        XCTAssertTrue(service.reserveQueuedAudio(3))
        XCTAssertFalse(service.reserveQueuedAudio(.infinity))
    }

    func testLongChunkMergePreservesAllNonBoundarySegments() {
        let previous = (0..<10_000).map { TranscriptionSegment(id: $0, start: Double($0), end: Double($0 + 1), text: "previous \($0)") }
        let next = (0..<10_000).map { TranscriptionSegment(id: $0, start: 10_000 + Double($0), end: 10_001 + Double($0), text: "next \($0)") }
        let merged = TranscriptionChunkProcessor.acceptedSegments(from: next, acceptedStart: 10_000, previousSegments: previous)
        XCTAssertEqual(merged, next)
    }
}
