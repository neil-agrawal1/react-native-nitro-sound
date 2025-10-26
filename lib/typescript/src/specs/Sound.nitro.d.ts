import type { HybridObject } from 'react-native-nitro-modules';
export declare enum AudioSourceAndroidType {
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
    HOTWORD = 1999
}
export declare enum OutputFormatAndroidType {
    DEFAULT = 0,
    THREE_GPP = 1,
    MPEG_4 = 2,
    AMR_NB = 3,
    AMR_WB = 4,
    AAC_ADIF = 5,
    AAC_ADTS = 6,
    OUTPUT_FORMAT_RTP_AVP = 7,
    MPEG_2_TS = 8,
    WEBM = 9
}
export declare enum AudioEncoderAndroidType {
    DEFAULT = 0,
    AMR_NB = 1,
    AMR_WB = 2,
    AAC = 3,
    HE_AAC = 4,
    AAC_ELD = 5,
    VORBIS = 6
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
export interface Sound extends HybridObject<{
    ios: 'swift';
    android: 'kotlin';
}> {
    startRecorder(): Promise<void>;
    stopRecorder(): Promise<void>;
    setVADMode(): Promise<void>;
    setManualMode(): Promise<void>;
    setIdleMode(): Promise<void>;
    startManualSegment(silenceTimeoutSeconds?: number): Promise<void>;
    stopManualSegment(): Promise<void>;
    setVADThreshold(threshold: number): Promise<void>;
    pauseRecorder(): Promise<string>;
    resumeRecorder(): Promise<string>;
    startPlayer(uri?: string, httpHeaders?: Record<string, string>): Promise<string>;
    stopPlayer(): Promise<string>;
    pausePlayer(): Promise<string>;
    resumePlayer(): Promise<string>;
    seekToPlayer(time: number): Promise<string>;
    setVolume(volume: number): Promise<string>;
    setPlaybackSpeed(playbackSpeed: number): Promise<string>;
    getCurrentPosition(): Promise<number>;
    getDuration(): Promise<number>;
    setLoopEnabled(enabled: boolean): Promise<string>;
    restartEngine(): Promise<void>;
    crossfadeTo(uri: string, duration?: number): Promise<string>;
    startAmbientLoop(uri: string, volume: number): Promise<void>;
    stopAmbientLoop(fadeDuration?: number): Promise<void>;
    setSubscriptionDuration(sec: number): void;
    addRecordBackListener(callback: (recordingMeta: RecordBackType) => void): void;
    removeRecordBackListener(): void;
    addPlayBackListener(callback: (playbackMeta: PlayBackType) => void): void;
    removePlayBackListener(): void;
    addPlaybackEndListener(callback: (playbackEndMeta: PlaybackEndType) => void): void;
    removePlaybackEndListener(): void;
    setLogCallback(callback: (message: string) => void): void;
    setSegmentCallback(callback: (filename: string, filePath: string, isManual: boolean, duration: number) => void): void;
    setManualSilenceCallback(callback: () => void): void;
    writeDebugLog(message: string): void;
    getDebugLogPath(): string | null;
    getAllDebugLogPaths(): string[];
    readDebugLog(path?: string): string | null;
    clearDebugLogs(): Promise<void>;
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
//# sourceMappingURL=Sound.nitro.d.ts.map