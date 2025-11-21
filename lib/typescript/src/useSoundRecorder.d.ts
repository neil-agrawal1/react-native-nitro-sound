import type { Sound as SoundType, RecordBackType } from './specs/Sound.nitro';
export type UseSoundRecorderOptions = {
    subscriptionDuration?: number;
    autoDispose?: boolean;
    onRecord?: (e: RecordBackType & {
        ended?: boolean;
    }) => void;
};
export type UseSoundRecorder = {
    sound: SoundType;
    startRecorder: SoundType['startRecorder'];
    pauseRecorder: SoundType['pauseRecorder'];
    resumeRecorder: SoundType['resumeRecorder'];
    stopRecorder: SoundType['stopRecorder'];
    mmss: SoundType['mmss'];
    mmssss: SoundType['mmssss'];
    dispose: () => void;
};
export declare function useSoundRecorder(options?: UseSoundRecorderOptions): UseSoundRecorder;
export { useSoundRecorder as useAudioRecorder };
//# sourceMappingURL=useSoundRecorder.d.ts.map