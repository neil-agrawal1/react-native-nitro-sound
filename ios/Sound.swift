
import Foundation
import AVFoundation
import NitroModules
import SoundAnalysis
import FluidAudio
import Speech

    final class HybridSound: HybridSoundSpec_base, HybridSoundSpec_protocol, SNResultsObserving {
    // Removed AVAudioRecorder - now using unified AVAudioEngine recording

    // Unified Audio Engine - single engine for recording and playback
    private var audioEngine: AVAudioEngine?
    private var audioEngineInitialized = false

    // Dual player nodes for crossfading support
    private var audioPlayerNodeA: AVAudioPlayerNode?
    private var audioPlayerNodeB: AVAudioPlayerNode?
    private var currentPlayerNode: AVAudioPlayerNode?
    private var currentAudioFile: AVAudioFile?

    // Ambient loop player (independent layer)
    private var audioPlayerNodeC: AVAudioPlayerNode?
    private var isAmbientLoopPlaying: Bool = false
    private var currentAmbientFile: AVAudioFile?

    // Track which player is active (for future crossfading)
    private enum ActivePlayer {
        case playerA, playerB, none
    }
    private var activePlayer: ActivePlayer = .none

    // Segment recording modes
    private enum SegmentMode {
        case idle       // No recording
        case autoVAD    // Automatic threshold detection (sleep talking)
        case manual     // Manual recording (alarm/day residue)
    }
    private var currentMode: SegmentMode = .idle

    // Crossfade state management
    private var crossfadeTimer: Timer?
    private var isCrossfading: Bool = false

    // Loop playback for overnight recording
    private var shouldLoopPlayback: Bool = false
    private var currentPlaybackURI: String?

    // Seamless looping with crossfade
    private var loopCrossfadeTimer: DispatchSourceTimer?
    private var loopCrossfadeDuration: TimeInterval = 0.200  // 200ms crossfade (masks audio engine buffer latency)
    private var isLoopCrossfadeActive: Bool = false
    private var playbackVolume: Float = 1.0  // Track desired playback volume for crossfades

    // Track starting frame offset for getCurrentPosition after seek
    private var startingFrameOffset: AVAudioFramePosition = 0

    // Cache last valid position to avoid returning 0 during player state transitions
    private var lastValidPosition: Double = 0.0

    private var playTimer: Timer?

    // Removed recordBackListener - only used with AVAudioRecorder
    private var playBackListener: ((PlayBackType) -> Void)?
    private var playbackEndListener: ((PlaybackEndType) -> Void)?
    private var didEmitPlaybackEnd = false

    private var subscriptionDuration: TimeInterval = 0.06
    private var playbackRate: Double = 1.0 // default 1x

    // Buffer recording properties - removed, now using native file events

    // Speech detection properties
    private var audioAnalyzer: SNAudioStreamAnalyzer?
    private var soundClassifier: SNClassifySoundRequest?
    private var isSpeechActive: Bool = false
    private var silenceFrameCount: Int = 0
    // private var audioLevelThreshold: Float = -25.0 // COMMENTED OUT - using VAD instead
    private var tapFrameCounter: Int = 0 // Debug counter

    // VAD properties
    private var vadManager: VadManager?
    private var vadStreamState: VadStreamState?
    private var vadThreshold: Float = 0.4  // 40% confidence (lower = more sensitive)

    // Audio format conversion (48kHz → 16kHz for VAD)
    private var audioConverter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?  // 16kHz format for VAD and file writing

    // MARK: - Audio Format Conversion Helper

    /// Converts a buffer from hardware sample rate (e.g., 48kHz) to 16kHz for VAD processing
    private func convertTo16kHz(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter = self.audioConverter,
              let targetFormat = self.targetFormat else {
            return nil
        }

        // Calculate output frame capacity based on sample rate ratio
        let sampleRateRatio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRateRatio)

        // Create output buffer at target format (16kHz)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            self.bridgedLog("⚠️ Conversion error: \(error.localizedDescription)")
            return nil
        }

        return outputBuffer
    }

    // Manual mode silence detection (default 15 seconds at ~14 fps = 210 frames)
    private var manualSilenceFrameCount: Int = 0
    private var manualSilenceThreshold: Int = 210  // Configurable, defaults to ~15 seconds at observed 14 fps

    // Rolling buffer for 3-second pre-roll (pre-allocated)
    private var rollingBuffer: RollingAudioBuffer?

    // File writing
    private var currentSegmentFile: AVAudioFile?
    private var currentSegmentIsManual: Bool = false
    private var segmentCounter = 0
    private var sessionTimestamp: Int64 = 0  // Unix timestamp for unique filenames across restarts
    private var silenceCounter = 0
    private let silenceThreshold = 25  // ~0.5 second of silence before ending segment
    private var segmentStartTime: Date?  // Track when segment started for duration calculation

    // Output directory for segments
    private var outputDirectory: URL?

    // Files are written to documents/speech_segments/ for JavaScript polling

    // Log callback to bridge Swift logs to JavaScript
    private var logCallback: ((String) -> Void)?

    // Segment callback to notify JavaScript when a new file is written
    private var segmentCallback: ((String, String, Bool, Double) -> Void)?

    // Manual silence timeout callback - notifies JS when 15s of silence detected in manual mode
    private var manualSilenceCallback: (() -> Void)?

    // MARK: - Unified Audio Engine Management

    override init() {
        super.init()
        setupAudioInterruptionHandling()
    }

    private func setupAudioInterruptionHandling() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleAudioInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        if type == .ended {
            // Restart engine after interruption
            if audioEngineInitialized {
                do {
                    try restartAudioEngine()
                } catch {
                    bridgedLog("❌ Failed to restart engine: \(error.localizedDescription)")
                }
            }
        }
    }

    private func restartAudioEngine() throws {
        guard let engine = audioEngine else {
            throw RuntimeError.error(withMessage: "No engine to restart")
        }

        // Session is already active from initializeAudioEngine(), no need to reactivate

        // Restart engine if stopped
        if !engine.isRunning {
            try engine.start()
        }
    }

    private func ensureEngineRunning() throws {
        guard let engine = audioEngine else {
            throw RuntimeError.error(withMessage: "Audio engine not initialized")
        }

        if !engine.isRunning {
            bridgedLog("⚠️ ENGINE: Restarting stopped engine")
            try restartAudioEngine()
        }
    }

    private func initializeAudioEngine() throws {
        guard !audioEngineInitialized else {
            return
        }

        bridgedLog("🎬 ENGINE: Initializing")

        // Setup audio session ONCE for recording + playback
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
        try audioSession.setPreferredSampleRate(44100)
        // Only set mono input if hardware supports it
        if audioSession.maximumInputNumberOfChannels >= 1 {
            try? audioSession.setPreferredInputNumberOfChannels(1)
        }
        try audioSession.setPreferredIOBufferDuration(0.0232) // ~23ms
        try audioSession.setActive(true)

        // Create the unified audio engine
        audioEngine = AVAudioEngine()

        // Create player nodes for crossfading support
        audioPlayerNodeA = AVAudioPlayerNode()
        audioPlayerNodeB = AVAudioPlayerNode()
        audioPlayerNodeC = AVAudioPlayerNode()

        // Attach nodes to engine
        guard let engine = audioEngine,
            let playerA = audioPlayerNodeA,
            let playerB = audioPlayerNodeB,
            let playerC = audioPlayerNodeC else {
            throw RuntimeError.error(withMessage: "Failed to create audio engine components")
        }

        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(playerC)

        // Connect player nodes to main mixer
        let mainMixer = engine.mainMixerNode
        engine.connect(playerA, to: mainMixer, format: nil)
        engine.connect(playerB, to: mainMixer, format: nil)
        engine.connect(playerC, to: mainMixer, format: nil)

        // Force input node initialization by accessing it (required for .playAndRecord)
        let _ = engine.inputNode

        // Now safe to start engine with both input and output configured
        try engine.start()
        audioEngineInitialized = true
        bridgedLog("✅ ENGINE: Initialized and running")
    }



    private func getCurrentPlayerNode() -> AVAudioPlayerNode? {
        // For now, always use player A. Later we can implement switching for crossfading
        switch activePlayer {
        case .playerA:
            return audioPlayerNodeA
        case .playerB:
            return audioPlayerNodeB
        case .none:
            // Default to player A for first use
            activePlayer = .playerA
            return audioPlayerNodeA
        }
    }

    private func handlePlaybackCompletion() {
        if let audioFile = self.currentAudioFile {
            let durationSeconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate
            let durationMs = durationSeconds * 1000
            self.emitPlaybackEndEvents(durationMs: durationMs, includePlaybackUpdate: true)
        }

        self.stopPlayTimer()
        self.currentPlayerNode = nil
    }

    private func scheduleMoreLoops(audioFile: AVAudioFile, playerNode: AVAudioPlayerNode) {
        guard self.shouldLoopPlayback else {
            return
        }

        // Schedule 3 more iterations
        playerNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
        playerNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
        playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
            // Recursive scheduling for continuous looping
            self?.scheduleMoreLoops(audioFile: audioFile, playerNode: playerNode)
        }
    }

    private func scheduleMoreAmbientLoops(audioFile: AVAudioFile, playerNode: AVAudioPlayerNode) {
        guard self.isAmbientLoopPlaying else {
            return
        }

        // Schedule 3 more iterations
        playerNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
        playerNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
        playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
            // Recursive scheduling for continuous looping
            self?.scheduleMoreAmbientLoops(audioFile: audioFile, playerNode: playerNode)
        }
    }


    // MARK: - Recording Methods

    public func startRecorder() throws -> Promise<Void> {
        let promise = Promise<Void>()

        bridgedLog("🎙️ RECORDING: Starting")

        // Return immediately and process in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            do {
                try self.initializeAudioEngine()
                let audioSession = AVAudioSession.sharedInstance()

                audioSession.requestRecordPermission { [weak self] allowed in
                    guard let self = self else { return }

                    if allowed {
                        DispatchQueue.global(qos: .userInitiated).async {
                            self.setupRecording(promise: promise)
                        }
                    } else {
                        self.bridgedLog("❌ RECORDING: Microphone permission denied")
                        promise.reject(withError: RuntimeError.error(withMessage: "Microphone permission denied. Please enable microphone access in Settings > Dust."))
                    }
                }

            } catch {
                self.bridgedLog("❌ RECORDING: Failed - \(error.localizedDescription)")
                promise.reject(withError: RuntimeError.error(withMessage: "Audio engine initialization failed: \(error.localizedDescription)"))
            }
        }

        return promise
    }

    // MARK: - Legacy Recording Methods (stubs for backwards compatibility)

    public func pauseRecorder() throws -> Promise<String> {
        let promise = Promise<String>()
        promise.reject(withError: RuntimeError.error(withMessage: "Pause/resume not supported with unified recording. Use start/stop instead."))
        return promise
    }

    public func resumeRecorder() throws -> Promise<String> {
        let promise = Promise<String>()
        promise.reject(withError: RuntimeError.error(withMessage: "Pause/resume not supported with unified recording. Use start/stop instead."))
        return promise
    }

    // MARK: - File Writing Methods

    private func trimLastSeconds(_ seconds: Double, fromFileAt url: URL) throws {
        guard seconds > 0 else { return }

        // Read the original file
        let originalFile = try AVAudioFile(forReading: url)
        let format = originalFile.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = originalFile.length
        let originalDuration = Double(totalFrames) / sampleRate

        // Calculate frames to keep (remove last N seconds)
        let framesToRemove = AVAudioFramePosition(seconds * sampleRate)
        let framesToKeep = max(0, totalFrames - framesToRemove)

        guard framesToKeep > 0 else {
            bridgedLog("⚠️ Trim would remove entire file, skipping")
            return
        }

        // Create temp file
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent("temp_trim_\(UUID().uuidString).wav")
        let trimmedFile = try AVAudioFile(forWriting: tempURL, settings: format.settings)

        // Read and write frames in chunks
        let bufferSize: AVAudioFrameCount = 4096
        var framesRead: AVAudioFramePosition = 0

        while framesRead < framesToKeep {
            let framesToRead = min(bufferSize, AVAudioFrameCount(framesToKeep - framesRead))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                throw RuntimeError.error(withMessage: "Failed to create buffer for trimming")
            }

            try originalFile.read(into: buffer, frameCount: framesToRead)
            try trimmedFile.write(from: buffer)

            framesRead += AVAudioFramePosition(buffer.frameLength)
        }

        // Replace original with trimmed version
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tempURL, to: url)

        let trimmedDuration = Double(framesToKeep) / sampleRate
        bridgedLog("✂️ Trimmed \(String(format: "%.1f", seconds))s → \(String(format: "%.1f", trimmedDuration))s")
    }

    private func resampleRecording(fileURL: URL) throws {
        // Read the original 16kHz file
        let sourceFile = try AVAudioFile(forReading: fileURL)
        let sourceFormat = sourceFile.processingFormat
        let sourceSampleRate = sourceFormat.sampleRate

        // Only resample if source is 16kHz (don't resample if already 44.1kHz)
        guard sourceSampleRate == 16000 else {
            return
        }

        // Create 44.1kHz output format
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: sourceFormat.channelCount,
            interleaved: false
        ) else {
            throw RuntimeError.error(withMessage: "Failed to create 44.1kHz output format")
        }

        // Create converter
        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw RuntimeError.error(withMessage: "Failed to create audio converter for resampling")
        }

        // Create temporary output file
        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("temp_resample_\(UUID().uuidString).wav")
        let outputFile = try AVAudioFile(forWriting: tempURL, settings: outputFormat.settings)

        // Calculate buffer sizes
        let inputFrameCapacity: AVAudioFrameCount = 8192
        let sampleRateRatio = outputFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(inputFrameCapacity) * sampleRateRatio)

        // Create buffers
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputFrameCapacity),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            throw RuntimeError.error(withMessage: "Failed to create conversion buffers")
        }

        var totalFramesConverted: AVAudioFramePosition = 0

        // Convert in chunks
        while sourceFile.framePosition < sourceFile.length {
            let framesToRead = min(inputFrameCapacity, AVAudioFrameCount(sourceFile.length - sourceFile.framePosition))

            // Read from source
            try sourceFile.read(into: inputBuffer, frameCount: framesToRead)
            inputBuffer.frameLength = framesToRead

            // Track if input is exhausted for this chunk
            var inputProvided = false

            // Convert to output - the input block may be called multiple times per convert() call
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                // Only provide the buffer once per convert() call
                if !inputProvided {
                    inputProvided = true
                    outStatus.pointee = .haveData
                    return inputBuffer
                } else {
                    // Input exhausted for this chunk
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }

            let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

            if let error = error {
                throw RuntimeError.error(withMessage: "Conversion error: \(error.localizedDescription)")
            }

            guard status != .error else {
                throw RuntimeError.error(withMessage: "Converter returned error status")
            }

            // Only write if we got output data
            if outputBuffer.frameLength > 0 {
                try outputFile.write(from: outputBuffer)
                totalFramesConverted += AVAudioFramePosition(outputBuffer.frameLength)
            }
        }

        // Flush the converter to get any remaining buffered samples
        // This is critical when upsampling - the converter buffers samples for interpolation
        var flushedFrames: AVAudioFramePosition = 0
        var flushIterations = 0
        while true {
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                // Signal end of stream to flush buffered samples
                outStatus.pointee = .endOfStream
                return nil
            }

            let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

            if let error = error {
                bridgedLog("⚠️ Flush error: \(error.localizedDescription)")
                break
            }

            // Write any flushed output
            if outputBuffer.frameLength > 0 {
                try outputFile.write(from: outputBuffer)
                totalFramesConverted += AVAudioFramePosition(outputBuffer.frameLength)
                flushedFrames += AVAudioFramePosition(outputBuffer.frameLength)
                flushIterations += 1
            } else {
                // No more output, flush complete
                break
            }

            // Safety check - prevent infinite loop
            if flushIterations > 10 {
                bridgedLog("⚠️ Flush safety limit reached")
                break
            }
        }

        // Replace original file with resampled version
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: tempURL, to: fileURL)

        let outputDuration = Double(totalFramesConverted) / outputFormat.sampleRate
        bridgedLog("🔄 Resampled 16kHz → 44.1kHz (\(String(format: "%.1f", outputDuration))s)")
    }

        // Replace your existing startNewSegment() with this version:
private func startNewSegment(with tapFormat: AVAudioFormat) {
    guard let outputDir = outputDirectory else {
        bridgedLog("⚠️ Cannot start segment: output directory not set")
        return
    }

    segmentCounter += 1
    // Use sessionTimestamp for unique filenames across app restarts
    let filename = String(format: "speech_%lld_%03d.wav", sessionTimestamp, segmentCounter)
    let fileURL = outputDir.appendingPathComponent(filename)

    // Track start time
    segmentStartTime = Date()

    do {
        currentSegmentFile = try AVAudioFile(
            forWriting: fileURL,
            settings: tapFormat.settings
        )

        let isManual = currentSegmentIsManual
        let modeType = isManual ? "MANUAL" : "AUTO"
        bridgedLog("🎙️ Started \(modeType) segment: \(filename) in mode: \(currentMode)")
        bridgedLog("🎚️ Audio format: \(tapFormat.sampleRate)Hz, \(tapFormat.channelCount) channels")
        if isManual {
            bridgedLog("⏱️ Manual segment silence timeout: \(Double(manualSilenceThreshold) / 14.0) seconds")
        }

        // Log VAD state when segment starts
        if !isManual, let vadState = vadStreamState {
            bridgedLog("🎤 Segment start - VAD triggered: \(vadState.triggered)")
        }

        // Pre-roll: flush ~3s of buffered audio into AUTO segments only
        // Manual segments start recording immediately without pre-roll
        if !isManual, let rollingBuffer = rollingBuffer {
            let preRollBuffers = rollingBuffer.getPreRollBuffers()
            for buffer in preRollBuffers {
                try currentSegmentFile?.write(from: buffer)
            }
            bridgedLog("📼 Pre-roll: wrote \(preRollBuffers.count) buffered frames")
            rollingBuffer.clear()
        } else if isManual {
            // Clear buffer for manual segments but don't write them
            rollingBuffer?.clear()
            bridgedLog("✂️ Manual segment: skipping pre-roll buffer")
        }

        silenceCounter = 0

    } catch {
        bridgedLog("❌ Failed to create speech segment: \(error.localizedDescription)")
        currentSegmentFile = nil
    }
}

    /// Ends the current segment and returns metadata for later callback
    /// Use this when you need to process the audio file before firing the callback
    /// Returns: Tuple with (filename, filePath, fileURL, isManual) or nil if no segment
    private func endCurrentSegmentWithoutCallback() -> (filename: String, filePath: String, fileURL: URL, isManual: Bool)? {
        guard let segmentFile = currentSegmentFile else { return nil }

        // Get file info before closing
        let filename = segmentFile.url.lastPathComponent
        let fileURL = segmentFile.url

        // Get relative path from Documents directory for cross-device compatibility
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        let absolutePath = segmentFile.url.path
        let filePath = absolutePath.replacingOccurrences(of: documentsPath + "/", with: "")

        let isManual = self.currentSegmentIsManual

        // Close the file
        currentSegmentFile = nil
        segmentStartTime = nil
        silenceCounter = 0

        bridgedLog("🛑 Segment closed (callback will fire after processing)")
        bridgedLog("   - Filename: \(filename)")
        bridgedLog("   - Is manual: \(isManual)")

        return (filename: filename, filePath: filePath, fileURL: fileURL, isManual: isManual)
    }

    /// Process a segment with trim + resample, then fire callback
    /// Use this for ALL manual segments to ensure proper playback speed
    private func processAndFireSegmentCallback(metadata: (filename: String, filePath: String, fileURL: URL, isManual: Bool), trimSeconds: Double) {
        // Trim silence from the end
        do {
            try self.trimLastSeconds(trimSeconds, fromFileAt: metadata.fileURL)
        } catch {
            bridgedLog("⚠️ Failed to trim silence: \(error.localizedDescription)")
        }

        // Resample 16kHz to 44.1kHz for correct playback speed
        do {
            try self.resampleRecording(fileURL: metadata.fileURL)
        } catch {
            bridgedLog("⚠️ Resampling failed: \(error.localizedDescription)")
        }

        // Read the actual processed file duration
        var actualDuration: Double = 0
        do {
            let processedFile = try AVAudioFile(forReading: metadata.fileURL)
            actualDuration = Double(processedFile.length) / processedFile.processingFormat.sampleRate
        } catch {
            bridgedLog("⚠️ Failed to read processed file: \(error.localizedDescription)")
        }

        // Fire callback with processed file info
        if let callback = self.segmentCallback {
            callback(metadata.filename, metadata.filePath, metadata.isManual, actualDuration)
            bridgedLog("✅ Segment ready: \(metadata.filename) (\(String(format: "%.1f", actualDuration))s)")
        } else {
            bridgedLog("⚠️ No callback set for segment")
        }
    }

    /// Ends the current segment and fires the callback immediately
    /// Use this for segments that don't need post-processing
    private func endCurrentSegment() {
        guard let segmentFile = currentSegmentFile else { return }

        // Get file info before closing
        let filename = segmentFile.url.lastPathComponent
        let fileURL = segmentFile.url

        // Get relative path from Documents directory for cross-device compatibility
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        let absolutePath = segmentFile.url.path
        let filePath = absolutePath.replacingOccurrences(of: documentsPath + "/", with: "")

        let isManual = self.currentSegmentIsManual
        let modeType = isManual ? "MANUAL" : "AUTO"

        // Close the file first
        currentSegmentFile = nil
        segmentStartTime = nil  // Reset start time

        // Wait for file system to flush before reading (fixes duration = 0 bug)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }

            // Calculate ACTUAL duration from the audio file (not timestamps)
            var duration: Double = 0
            var durationString = "unknown"
            var fileSize: UInt64 = 0
            var frameCount: AVAudioFramePosition = 0

            do {
                let audioFile = try AVAudioFile(forReading: fileURL)
                frameCount = audioFile.length
                let sampleRate = audioFile.processingFormat.sampleRate
                duration = Double(frameCount) / sampleRate
                durationString = String(format: "%.1f seconds", duration)

                // Get file size
                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                fileSize = attributes[.size] as? UInt64 ?? 0

                self.bridgedLog("📊 Audio file stats:")
                self.bridgedLog("   - Frames: \(frameCount)")
                self.bridgedLog("   - Sample rate: \(sampleRate)Hz")
                self.bridgedLog("   - Calculated duration: \(duration)s")
                self.bridgedLog("   - File size: \(fileSize) bytes")
            } catch {
                self.bridgedLog("⚠️ Could not read audio file duration: \(error.localizedDescription)")
            }

            // Notify JavaScript
            self.bridgedLog("🛑 Ended \(modeType) segment: \(filename) (duration: \(durationString))")
            self.bridgedLog("📤 Calling callback - isManual: \(isManual), duration: \(duration)s (SECONDS)")

            // Log VAD state when segment ends
            if !isManual, let vadState = self.vadStreamState {
                self.bridgedLog("🎤 Segment end - VAD triggered: \(vadState.triggered)")
            }

            // Notify JavaScript via callback
            if let callback = self.segmentCallback {
                callback(filename, filePath, isManual, duration)
                self.bridgedLog("✅ Callback fired for \(filename)")
            } else {
                self.bridgedLog("⚠️ No callback set for segment")
            }

            self.silenceCounter = 0
        }
    }

    private func setupRecording(promise: Promise<Void>) {
        do {
            guard let engine = self.audioEngine else {
                promise.reject(withError: RuntimeError.error(withMessage: "Unified audio engine not initialized"))
                return
            }

            if !engine.isRunning {
                throw RuntimeError.error(withMessage: "Audio engine is not running")
            }

            // Initialize session timestamp for unique filenames (milliseconds since epoch)
            self.sessionTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
            self.segmentCounter = 0

            let inputNode = engine.inputNode
            let hwFormat = inputNode.outputFormat(forBus: 0)

            // Create target format for VAD (16kHz mono)
            guard let target16kHzFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ) else {
                throw RuntimeError.error(withMessage: "Failed to create 16kHz target format")
            }

            self.targetFormat = target16kHzFormat

            // Create audio converter from hardware rate → 16kHz
            guard let converter = AVAudioConverter(from: hwFormat, to: target16kHzFormat) else {
                throw RuntimeError.error(withMessage: "Failed to create audio converter from \(Int(hwFormat.sampleRate))Hz to 16kHz")
            }
            self.audioConverter = converter

            // Remove any existing taps
            inputNode.removeTap(onBus: 0)

            // Init rolling buffer for pre-roll
            rollingBuffer = RollingAudioBuffer()

            // Set mode to idle FIRST (before VAD initialization)
            self.currentMode = .idle

            // Initialize VAD components asynchronously (non-blocking)
            Task {
                do {
                    let vadConfig = VadConfig(threshold: self.vadThreshold)
                    self.vadManager = try await VadManager(config: vadConfig)
                    self.vadStreamState = VadStreamState.initial()
                    self.bridgedLog("✅ VAD initialized")
                } catch {
                    self.bridgedLog("⚠️ VAD init failed, using fallback")
                }
            }

            // Set default output directory if needed
            if outputDirectory == nil {
                let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                outputDirectory = documentsURL.appendingPathComponent("speech_segments")
            }
            if let outputDir = outputDirectory {
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            }

            // Install tap using HARDWARE format (not 16kHz)
            // We'll convert buffers to 16kHz inside the callback
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, time in
                guard let self = self else { return }

                self.tapFrameCounter += 1

                // Convert buffer from hardware rate (48kHz) to 16kHz for VAD
                guard let converted16kHzBuffer = self.convertTo16kHz(buffer) else {
                    return
                }

                // VAD-based speech detection - ONLY when needed
                var audioIsLoud = false

                // Only compute VAD if we're in a mode that needs it
                if self.currentMode == .autoVAD || self.currentMode == .manual {
                    if let vadMgr = self.vadManager,
                       let vadState = self.vadStreamState {

                        // Extract Float array from CONVERTED 16kHz buffer SYNCHRONOUSLY
                        // Check if buffer has valid float channel data
                        if let floatChannelData = converted16kHzBuffer.floatChannelData,
                           floatChannelData[0] != nil {
                            // Valid buffer - process VAD
                            let frameLength = Int(converted16kHzBuffer.frameLength)
                            let samples = Array(UnsafeBufferPointer(start: floatChannelData[0], count: frameLength))

                            // Process VAD asynchronously (runs in background) with COPIED samples
                            Task {
                                do {
                                    // Use public streaming API with the samples we copied above
                                    let streamResult = try await vadMgr.processStreamingChunk(
                                        samples,
                                        state: vadState,
                                        config: .default
                                    )

                                    // Update state for next chunk
                                    self.vadStreamState = streamResult.state

                                } catch {
                                    // VAD processing error - state stays at previous value (silent fail)
                                }
                            }

                            // Use triggered state from most recent VAD result
                            audioIsLoud = vadState.triggered

                            // Log VAD state periodically
                            // if self.tapFrameCounter % 100 == 0 {
                            //     self.bridgedLog("🎤 Frame \(self.tapFrameCounter): VAD triggered = \(vadState.triggered)")
                            // }
                        } else {
                            // Buffer data is invalid - log and skip VAD for this frame
                            // if self.tapFrameCounter % 100 == 0 {
                            //     self.bridgedLog("⚠️ Frame \(self.tapFrameCounter): Invalid floatChannelData, skipping VAD (audioIsLoud stays false)")
                            // }
                            // audioIsLoud stays false - continue with normal buffer writing below
                        }

                    } else {
                        // VAD not initialized yet - log this condition
                        if self.tapFrameCounter % 200 == 0 {
                            let vadMgrExists = (self.vadManager != nil)
                            let vadStateExists = (self.vadStreamState != nil)
                            self.bridgedLog("⚠️ Frame \(self.tapFrameCounter): VAD not ready (vadMgr: \(vadMgrExists), vadState: \(vadStateExists))")
                        }
                        // audioIsLoud stays false - no fallback available
                    }

                    // Log final audioIsLoud value periodically
                    // if self.tapFrameCounter % 100 == 0 {
                    //     self.bridgedLog("🔊 Frame \(self.tapFrameCounter): audioIsLoud = \(audioIsLoud)")
                    // }
                }
                // In idle mode, audioIsLoud stays false - no processing

                // Pre-roll - write CONVERTED 16kHz buffer (not raw hardware buffer)
                if self.currentMode != .idle {
                    self.rollingBuffer?.write(converted16kHzBuffer)
                }

                // Segment handling - only run automatic detection if in autoVAD mode
                if self.currentMode == .autoVAD {
                    let isCurrentlyRecordingSegment = self.currentSegmentFile != nil
                    if audioIsLoud {
                        if !isCurrentlyRecordingSegment {
                            self.bridgedLog("🔊 Speech detected! Starting AUTO segment (mode: \(self.currentMode))")
                            self.currentSegmentIsManual = false
                            // Use target 16kHz format for file writing
                            if let targetFormat = self.targetFormat {
                                self.startNewSegment(with: targetFormat)
                            } else {
                                self.bridgedLog("⚠️ Cannot start segment: targetFormat is nil!")
                            }
                        } else {
                            // Already recording - log periodically
                            if self.tapFrameCounter % 100 == 0 {
                                self.bridgedLog("🎙️ AUTO segment already recording, speech continuing (frame: \(self.tapFrameCounter))")
                            }
                        }
                        self.silenceFrameCount = 0
                    } else if isCurrentlyRecordingSegment {
                        self.silenceFrameCount += 1
                        if self.silenceFrameCount >= 50 {
                            self.bridgedLog("🤫 Silence detected, ending AUTO segment after 50 frames")
                            // Use same processing pipeline as manual segments (trim + resample)
                            if let metadata = self.endCurrentSegmentWithoutCallback() {
                                // No trim needed for auto segments (0 seconds)
                                self.processAndFireSegmentCallback(metadata: metadata, trimSeconds: 0)
                            }
                            self.silenceFrameCount = 0
                        }
                    }
                } else if self.currentMode == .manual {
                    // In manual mode, detect silence for automatic progression
                    if audioIsLoud {
                        // Reset silence counter on speech
                        if self.manualSilenceFrameCount > 0 {
                            self.bridgedLog("🗣️ Speech detected! Resetting silence counter (was at \(self.manualSilenceFrameCount) frames)")
                            self.manualSilenceFrameCount = 0
                        }
                        // Log more frequently when speech is detected
                        if self.tapFrameCounter % 100 == 0 {
                            self.bridgedLog("🎙️ MANUAL mode: Speech detected (frame: \(self.tapFrameCounter))")
                        }
                    } else {
                        // Increment silence counter
                        self.manualSilenceFrameCount += 1

                        // Log progress every 5 seconds (70 frames at ~14fps)
                        if self.manualSilenceFrameCount % 70 == 0 {
                            let seconds = self.manualSilenceFrameCount / 14
                            self.bridgedLog("🤫 \(seconds) seconds of silence in manual mode...")
                        }

                        if self.manualSilenceFrameCount >= self.manualSilenceThreshold {
                            self.bridgedLog("🤫 Silence threshold reached in MANUAL mode (\(self.manualSilenceFrameCount) frames)")
                            self.manualSilenceFrameCount = 0  // Reset counter

                            // Close segment and get metadata (NO callback yet)
                            guard let metadata = self.endCurrentSegmentWithoutCallback() else {
                                self.bridgedLog("⚠️ No segment to end")
                                return
                            }

                            // Process the audio file (trim silence, then resample) and fire callback
                            let silenceDurationSeconds = Double(self.manualSilenceThreshold) / 14.0
                            self.processAndFireSegmentCallback(metadata: metadata, trimSeconds: silenceDurationSeconds)

                            // Notify JavaScript via callback
                            if let callback = self.manualSilenceCallback {
                                DispatchQueue.main.async {
                                    callback()
                                }
                            }
                        }
                    }
                }

                // Write to file ONLY if recording a segment AND not in idle mode
                // Write the CONVERTED 16kHz buffer (not the raw hardware buffer)
                if self.currentMode != .idle, let segmentFile = self.currentSegmentFile {
                    do {
                        try segmentFile.write(from: converted16kHzBuffer)
                    } catch {
                        // Silent fail to avoid log spam
                    }
                }
            }

            self.bridgedLog("✅ RECORDING: Active")
            promise.resolve(withResult: ())

        } catch {
            bridgedLog("❌ RECORDING: Setup failed - \(error.localizedDescription)")
            promise.reject(withError: RuntimeError.error(withMessage: "Recording setup failed: \(error.localizedDescription)"))
        }
    }

    public func stopRecorder() throws -> Promise<Void> {
        let promise = Promise<Void>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            // End any current segment before stopping
            if self.currentSegmentFile != nil {
                self.bridgedLog("🛑 Ending current segment before stopping recorder")

                // Get metadata and process with trim + resample
                if let metadata = self.endCurrentSegmentWithoutCallback() {
                    // Use 0 seconds trim for manual stop (no silence to remove)
                    self.processAndFireSegmentCallback(metadata: metadata, trimSeconds: 0)
                }
            }

            // Remove tap from unified engine's input node
            if let engine = self.audioEngine {
                engine.inputNode.removeTap(onBus: 0)
            }

            // Clean up VAD resources
            self.vadManager = nil
            self.vadStreamState = nil
            self.bridgedLog("🧹 VAD resources cleaned up")

            // Reset mode to idle
            self.bridgedLog("🔄 Mode change: \(self.currentMode) → idle (stopRecorder)")
            self.currentMode = .idle

            // No callback to clear - using event emitting

            // Keep the unified engine running for potential playback or quick restart
            promise.resolve(withResult: ())
        }

        return promise
    }

    // MARK: - Mode Control Methods

    public func setManualMode() throws -> Promise<Void> {
        let promise = Promise<Void>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            // Switch to manual mode (suppresses auto detection)
            self.bridgedLog("🔄 Mode change: \(self.currentMode) → manual")
            self.currentMode = .manual
            self.currentSegmentIsManual = true
            self.silenceFrameCount = 0
            self.manualSilenceFrameCount = 0  // Reset manual silence counter

            // Force close any existing segment (might be from auto detection)
            if self.currentSegmentFile != nil {
                self.bridgedLog("⚠️ Closing existing auto segment before manual mode")
                self.endCurrentSegment()
            }

            self.bridgedLog("✅ Manual mode set (ready for manual segment recording)")

            promise.resolve(withResult: ())
        }

        return promise
    }

    public func startManualSegment(silenceTimeoutSeconds: Double?) throws -> Promise<Void> {
        let promise = Promise<Void>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            // Verify we're in manual mode
            guard self.currentMode == .manual else {
                promise.reject(withError: RuntimeError.error(withMessage: "Not in manual mode. Call setManualMode() first."))
                return
            }

            // If already recording a segment, stop it first
            if self.currentSegmentFile != nil {
                self.bridgedLog("⚠️ Stopping existing manual segment before starting new one")
                self.endCurrentSegment()
            }

            // Verify target format is available
            guard let targetFormat = self.targetFormat else {
                promise.reject(withError: RuntimeError.error(withMessage: "Target format not initialized"))
                return
            }

            // Configure silence timeout (default to 15 seconds if not provided)
            let timeoutSeconds = silenceTimeoutSeconds ?? 15.0
            self.manualSilenceThreshold = Int(timeoutSeconds * 14)  // ~14 fps from VAD analysis
            self.bridgedLog("🔇 Manual silence timeout set to \(timeoutSeconds)s (\(self.manualSilenceThreshold) frames)")

            // Reset silence counter
            self.manualSilenceFrameCount = 0

            // Start new manual segment
            self.startNewSegment(with: targetFormat)
            self.bridgedLog("🗣️ Manual segment started")

            promise.resolve(withResult: ())
        }

        return promise
    }

    public func stopManualSegment() throws -> Promise<Void> {
        let promise = Promise<Void>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            // End current segment if one exists
            if self.currentSegmentFile != nil {
                self.bridgedLog("🛑 Stopping manual segment")

                // Get metadata and process with trim + resample
                if let metadata = self.endCurrentSegmentWithoutCallback() {
                    // Use 0 seconds trim for manual stop (no silence to remove)
                    self.processAndFireSegmentCallback(metadata: metadata, trimSeconds: 0)
                }
            } else {
                self.bridgedLog("ℹ️ No segment to stop (no-op)")
            }

            // Stay in manual mode (as per user's answer)
            promise.resolve(withResult: ())
        }

        return promise
    }

    public func setIdleMode() throws -> Promise<Void> {
        let promise = Promise<Void>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            // End any current segment before switching to idle
            if self.currentSegmentFile != nil {
                self.bridgedLog("🛑 Ending current segment before idle mode")
                self.endCurrentSegment()
            }

            // Switch to idle mode (keeps tap active for quick resume)
            self.bridgedLog("🔄 Mode change: \(self.currentMode) → idle (setIdleMode)")
            self.currentMode = .idle
            self.bridgedLog("✅ Switched to idle mode (tap remains active)")

            promise.resolve(withResult: ())
        }

        return promise
    }

    public func setVADMode() throws -> Promise<Void> {
        let promise = Promise<Void>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            // End any current segment before mode switch
            if self.currentSegmentFile != nil {
                self.bridgedLog("🛑 Ending current segment before VAD mode")
                self.endCurrentSegment()
            }

            // Switch to autoVAD mode
            self.bridgedLog("🔄 Mode change: \(self.currentMode) → autoVAD")
            self.currentMode = .autoVAD
            self.silenceFrameCount = 0
            self.currentSegmentIsManual = false

            // Reset VAD state to fresh initial state (prevents false positives from stale data)
            self.vadStreamState = VadStreamState.initial()
            self.bridgedLog("🧹 VAD state reset to fresh initial state")

            self.bridgedLog("✅ Switched to VAD mode (automatic segmentation)")

            promise.resolve(withResult: ())
        }

        return promise
    }

    public func setVADThreshold(threshold: Double) throws -> Promise<Void> {
        let promise = Promise<Void>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            // Validate threshold (0.0 to 1.0)
            let clampedThreshold = max(0.0, min(1.0, threshold))
            self.vadThreshold = Float(clampedThreshold)
            self.bridgedLog("🎚️ VAD threshold set to \(clampedThreshold)")

            promise.resolve(withResult: ())
        }

        return promise
    }

    // MARK: - Playback Methods

    public func startPlayer(uri: String?, httpHeaders: Dictionary<String, String>?) throws -> Promise<String> {
        let promise = Promise<String>()

        // Return immediately and process in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            do {
                try self.initializeAudioEngine()
                try self.ensureEngineRunning()

                guard let uri = uri, !uri.isEmpty else {
                    self.bridgedLog("❌ PLAYBACK: No URI provided")
                    promise.reject(withError: RuntimeError.error(withMessage: "URI is required for playback"))
                    return
                }

                self.currentPlaybackURI = uri

                // Handle all URLs the same way with AVAudioFile
                let url: URL
                if uri.hasPrefix("http") {
                    url = URL(string: uri)!
                } else if uri.hasPrefix("file://") {
                    url = URL(string: uri)!
                } else {
                    url = URL(fileURLWithPath: uri)
                }

                // For local files, check if file exists
                if !uri.hasPrefix("http") {
                    if !FileManager.default.fileExists(atPath: url.path) {
                        self.bridgedLog("❌ PLAYBACK: File not found - \(url.lastPathComponent)")
                        promise.reject(withError: RuntimeError.error(withMessage: "Audio file does not exist at path: \(uri)"))
                        return
                    }
                }

                // Load the audio file
                let audioFile: AVAudioFile
                if uri.hasPrefix("http") {
                    let data = try Data(contentsOf: url)
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("temp_audio_\(UUID().uuidString).m4a")
                    try data.write(to: tempURL)
                    audioFile = try AVAudioFile(forReading: tempURL)
                } else {
                    audioFile = try AVAudioFile(forReading: url)
                }

                self.currentAudioFile = audioFile

                // Reset starting frame offset (playing from beginning)
                self.startingFrameOffset = 0

                // Get the current player node (will alternate for crossfading in future)
                guard let playerNode = self.getCurrentPlayerNode() else {
                    promise.reject(withError: RuntimeError.error(withMessage: "Failed to get player node"))
                    return
                }

                self.currentPlayerNode = playerNode

                // Stop any current playback on this node
                playerNode.stop()

                // Set volume
                playerNode.volume = 1.0

                // Schedule file for playback
                if self.shouldLoopPlayback {
                    // Use crossfade looping for seamless M4A loops
                    self.startSeamlessLoop(audioFile: audioFile, url: url)
                } else {
                    // Non-looping: schedule file with completion handler that stops the player
                    playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
                        guard let self = self else { return }

                        // Get current position when completion fires
                        var currentPos: Double = 0
                        if let nodeTime = playerNode.lastRenderTime,
                           let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
                            currentPos = Double(playerTime.sampleTime) / audioFile.fileFormat.sampleRate
                        }

                        self.bridgedLog("🎬 scheduleFile COMPLETION HANDLER fired!")
                        self.bridgedLog("  ⏱️ Position when fired: \(String(format: "%.2f", currentPos))s")
                        self.bridgedLog("  📊 Expected duration: \(String(format: "%.2f", Double(audioFile.length) / audioFile.fileFormat.sampleRate))s")
                        self.bridgedLog("  ▶️ Node isPlaying: \(playerNode.isPlaying)")

                        // DO NOT call stop() here - this completion handler fires when the buffer is SCHEDULED,
                        // not when playback ends. Calling stop() here causes premature audio cutoff.
                        // The timer-based detection (60ms polling of isPlaying) handles actual playback completion.
                    }
                }

                // Play on main queue
                DispatchQueue.main.async {
                    self.didEmitPlaybackEnd = false
                    self.startPlayTimer()

                    playerNode.play()

                    promise.resolve(withResult: uri)
                }

            } catch {
                self.bridgedLog("❌ Playback error: \(error.localizedDescription)")
                promise.reject(withError: RuntimeError.error(withMessage: "Playback error: \(error.localizedDescription)"))
            }
        }

        return promise
    }

    // MARK: - Seamless Loop Methods

    private func startSeamlessLoop(audioFile: AVAudioFile, url: URL) {
        guard let primaryNode = self.currentPlayerNode else { return }

        // Schedule first playback
        primaryNode.scheduleFile(audioFile, at: nil, completionHandler: nil)

        // Calculate when to trigger crossfade (20ms before end)
        let totalDuration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        let crossfadeStartTime = max(0, totalDuration - self.loopCrossfadeDuration)

        self.bridgedLog("🔁 Starting seamless loop (duration: \(String(format: "%.2f", totalDuration))s, crossfade at: \(String(format: "%.3f", crossfadeStartTime))s)")

        // Schedule crossfade timer
        self.scheduleLoopCrossfade(after: crossfadeStartTime, audioFile: audioFile, url: url)
    }

    private func scheduleLoopCrossfade(after delay: TimeInterval, audioFile: AVAudioFile, url: URL) {
        // Cancel any existing timer
        self.loopCrossfadeTimer?.cancel()
        self.loopCrossfadeTimer = nil

        // Create new timer
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + delay)

        timer.setEventHandler { [weak self] in
            guard let self = self else { return }

            self.bridgedLog("⏰ Loop timer fired!")

            // Check if looping is still enabled
            guard self.shouldLoopPlayback else {
                self.bridgedLog("🛑 Loop disabled, stopping crossfade timer")
                return
            }

            self.triggerSeamlessLoopCrossfade(audioFile: audioFile, url: url)
        }

        self.loopCrossfadeTimer = timer
        timer.resume()
    }

    private func triggerSeamlessLoopCrossfade(audioFile: AVAudioFile, url: URL) {
        guard self.shouldLoopPlayback, !self.isLoopCrossfadeActive else {
            self.bridgedLog("⚠️ Seamless crossfade skipped - looping:\(self.shouldLoopPlayback) active:\(self.isLoopCrossfadeActive)")
            return
        }

        self.isLoopCrossfadeActive = true

        // Get alternate player node
        let newNode: AVAudioPlayerNode
        let oldNode = self.currentPlayerNode!

        if self.activePlayer == .playerA {
            newNode = self.audioPlayerNodeB!
            self.activePlayer = .playerB
        } else {
            newNode = self.audioPlayerNodeA!
            self.activePlayer = .playerA
        }

        self.bridgedLog("🔄 Crossfading loop: \(self.activePlayer == .playerA ? "B→A" : "A→B")")
        self.bridgedLog("   Old node isPlaying: \(oldNode.isPlaying), volume: \(oldNode.volume)")
        self.bridgedLog("   New node isPlaying: \(newNode.isPlaying), volume: \(newNode.volume)")
        self.bridgedLog("   Duration: \(String(format: "%.2f", Double(audioFile.length) / audioFile.fileFormat.sampleRate))s")

        // Prepare new node
        self.bridgedLog("   📋 Stopping and resetting new node...")
        newNode.stop()
        newNode.reset()
        newNode.volume = 0.0

        self.bridgedLog("   📋 Scheduling file on new node...")
        newNode.scheduleFile(audioFile, at: nil, completionHandler: nil)

        self.bridgedLog("   ▶️ Starting playback on new node...")
        newNode.play()

        self.bridgedLog("   New node isPlaying after play(): \(newNode.isPlaying)")

        // Schedule next crossfade IMMEDIATELY (before crossfade completes)
        // This ensures timing is relative to when playback STARTED, not when fade finishes
        let totalDuration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        let crossfadeStartTime = max(0, totalDuration - self.loopCrossfadeDuration)
        self.bridgedLog("   ⏰ Next crossfade scheduled in \(String(format: "%.3f", crossfadeStartTime))s")
        self.scheduleLoopCrossfade(after: crossfadeStartTime, audioFile: audioFile, url: url)

        // Crossfade (20ms) - respect current playback volume
        self.bridgedLog("   🎚️ Starting fade out (old): \(self.playbackVolume) → 0.0 over \(String(format: "%.3f", self.loopCrossfadeDuration))s")
        self.fadeVolume(node: oldNode, from: self.playbackVolume, to: 0.0, duration: self.loopCrossfadeDuration) {
            self.bridgedLog("   ✅ Fade out complete, stopping old node")
            oldNode.stop()
            oldNode.reset()
        }

        self.bridgedLog("   🎚️ Starting fade in (new): 0.0 → \(self.playbackVolume) over \(String(format: "%.3f", self.loopCrossfadeDuration))s")
        self.fadeVolume(node: newNode, from: 0.0, to: self.playbackVolume, duration: self.loopCrossfadeDuration) { [weak self] in
            guard let self = self else { return }

            self.bridgedLog("   ✅ Fade in complete")
            // Update current player reference and reset flag
            self.currentPlayerNode = newNode
            self.isLoopCrossfadeActive = false
            self.bridgedLog("   🏁 Seamless crossfade cycle complete")
        }
    }

    public func setLoopEnabled(enabled: Bool) throws -> Promise<String> {
        let promise = Promise<String>()

        self.shouldLoopPlayback = enabled
        let status = enabled ? "enabled" : "disabled"

        promise.resolve(withResult: "Loop \(status)")
        return promise
    }

    public func restartEngine() throws -> Promise<Void> {
        let promise = Promise<Void>()

        do {
            try restartAudioEngine()
            promise.resolve(withResult: ())
        } catch {
            bridgedLog("❌ Failed to restart engine: \(error.localizedDescription)")
            promise.reject(withError: RuntimeError.error(withMessage: "Failed to restart engine: \(error.localizedDescription)"))
        }

        return promise
    }

    public func stopPlayer() throws -> Promise<String> {
        let promise = Promise<String>()

        // Cancel loop crossfade timer
        self.loopCrossfadeTimer?.cancel()
        self.loopCrossfadeTimer = nil
        self.isLoopCrossfadeActive = false

        // Stop AND RESET both player nodes
        if let playerA = self.audioPlayerNodeA {
            playerA.stop()
            playerA.reset()  // Clear all scheduled buffers and reset state
            playerA.volume = 1.0 // Reset volume
        }

        if let playerB = self.audioPlayerNodeB {
            playerB.stop()
            playerB.reset()  // Clear all scheduled buffers and reset state
            playerB.volume = 1.0 // Reset volume
        }

        // Stop ambient loop if playing
        if self.isAmbientLoopPlaying, let playerC = self.audioPlayerNodeC {
            playerC.stop()
            playerC.reset()
            playerC.volume = 1.0
            self.isAmbientLoopPlaying = false
            self.currentAmbientFile = nil
        }

        self.currentPlayerNode = nil

        // Clear the audio file reference
        self.currentAudioFile = nil

        // Stop the play timer
        self.stopPlayTimer()

        // Reset active player state
        self.activePlayer = .none

        // Clear loop state
        self.shouldLoopPlayback = false
        self.currentPlaybackURI = nil

        // Reset position cache
        self.lastValidPosition = 0.0

        // Keep the unified engine running for recording or future playback
        promise.resolve(withResult: "Player stopped")

        return promise
    }

    public func pausePlayer() throws -> Promise<String> {
        let promise = Promise<String>()

        if let playerNode = self.currentPlayerNode {
            playerNode.pause()
            self.stopPlayTimer()
            promise.resolve(withResult: "Player paused")
        } else {
            promise.reject(withError: RuntimeError.error(withMessage: "No active player node"))
        }

        return promise
    }

    public func resumePlayer() throws -> Promise<String> {
        let promise = Promise<String>()

        if let playerNode = self.currentPlayerNode {
            playerNode.play()
            DispatchQueue.main.async {
                self.startPlayTimer()
            }
            promise.resolve(withResult: "Player resumed")
        } else {
            promise.reject(withError: RuntimeError.error(withMessage: "No active player node"))
        }

        return promise
    }

    public func seekToPlayer(time: Double) throws -> Promise<String> {
        let promise = Promise<String>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self,
                  let playerNode = self.currentPlayerNode,
                  let audioFile = self.currentAudioFile else {
                promise.reject(withError: RuntimeError.error(withMessage: "No active playback"))
                return
            }

            // Calculate and clamp frame position
            let sampleRate = audioFile.fileFormat.sampleRate
            let totalFrames = audioFile.length
            let timeInSeconds = time / 1000.0  // Convert milliseconds to seconds
            let targetFrame = AVAudioFramePosition(timeInSeconds * sampleRate)
            let clampedFrame = max(0, min(targetFrame, totalFrames))
            let remainingFrames = totalFrames - clampedFrame

            // Guard: If no frames left to play, stop playback
            guard remainingFrames > 0 else {
                playerNode.stop()
                let seekTimeSeconds = Double(clampedFrame) / sampleRate
                promise.resolve(withResult: "Seeked to end (\(String(format: "%.1f", seekTimeSeconds))s)")
                return
            }

            // Preserve state
            let wasPlaying = playerNode.isPlaying
            let volume = playerNode.volume

            // Cancel old crossfade timer (invalidated by seek)
            self.loopCrossfadeTimer?.cancel()
            self.loopCrossfadeTimer = nil
            self.isLoopCrossfadeActive = false

            // Stop and reset
            playerNode.stop()
            playerNode.reset()

            // Save the starting frame offset for getCurrentPosition
            self.startingFrameOffset = clampedFrame

            // Schedule from new position
            if self.shouldLoopPlayback {
                // Use scheduleSegment for precise frame control
                playerNode.scheduleSegment(
                    audioFile,
                    startingFrame: clampedFrame,
                    frameCount: AVAudioFrameCount(remainingFrames),
                    at: nil,
                    completionHandler: nil
                )

                // Calculate remaining duration
                let totalDuration = Double(totalFrames) / sampleRate
                let seekTime = Double(clampedFrame) / sampleRate
                let remainingDuration = totalDuration - seekTime

                // Recalculate crossfade timing
                let crossfadeStartTime = max(0, remainingDuration - self.loopCrossfadeDuration)

                self.bridgedLog("🔍 Seeked to \(String(format: "%.2f", seekTime))s, crossfade in \(String(format: "%.2f", crossfadeStartTime))s")

                // Get URL and reschedule crossfade
                if let uri = self.currentPlaybackURI {
                    let url: URL
                    if uri.hasPrefix("http") {
                        url = URL(string: uri)!
                    } else if uri.hasPrefix("file://") {
                        url = URL(string: uri)!
                    } else {
                        url = URL(fileURLWithPath: uri)
                    }

                    self.scheduleLoopCrossfade(after: crossfadeStartTime, audioFile: audioFile, url: url)
                }

            } else {
                // Non-looping: schedule with completion handler
                playerNode.scheduleSegment(
                    audioFile,
                    startingFrame: clampedFrame,
                    frameCount: AVAudioFrameCount(remainingFrames),
                    at: nil
                ) { [weak self] in
                    DispatchQueue.main.async {
                        playerNode.stop()
                    }
                }
            }

            // Restore state
            playerNode.volume = volume
            if wasPlaying {
                playerNode.play()
            }

            let seekTimeSeconds = Double(clampedFrame) / sampleRate

            // Update position cache to the seeked position (in milliseconds)
            self.lastValidPosition = seekTimeSeconds * 1000.0

            promise.resolve(withResult: "Seeked to \(String(format: "%.1f", seekTimeSeconds))s")
        }

        return promise
    }

    public func setVolume(volume: Double) throws -> Promise<String> {
        let promise = Promise<String>()

        // Store the desired playback volume for crossfades
        self.playbackVolume = Float(volume)

        if let playerNode = self.currentPlayerNode {
            playerNode.volume = Float(volume)
            promise.resolve(withResult: "Volume set to \(volume)")
        } else if let engine = self.audioEngine {
            engine.mainMixerNode.outputVolume = Float(volume)
            promise.resolve(withResult: "Volume set to \(volume)")
        } else {
            promise.reject(withError: RuntimeError.error(withMessage: "No player instance"))
        }

        return promise
    }

    public func setPlaybackSpeed(playbackSpeed: Double) throws -> Promise<String> {
        let promise = Promise<String>()

        // Persist desired rate for future players
        self.playbackRate = playbackSpeed

        // Note: AVAudioPlayerNode doesn't support rate changes like AVAudioPlayer
        // This would require using AVAudioUnitTimePitch effect node
        // For now, we'll just store the rate for future use
        promise.resolve(withResult: "Playback speed stored (rate change not yet supported with unified engine)")

        return promise
    }

    public func getCurrentPosition() throws -> Promise<Double> {
        let promise = Promise<Double>()

        guard let playerNode = self.currentPlayerNode,
              let audioFile = self.currentAudioFile,
              playerNode.isPlaying else {
            // Return cached position instead of 0 when player is paused/transitioning
            promise.resolve(withResult: self.lastValidPosition)
            return promise
        }

        // Get last render time to calculate current position
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            // Return cached position instead of 0 when timing info unavailable
            promise.resolve(withResult: self.lastValidPosition)
            return promise
        }

        // Calculate position in milliseconds
        // Add the starting frame offset to account for seeks
        let sampleRate = audioFile.fileFormat.sampleRate
        let totalSampleTime = self.startingFrameOffset + playerTime.sampleTime
        let positionSeconds = Double(totalSampleTime) / sampleRate
        let positionMs = positionSeconds * 1000.0

        // Cache the valid position before returning
        self.lastValidPosition = positionMs

        promise.resolve(withResult: positionMs)
        return promise
    }

    public func getDuration() throws -> Promise<Double> {
        let promise = Promise<Double>()

        guard let audioFile = self.currentAudioFile else {
            promise.resolve(withResult: 0.0)
            return promise
        }

        // Get actual playable duration (uses AVAsset for M4A to exclude AAC padding)
        let durationSeconds = getActualDurationSeconds(audioFile: audioFile)
        let durationMs = durationSeconds * 1000.0

        if audioFile.url.pathExtension.lowercased() == "m4a" {
            bridgedLog("⏱️ M4A duration via AVAsset: \(String(format: "%.2f", durationSeconds))s (excludes padding)")
        }

        promise.resolve(withResult: durationMs)
        return promise
    }

    // MARK: - Subscription

    public func setSubscriptionDuration(sec: Double) throws {
        self.subscriptionDuration = sec
    }

    // MARK: - Listeners

    public func addRecordBackListener(callback: @escaping (RecordBackType) -> Void) throws {
        // Removed - only used with AVAudioRecorder metering
        // Buffer recorder uses direct file writing without metering callbacks
    }

    public func removeRecordBackListener() throws {
        // Removed - only used with AVAudioRecorder metering
    }

    public func addPlayBackListener(callback: @escaping (PlayBackType) -> Void) throws {
        self.playBackListener = callback
    }

    public func removePlayBackListener() throws {
        self.playBackListener = nil
        self.stopPlayTimer()
    }

    public func addPlaybackEndListener(callback: @escaping (PlaybackEndType) -> Void) throws {
        self.playbackEndListener = callback
    }

    public func removePlaybackEndListener() throws {
        self.playbackEndListener = nil
    }

    // MARK: - Logging Methods

    public func setLogCallback(callback: @escaping (String) -> Void) throws {
        self.logCallback = callback
    }

    public func setSegmentCallback(callback: @escaping (String, String, Bool, Double) -> Void) throws {
        self.segmentCallback = callback
    }

    public func setManualSilenceCallback(callback: @escaping () -> Void) throws {
        self.manualSilenceCallback = callback
    }

    private func bridgedLog(_ message: String) {
        // Log to native console
        NSLog("%@", message)

        // Log to file for debugging
        FileLogger.shared.log(message)

        // Send to JavaScript if callback is available
        if let callback = self.logCallback {
            DispatchQueue.main.async {
                callback(message)
            }
        }
    }

    public func writeDebugLog(message: String) throws {
        FileLogger.shared.log(message)
    }

    public func getDebugLogPath() throws -> String? {
        return FileLogger.shared.getCurrentLogPath()
    }

    public func getAllDebugLogPaths() throws -> [String] {
        return FileLogger.shared.getAllLogPaths()
    }

    public func readDebugLog(path: String?) throws -> String? {
        if let path = path {
            return FileLogger.shared.readLog(at: path)
        } else {
            return FileLogger.shared.readCurrentLog()
        }
    }

    public func clearDebugLogs() throws -> Promise<Void> {
        let promise = Promise<Void>()

        FileLogger.shared.clearAllLogs()
        promise.resolve(withResult: ())

        return promise
    }

    // MARK: - Utility Methods

    public func mmss(secs: Double) throws -> String {
        let totalSeconds = Int(secs)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    public func mmssss(milisecs: Double) throws -> String {
        let totalSeconds = Int(milisecs / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let milliseconds = Int(milisecs.truncatingRemainder(dividingBy: 1000)) / 10
        return String(format: "%02d:%02d:%02d", minutes, seconds, milliseconds)
    }

    // MARK: - Speech Recognition Methods
    public func transcribeAudioFile(filePath: String) throws -> Promise<String> {
        let promise = Promise<String>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            // Create recognizer
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
                promise.reject(withError: RuntimeError.error(withMessage: "Speech recognizer unavailable"))
                return
            }

            guard recognizer.isAvailable else {
                promise.reject(withError: RuntimeError.error(withMessage: "Speech recognizer not available"))
                return
            }
            
            // Ensure file:// prefix
            var urlPath = filePath
            if !urlPath.hasPrefix("file://") {
                urlPath = "file://" + urlPath
            }
            
            guard let url = URL(string: urlPath) else {
                self.bridgedLog("ℹ️ Invalid file path: \(filePath)")
                promise.resolve(withResult: "No Speech Detected")
                return
            }

            // Check file exists
            if !FileManager.default.fileExists(atPath: url.path) {
                self.bridgedLog("ℹ️ Audio file not found: \(url.path)")
                promise.resolve(withResult: "No Speech Detected")
                return
            }

            self.bridgedLog("🎤 Starting file transcription")

            // Create recognition request
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            
            // Start recognition task
            recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    self.bridgedLog("ℹ️ Transcription failed: \(error.localizedDescription)")
                    promise.resolve(withResult: "No Speech Detected")
                    return
                }

                if let result = result, result.isFinal {
                    let transcription = result.bestTranscription.formattedString
                    if transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.bridgedLog("ℹ️ No speech detected in audio")
                        promise.resolve(withResult: "No Speech Detected")
                    } else {
                        self.bridgedLog("✅ Transcription complete: \(transcription.prefix(100))...")
                        promise.resolve(withResult: transcription)
                    }
                } else if let result = result {
                    let transcription = result.bestTranscription.formattedString
                    if transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        promise.resolve(withResult: "No Speech Detected")
                    } else {
                        promise.resolve(withResult: transcription)
                    }
                } else {
                    self.bridgedLog("ℹ️ No speech detected in audio")
                    promise.resolve(withResult: "No Speech Detected")
                }
            }
        }
        
        return promise
    }

    // MARK: - Crossfade Methods
    public func crossfadeTo(uri: String, duration: Double? = 3.0) throws -> Promise<String> {
        let promise = Promise<String>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            do {
                guard !uri.isEmpty else {
                    promise.reject(withError: RuntimeError.error(withMessage: "URI is required for crossfade"))
                    return
                }

                let fadeDuration = duration ?? 3.0

                // Ensure audio engine is initialized for crossfading
                try self.initializeAudioEngine()

                // Cancel seamless loop timer from previous track
                self.loopCrossfadeTimer?.cancel()
                self.loopCrossfadeTimer = nil
                self.isLoopCrossfadeActive = false

                // Pick next player node
                let newNode: AVAudioPlayerNode
                switch self.activePlayer {
                case .playerA: newNode = self.audioPlayerNodeB!
                case .playerB: newNode = self.audioPlayerNodeA!
                case .none:
                    // Nothing is playing → just start normally
                    let startPromise = try self.startPlayer(uri: uri, httpHeaders: nil)
                    startPromise.then { result in promise.resolve(withResult: result) }
                                .catch { error in promise.reject(withError: error) }
                    return
                }

                // Load the audio file
                let url: URL
                if uri.hasPrefix("http") {
                    // Handle RN dev/bundled assets (http://localhost:8081/…)
                    let data = try Data(contentsOf: URL(string: uri)!)

                    // Extract file extension from original URL (before query string)
                    let originalURL = URL(string: uri)!
                    let pathWithoutQuery = originalURL.path  // Gets path before ? query params
                    let fileExtension = (pathWithoutQuery as NSString).pathExtension.isEmpty ? "m4a" : (pathWithoutQuery as NSString).pathExtension

                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("crossfade_temp_\(UUID().uuidString).\(fileExtension)")
                    try data.write(to: tempURL)
                    url = tempURL
                } else if uri.hasPrefix("file://") {
                    url = URL(string: uri)!
                } else {
                    url = URL(fileURLWithPath: uri)
                }

                guard FileManager.default.fileExists(atPath: url.path) else {
                    promise.reject(withError: RuntimeError.error(withMessage: "Audio file does not exist: \(url.path)"))
                    return
                }

                let audioFile = try AVAudioFile(forReading: url)

                // Prepare new node
                newNode.stop()
                newNode.volume = 0.0

                // Reset position tracking for new track (BEFORE updating currentAudioFile)
                // This prevents getCurrentPosition() from using mismatched file/node/offset during crossfade
                self.startingFrameOffset = 0
                self.lastValidPosition = 0.0

                // Store audio file reference early to ensure it's retained for looping
                self.currentAudioFile = audioFile

                // Schedule file for playback (just once - seamless loop will handle the rest)
                if self.shouldLoopPlayback {
                    newNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
                } else {
                    newNode.scheduleFile(audioFile, at: nil) { [weak self] in
                        self?.handlePlaybackCompletion()
                    }
                }

                newNode.play()

                // Start fading
                if let currentNode = self.currentPlayerNode {
                    self.fadeVolume(node: currentNode, from: 1.0, to: 0.0, duration: fadeDuration) {
                        // Stop old node when fade out completes
                        currentNode.stop()
                        currentNode.volume = 0.0  // Ensure volume stays at 0
                    }
                }
                self.fadeVolume(node: newNode, from: 0.0, to: 1.0, duration: fadeDuration) {
                    // Swap references after new node fades in
                    self.currentPlayerNode = newNode
                    self.activePlayer = (newNode == self.audioPlayerNodeA) ? .playerA : .playerB

                    // Start seamless loop timer if looping is enabled
                    if self.shouldLoopPlayback {
                        let totalDuration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
                        let crossfadeStartTime = max(0, totalDuration - self.loopCrossfadeDuration)
                        self.scheduleLoopCrossfade(after: crossfadeStartTime, audioFile: audioFile, url: url)
                    }
                }

                // Resolve immediately (crossfade started)
                promise.resolve(withResult: uri)

            } catch {
                promise.reject(withError: RuntimeError.error(withMessage: error.localizedDescription))
            }
        }

        return promise
    }

    // MARK: - Ambient Loop Methods
    public func startAmbientLoop(uri: String, volume: Double) throws -> Promise<Void> {
        let promise = Promise<Void>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            do {
                // Initialize audio engine if needed
                try self.initializeAudioEngine()
                try self.ensureEngineRunning()

                guard let playerC = self.audioPlayerNodeC else {
                    promise.reject(withError: RuntimeError.error(withMessage: "Ambient player not initialized"))
                    return
                }

                // Load audio file
                let url: URL
                if uri.hasPrefix("http") {
                    let data = try Data(contentsOf: URL(string: uri)!)
                    let pathWithoutQuery = URL(string: uri)!.path
                    let fileExtension = (pathWithoutQuery as NSString).pathExtension.isEmpty ? "wav" : (pathWithoutQuery as NSString).pathExtension
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ambient_\(UUID().uuidString).\(fileExtension)")
                    try data.write(to: tempURL)
                    url = tempURL
                } else if uri.hasPrefix("file://") {
                    url = URL(string: uri)!
                } else {
                    url = URL(fileURLWithPath: uri)
                }

                let audioFile = try AVAudioFile(forReading: url)
                self.currentAmbientFile = audioFile

                // Stop if already playing
                if self.isAmbientLoopPlaying {
                    playerC.stop()
                    playerC.reset()
                }

                // Set volume
                playerC.volume = Float(volume)

                // Schedule for looping (pre-schedule 3 iterations)
                playerC.scheduleFile(audioFile, at: nil, completionHandler: nil)
                playerC.scheduleFile(audioFile, at: nil, completionHandler: nil)
                playerC.scheduleFile(audioFile, at: nil) { [weak self] in
                    self?.scheduleMoreAmbientLoops(audioFile: audioFile, playerNode: playerC)
                }

                // Play
                playerC.play()
                self.isAmbientLoopPlaying = true

                self.bridgedLog("🎵 Ambient loop started at \(Int(volume * 100))% volume")
                promise.resolve(withResult: ())

            } catch {
                self.bridgedLog("❌ Failed to start ambient loop: \(error.localizedDescription)")
                promise.reject(withError: RuntimeError.error(withMessage: error.localizedDescription))
            }
        }

        return promise
    }

    public func stopAmbientLoop(fadeDuration: Double?) throws -> Promise<Void> {
        let promise = Promise<Void>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            guard let playerC = self.audioPlayerNodeC else {
                promise.resolve(withResult: ())
                return
            }

            if !self.isAmbientLoopPlaying {
                promise.resolve(withResult: ())
                return
            }

            let duration = fadeDuration ?? 2.0

            if duration > 0 {
                // Fade out
                self.fadeVolume(node: playerC, from: playerC.volume, to: 0.0, duration: duration) {
                    playerC.stop()
                    playerC.reset()
                    self.isAmbientLoopPlaying = false
                    self.currentAmbientFile = nil
                    self.bridgedLog("🔇 Ambient loop stopped (faded)")
                    promise.resolve(withResult: ())
                }
            } else {
                // Immediate stop
                playerC.stop()
                playerC.reset()
                self.isAmbientLoopPlaying = false
                self.currentAmbientFile = nil
                self.bridgedLog("🔇 Ambient loop stopped (immediate)")
                promise.resolve(withResult: ())
            }
        }

        return promise
    }

    // MARK: - Volume Fade Helper
    private func fadeVolume(
        node: AVAudioPlayerNode,
        from startVolume: Float,
        to targetVolume: Float,
        duration: Double,
        completion: (() -> Void)? = nil
    ) {
        let steps = 30
        let stepDuration = duration / Double(steps)
        let volumeStep = (targetVolume - startVolume) / Float(steps)

        var currentStep = 0
        node.volume = startVolume

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: stepDuration)

        timer.setEventHandler {
            guard node.engine != nil else {
                timer.cancel()
                return
            }

            let newVolume = startVolume + Float(currentStep) * volumeStep
            DispatchQueue.main.async {
                node.volume = newVolume
            }

            currentStep += 1
            if currentStep > steps {
                timer.cancel()
                DispatchQueue.main.async {
                    node.volume = targetVolume
                    completion?()
                }
            }
        }

        timer.resume()
    }

    // MARK: - Private Methods



    // MARK: - Timer Management

    // Removed startRecordTimer - only needed for AVAudioRecorder metering

    // Removed stopRecordTimer - only needed for AVAudioRecorder

    /// Get actual playable duration in seconds for the current audio file
    /// For M4A files, uses AVAsset (respects iTunSMPB, excludes padding)
    /// For other formats, uses AVAudioFile
    private func getActualDurationSeconds(audioFile: AVAudioFile) -> Double {
        let fileURL = audioFile.url
        if fileURL.pathExtension.lowercased() == "m4a" {
            let asset = AVAsset(url: fileURL)
            return CMTimeGetSeconds(asset.duration)
        } else {
            return Double(audioFile.length) / audioFile.fileFormat.sampleRate
        }
    }

    private func startPlayTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }


            self.didEmitPlaybackEnd = false

            self.playTimer = Timer.scheduledTimer(withTimeInterval: self.subscriptionDuration, repeats: true) { [weak self] timer in
                guard let self = self else { return }

                // Check if we have a player node and audio file
                guard let playerNode = self.currentPlayerNode,
                      let audioFile = self.currentAudioFile else {
                    self.stopPlayTimer()
                    return
                }

                // Continue running timer if EITHER listener is registered
                // This allows playback end detection even without progress updates
                guard self.playBackListener != nil || self.playbackEndListener != nil else {
                    return
                }

                // Calculate actual playable duration (uses AVAsset for M4A to exclude padding)
                let durationSeconds = self.getActualDurationSeconds(audioFile: audioFile)
                let durationMs = durationSeconds * 1000

                // Get current playback position from audio hardware
                var currentTimeSeconds: Double = 0
                if let nodeTime = playerNode.lastRenderTime,
                   let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
                    currentTimeSeconds = Double(playerTime.sampleTime) / audioFile.fileFormat.sampleRate
                }

                // Check if we've reached the end of the audio file
                // Use a small tolerance (0.05s) to account for timing precision
                if playerNode.isPlaying && currentTimeSeconds >= (durationSeconds - 0.05) {
                    self.bridgedLog("🎯 Timer detected playback reached end at \(String(format: "%.2f", currentTimeSeconds))s / \(String(format: "%.2f", durationSeconds))s")
                    playerNode.stop()
                    // Next timer tick (60ms) will detect !isPlaying and fire completion
                }

                // Check if playback has finished (ALWAYS check, even if no playBackListener)
                if !playerNode.isPlaying {
                    // GUARD: Prevent infinite logging if we've already handled playback end
                    guard !self.didEmitPlaybackEnd else {
                        return
                    }

                    // Get position when timer detected stop
                    var stopPos: Double = 0
                    if let nodeTime = playerNode.lastRenderTime,
                       let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
                        stopPos = Double(playerTime.sampleTime) / audioFile.fileFormat.sampleRate
                    }

                    self.bridgedLog("⏹️ TIMER detected playback stopped!")
                    self.bridgedLog("  ⏱️ Position when detected: \(String(format: "%.2f", stopPos))s")
                    self.bridgedLog("  📊 Expected duration: \(String(format: "%.2f", durationSeconds))s")
                    self.bridgedLog("  ⚠️ Difference: \(String(format: "%.2f", durationSeconds - stopPos))s early")

                    // Emit playback end events (will emit to both listeners if registered)
                    self.emitPlaybackEndEvents(durationMs: durationMs, includePlaybackUpdate: true)
                    self.stopPlayTimer()
                    return
                }

                // Emit progress updates ONLY if playBackListener is registered
                if let listener = self.playBackListener {
                    // Get the player node's current time
                    var currentTimeMs: Double = 0
                    if let nodeTime = playerNode.lastRenderTime,
                       let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
                        // Use audio file's sample rate, not hardware output rate
                        let sampleRate = audioFile.fileFormat.sampleRate
                        currentTimeMs = Double(playerTime.sampleTime) / sampleRate * 1000
                    }

                    let playBack = PlayBackType(
                        isMuted: false,
                        duration: durationMs,
                        currentPosition: currentTimeMs
                    )

                    listener(playBack)
                }
            }

        }
    }

    private func stopPlayTimer() {
        stopTimer(for: \.playTimer)
    }

    private func stopTimer(for keyPath: ReferenceWritableKeyPath<HybridSound, Timer?>) {
        if Thread.isMainThread {
            self[keyPath: keyPath]?.invalidate()
            self[keyPath: keyPath] = nil
        } else {
            DispatchQueue.main.sync {
                self[keyPath: keyPath]?.invalidate()
                self[keyPath: keyPath] = nil
            }
        }
    }

    private func emitPlaybackEndEvents(durationMs: Double, includePlaybackUpdate: Bool) {
        guard !self.didEmitPlaybackEnd else {
            return
        }
        self.didEmitPlaybackEnd = true

        if includePlaybackUpdate, let listener = self.playBackListener {
            let finalPlayBack = PlayBackType(
                isMuted: false,
                duration: durationMs,
                currentPosition: durationMs
            )
            listener(finalPlayBack)
        }

        if let endListener = self.playbackEndListener {
            let endEvent = PlaybackEndType(
                duration: durationMs,
                currentPosition: durationMs
            )
            endListener(endEvent)
        }
    }

    // MARK: - AVAudioPlayerDelegate via proxy
    deinit {
        playTimer?.invalidate()
        crossfadeTimer?.invalidate()
        loopCrossfadeTimer?.cancel()

        // Cleanup unified audio engine if needed
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            // Don't stop the engine here as it might be used by other instances
        }
        // No callback to clear - using event emitting
    }

    private class AudioPlayerDelegateProxy: NSObject, AVAudioPlayerDelegate {
        weak var owner: HybridSound?
        init(owner: HybridSound) { self.owner = owner }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            guard let owner = owner else { return }
            let finalDurationMs = player.duration * 1000
            owner.emitPlaybackEndEvents(durationMs: finalDurationMs, includePlaybackUpdate: true)
            owner.stopPlayTimer()
        }

        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
            NSLog("AVAudioPlayer decode error: \(String(describing: error))")
        }
    }

    private var playerDelegateProxy: AudioPlayerDelegateProxy?
    private func ensurePlayerDelegate() {
        if playerDelegateProxy == nil { playerDelegateProxy = AudioPlayerDelegateProxy(owner: self) }
        else { playerDelegateProxy?.owner = self }
    }
}

// MARK: - Rolling Audio Buffer for Short Pre-Roll
private class RollingAudioBuffer {
    private let bufferSize: Int = 30  // ~0.6 seconds at 48kHz, 1024 samples/buffer
    private var buffers: [AVAudioPCMBuffer?]
    private var writeIndex: Int = 0
    private var isFull: Bool = false

    init() {
        // Pre-allocate all slots to avoid runtime allocations
        self.buffers = Array(repeating: nil, count: bufferSize)
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        // Deep copy the buffer since AVAudioPCMBuffer can be reused by the tap
        if let copiedBuffer = buffer.deepCopy() as? AVAudioPCMBuffer {
            buffers[writeIndex] = copiedBuffer
            writeIndex = (writeIndex + 1) % bufferSize

            if writeIndex == 0 && !isFull {
                isFull = true
            }
        }
    }

    func getPreRollBuffers() -> [AVAudioPCMBuffer] {
        var result: [AVAudioPCMBuffer] = []

        if !isFull {
            // Buffer not full yet, return what we have
            for i in 0..<writeIndex {
                if let buffer = buffers[i] {
                    result.append(buffer)
                }
            }
        } else {
            // Return buffers in chronological order (oldest first)
            for i in writeIndex..<bufferSize {
                if let buffer = buffers[i] {
                    result.append(buffer)
                }
            }
            for i in 0..<writeIndex {
                if let buffer = buffers[i] {
                    result.append(buffer)
                }
            }
        }

        return result
    }

    func clear() {
        // Don't deallocate, just nil out references
        for i in 0..<bufferSize {
            buffers[i] = nil
        }
        writeIndex = 0
        isFull = false
    }
}

// MARK: - AVAudioPCMBuffer Extension for Deep Copy
private extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let newBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCapacity
        ) else { return nil }

        newBuffer.frameLength = frameLength

        // Copy audio data
        if let fromFloatChannelData = self.floatChannelData,
           let toFloatChannelData = newBuffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                memcpy(toFloatChannelData[channel],
                       fromFloatChannelData[channel],
                       Int(frameLength) * MemoryLayout<Float>.size)
            }
        }

        return newBuffer
    }
}

// MARK: - Audio Level Detection (Replacing SNResultsObserving)
extension HybridSound {
    // COMMENTED OUT - RMS detection replaced with VAD (kept for reference/fallback)
    // Simple audio level detection using RMS-based threshold
    private func isAudioLoudEnough(_ buffer: AVAudioPCMBuffer) -> Bool {
        // VAD is now the primary detection method - RMS used only as fallback
        // when VAD initialization fails
        guard let channelData = buffer.floatChannelData else { return false }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return false }

        // Calculate RMS (Root Mean Square) for audio level
        var sum: Float = 0.0
        let samples = channelData.pointee

        for i in 0..<frameLength {
            let sample = samples[i]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameLength))
        let db = 20 * log10(max(rms, 0.000001))

        // Fixed threshold -25dB (since audioLevelThreshold property is commented out)
        return db > -25.0  // HARDCODED fallback threshold
    }

    // SNResultsObserving stub methods (keeping for protocol conformance if needed)
    func request(_ request: SNRequest, didProduce result: SNResult) {
        // No longer used - using audio level detection instead
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        // No longer used
    }

    func requestDidComplete(_ request: SNRequest) {
        // No longer used
    }
}
