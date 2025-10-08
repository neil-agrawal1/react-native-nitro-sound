
import Foundation
import AVFoundation
import NitroModules
import SoundAnalysis
import FluidAudio

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
    private var vadThreshold: Float = 0.6
    private var speechConfidence: Float = 0.0

    // Manual mode silence detection (15 seconds at ~50 fps = 750 frames)
    private var manualSilenceFrameCount: Int = 0
    private let manualSilenceThreshold: Int = 750  // ~15 seconds of silence

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
            try restartAudioEngine()
        }
    }

    private func initializeAudioEngine() throws {
        guard !audioEngineInitialized else { return }

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

        // Return immediately and process in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            do {
                // Initialize unified audio engine (this will set up the session if not already done)
                try self.initializeAudioEngine()

                // Request microphone permission
                let audioSession = AVAudioSession.sharedInstance()

                audioSession.requestRecordPermission { [weak self] allowed in
                    guard let self = self else { return }

                    if allowed {
                        DispatchQueue.global(qos: .userInitiated).async {
                            self.setupRecording(promise: promise)
                        }
                    } else {
                        self.bridgedLog("❌ Microphone permission denied - check Settings > Dust > Microphone")
                        promise.reject(withError: RuntimeError.error(withMessage: "Microphone permission denied. Please enable microphone access in Settings > Dust."))
                    }
                }

            } catch {
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
        bridgedLog("📂 File path: \(fileURL.path)")

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



    private func endCurrentSegment() {
        guard let segmentFile = currentSegmentFile else { return }

        // Calculate duration in seconds
        var duration: Double = 0
        var durationString = "unknown"
        if let startTime = segmentStartTime {
            duration = Date().timeIntervalSince(startTime)
            durationString = String(format: "%.1f seconds", duration)
        }

        // Get file info before closing
        let filename = segmentFile.url.lastPathComponent

        // Get relative path from Documents directory for cross-device compatibility
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        let absolutePath = segmentFile.url.path
        let filePath = absolutePath.replacingOccurrences(of: documentsPath + "/", with: "")

        let isManual = self.currentSegmentIsManual
        let modeType = isManual ? "MANUAL" : "AUTO"
        bridgedLog("🛑 Ended \(modeType) segment: \(filename) (duration: \(durationString))")
        bridgedLog("📤 Calling callback with relativePath: \(filePath), isManual: \(isManual), duration: \(duration)s")

        // Close the file
        currentSegmentFile = nil
        segmentStartTime = nil  // Reset start time

        // Notify JavaScript via callback
        if let callback = self.segmentCallback {
            callback(filename, filePath, self.currentSegmentIsManual, duration)
            bridgedLog("✅ Callback fired for \(filename)")
        } else {
            bridgedLog("⚠️ No callback set for segment")
        }

        silenceCounter = 0
    }

    private func setupRecording(promise: Promise<Void>) {
        do {
            guard let engine = self.audioEngine else {
                promise.reject(withError: RuntimeError.error(withMessage: "Unified audio engine not initialized"))
                return
            }

            // Engine should already be running from initialization
            if !engine.isRunning {
                throw RuntimeError.error(withMessage: "Audio engine is not running")
            }

            // Initialize session timestamp for unique filenames (milliseconds since epoch)
            self.sessionTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
            self.segmentCounter = 0
            self.bridgedLog("🆔 Session ID: \(self.sessionTimestamp)")

            let inputNode = engine.inputNode

            // Query *real* hardware format after engine has started
            let hwFormat = inputNode.inputFormat(forBus: 0)

            // Define explicit tap format (force 16kHz mono for VAD)
            // FluidAudio VAD requires 16kHz sample rate
            let tapFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,  // Fixed at 16kHz for VAD
                channels: 1,
                interleaved: false
            )!

            // Log hardware vs tap formats to verify iOS automatic conversion
            self.bridgedLog("🎤 Hardware format: \(Int(hwFormat.sampleRate))Hz, \(hwFormat.channelCount) channels")
            self.bridgedLog("🎚️ Tap format: \(Int(tapFormat.sampleRate))Hz, \(tapFormat.channelCount) channels")
            self.bridgedLog("✅ Audio engine will automatically convert \(Int(hwFormat.sampleRate))Hz → \(Int(tapFormat.sampleRate))Hz")

            // Remove any existing taps
            inputNode.removeTap(onBus: 0)

            // Init rolling buffer for pre-roll
            rollingBuffer = RollingAudioBuffer()

            // Initialize VAD components asynchronously (non-blocking)
            // Recording starts immediately; VAD becomes active when ready
            Task {
                do {
                    let vadConfig = VadConfig(threshold: Double(self.vadThreshold))
                    self.vadManager = try await VadManager(config: vadConfig)
                    self.vadStreamState = await self.vadManager?.makeStreamState()
                    self.bridgedLog("✅ VAD initialized (threshold: \(self.vadThreshold), sample rate: 16kHz)")
                } catch {
                    self.bridgedLog("⚠️ VAD initialization failed: \(error.localizedDescription)")
                    self.bridgedLog("⚠️ Falling back to RMS detection")
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

            // Install tap
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, time in
                guard let self = self else { return }

                self.tapFrameCounter += 1

                // VAD-based speech detection (replaces RMS)
                var audioIsLoud = false

                if let vadMgr = self.vadManager,
                   var vadState = self.vadStreamState {
                    // Process VAD asynchronously (runs in background)
                    Task {
                        do {
                            // Extract Float array directly from buffer (already 16kHz from tap)
                            guard let floatChannelData = buffer.floatChannelData else { return }
                            let frameLength = Int(buffer.frameLength)
                            let samples = Array(UnsafeBufferPointer(start: floatChannelData[0], count: frameLength))

                            // Process with VAD
                            let vadResult = try await vadMgr.processStreamingChunk(
                                samples,
                                state: vadState,
                                config: .default
                            )

                            // Update state and confidence for next chunk
                            self.vadStreamState = vadResult.state
                            self.speechConfidence = Float(vadResult.probability)

                        } catch {
                            // VAD processing error - confidence stays at previous value
                        }
                    }

                    // Use most recent VAD result (from previous frame)
                    audioIsLoud = self.speechConfidence > self.vadThreshold

                } else {
                    // Fallback to RMS if VAD not initialized
                    audioIsLoud = self.isAudioLoudEnough(buffer)
                }

                // Pre-roll
                self.rollingBuffer?.write(buffer)

                // Segment handling - only run automatic detection if in autoVAD mode
                if self.currentMode == .autoVAD {
                    let isCurrentlyRecordingSegment = self.currentSegmentFile != nil
                    if audioIsLoud {
                        if !isCurrentlyRecordingSegment {
                            self.bridgedLog("🔊 Speech detected! Starting AUTO segment (mode: \(self.currentMode))")
                            self.currentSegmentIsManual = false
                            self.startNewSegment(with: tapFormat)
                        }
                        self.silenceFrameCount = 0
                    } else if isCurrentlyRecordingSegment {
                        self.silenceFrameCount += 1
                        if self.silenceFrameCount >= 50 {
                            self.bridgedLog("🤫 Silence detected, ending AUTO segment after 50 frames")
                            self.endCurrentSegment()
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
                        if self.tapFrameCounter % 2000 == 0 {  // Log every ~20 seconds
                            self.bridgedLog("🎙️ MANUAL recording active (frame: \(self.tapFrameCounter))")
                        }
                    } else {
                        // Increment silence counter
                        self.manualSilenceFrameCount += 1

                        // Log progress every 5 seconds (250 frames at ~50fps)
                        if self.manualSilenceFrameCount % 250 == 0 {
                            let seconds = self.manualSilenceFrameCount / 50
                            self.bridgedLog("🤫 \(seconds) seconds of silence in manual mode...")
                        }

                        if self.manualSilenceFrameCount >= self.manualSilenceThreshold {
                            self.bridgedLog("🤫 15 seconds of silence detected in MANUAL mode, stopping recording")
                            self.manualSilenceFrameCount = 0  // Reset counter

                            // Notify JavaScript via callback
                            if let callback = self.manualSilenceCallback {
                                DispatchQueue.main.async {
                                    callback()
                                }
                            }
                        }
                    }
                }

                // Write to file if recording
                if let segmentFile = self.currentSegmentFile {
                    do {
                        try segmentFile.write(from: buffer)
                    } catch {
                        self.bridgedLog("❌ Failed to write buffer: \(error.localizedDescription)")
                    }
                }
            }

            // Set mode to idle when recording starts (will switch to VAD/manual via mode control methods)
            self.currentMode = .idle
            self.bridgedLog("🔄 Recording mode: idle (waiting for mode switch)")

            promise.resolve(withResult: ())

        } catch {
            bridgedLog("❌ Recording setup failed: \(error.localizedDescription)")
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
                self.endCurrentSegment()
            }

            // Remove tap from unified engine's input node
            if let engine = self.audioEngine {
                engine.inputNode.removeTap(onBus: 0)
            }

            // Clean up VAD resources
            self.vadManager = nil
            self.vadStreamState = nil
            self.speechConfidence = 0.0
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
                self.bridgedLog("⚠️ Closing existing auto segment before manual recording")
                self.endCurrentSegment()
            }

            // Always start a fresh segment for manual recording
            guard let engine = self.audioEngine else {
                promise.reject(withError: RuntimeError.error(withMessage: "Audio engine not initialized"))
                return
            }

            let tapFormat = engine.inputNode.inputFormat(forBus: 0)
            self.startNewSegment(with: tapFormat)
            self.bridgedLog("🗣️ Manual segment started (alarm/day residue)")

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
                // Initialize unified audio engine (will only initialize once)
                try self.initializeAudioEngine()

                // Ensure engine is running
                try self.ensureEngineRunning()

                guard let uri = uri, !uri.isEmpty else {
                    promise.reject(withError: RuntimeError.error(withMessage: "URI is required for playback"))
                    return
                }

                // Store URI for potential looping
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
                        self.bridgedLog("❌ File does not exist at path: \(url.path)")
                        promise.reject(withError: RuntimeError.error(withMessage: "Audio file does not exist at path: \(uri)"))
                        return
                    }
                }

                // Load the audio file
                let audioFile: AVAudioFile
                if uri.hasPrefix("http") {
                    // For HTTP URLs, download the data first (temporary solution)
                    // TODO: Implement proper streaming
                    let data = try Data(contentsOf: url)
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("temp_audio_\(UUID().uuidString).m4a")
                    try data.write(to: tempURL)
                    audioFile = try AVAudioFile(forReading: tempURL)
                } else {
                    audioFile = try AVAudioFile(forReading: url)
                }

                self.currentAudioFile = audioFile

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
                    // Pre-schedule multiple iterations for seamless looping
                    playerNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
                    playerNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
                    playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
                        // When 3rd iteration completes, schedule 3 more
                        self?.scheduleMoreLoops(audioFile: audioFile, playerNode: playerNode)
                    }
                } else {
                    // Non-looping: schedule file with completion
                    playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
                        DispatchQueue.main.async {
                            self?.handlePlaybackCompletion()
                        }
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

        // Note: AVAudioPlayerNode doesn't support seeking directly like AVAudioPlayer
        // This would require stopping, rescheduling from the seek position, and restarting
        // For now, we'll indicate that seeking is not supported with player nodes
        promise.reject(withError: RuntimeError.error(withMessage: "Seeking is not currently supported with unified audio engine"))

        return promise
    }

    public func setVolume(volume: Double) throws -> Promise<String> {
        let promise = Promise<String>()

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

        // Send to JavaScript if callback is available
        if let callback = self.logCallback {
            DispatchQueue.main.async {
                callback(message)
            }
        }
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

                // Store audio file reference early to ensure it's retained for looping
                self.currentAudioFile = audioFile

                // Schedule file(s) for playback
                if self.shouldLoopPlayback {
                    // Pre-schedule multiple iterations for seamless looping
                    newNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
                    newNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
                    newNode.scheduleFile(audioFile, at: nil) { [weak self] in
                        // When 3rd iteration completes, schedule 3 more
                        self?.scheduleMoreLoops(audioFile: audioFile, playerNode: newNode)
                    }
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

    private func startPlayTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }


            self.didEmitPlaybackEnd = false

            self.playTimer = Timer.scheduledTimer(withTimeInterval: self.subscriptionDuration, repeats: true) { [weak self] timer in
                guard let self = self else { return }

                // First check if we have a player node and listener
                guard let playerNode = self.currentPlayerNode,
                      let audioFile = self.currentAudioFile,
                      let listener = self.playBackListener else {
                    self.stopPlayTimer()
                    return
                }

                // Check if player node is still playing
                if !playerNode.isPlaying {
                    // Send final callback if duration is available
                    let durationSeconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate
                    let durationMs = durationSeconds * 1000
                    if durationMs > 0 {
                        self.emitPlaybackEndEvents(durationMs: durationMs, includePlaybackUpdate: true)
                    }

                    self.stopPlayTimer()
                    return
                }

                // Calculate current position for AVAudioPlayerNode
                // This is an approximation - for accurate position tracking, we'd need to use AVAudioTime
                let durationSeconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate
                let durationMs = durationSeconds * 1000

                // Get the player node's current time (this is approximate)
                var currentTimeMs: Double = 0
                if let nodeTime = playerNode.lastRenderTime,
                   let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
                    currentTimeMs = Double(playerTime.sampleTime) / playerTime.sampleRate * 1000
                }


                let playBack = PlayBackType(
                    isMuted: false,
                    duration: durationMs,
                    currentPosition: currentTimeMs
                )

                listener(playBack)

                // Check if playback finished - use a small threshold for floating point comparison
                let threshold = 100.0 // 100ms threshold
                if durationMs > 0 && currentTimeMs >= (durationMs - threshold) {
                    self.emitPlaybackEndEvents(durationMs: durationMs, includePlaybackUpdate: true)
                    self.stopPlayTimer()
                    return
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
