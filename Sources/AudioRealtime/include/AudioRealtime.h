#ifndef DAMPER_AUDIO_REALTIME_H
#define DAMPER_AUDIO_REALTIME_H
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>
#include "AudioMeasurement.h"

/// Immutable buffer mapping. Each channel points at a buffer and an offset within its frame.
/// All buffers in one direction must have the supplied stride (1 planar, 1/2 interleaved).
typedef struct {
    uint32_t inputBuffer[2];
    uint32_t inputChannel[2];
    uint32_t outputBuffer[2];
    uint32_t outputChannel[2];
    uint32_t inputStride;
    uint32_t outputStride;
    uint32_t channels;
    uint32_t inputBufferCount;
    uint32_t outputBufferCount;
} AudioRealtimeLayout;

typedef struct AudioRealtimeState AudioRealtimeState;
/// Control-plane functions; destroy only after IOProc is destroyed.
AudioRealtimeState * _Nullable AudioRealtimeCreate(AudioRealtimeLayout layout, float initialGain, uint32_t rampFrames);
void AudioRealtimeDestroy(AudioRealtimeState * _Nullable state);
void AudioRealtimeSetGain(AudioRealtimeState * _Nullable state, float gain);
bool AudioRealtimeHasRendered(const AudioRealtimeState * _Nullable state);
bool AudioRealtimeHasFault(const AudioRealtimeState * _Nullable state);
/// Install before starting IO. FD must be a nonblocking pipe; first fault writes one byte.
void AudioRealtimeSetFaultFileDescriptor(AudioRealtimeState * _Nullable state, int descriptor);
/// Direct DSP entry point for tests. Callback uses the same function. Outputs are cleared first.
bool AudioRealtimeProcess(AudioRealtimeState * _Nullable state, const AudioBufferList * _Nullable input, AudioBufferList * _Nullable output);
OSStatus AudioRealtimeIOProc(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
                         const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
                         AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime, void * _Nullable context);
typedef struct AudioAccessProbeState AudioAccessProbeState;
AudioAccessProbeState * _Nullable AudioAccessProbeCreate(void);
void AudioAccessProbeDestroy(AudioAccessProbeState * _Nullable state);
bool AudioAccessProbeObservedSignal(const AudioAccessProbeState * _Nullable state);
/// Install before starting IO; keep the nonblocking pipe open until IOProc removal.
/// The first finite nonzero sample attempts one byte once. Defaults to no descriptor.
void AudioAccessProbeSetSignalFileDescriptor(AudioAccessProbeState * _Nullable state, int descriptor);
/// Permission probe: zeroes output and reports the first finite nonzero input sample; retains no audio and never renders it.
OSStatus AudioAccessProbeIOProc(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
                            const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
                            AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime, void * _Nullable context);
/// Control-plane helper. Sets every stream explicitly and reads back the setting.
OSStatus AudioRealtimeConfigureStreams(AudioObjectID device, AudioDeviceIOProcID _Nullable proc,
                                   AudioObjectPropertyScope scope, uint32_t streamCount,
                                   const uint32_t * _Nonnull enabled);
#endif
