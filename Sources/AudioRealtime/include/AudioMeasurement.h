#ifndef DAMPER_AUDIO_MEASUREMENT_H
#define DAMPER_AUDIO_MEASUREMENT_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct AudioMeasurement AudioMeasurement;

/// Measures signal level for the opt-in audio check, and keeps no audio. Only one callback at a
/// time may use a context. Stop and destroy that IOProc before reading results or destroying it.
AudioMeasurement * _Nullable AudioMeasurementCreate(void);
void AudioMeasurementDestroy(AudioMeasurement * _Nullable state);

/// Float32 mono, interleaved stereo or planar stereo only. Malformed/nonfinite
/// input permanently invalidates the measurement and clears its accumulated totals.
void AudioMeasurementProcess(AudioMeasurement * _Nullable state,
                               const AudioBufferList * _Nullable input);
/// Returns zero for invalid, absent or empty measurements; inspect Valid and count.
double AudioMeasurementRMS(const AudioMeasurement * _Nullable state);
uint64_t AudioMeasurementSampleCount(const AudioMeasurement * _Nullable state);
bool AudioMeasurementValid(const AudioMeasurement * _Nullable state);

/// Read-only diagnostic tap callback. Clears bounded, valid output buffers, never
/// plays input, allocates, logs, locks, or invokes Swift/Objective-C.
OSStatus AudioMeasurementIOProc(AudioObjectID device,
                                 const AudioTimeStamp * _Nonnull now,
                                 const AudioBufferList * _Nonnull input,
                                 const AudioTimeStamp * _Nonnull inputTime,
                                 AudioBufferList * _Nonnull output,
                                 const AudioTimeStamp * _Nonnull outputTime,
                                 void * _Nullable context);

#endif
