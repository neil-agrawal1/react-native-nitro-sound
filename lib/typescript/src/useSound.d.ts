import type { Sound as SoundType, PlayBackType, RecordBackType } from './specs/Sound.nitro';
export type UseSoundOptions = {
    subscriptionDuration?: number;
    autoDispose?: boolean;
    onRecord?: (e: RecordBackType & {
        ended?: boolean;
    }) => void;
    onPlayback?: (e: PlayBackType & {
        ended?: boolean;
    }) => void;
    onPlaybackEnd?: (e: {
        duration: number;
        currentPosition: number;
    }) => void;
};
export type UseSoundState = {
    isRecording: boolean;
    isPlaying: boolean;
    duration: number;
    currentPosition: number;
};
export type UseSound = {
    sound: SoundType;
    state: UseSoundState;
    startRecorder: SoundType['startRecorder'];
    pauseRecorder: SoundType['pauseRecorder'];
    resumeRecorder: SoundType['resumeRecorder'];
    stopRecorder: SoundType['stopRecorder'];
    startPlayer: SoundType['startPlayer'];
    pausePlayer: SoundType['pausePlayer'];
    resumePlayer: SoundType['resumePlayer'];
    stopPlayer: SoundType['stopPlayer'];
    seekToPlayer: SoundType['seekToPlayer'];
    setVolume: SoundType['setVolume'];
    setPlaybackSpeed: SoundType['setPlaybackSpeed'];
    mmss: SoundType['mmss'];
    mmssss: SoundType['mmssss'];
    dispose: () => void;
};
export declare function useSound(options?: UseSoundOptions): UseSound;
//# sourceMappingURL=useSound.d.ts.map