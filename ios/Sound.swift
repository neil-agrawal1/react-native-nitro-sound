
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
    private let engineInitLock = NSLock() // Thread-safe initialization guard

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
    private var loopCrossfadeDuration: TimeInterval = 1.0  // 1 second crossfade
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
    private var vadThreshold: Float = 0.2  // 20% confidence (lower = more sensitive)

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
        // Handle audio interruptions (phone calls, other apps, etc.)
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
            // Check if we should resume (iOS tells us via interruption options)
            let shouldResume = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt) == AVAudioSession.InterruptionOptions.shouldResume.rawValue
            
            bridgedLog("🔊 Audio interruption ended (shouldResume: \(shouldResume))")
            logStateSnapshot(context: "interruption-ended")
            
            // CRITICAL: If audio was playing (silent loop, ambient loop, or regular playback),
            // we need to restart it to keep the session active (like Spotify does)
            // This keeps the app alive in background and prevents session deactivation
            
            // Restart engine after interruption
            if audioEngineInitialized {
                bridgedLog("🔧 Engine is initialized - attempting restart")
                var sessionReactivated = false
                do {
                    // restartAudioEngine() reactivates the session AND restarts the engine
                    bridgedLog("🔧 Calling restartAudioEngine()...")
                    try restartAudioEngine()
                    sessionReactivated = true
                    bridgedLog("✅ Engine restart succeeded")
                    logStateSnapshot(context: "after-restart-success")
                    
                    // Resume playback if we were playing before interruption
                    // This keeps the session active, preventing deactivation (like Spotify)
                    // Only resume if session reactivation succeeded
                    if shouldResume && sessionReactivated {
                        bridgedLog("🔄 Attempting to resume playback (shouldResume=\(shouldResume), sessionReactivated=\(sessionReactivated))")
                        // Resume main playback if it was looping (silent loop or journey audio)
                        if shouldLoopPlayback, let playerNode = currentPlayerNode, let audioFile = currentAudioFile {
                            bridgedLog("🔄 Resuming loop playback after interruption")
                            bridgedLog("   Player node state: isPlaying=\(playerNode.isPlaying), uri=\(currentPlaybackURI ?? "none")")
                            // Player node might have stopped, restart it with seamless looping
                            if !playerNode.isPlaying {
                                bridgedLog("   Player node stopped - restarting with seamless loop")
                                // Use the same seamless loop logic as startSeamlessLoop()
                                if let uri = currentPlaybackURI {
                                    let url: URL
                                    if uri.hasPrefix("file://") {
                                        url = URL(string: uri)!
                                    } else {
                                        url = URL(fileURLWithPath: uri)
                                    }
                                    startSeamlessLoop(audioFile: audioFile, url: url)
                                    bridgedLog("   ✅ Seamless loop restarted")
                                } else {
                                    // Fallback: simple reschedule
                                    bridgedLog("   Using fallback reschedule (no URI)")
                                    playerNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
                                    playerNode.play()
                                    bridgedLog("   ✅ Fallback playback started")
                                }
                            } else {
                                bridgedLog("   Player node already playing - no restart needed")
                            }
                        } else {
                            bridgedLog("   No loop playback to resume (shouldLoopPlayback=\(shouldLoopPlayback), playerNode=\(currentPlayerNode != nil), audioFile=\(currentAudioFile != nil))")
                        }
                        
                        // Resume ambient loop if it was playing
                        if isAmbientLoopPlaying, let playerC = audioPlayerNodeC, let ambientFile = currentAmbientFile {
                            bridgedLog("🔄 Resuming ambient loop after interruption")
                            bridgedLog("   Ambient player state: isPlaying=\(playerC.isPlaying)")
                            if !playerC.isPlaying {
                                bridgedLog("   Ambient player stopped - restarting")
                                // Reschedule multiple iterations for seamless looping
                                playerC.scheduleFile(ambientFile, at: nil, completionHandler: nil)
                                playerC.scheduleFile(ambientFile, at: nil, completionHandler: nil)
                                playerC.scheduleFile(ambientFile, at: nil) { [weak self] in
                                    self?.scheduleMoreAmbientLoops(audioFile: ambientFile, playerNode: playerC)
                                }
                                playerC.play()
                                bridgedLog("   ✅ Ambient loop restarted")
                            } else {
                                bridgedLog("   Ambient player already playing - no restart needed")
                            }
                        } else {
                            bridgedLog("   No ambient loop to resume (isAmbientLoopPlaying=\(isAmbientLoopPlaying), playerC=\(audioPlayerNodeC != nil), ambientFile=\(currentAmbientFile != nil))")
                        }
                        
                        bridgedLog("🔄 Playback resume attempt completed")
                    } else {
                        bridgedLog("⚠️ Not resuming playback: shouldResume=\(shouldResume), sessionReactivated=\(sessionReactivated)")
                    }
                } catch {
                    // In background with locked device, reactivation might fail
                    // This is OK - the next audio operation (alarm, silent loop restart) will reinitialize
                    let nsError = error as NSError
                    let errorCode = nsError.code
                    
                    bridgedLog("❌ Engine restart failed during interruption recovery")
                    bridgedLog("   Error: \(error.localizedDescription)")
                    bridgedLog("   Error code: \(errorCode)")
                    logStateSnapshot(context: "after-restart-failure")
                    // Don't crash - next operation will handle reinitialization
                }
            } else {
                bridgedLog("⚠️ Engine not initialized - skipping restart")
            }
        } else if type == .began {
            bridgedLog("🔇 Audio interruption began")
            logStateSnapshot(context: "interruption-began")
            // Engine will be stopped automatically by iOS
            // Player nodes will also stop automatically
            bridgedLog("   Engine and players will be stopped automatically by iOS")
        }
    }

    // MARK: - Debug Logging Helper

    private func logStateSnapshot(context: String) {
        let session = AVAudioSession.sharedInstance()

        // Recording state
        let mode = currentMode == .idle ? "idle" : (currentMode == .manual ? "manual" : "vad")
        let hasTap = audioEngine?.inputNode.engine != nil
        let hasSegment = currentSegmentFile != nil

        // Engine state
        let engineInit = audioEngineInitialized
        let engineRun = audioEngine?.isRunning ?? false

        // Session state
        let category = session.category.rawValue
        let route = session.currentRoute.outputs.map { $0.portName }.joined(separator: ", ")
        let sampleRate = Int(session.sampleRate)

        bridgedLog("📊 STATE SNAPSHOT [\(context)]:")
        bridgedLog("   🎙️ Recording: mode=\(mode), tap=\(hasTap), segment=\(hasSegment)")
        bridgedLog("   🔧 Engine: init=\(engineInit), running=\(engineRun)")
        bridgedLog("   🔊 Playback: loop=\(shouldLoopPlayback), ambient=\(isAmbientLoopPlaying)")
        bridgedLog("   📡 Session: \(category), \(sampleRate)Hz, route=[\(route)]")
    }

    private func restartAudioEngine() throws {
        guard let engine = audioEngine else {
            bridgedLog("❌ Cannot restart engine - engine is nil")
            throw RuntimeError.error(withMessage: "No engine to restart")
        }

        bridgedLog("🔧 Starting engine restart process...")
        bridgedLog("   Engine state: initialized=\(audioEngineInitialized), running=\(engine.isRunning)")

        // IMPORTANT: AVAudioSession and AVAudioEngine are separate systems:
        // - AVAudioSession: iOS system-level singleton that controls audio permissions/routing
        // - AVAudioEngine: Your app's audio processing engine instance
        //
        // After an interruption, iOS may deactivate the session (setActive(false))
        // but the engine instance still exists. We must reactivate the SESSION first,
        // then restart the ENGINE. Trying to start the engine without an active session
        // can cause format errors (2003329396) because hardware isn't accessible.
        let audioSession = AVAudioSession.sharedInstance()
        
        // Log session state before reactivation
        let sessionCategory = audioSession.category.rawValue
        let currentRoute = audioSession.currentRoute
        bridgedLog("   📡 Session state before reactivation: category=\(sessionCategory)")
        bridgedLog("   🔌 Current route: [\(currentRoute.outputs.map { $0.portName }.joined(separator: ", "))]")
        
        // Step 1: Reactivate the audio session (tell iOS we want audio access again)
        // NOTE: In background with locked device, this might fail if iOS has suspended the app.
        // That's OK - the next audio operation (alarm, silent loop) will fully reinitialize.
        bridgedLog("   🔧 Step 1: Reactivating audio session...")
        do {
            try audioSession.setActive(true, options: [])
            bridgedLog("   ✅ Audio session reactivated successfully")
        } catch {
            let nsError = error as NSError
            bridgedLog("   ⚠️ Failed to reactivate audio session: \(error.localizedDescription) (code: \(nsError.code))")
            bridgedLog("   ⚠️ This may fail in background - continuing anyway")
            // In background, this might fail - that's OK, next operation will reinitialize
            // Continue anyway - session might still be active or will be activated by engine.start()
        }

        // Step 2: Restart the audio engine (start audio processing)
        if !engine.isRunning {
            bridgedLog("   🔧 Step 2: Starting audio engine...")
            do {
                try engine.start()
                bridgedLog("   ✅ Audio engine started successfully")
                bridgedLog("   ✅ Engine restart completed successfully")
            } catch {
                // If restart fails with format error (2003329396 = kAudioFormatUnsupportedDataFormatError),
                // the engine's format configuration is likely stale/invalid after interruption
                let nsError = error as NSError
                let errorCode = nsError.code
                
                bridgedLog("   ❌ Engine start failed: \(error.localizedDescription) (code: \(errorCode))")
                
                if errorCode == 2003329396 { // kAudioFormatUnsupportedDataFormatError
                    bridgedLog("   ⚠️ Format error detected (2003329396) - engine format is stale/invalid")
                    bridgedLog("   🔧 Destroying engine for full reinitialize...")
                    // Destroy the engine instance so initializeAudioEngine() creates a fresh one
                    // This ensures we get a clean format configuration on next operation
                    audioEngine = nil
                    audioPlayerNodeA = nil
                    audioPlayerNodeB = nil
                    audioPlayerNodeC = nil
                    audioEngineInitialized = false
                    bridgedLog("   ✅ Engine destroyed - will reinitialize on next operation")
                    // Don't throw - allow graceful degradation, next operation will fully reinitialize
                } else {
                    // Re-throw other errors (they might be recoverable)
                    bridgedLog("   ❌ Engine restart failed with non-format error - rethrowing")
                    throw error
                }
            }
        } else {
            bridgedLog("   ℹ️ Engine already running - no restart needed")
            bridgedLog("   ✅ Engine restart check completed")
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
        // Thread-safe initialization: serialize access to guard check and initialization
        engineInitLock.lock()
        defer { engineInitLock.unlock() }

        guard !audioEngineInitialized else {
            bridgedLog("ℹ️ Engine already initialized - skipping initialization")
            return
        }

        bridgedLog("🔧 Starting audio engine initialization...")
        logStateSnapshot(context: "before-engine-init")
        
        // Check if we're initializing during active recording (shouldn't happen, but log it)
        let modeDescription: String
        switch currentMode {
        case .idle:
            modeDescription = "idle"
        case .manual:
            modeDescription = "manual"
        case .autoVAD:
            modeDescription = "autoVAD"
        }
        let hasActiveSegment = currentSegmentFile != nil
        if currentMode != .idle || hasActiveSegment {
            bridgedLog("   ⚠️ WARNING: Initializing engine during active recording session!")
            bridgedLog("   ⚠️ Recording mode: \(modeDescription), segmentActive: \(hasActiveSegment)")
        }

        // Setup audio session ONCE for recording + playback
        let audioSession = AVAudioSession.sharedInstance()
        
        // Log current session state
        let currentRoute = audioSession.currentRoute
        bridgedLog("   📡 Current session state:")
        bridgedLog("      Category: \(audioSession.category.rawValue)")
        bridgedLog("      Route: [\(currentRoute.outputs.map { $0.portName }.joined(separator: ", "))]")
        bridgedLog("      Sample rate: \(audioSession.sampleRate)Hz")
        bridgedLog("      Input channels: \(audioSession.inputNumberOfChannels)")
        
        // Configure session category and settings first
        bridgedLog("   🔧 Step 1: Configuring audio session...")
        try audioSession.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
        bridgedLog("   ✅ Session category set: .playAndRecord")
        
        try audioSession.setPreferredSampleRate(44100)
        bridgedLog("   ✅ Preferred sample rate set: 44100Hz")
        
        // Only set mono input if hardware supports it
        if audioSession.maximumInputNumberOfChannels >= 1 {
            try? audioSession.setPreferredInputNumberOfChannels(1)
            bridgedLog("   ✅ Preferred input channels set: 1 (mono)")
        } else {
            bridgedLog("   ℹ️ Hardware doesn't support mono input - using default")
        }
        
        try audioSession.setPreferredIOBufferDuration(0.0232) // ~23ms
        bridgedLog("   ✅ Preferred I/O buffer duration set: 0.0232s (~23ms)")
        
        // Activate session - CRITICAL: This must succeed for engine to work
        // If this fails (e.g., in background), we throw so caller knows to retry when app wakes
        bridgedLog("   🔧 Step 2: Activating audio session...")
        do {
            try audioSession.setActive(true)
            bridgedLog("   ✅ Audio session activated successfully")
        } catch {
            // Session activation failed - this means we can't use audio right now
            // This can happen if app is suspended in background after interruption
            // The caller (alarm/silent loop) should retry when app wakes up
            let nsError = error as NSError
            bridgedLog("   ❌ Session activation failed: \(error.localizedDescription) (code: \(nsError.code))")
            bridgedLog("   ⚠️ This may happen if app is suspended in background")
            bridgedLog("   ⚠️ Will need to retry when app wakes (alarm will trigger this)")
            throw RuntimeError.error(withMessage: "Audio session activation failed - app may be suspended. Retry when app wakes: \(error.localizedDescription)")
        }

        // Create the unified audio engine
        bridgedLog("   🔧 Step 3: Creating audio engine...")
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else {
            throw RuntimeError.error(withMessage: "Failed to create audio engine")
        }
        bridgedLog("   ✅ Audio engine created")

        // Create player nodes for crossfading support
        bridgedLog("   🔧 Step 4: Creating player nodes...")
        audioPlayerNodeA = AVAudioPlayerNode()
        audioPlayerNodeB = AVAudioPlayerNode()
        audioPlayerNodeC = AVAudioPlayerNode()
        bridgedLog("   ✅ Player nodes created (A, B, C)")

        // Attach nodes to engine
        guard let playerA = audioPlayerNodeA,
            let playerB = audioPlayerNodeB,
            let playerC = audioPlayerNodeC else {
            throw RuntimeError.error(withMessage: "Failed to create audio engine components")
        }

        bridgedLog("   🔧 Step 5: Attaching nodes to engine...")
        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(playerC)
        bridgedLog("   ✅ All player nodes attached")

        // Connect player nodes to main mixer
        bridgedLog("   🔧 Step 6: Connecting nodes to mixer...")
        let mainMixer = engine.mainMixerNode
        engine.connect(playerA, to: mainMixer, format: nil)
        engine.connect(playerB, to: mainMixer, format: nil)
        engine.connect(playerC, to: mainMixer, format: nil)
        bridgedLog("   ✅ All player nodes connected to main mixer")

        // Force input node initialization by accessing it (required for .playAndRecord)
        bridgedLog("   🔧 Step 7: Initializing input node...")
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        bridgedLog("   ✅ Input node initialized")
        bridgedLog("      Input format: \(Int(inputFormat.sampleRate))Hz, \(inputFormat.channelCount) channels")

        // Now safe to start engine with both input and output configured
        bridgedLog("   🔧 Step 8: Starting audio engine...")
        do {
            try engine.start()
            audioEngineInitialized = true
            bridgedLog("   ✅ Audio engine started successfully")
            bridgedLog("✅ Engine initialization completed successfully")
            logStateSnapshot(context: "after-engine-init")
        } catch {
            let nsError = error as NSError
            bridgedLog("   ❌ Engine start failed: \(error.localizedDescription) (code: \(nsError.code))")
            audioEngineInitialized = false
            throw error
        }
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
        if outputDuration > 0.1 {
            bridgedLog("🔄 Resampled 16kHz → 44.1kHz (\(String(format: "%.1f", outputDuration))s)")
        }
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

        // Pre-roll: flush ~3s of buffered audio into AUTO segments only
        // Manual segments start recording immediately without pre-roll
        if !isManual, let rollingBuffer = rollingBuffer {
            let preRollBuffers = rollingBuffer.getPreRollBuffers()
            for buffer in preRollBuffers {
                try currentSegmentFile?.write(from: buffer)
            }
            rollingBuffer.clear()
        } else if isManual {
            // Clear buffer for manual segments but don't write them
            rollingBuffer?.clear()
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

        // Close the file first
        currentSegmentFile = nil
        segmentStartTime = nil  // Reset start time

        // Wait for file system to flush before reading (fixes duration = 0 bug)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }

            // Calculate ACTUAL duration from the audio file (not timestamps)
            var duration: Double = 0

            do {
                let audioFile = try AVAudioFile(forReading: fileURL)
                let frameCount = audioFile.length
                let sampleRate = audioFile.processingFormat.sampleRate
                duration = Double(frameCount) / sampleRate
            } catch {
                self.bridgedLog("⚠️ Could not read audio file duration: \(error.localizedDescription)")
            }

            // Notify JavaScript via callback
            if let callback = self.segmentCallback {
                callback(filename, filePath, isManual, duration)
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

                // Only compute VAD if we're in autoVAD mode, or in manual mode with active segment
                if self.currentMode == .autoVAD || (self.currentMode == .manual && self.currentSegmentFile != nil) {
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
                // Only write buffer in autoVAD mode, or in manual mode when segment is active
                if self.currentMode == .autoVAD || (self.currentMode == .manual && self.currentSegmentFile != nil) {
                    self.rollingBuffer?.write(converted16kHzBuffer)
                }

                // Segment handling - only run automatic detection if in autoVAD mode
                if self.currentMode == .autoVAD {
                    let isCurrentlyRecordingSegment = self.currentSegmentFile != nil
                    if audioIsLoud {
                        if !isCurrentlyRecordingSegment {
                            self.currentSegmentIsManual = false
                            // Use target 16kHz format for file writing
                            if let targetFormat = self.targetFormat {
                                self.startNewSegment(with: targetFormat)
                            } else {
                                self.bridgedLog("⚠️ Cannot start segment: targetFormat is nil!")
                            }
                        }
                        self.silenceFrameCount = 0
                    } else if isCurrentlyRecordingSegment {
                        self.silenceFrameCount += 1
                        if self.silenceFrameCount >= 50 {
                            // Use same processing pipeline as manual segments (trim + resample)
                            if let metadata = self.endCurrentSegmentWithoutCallback() {
                                // No trim needed for auto segments (0 seconds)
                                self.processAndFireSegmentCallback(metadata: metadata, trimSeconds: 0)
                            }
                            self.silenceFrameCount = 0
                        }
                    }
                } else if self.currentMode == .manual && self.currentSegmentFile != nil {
                    // In manual mode with active segment, detect silence for automatic progression
                    if audioIsLoud {
                        // Reset silence counter on speech
                        if self.manualSilenceFrameCount > 0 {
                            let elapsedSeconds = Double(self.manualSilenceFrameCount) / 14.0
                            self.bridgedLog("🔊 SPEECH DETECTED - resetting silence counter (was at \(self.manualSilenceFrameCount) frames / \(String(format: "%.1f", elapsedSeconds))s)")
                            self.manualSilenceFrameCount = 0
                        }
                    } else {
                        // Increment silence counter
                        self.manualSilenceFrameCount += 1

                        // Log every 50 frames (~3.5s at 14fps) to track progress
                        if self.manualSilenceFrameCount % 50 == 0 {
                            let thresholdSeconds = Double(self.manualSilenceThreshold) / 14.0
                            let elapsedSeconds = Double(self.manualSilenceFrameCount) / 14.0
                            self.bridgedLog("🔇 Silence detected: \(self.manualSilenceFrameCount)/\(self.manualSilenceThreshold) frames (\(String(format: "%.1f", elapsedSeconds))s / \(String(format: "%.1f", thresholdSeconds))s)")
                        }

                        if self.manualSilenceFrameCount >= self.manualSilenceThreshold {
                            let thresholdSeconds = Double(self.manualSilenceThreshold) / 14.0
                            self.bridgedLog("⚠️ SILENCE TIMEOUT: \(self.manualSilenceFrameCount)/\(self.manualSilenceThreshold) frames reached (\(String(format: "%.1f", thresholdSeconds))s)")
                            self.manualSilenceFrameCount = 0  // Reset counter

                            // Close segment and get metadata (NO callback yet)
                            guard let metadata = self.endCurrentSegmentWithoutCallback() else {
                                self.bridgedLog("⚠️ No segment to end")
                                return
                            }

                            // Process the audio file (trim silence, then resample) and fire callback
                            let silenceDurationSeconds = Double(self.manualSilenceThreshold) / 14.0

                            // Don't trim for voice command segments (1s timeout)
                            // Only trim for longer segments like dreams (15s timeout)
                            let shouldTrim = silenceDurationSeconds > 2.0  // If timeout > 2s, it's a dream segment
                            let trimAmount = shouldTrim ? silenceDurationSeconds : 0.0

                            self.bridgedLog("🔧 Trim decision: timeout=\(String(format: "%.1f", silenceDurationSeconds))s, trim=\(shouldTrim ? "YES" : "NO")")
                            self.processAndFireSegmentCallback(metadata: metadata, trimSeconds: trimAmount)

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

            // Reset mode to idle
            self.currentMode = .idle

            // No callback to clear - using event emitting

            // Keep the unified engine running for potential playback or quick restart
            promise.resolve(withResult: ())
        }

        return promise
    }

    /**
     * End the engine session and completely destroy all audio resources.
     * This method performs a full teardown:
     * - Ends any active recording segments
     * - Stops all playback
     * - Stops the audio engine
     * - Deactivates the audio session (removes microphone indicator)
     * - Destroys the engine instance (forces clean re-initialization)
     *
     * Call this when stopping a sleep session to ensure the microphone
     * indicator disappears and all audio resources are released.
     */
    public func endEngineSession() throws -> Promise<Void> {
        let promise = Promise<Void>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            self.bridgedLog("🔚 endEngineSession() called - full teardown")

            // Step 1: End any active recording segments
            if self.currentSegmentFile != nil {
                self.bridgedLog("   Ending active recording segment...")
                if let metadata = self.endCurrentSegmentWithoutCallback() {
                    self.processAndFireSegmentCallback(metadata: metadata, trimSeconds: 0)
                }
            }

            // Step 2: Stop all playback
            self.bridgedLog("   Stopping all player nodes...")
            self.currentPlayerNode?.stop()
            self.audioPlayerNodeA?.stop()
            self.audioPlayerNodeB?.stop()
            self.audioPlayerNodeC?.stop()

            // Step 3: Remove microphone tap
            if let engine = self.audioEngine {
                self.bridgedLog("   Removing microphone tap...")
                engine.inputNode.removeTap(onBus: 0)
            }

            // Step 4: Stop the audio engine
            if let engine = self.audioEngine, engine.isRunning {
                self.bridgedLog("   Stopping audio engine...")
                engine.stop()
            }

            // Step 5: Deactivate audio session (critical for removing mic indicator)
            let audioSession = AVAudioSession.sharedInstance()
            self.bridgedLog("   Deactivating audio session...")
            do {
                try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                self.bridgedLog("   ✅ Audio session deactivated - mic indicator should disappear")
            } catch {
                self.bridgedLog("   ⚠️ Failed to deactivate session: \(error.localizedDescription)")
                // Continue cleanup even if deactivation fails
            }

            // Step 6: Destroy engine instance (forces re-initialization on next session)
            self.bridgedLog("   Destroying engine instance...")
            self.audioEngine = nil
            self.audioPlayerNodeA = nil
            self.audioPlayerNodeB = nil
            self.audioPlayerNodeC = nil
            self.audioEngineInitialized = false

            // Step 7: Clean up recording resources
            self.currentSegmentFile = nil
            self.vadManager = nil
            self.vadStreamState = nil

            // Step 8: Reset playback state
            self.currentPlayerNode = nil
            self.currentAudioFile = nil
            self.currentAmbientFile = nil
            self.isAmbientLoopPlaying = false
            self.shouldLoopPlayback = false
            self.currentPlaybackURI = nil

            // Step 9: Reset mode
            self.currentMode = .idle

            self.bridgedLog("✅ endEngineSession() completed - all resources destroyed")
            promise.resolve(withResult: ())
        }

        return promise
    }

    // MARK: - Mode Control Methods

    public func setManualMode() throws -> Promise<Void> {
        bridgedLog("🔧 [1/5] setManualMode() called")
        let promise = Promise<Void>()

        bridgedLog("🔧 [2/5] Promise created, dispatching to queue...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }
            self.bridgedLog("🔧 [3/5] Inside async block - starting mode switch")

            // Force close any existing segment (might be from auto detection)
            // Close synchronously WITHOUT callback to avoid promise lifetime issues
            if self.currentSegmentFile != nil {
                self.bridgedLog("⚠️ Closing existing segment before manual mode (no callback)")
                self.currentSegmentFile = nil  // Just close the file, don't fire callback
                self.segmentStartTime = nil
            }

            // Switch to manual mode (suppresses auto detection)
            self.currentMode = .manual
            self.currentSegmentIsManual = true
            self.silenceFrameCount = 0
            self.manualSilenceFrameCount = 0  // Reset manual silence counter

            self.bridgedLog("🔧 [4/5] Mode flags set, resolving promise...")
            promise.resolve(withResult: ())
            self.bridgedLog("🔧 [5/5] setManualMode() completed successfully")
        }

        bridgedLog("🔧 Returning promise from setManualMode()")
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

            // Reset silence counter
            self.manualSilenceFrameCount = 0

            // Start new manual segment
            self.startNewSegment(with: targetFormat)

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
                // Get metadata and process with trim + resample
                if let metadata = self.endCurrentSegmentWithoutCallback() {
                    // Use 0 seconds trim for manual stop (no silence to remove)
                    self.processAndFireSegmentCallback(metadata: metadata, trimSeconds: 0)
                }
            }

            // Stay in manual mode (as per user's answer)
            promise.resolve(withResult: ())
        }

        return promise
    }

    public func setIdleMode() throws -> Promise<Void> {
        bridgedLog("🔧 [1/5] setIdleMode() called")
        let promise = Promise<Void>()

        bridgedLog("🔧 [2/5] Promise created, dispatching to queue...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }
            self.bridgedLog("🔧 [3/5] Inside async block - starting mode switch")

            // End any current segment before switching to idle
            if self.currentSegmentFile != nil {
                self.bridgedLog("⚠️ Closing existing segment before idle mode")
                self.endCurrentSegment()
            }

            // Switch to idle mode (keeps tap active for quick resume)
            self.currentMode = .idle

            self.bridgedLog("🔧 [4/5] Mode flags set, resolving promise...")
            promise.resolve(withResult: ())
            self.bridgedLog("🔧 [5/5] setIdleMode() completed successfully")
        }

        bridgedLog("🔧 Returning promise from setIdleMode()")
        return promise
    }

    public func setVADMode() throws -> Promise<Void> {
        bridgedLog("🔧 [1/5] setVADMode() called")
        let promise = Promise<Void>()

        bridgedLog("🔧 [2/5] Promise created, dispatching to queue...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }
            self.bridgedLog("🔧 [3/5] Inside async block - starting mode switch")

            // End any current segment before mode switch
            if self.currentSegmentFile != nil {
                self.bridgedLog("⚠️ Closing existing segment before VAD mode")
                self.endCurrentSegment()
            }

            // Switch to autoVAD mode
            self.currentMode = .autoVAD
            self.silenceFrameCount = 0
            self.currentSegmentIsManual = false

            // Reset VAD state to fresh initial state (prevents false positives from stale data)
            self.vadStreamState = VadStreamState.initial()

            self.bridgedLog("🔧 [4/5] Mode flags set, resolving promise...")
            promise.resolve(withResult: ())
            self.bridgedLog("🔧 [5/5] setVADMode() completed successfully")
        }

        bridgedLog("🔧 Returning promise from setVADMode()")
        return promise
    }

    public func getCurrentMode() throws -> Promise<RecordingMode> {
        let promise = Promise<RecordingMode>()
        
        // Return current mode (synchronous - just reading property)
        // Convert Swift SegmentMode enum to RecordingMode type
        let recordingMode: RecordingMode
        switch self.currentMode {
        case .idle:
            recordingMode = RecordingMode(fromString: "idle")!
        case .manual:
            recordingMode = RecordingMode(fromString: "manual")!
        case .autoVAD:
            recordingMode = RecordingMode(fromString: "vad")!  // TypeScript uses 'vad', Swift uses 'autoVAD'
        }
        
        promise.resolve(withResult: recordingMode)
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

                // Set volume (use playbackVolume if set, otherwise default to 1.0)
                playerNode.volume = self.playbackVolume

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

        let totalDuration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        self.bridgedLog("🔄 Crossfading loop: \(self.activePlayer == .playerA ? "B→A" : "A→B") (\(String(format: "%.1f", totalDuration))s)")

        // Prepare new node
        newNode.stop()
        newNode.reset()
        newNode.volume = 0.0
        newNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
        newNode.play()

        // Schedule next crossfade IMMEDIATELY (before crossfade completes)
        // This ensures timing is relative to when playback STARTED, not when fade finishes
        let crossfadeStartTime = max(0, totalDuration - self.loopCrossfadeDuration)
        self.scheduleLoopCrossfade(after: crossfadeStartTime, audioFile: audioFile, url: url)

        // Crossfade - respect current playback volume
        self.fadeVolume(node: oldNode, from: self.playbackVolume, to: 0.0, duration: self.loopCrossfadeDuration) {
            oldNode.stop()
            oldNode.reset()
        }

        self.fadeVolume(node: newNode, from: 0.0, to: self.playbackVolume, duration: self.loopCrossfadeDuration) { [weak self] in
            guard let self = self else { return }
            // Update current player reference and reset flag
            self.currentPlayerNode = newNode
            self.isLoopCrossfadeActive = false
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
        // Log to file for debugging
        FileLogger.shared.log(message)

        // Send to JavaScript if callback is available
        if let callback = self.logCallback {
            DispatchQueue.main.async {
                callback(message)
            }
        } else {
            // Fallback: if no JS callback, log to native console
            NSLog("%@", message)
        }
    }

    public func writeDebugLog(message: String) throws {
        FileLogger.shared.log(message)
    }

    public func getDebugLogPath() throws -> String {
        return FileLogger.shared.getCurrentLogPath() ?? ""
    }

    public func getAllDebugLogPaths() throws -> [String] {
        return FileLogger.shared.getAllLogPaths()
    }

    public func readDebugLog(path: String?) throws -> String {
        if let path = path {
            return FileLogger.shared.readLog(at: path) ?? ""
        } else {
            return FileLogger.shared.readCurrentLog() ?? ""
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

            // Create recognition request
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false

            // Start recognition task
            recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    promise.resolve(withResult: "No Speech Detected")
                    return
                }

                if let result = result, result.isFinal {
                    let transcription = result.bestTranscription.formattedString
                    if transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
    public func crossfadeTo(uri: String, duration: Double? = 3.0, targetVolume: Double? = 1.0) throws -> Promise<String> {
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
                let finalVolume = Float(targetVolume ?? 1.0)

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

                // Schedule seamless loop timer immediately (synchronized with playback start)
                // This must happen BEFORE crossfade completes, so timer is synchronized with actual playback
                if self.shouldLoopPlayback {
                    let totalDuration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
                    let crossfadeStartTime = max(0, totalDuration - self.loopCrossfadeDuration)
                    self.scheduleLoopCrossfade(after: crossfadeStartTime, audioFile: audioFile, url: url)
                }

                // Start fading
                if let currentNode = self.currentPlayerNode {
                    self.fadeVolume(node: currentNode, from: currentNode.volume, to: 0.0, duration: fadeDuration) {
                        // Stop old node when fade out completes
                        currentNode.stop()
                        currentNode.volume = 0.0  // Ensure volume stays at 0
                    }
                }

                // BUGFIX: Update playbackVolume to match target for subsequent loop iterations
                self.playbackVolume = finalVolume

                self.fadeVolume(node: newNode, from: 0.0, to: finalVolume, duration: fadeDuration) {
                    // Swap references after new node fades in
                    self.currentPlayerNode = newNode
                    self.activePlayer = (newNode == self.audioPlayerNodeA) ? .playerA : .playerB

                    // Note: Seamless loop timer is already scheduled above (right after play())
                    // to ensure it's synchronized with playback start time, not crossfade completion
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

        var currentStep = 0
        node.volume = startVolume

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: stepDuration)

        timer.setEventHandler {
            guard node.engine != nil else {
                timer.cancel()
                return
            }

            // Calculate progress (0.0 to 1.0)
            let progress = Float(currentStep) / Float(steps)

            // Equal-power crossfade curve
            let newVolume: Float
            if startVolume > targetVolume {
                // Fading out: sqrt(1 - progress) * startVolume
                newVolume = sqrt(1.0 - progress) * startVolume
            } else {
                // Fading in: sqrt(progress) * targetVolume
                newVolume = sqrt(progress) * targetVolume
            }

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
