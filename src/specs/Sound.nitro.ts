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

export interface Sound
  extends HybridObject<{ ios: 'swift'; android: 'kotlin' }> {
  // Recording methods (unified AVAudioEngine with speech detection)
  startRecorder(): Promise<void>;
  stopRecorder(): Promise<void>;

  // Segment mode control (for alarm-based manual recording)
  startManualSegment(): Promise<void>;
  stopManualSegment(): Promise<void>;

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

  // Loop control methods
  setLoopEnabled(enabled: boolean): Promise<string>;

  // Engine management
  restartEngine(): Promise<void>;

  // Crossfade methods
  crossfadeTo(uri: string, duration?: number): Promise<string>;

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
  setSegmentCallback(callback: (filename: string, filePath: string, isManual: boolean) => void): void;

  // Utility methods
  mmss(secs: number): string;
  mmssss(milisecs: number): string;
}
