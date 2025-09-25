// Re-export the default instance and types from the main implementation
export * from './index';               // the real RN entry (index.tsx)
export * from './src/specs/Sound.nitro'; 
//   // types from the spec// Re-export types from the nitro module
export type {
  AudioSet,
  RecordBackType,
  PlayBackType,
  AVEncodingOption,
  AVModeIOSOption,
} from './src/specs/Sound.nitro';

export {
  AudioSourceAndroidType,
  OutputFormatAndroidType,
  AudioEncoderAndroidType,
  AVEncoderAudioQualityIOSType,
  AVLinearPCMBitDepthKeyIOSType,
} from './src/specs/Sound.nitro';
