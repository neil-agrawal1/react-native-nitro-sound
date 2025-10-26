"use strict";

import { useMemo, useState } from 'react';
import { useSoundRecorder } from "./useSoundRecorder.js";
export function useSoundRecorderWithStates(options = {}) {
  const [state, setState] = useState({
    isRecording: false,
    currentPosition: 0
  });
  const base = useSoundRecorder({
    ...options,
    onRecord: e => {
      options.onRecord?.(e);
      setState(s => ({
        ...s,
        isRecording: e.isRecording ?? true,
        currentPosition: e.currentPosition ?? s.currentPosition
      }));
      if (e.ended) {
        setState(s => ({
          ...s,
          isRecording: false
        }));
      }
    }
  });
  return useMemo(() => ({
    ...base,
    state
  }), [base, state]);
}

// Alias
export { useSoundRecorderWithStates as useAudioRecorderWithStates };
//# sourceMappingURL=useSoundRecorderWithStates.js.map