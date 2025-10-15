"use strict";

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ensureSoundActivation } from "./utils/sound.js";
export function useSound(options = {}) {
  const {
    subscriptionDuration,
    autoDispose = true
  } = options;
  const soundRef = useRef(null);
  const [state, setState] = useState({
    isRecording: false,
    isPlaying: false,
    duration: 0,
    currentPosition: 0
  });

  // Configure subscription duration
  useEffect(() => {
    if (subscriptionDuration != null) {
      ensureSoundActivation(soundRef).setSubscriptionDuration(subscriptionDuration);
    }
  }, [subscriptionDuration]);

  // Attach listeners: forward native events to user callbacks instead of updating React state
  useEffect(() => {
    const sound = ensureSoundActivation(soundRef);
    const lastRecordRef = {
      current: null
    };
    const lastPlaybackRef = {
      current: null
    };
    const onRecord = e => {
      lastRecordRef.current = e;
      options.onRecord?.({
        ...e,
        ended: e.isRecording === false
      });
    };
    const onPlay = e => {
      lastPlaybackRef.current = e;
      const ended = e.duration > 0 && e.currentPosition >= e.duration;
      options.onPlayback?.({
        ...e,
        ended
      });
      // Only flip coarse flag locally to reflect play/pause status without spamming renders
      if (ended && state.isPlaying) {
        setState(s => ({
          ...s,
          isPlaying: false
        }));
      }
    };
    const onPlayEnd = e => {
      options.onPlayback?.({
        duration: e.duration,
        currentPosition: e.currentPosition,
        ended: true
      });
      options.onPlaybackEnd?.(e);
      setState(s => ({
        ...s,
        isPlaying: false
      }));
    };
    sound.addRecordBackListener(onRecord);
    sound.addPlayBackListener(onPlay);
    sound.addPlaybackEndListener(onPlayEnd);
    return () => {
      sound.removeRecordBackListener();
      sound.removePlayBackListener();
      sound.removePlaybackEndListener();
    };
    // Intentionally do not include options in deps to avoid re-subscribing per render
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Controls (wrap to update local state eagerly when appropriate)
  const startRecorder = useCallback(async (...args) => {
    const res = await ensureSoundActivation(soundRef).startRecorder(...args);
    setState(s => ({
      ...s,
      isRecording: true
    }));
    return res;
  }, []);
  const pauseRecorder = useCallback(async () => {
    const res = await ensureSoundActivation(soundRef).pauseRecorder();
    setState(s => ({
      ...s,
      isRecording: false
    }));
    return res;
  }, []);
  const resumeRecorder = useCallback(async () => {
    const res = await ensureSoundActivation(soundRef).resumeRecorder();
    setState(s => ({
      ...s,
      isRecording: true
    }));
    return res;
  }, []);
  const stopRecorder = useCallback(async () => {
    const res = await ensureSoundActivation(soundRef).stopRecorder();
    setState(s => ({
      ...s,
      isRecording: false
    }));
    // Inform consumer that recording ended
    options.onRecord?.({
      isRecording: false,
      currentPosition: 0,
      recordSecs: 0,
      ended: true
    });
    return res;
  }, [options]);
  const startPlayer = useCallback(async (...args) => {
    const res = await ensureSoundActivation(soundRef).startPlayer(...args);
    setState(s => ({
      ...s,
      isPlaying: true
    }));
    return res;
  }, []);
  const pausePlayer = useCallback(async () => {
    const res = await ensureSoundActivation(soundRef).pausePlayer();
    setState(s => ({
      ...s,
      isPlaying: false
    }));
    return res;
  }, []);
  const resumePlayer = useCallback(async () => {
    const res = await ensureSoundActivation(soundRef).resumePlayer();
    setState(s => ({
      ...s,
      isPlaying: true
    }));
    return res;
  }, []);
  const stopPlayer = useCallback(async () => {
    const res = await ensureSoundActivation(soundRef).stopPlayer();
    setState(s => ({
      ...s,
      isPlaying: false,
      currentPosition: 0
    }));
    return res;
  }, []);
  const seekToPlayer = useCallback(async time => {
    const res = await ensureSoundActivation(soundRef).seekToPlayer(time);
    setState(s => ({
      ...s,
      currentPosition: time
    }));
    return res;
  }, []);
  const setVolume = useCallback(async v => {
    return ensureSoundActivation(soundRef).setVolume(v);
  }, []);
  const setPlaybackSpeed = useCallback(async sp => {
    return ensureSoundActivation(soundRef).setPlaybackSpeed(sp);
  }, []);
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
    state,
    startRecorder,
    pauseRecorder,
    resumeRecorder,
    stopRecorder,
    startPlayer,
    pausePlayer,
    resumePlayer,
    stopPlayer,
    seekToPlayer,
    setVolume,
    setPlaybackSpeed,
    mmss,
    mmssss,
    dispose
  }), [state, startRecorder, pauseRecorder, resumeRecorder, stopRecorder, startPlayer, pausePlayer, resumePlayer, stopPlayer, seekToPlayer, setVolume, setPlaybackSpeed, mmss, mmssss, dispose]);
}
//# sourceMappingURL=useSound.js.map