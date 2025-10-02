
import Foundation
import AVFoundation
import NitroModules
import SoundAnalysis

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

    // Track which player is active (for future crossfading)
    private enum ActivePlayer {
        case playerA, playerB, none
    }
    private var activePlayer: ActivePlayer = .none

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
    private var audioLevelThreshold: Float = -25.0 // dB threshold for audio detection (less sensitive for sleep talking)
    private var tapFrameCounter: Int = 0 // Debug counter

    // Rolling buffer for 3-second pre-roll (pre-allocated)
    private var rollingBuffer: RollingAudioBuffer?

    // File writing
    private var currentSegmentFile: AVAudioFile?
    private var segmentCounter = 0
    private var silenceCounter = 0
    private let silenceThreshold = 25  // ~0.5 second of silence before ending segment

    // Output directory for segments
    private var outputDirectory: URL?

    // Files are written to documents/speech_segments/ for JavaScript polling

    // Log callback to bridge Swift logs to JavaScript
    private var logCallback: ((String) -> Void)?

    // Segment callback to notify JavaScript when a new file is written
    private var segmentCallback: ((String, String) -> Void)?

    // MARK: - Unified Audio Engine Management

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

        // Attach nodes to engine
        guard let engine = audioEngine,
            let playerA = audioPlayerNodeA,
            let playerB = audioPlayerNodeB else {
            throw RuntimeError.error(withMessage: "Failed to create audio engine components")
        }

        engine.attach(playerA)
        engine.attach(playerB)

        // Connect player nodes to main mixer
        let mainMixer = engine.mainMixerNode
        engine.connect(playerA, to: mainMixer, format: nil)
        engine.connect(playerB, to: mainMixer, format: nil)

        // Force input node initialization by accessing it (required for .playAndRecord)
        let _ = engine.inputNode
        bridgedLog("🎙️ Input node accessed to ensure proper .playAndRecord configuration")

        // Now safe to start engine with both input and output configured
        try engine.start()
        audioEngineInitialized = true
        bridgedLog("✅ Audio engine initialized and started with .playAndRecord")
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
        // Handle one-shot playback completion

        if let audioFile = self.currentAudioFile {
            let durationSeconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate
            let durationMs = durationSeconds * 1000
            self.emitPlaybackEndEvents(durationMs: durationMs, includePlaybackUpdate: true)
        }

        self.stopPlayTimer()
        self.currentPlayerNode = nil
        self.bridgedLog("🎵 Playback completed (non-looping)")
    }

    private func scheduleMoreLoops(audioFile: AVAudioFile, playerNode: AVAudioPlayerNode) {
        guard self.shouldLoopPlayback else {
            self.bridgedLog("🔄 Loop scheduling cancelled (looping disabled)")
            return
        }

        // Schedule 3 more iterations
        playerNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
        playerNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
        playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
            // Recursive scheduling for continuous looping
            self?.scheduleMoreLoops(audioFile: audioFile, playerNode: playerNode)
        }
        self.bridgedLog("🔄 Scheduled 3 more loop iterations")
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

                // Check current permission status first
                let currentStatus = audioSession.recordPermission
                self.bridgedLog("🎤 Current microphone permission: \(currentStatus.rawValue)")

                audioSession.requestRecordPermission { [weak self] allowed in
                    guard let self = self else { return }

                    self.bridgedLog("🎤 Microphone permission result: \(allowed)")

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
        bridgedLog("🎙️ ❌ No output directory set for speech segments")
        return
    }

    segmentCounter += 1
    let filename = String(format: "speech_%03d.wav", segmentCounter)
    let fileURL = outputDir.appendingPathComponent(filename)

    do {
        // Always use the tap format (guaranteed valid from setupBufferRecording)
        currentSegmentFile = try AVAudioFile(
            forWriting: fileURL,
            settings: tapFormat.settings
        )

        bridgedLog("🎙️ ✅ Started speech segment: \(filename) [SR: \(tapFormat.sampleRate), CH: \(tapFormat.channelCount)]")

        // Pre-roll: flush ~3s of buffered audio into the new file
        if let rollingBuffer = rollingBuffer {
            let preRollBuffers = rollingBuffer.getPreRollBuffers()
            for buffer in preRollBuffers {
                try currentSegmentFile?.write(from: buffer)
            }
            bridgedLog("🎙️ ✅ Wrote \(preRollBuffers.count) pre-roll buffers into new segment")
            rollingBuffer.clear()
            bridgedLog("🔄 Cleared rolling buffer after pre-roll")
        }

        silenceCounter = 0

    } catch {
        bridgedLog("🎙️ ❌ Failed to create speech segment file: \(error.localizedDescription)")
        currentSegmentFile = nil
    }
}



    private func endCurrentSegment() {
        guard let segmentFile = currentSegmentFile else { return }

        // Get file info before closing
        let filename = segmentFile.url.lastPathComponent
        let filePath = segmentFile.url.path
        let frameCount = segmentFile.length
        let sampleRate = segmentFile.fileFormat.sampleRate
        let duration = Double(frameCount) / sampleRate

        // Close the file
        currentSegmentFile = nil

        self.bridgedLog("🎙️ ✅ Ended speech segment: \(filename) (\(String(format: "%.1f", duration))s)")

        // Notify JavaScript via callback
        if let callback = self.segmentCallback {
            callback(filename, filePath)
            self.bridgedLog("📡 Notified JS of new segment: \(filename)")
        }

        silenceCounter = 0
    }

    private func setupRecording(promise: Promise<Void>) {
        bridgedLog("🚀 setupRecording called - Starting audio level detection setup")

        do {
            guard let engine = self.audioEngine else {
                promise.reject(withError: RuntimeError.error(withMessage: "Unified audio engine not initialized"))
                return
            }

            // Log session state
            let audioSession = AVAudioSession.sharedInstance()
            bridgedLog("📱 Audio session already configured in initializeAudioEngine()")
            bridgedLog("🔧 Audio session category: \(audioSession.category.rawValue)")
            bridgedLog("🔧 Audio session mode: \(audioSession.mode.rawValue)")
            bridgedLog("🔧 Audio session active: \(audioSession.isOtherAudioPlaying ? "OTHER AUDIO PLAYING" : "CLEAR")")

            // Engine should already be running from initialization
            if !engine.isRunning {
                bridgedLog("❌ Engine is not running - this is unexpected")
                throw RuntimeError.error(withMessage: "Audio engine is not running")
            }
            bridgedLog("✅ Engine is running and ready for buffer recording")

            let inputNode = engine.inputNode
            bridgedLog("🎙️ Input node obtained")

            // Query *real* hardware format after engine has started
            let hwFormat = inputNode.inputFormat(forBus: 0)
            bridgedLog("🎙️ HW input format - SR: \(hwFormat.sampleRate), CH: \(hwFormat.channelCount)")

            // Define explicit tap format (force mono 44.1k if hwFormat invalid)
            let tapFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: hwFormat.sampleRate > 0 ? hwFormat.sampleRate : 44100,
                channels: 1,
                interleaved: false
            )!

            bridgedLog("🎙️ Using tap format - SR: \(tapFormat.sampleRate), CH: \(tapFormat.channelCount)")

            // Remove any existing taps
            bridgedLog("🧹 Removing any existing taps on input node")
            inputNode.removeTap(onBus: 0)

            // Init rolling buffer for pre-roll
            rollingBuffer = RollingAudioBuffer()

            // Set default output directory if needed
            if outputDirectory == nil {
                let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                outputDirectory = documentsURL.appendingPathComponent("speech_segments")
            }
            if let outputDir = outputDirectory {
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            }

            // Install tap
            bridgedLog("📍 Installing tap with explicit format...")
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, time in
                guard let self = self else { return }

                // Debug log frames
                self.tapFrameCounter += 1
                if self.tapFrameCounter <= 10 {
                    self.bridgedLog("📡 Tap frame #\(self.tapFrameCounter) - buffer size: \(buffer.frameLength), time: \(time.sampleTime)")
                } else if self.tapFrameCounter % 100 == 0 {
                    self.bridgedLog("📡 Tap frame #\(self.tapFrameCounter) - buffer size: \(buffer.frameLength)")
                }

                // Audio level detection
                let audioIsLoud = self.isAudioLoudEnough(buffer)

                // Pre-roll
                self.rollingBuffer?.write(buffer)

                // Segment handling
                let isCurrentlyRecordingSegment = self.currentSegmentFile != nil
                if audioIsLoud {
                    if !isCurrentlyRecordingSegment {
                        self.bridgedLog("🎙️ Audio detected - starting new segment")
                        self.startNewSegment(with: tapFormat)
                    }
                    self.silenceFrameCount = 0
                } else if isCurrentlyRecordingSegment {
                    self.silenceFrameCount += 1
                    if self.silenceFrameCount >= 50 {
                        self.bridgedLog("🎙️ Silence detected - ending segment")
                        self.endCurrentSegment()
                        self.silenceFrameCount = 0
                    }
                }

                // Write to file if recording
                if let segmentFile = self.currentSegmentFile {
                    do {
                        try segmentFile.write(from: buffer)
                    } catch {
                        self.bridgedLog("🎙️ ❌ Failed to write buffer: \(error.localizedDescription)")
                    }
                }
            }

            bridgedLog("✅ Tap installed successfully! Threshold: \(self.audioLevelThreshold) dB")
            promise.resolve(withResult: ())

        } catch {
            bridgedLog("🎙️ ❌ Recording setup failed: \(error.localizedDescription)")
            promise.reject(withError: RuntimeError.error(withMessage: "Recording setup failed: \(error.localizedDescription)"))
        }
    }


    private func convertBufferToFloatArray(buffer: AVAudioPCMBuffer) -> [Double] {
        guard let floatChannelData = buffer.floatChannelData else {
            return []
        }

        let frameLength = Int(buffer.frameLength)
        let channelData = floatChannelData[0] // Use first channel (mono)

        var samples: [Double] = []
        samples.reserveCapacity(frameLength)

        for i in 0..<frameLength {
            samples.append(Double(channelData[i]))
        }

        return samples
    }

    public func stopRecorder() throws -> Promise<Void> {
        let promise = Promise<Void>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            // Remove tap from unified engine's input node
            if let engine = self.audioEngine {
                engine.inputNode.removeTap(onBus: 0)
            }

            // No callback to clear - using event emitting

            // Keep the unified engine running for potential playback or quick restart
            print("🎙️ Recording stopped successfully (unified engine remains active)")
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
                self.bridgedLog("🎵 Starting player for URI: \(uri ?? "nil")")

                // Initialize unified audio engine (will only initialize once)
                try self.initializeAudioEngine()

                guard let uri = uri, !uri.isEmpty else {
                    promise.reject(withError: RuntimeError.error(withMessage: "URI is required for playback"))
                    return
                }

                print("🎵 URI provided: \(uri)")

                // Store URI for potential looping
                self.currentPlaybackURI = uri
                if self.shouldLoopPlayback {
                    print("🔄 Looping enabled for playback")
                }

                // Handle all URLs the same way with AVAudioFile
                let url: URL
                if uri.hasPrefix("http") {
                    // For now, handle HTTP URLs as before
                    // TODO: Implement proper streaming with AVAudioPlayerNode
                    print("🎵 Detected remote URL, will load file data")
                    url = URL(string: uri)!
                } else if uri.hasPrefix("file://") {
                    print("🎵 URI has file:// prefix")
                    url = URL(string: uri)!
                    print("🎵 Created URL from string: \(url)")
                } else {
                    print("🎵 URI is plain path")
                    url = URL(fileURLWithPath: uri)
                    print("🎵 Created URL from file path: \(url)")
                }

                // For local files, check if file exists
                if !uri.hasPrefix("http") {
                    print("🎵 Final URL path: \(url.path)")
                    print("🎵 Checking if file exists at path: \(url.path)")

                    if !FileManager.default.fileExists(atPath: url.path) {
                        self.bridgedLog("🎵 ❌ File does not exist at path: \(url.path)")
                        promise.reject(withError: RuntimeError.error(withMessage: "Audio file does not exist at path: \(uri)"))
                        return
                    }
                }

                print("🎵 ✅ Loading audio file with AVAudioFile...")

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
                    self.bridgedLog("🔄 File scheduled for seamless looping (3 iterations pre-scheduled)")
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
                    self.bridgedLog("🎵 Playback started (file-based)")

                    promise.resolve(withResult: uri)
                }

            } catch {
                self.bridgedLog("🎵 ❌ Playback error: \(error.localizedDescription)")
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

    public func stopPlayer() throws -> Promise<String> {
        let promise = Promise<String>()

        // Stop both player nodes
        if let playerA = self.audioPlayerNodeA {
            playerA.stop()
            playerA.volume = 1.0 // Reset volume
        }

        if let playerB = self.audioPlayerNodeB {
            playerB.stop()
            playerB.volume = 1.0 // Reset volume
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
        print("🎵 Removing playback listener and stopping timer")
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

    public func setSegmentCallback(callback: @escaping (String, String) -> Void) throws {
        self.segmentCallback = callback
        bridgedLog("✅ Segment callback registered")
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
                    self.bridgedLog("🔄 Crossfade target scheduled for looping")
                } else {
                    newNode.scheduleFile(audioFile, at: nil) { [weak self] in
                        self?.handlePlaybackCompletion()
                    }
                }

                newNode.play()

                // Start fading
                if let currentNode = self.currentPlayerNode {
                    self.fadeVolume(node: currentNode, from: 1.0, to: 0.0, duration: fadeDuration)
                }
                self.fadeVolume(node: newNode, from: 0.0, to: 1.0, duration: fadeDuration) {
                    // Swap after fade
                    self.currentPlayerNode?.stop()
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
            print("🎵 Playback end already emitted, skipping duplicate")
            return
        }
        self.didEmitPlaybackEnd = true

        if includePlaybackUpdate, let listener = self.playBackListener {
            let finalPlayBack = PlayBackType(
                isMuted: false,
                duration: durationMs,
                currentPosition: durationMs
            )
            print("🎵 Emitting final playback update at \(durationMs)ms")
            listener(finalPlayBack)
        }

        if let endListener = self.playbackEndListener {
            let endEvent = PlaybackEndType(
                duration: durationMs,
                currentPosition: durationMs
            )
            print("🎵 Emitting playback end event at \(durationMs)ms")
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
            print("🎵 AVAudioPlayer finished playing. success=\(flag)")
            guard let owner = owner else { return }
            let finalDurationMs = player.duration * 1000
            owner.emitPlaybackEndEvents(durationMs: finalDurationMs, includePlaybackUpdate: true)
            owner.stopPlayTimer()
        }

        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
            print("🎵 AVAudioPlayer decode error: \(String(describing: error))")
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
                print("🔄 Rolling buffer is now full (0.6 seconds of pre-roll ready)")
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
    // Simple audio level detection to replace ML-based speech detection
    private func isAudioLoudEnough(_ buffer: AVAudioPCMBuffer) -> Bool {
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

        let isLoud = db > audioLevelThreshold

        // Log ALL audio levels periodically (every 44th frame ≈ 1 second at 44100Hz)
        if tapFrameCounter % 44 == 0 {
            let status = isLoud ? "🔊 LOUD" : "🔇 quiet"
            self.bridgedLog("📊 Audio Level: \(String(format: "%.2f", db)) dB (threshold: \(String(format: "%.1f", audioLevelThreshold)) dB) - \(status)")
        }

        // Log when threshold is crossed
        if isLoud {
            self.bridgedLog("🔊 AUDIO DETECTED! Level: \(String(format: "%.2f", db)) dB > threshold: \(String(format: "%.1f", audioLevelThreshold)) dB")
        }

        // Sound detected if above threshold
        return isLoud
    }

    // SNResultsObserving stub methods (keeping for protocol conformance if needed)
    func request(_ request: SNRequest, didProduce result: SNResult) {
        // No longer used - using audio level detection instead
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        print("🎙️ Speech detection error (ignored): \(error)")
    }

    func requestDidComplete(_ request: SNRequest) {
        print("🎙️ Speech detection request completed (ignored)")
    }
}
