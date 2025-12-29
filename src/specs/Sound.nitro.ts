import type { HybridObject } from 'react-native-nitro-modules';

// Enums
export enum AudioSourceAndroidType {
  DEFAULT = 0,
  MIC = 1,
  VOICE_UPLINK = 2,
  VOICE_DOWNLINK = 3,
  VOICE_CALL = 4,
  CAMCORDER = 5,
  VOICE_RECOGNITION = 6,
  VOICE_COMMUNICATION = 7,
  REMOTE_SUBMIX = 8,
  UNPROCESSED = 9,
  RADIO_TUNER = 1998,
  HOTWORD = 1999,
}

export enum OutputFormatAndroidType {
  DEFAULT = 0,
  THREE_GPP = 1,
  MPEG_4 = 2,
  AMR_NB = 3,
  AMR_WB = 4,
  AAC_ADIF = 5,
  AAC_ADTS = 6,
  OUTPUT_FORMAT_RTP_AVP = 7,
  MPEG_2_TS = 8,
  WEBM = 9,
}

export enum AudioEncoderAndroidType {
  DEFAULT = 0,
  AMR_NB = 1,
  AMR_WB = 2,
  AAC = 3,
  HE_AAC = 4,
  AAC_ELD = 5,
  VORBIS = 6,
}


export interface RecordBackType {
  isRecording?: boolean;
  currentPosition: number;
  currentMetering?: number;
  recordSecs?: number;
}

export interface PlayBackType {
  isMuted?: boolean;
  duration: number;
  currentPosition: number;
}

export interface PlaybackEndType {
  duration: number;
  currentPosition: number;
}

export type RecordBackListener = (recordingMeta: RecordBackType) => void;
export type PlayBackListener = (playbackMeta: PlayBackType) => void;
export type PlaybackEndListener = (playbackEndMeta: PlaybackEndType) => void;

// Recording mode type (for getCurrentMode)
export type RecordingMode = 'idle' | 'manual' | 'vad';

export interface Sound
  extends HybridObject<{ ios: 'swift'; android: 'kotlin' }> {
  // Recording methods (unified AVAudioEngine with speech detection)
  startRecorder(): Promise<void>;
  stopRecorder(): Promise<void>;

  /**
   * End the engine session and completely destroy all audio resources.
   * This performs a full teardown:
   * - Ends any active recording segments
   * - Stops all playback
   * - Stops the audio engine
   * - Deactivates the audio session (removes microphone indicator)
   * - Destroys the engine instance (forces clean re-initialization)
   *
   * Call this when stopping a sleep session to ensure the microphone
   * indicator disappears and all audio resources are released.
   */
  endEngineSession(): Promise<void>;

  /**
   * Initialize audio engine in playback-only mode (no microphone access).
   * Used for standalone alarm mode when no session is running.
   *
   * IMPORTANT: This uses .playback category instead of .playAndRecord,
   * so NO microphone indicator will be shown.
   *
   * Use endPlaybackOnlySession() to teardown - NOT endEngineSession()
   * which would crash trying to access inputNode.
   */
  initializePlaybackOnly(): Promise<void>;

  /**
   * End playback-only session - safe teardown without inputNode access.
   *
   * Use this to teardown after initializePlaybackOnly(). If you used
   * startRecorder() (with .playAndRecord), use endEngineSession() instead.
   */
  endPlaybackOnlySession(): Promise<void>;

  // Segment mode control (for alarm-based manual recording)
  setVADMode(): Promise<void>;
  setManualMode(): Promise<void>;
  setIdleMode(): Promise<void>;
  getCurrentMode(): Promise<RecordingMode>;

  /**
   * Check if a recording segment is actively being recorded.
   * This is the SOURCE OF TRUTH for recording state - checks if:
   * 1. A segment file is open (currentSegmentFile != nil)
   * 2. We're in a recording mode (manual or VAD, not idle)
   * 3. The audio engine is running with an active input tap
   *
   * Use this for UI indicators that need to show actual recording status.
   * Unlike JS-side segmentActive which can become stale, this queries native directly.
   *
   * @returns true if actively recording a segment, false otherwise
   */
  isSegmentRecording(): Promise<boolean>;

  // Manual segment control (separate from mode setting)
  startManualSegment(silenceTimeoutSeconds?: number): Promise<void>;
  stopManualSegment(): Promise<void>;

  // VAD configuration
  setVADThreshold(threshold: number): Promise<void>;

  // Legacy methods (stubs for backwards compatibility)
  pauseRecorder(): Promise<string>;
  resumeRecorder(): Promise<string>;

  // Playback methods
  startPlayer(
    uri?: string,
    httpHeaders?: Record<string, string>
  ): Promise<string>;
  stopPlayer(): Promise<string>;
  pausePlayer(): Promise<string>;
  resumePlayer(): Promise<string>;
  seekToPlayer(time: number): Promise<string>;
  setVolume(volume: number): Promise<string>;
  setPlaybackSpeed(playbackSpeed: number): Promise<string>;

  // Now Playing (lock screen controls)
  /**
   * Update Now Playing info on lock screen
   * @param title Track title to display
   * @param artist Artist name (optional)
   * @param duration Total duration in seconds
   * @param currentTime Current playback position in seconds
   */
  updateNowPlaying(
    title: string,
    artist: string,
    duration: number,
    currentTime: number
  ): Promise<void>;

  /**
   * Clear Now Playing info from lock screen
   */
  clearNowPlaying(): Promise<void>;

  /**
   * Set artwork for Now Playing lock screen display
   * @param imagePath Path to the image file (local file path)
   */
  setNowPlayingArtwork(imagePath: string): Promise<void>;

  // Position/duration query methods (milliseconds)
  getCurrentPosition(): Promise<number>;
  getDuration(): Promise<number>;

  // Loop control methods
  setLoopEnabled(enabled: boolean): Promise<string>;

  // Engine management
  restartEngine(): Promise<void>;

  // Crossfade methods
  crossfadeTo(uri: string, duration?: number, targetVolume?: number): Promise<string>;

  // Volume fade (smooth native fade using equal-power curve)
  fadeVolumeTo(targetVolume: number, duration: number): Promise<void>;

  // Ambient loop methods
  startAmbientLoop(uri: string, volume: number): Promise<void>;
  stopAmbientLoop(fadeDuration?: number): Promise<void>;

  // Subscription
  setSubscriptionDuration(sec: number): void;

  // Listeners
  addRecordBackListener(
    callback: (recordingMeta: RecordBackType) => void
  ): void;
  removeRecordBackListener(): void;
  addPlayBackListener(callback: (playbackMeta: PlayBackType) => void): void;
  removePlayBackListener(): void;
  addPlaybackEndListener(
    callback: (playbackEndMeta: PlaybackEndType) => void
  ): void;
  removePlaybackEndListener(): void;

  // Logging methods
  setLogCallback(callback: (message: string) => void): void;

  // Speech segment callback (called when a new segment file is written)
  setSegmentCallback(callback: (filename: string, filePath: string, isManual: boolean, duration: number) => void): void;

  // Manual silence timeout callback (called when 15s of silence detected in manual mode)
  setManualSilenceCallback(callback: () => void): void;

  // Lock screen track navigation callbacks
  setNextTrackCallback(callback: () => void): void;
  removeNextTrackCallback(): void;
  setPreviousTrackCallback(callback: () => void): void;
  removePreviousTrackCallback(): void;

  // Lock screen pause/play callbacks (to sync UI with lock screen controls)
  setPauseCallback(callback: () => void): void;
  removePauseCallback(): void;
  setPlayCallback(callback: () => void): void;
  removePlayCallback(): void;

  /**
   * Completely tear down remote command center - removes all targets and clears Now Playing.
   * Widget will disappear as if it was never configured.
   * Call this when transitioning to night phase to hide lock screen controls.
   */
  teardownRemoteCommands(): Promise<void>;

  // Debug logging methods
  writeDebugLog(message: string): void;
  getDebugLogPath(): string;
  getAllDebugLogPaths(): string[];
  readDebugLog(path?: string): string;
  clearDebugLogs(): Promise<void>;
  setDebugLogUserIdentifier(identifier: string): void;

  // Utility methods
  mmss(secs: number): string;
  mmssss(milisecs: number): string;

  /**
   * Transcribe an audio file to text using iOS Speech Recognition
   * @param filePath Path to audio file (with or without file:// prefix)
   * @returns Promise resolving to transcribed text
   * @throws Error if file not found or speech recognition unavailable
   */
  transcribeAudioFile(filePath: string): Promise<string>;
}
