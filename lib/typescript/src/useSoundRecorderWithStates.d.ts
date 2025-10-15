import { useSoundRecorder } from './useSoundRecorder';
import type { UseSoundRecorderOptions } from './useSoundRecorder';
export type UseSoundRecorderState = {
    isRecording: boolean;
    currentPosition: number;
};
export type UseSoundRecorderWithStates = ReturnType<typeof useSoundRecorder> & {
    state: UseSoundRecorderState;
};
export declare function useSoundRecorderWithStates(options?: UseSoundRecorderOptions): UseSoundRecorderWithStates;
export { useSoundRecorderWithStates as useAudioRecorderWithStates };
//# sourceMappingURL=useSoundRecorderWithStates.d.ts.map