"use strict";

import { useCallback, useEffect, useMemo, useRef } from 'react';
import { ensureSoundActivation } from "./utils/sound.js";
export function useSoundRecorder(options = {}) {
  const {
    subscriptionDuration,
    autoDispose = true
  } = options;
  const soundRef = useRef(null);

  // Configure subscription duration
  useEffect(() => {
    if (subscriptionDuration != null) {
      ensureSoundActivation(soundRef).setSubscriptionDuration(subscriptionDuration);
    }
  }, [subscriptionDuration]);

  // Wire native record listener to user callback
  useEffect(() => {
    const sound = ensureSoundActivation(soundRef);
    const onRecord = e => {
      options.onRecord?.({
        ...e,
        ended: e.isRecording === false
      });
    };
    sound.addRecordBackListener(onRecord);
    return () => {
      try {
        sound.removeRecordBackListener();
      } catch {}
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Controls
  const startRecorder = useCallback(async (...args) => ensureSoundActivation(soundRef).startRecorder(...args), []);
  const pauseRecorder = useCallback(async () => ensureSoundActivation(soundRef).pauseRecorder(), []);
  const resumeRecorder = useCallback(async () => ensureSoundActivation(soundRef).resumeRecorder(), []);
  const stopRecorder = useCallback(async () => {
    const res = await ensureSoundActivation(soundRef).stopRecorder();
    options.onRecord?.({
      isRecording: false,
      currentPosition: 0,
      recordSecs: 0,
      ended: true
    });
    return res;
  }, [options]);
  const mmss = useCallback(secs => ensureSoundActivation(soundRef).mmss(secs), []);
  const mmssss = useCallback(ms => ensureSoundActivation(soundRef).mmssss(ms), []);
  const dispose = useCallback(() => {
    try {
      soundRef.current?.dispose();
    } catch {}
    soundRef.current = null;
  }, []);
  useEffect(() => {
    return () => {
      if (autoDispose) dispose();
    };
  }, [autoDispose, dispose]);
  return useMemo(() => ({
    sound: ensureSoundActivation(soundRef),
    startRecorder,
    pauseRecorder,
    resumeRecorder,
    stopRecorder,
    mmss,
    mmssss,
    dispose
  }), [startRecorder, pauseRecorder, resumeRecorder, stopRecorder, mmss, mmssss, dispose]);
}

// Alias with alternative naming preference
export { useSoundRecorder as useAudioRecorder };
//# sourceMappingURL=useSoundRecorder.js.map