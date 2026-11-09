#include "AudioRealtime.h"
#include "TapBufferValidation.h"
#include <stdatomic.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include <limits.h>
#include <unistd.h>

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Real-time gain and flags must be lock-free");
struct AudioRealtimeState {
    AudioRealtimeLayout layout;
    _Atomic(uint32_t) targetBits;
    _Atomic(uint32_t) rendered;
    _Atomic(uint32_t) fault;
    float current, destination, step;
    uint32_t rampFrames, remaining;
    int faultFD;
};
static float safeGain(float gain) { return isfinite(gain) ? fminf(1, fmaxf(0, gain)) : 0; }
static uint32_t bits(float f) { uint32_t b; memcpy(&b, &f, sizeof b); return b; }
static float fromBits(uint32_t b) { float f; memcpy(&f, &b, sizeof f); return f; }
static bool validLayout(AudioRealtimeLayout l) {
    if (l.channels < 1 || l.channels > 2 || l.inputStride < 1 || l.inputStride > 2 ||
        l.outputStride < 1 || l.outputStride > 2 || l.inputBufferCount < 1 ||
        l.inputBufferCount > 2 || l.outputBufferCount < 1 || l.outputBufferCount > 2) return false;
    for (uint32_t c = 0; c < l.channels; ++c) {
        if (l.inputBuffer[c] >= l.inputBufferCount || l.outputBuffer[c] >= l.outputBufferCount ||
            l.inputChannel[c] >= l.inputStride || l.outputChannel[c] >= l.outputStride) return false;
        if (c && l.outputBuffer[c] == l.outputBuffer[0] && l.outputChannel[c] == l.outputChannel[0]) return false;
    }
    return true;
}
AudioRealtimeState *AudioRealtimeCreate(AudioRealtimeLayout layout, float initialGain, uint32_t rampFrames) {
    if (!validLayout(layout)) return NULL;
    AudioRealtimeState *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    s->layout = layout;
    s->faultFD = -1;
    s->current = s->destination = safeGain(initialGain);
    s->rampFrames = rampFrames;
    atomic_init(&s->targetBits, bits(s->current));
    atomic_init(&s->rendered, 0);
    atomic_init(&s->fault, 0);
    return s;
}
void AudioRealtimeDestroy(AudioRealtimeState *s) { free(s); }
void AudioRealtimeSetGain(AudioRealtimeState *s, float gain) {
    if (s) atomic_store_explicit(&s->targetBits, bits(safeGain(gain)), memory_order_relaxed);
}
bool AudioRealtimeHasRendered(const AudioRealtimeState *s) {
    return s && atomic_load_explicit(&s->rendered, memory_order_relaxed) != 0;
}
bool AudioRealtimeHasFault(const AudioRealtimeState *s) {
    return s && atomic_load_explicit(&s->fault, memory_order_relaxed) != 0;
}
void AudioRealtimeSetFaultFileDescriptor(AudioRealtimeState *s, int fd) { if (s) s->faultFD = fd; }
static void clearOutput(AudioBufferList *out) {
    if (!out) return;
    for (uint32_t b = 0; b < out->mNumberBuffers; ++b)
        if (out->mBuffers[b].mData) memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);
}
bool AudioRealtimeProcess(AudioRealtimeState *s, const AudioBufferList *in, AudioBufferList *out) {
    clearOutput(out);
    if (!s) return false;
    AudioRealtimeLayout l = s->layout;
    if (!in || !out || in->mNumberBuffers != l.inputBufferCount || out->mNumberBuffers != l.outputBufferCount)
        goto invalid;
    uint32_t frames = UINT_MAX;
    const float *src[2]; float *dst[2];
    for (uint32_t c = 0; c < l.channels; ++c) {
        const AudioBuffer *a = &in->mBuffers[l.inputBuffer[c]];
        AudioBuffer *b = &out->mBuffers[l.outputBuffer[c]];
        if (a->mNumberChannels != l.inputStride || b->mNumberChannels != l.outputStride ||
            a->mDataByteSize % (sizeof(float) * l.inputStride) ||
            b->mDataByteSize % (sizeof(float) * l.outputStride)) goto invalid;
        // Disabled/temporarily empty input streams produce silence, not stale audio.
        if (!a->mData || !b->mData || (!a->mDataByteSize && b->mDataByteSize)) return false;
        uint32_t n = a->mDataByteSize / (sizeof(float) * l.inputStride);
        uint32_t m = b->mDataByteSize / (sizeof(float) * l.outputStride);
        if (n != m || (frames != UINT_MAX && n != frames)) goto invalid;
        frames = n;
        src[c] = (const float *)a->mData + l.inputChannel[c];
        dst[c] = (float *)b->mData + l.outputChannel[c];
    }
    float target = fromBits(atomic_load_explicit(&s->targetBits, memory_order_relaxed));
    if (target != s->destination) {
        s->destination = target;
        s->remaining = s->rampFrames;
        s->step = s->remaining ? (target - s->current) / s->remaining : 0;
        if (!s->remaining) s->current = target;
    }
    for (uint32_t f = 0; f < frames; ++f) {
        if (s->remaining) {
            // Rounding must not carry a ramp past its destination.
            s->current = s->step > 0 ? fminf(s->current + s->step, s->destination)
                                     : fmaxf(s->current + s->step, s->destination);
            if (!--s->remaining) s->current = s->destination;
        }
        float gain = s->current;
        for (uint32_t c = 0; c < l.channels; ++c) {
            float v = src[c][f * l.inputStride];
            // Never propagate NaN, infinity, or out-of-range PCM into the hardware.
            dst[c][f * l.outputStride] = isfinite(v) ? fminf(1, fmaxf(-1, v)) * gain : 0;
        }
    }
    if (frames) atomic_store_explicit(&s->rendered, 1, memory_order_relaxed);
    return true;
invalid:
    if (!atomic_exchange_explicit(&s->fault, 1, memory_order_relaxed) && s->faultFD >= 0) {
        // A one-shot, nonblocking wakeup. No dispatch/Swift runtime on the audio thread.
        const char byte = 1;
        (void)write(s->faultFD, &byte, 1);
    }
    return false;
}
OSStatus AudioRealtimeIOProc(AudioObjectID device, const AudioTimeStamp *now,
                         const AudioBufferList *input, const AudioTimeStamp *inputTime,
                         AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    AudioRealtimeProcess(context, input, output);
    return noErr;
}
struct AudioAccessProbeState {
    _Atomic(uint32_t) observedSignal;
    int signalFD;
};
AudioAccessProbeState *AudioAccessProbeCreate(void) {
    AudioAccessProbeState *s = calloc(1, sizeof *s);
    if (s) {
        atomic_init(&s->observedSignal, 0);
        s->signalFD = -1;
    }
    return s;
}
void AudioAccessProbeDestroy(AudioAccessProbeState *s) { free(s); }
void AudioAccessProbeSetSignalFileDescriptor(AudioAccessProbeState *s, int fd) { if (s) s->signalFD = fd; }
bool AudioAccessProbeObservedSignal(const AudioAccessProbeState *s) {
    return s && atomic_load_explicit(&s->observedSignal, memory_order_relaxed) != 0;
}
OSStatus AudioAccessProbeIOProc(AudioObjectID device, const AudioTimeStamp *now,
                            const AudioBufferList *input, const AudioTimeStamp *inputTime,
                            AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    if (!AudioTapClearOutputs(output)) return noErr;
    AudioAccessProbeState *state = context;
    if (state && !AudioAccessProbeObservedSignal(state) && AudioTapValidInput(input)) {
        for (uint32_t b = 0; b < input->mNumberBuffers; ++b) {
            const AudioBuffer *buffer = &input->mBuffers[b];
            const float *samples = buffer->mData;
            for (uint32_t n = 0; n < buffer->mDataByteSize / sizeof(float); ++n) {
                if (isfinite(samples[n]) && samples[n] != 0) {
                    if (!atomic_exchange_explicit(&state->observedSignal, 1, memory_order_relaxed) && state->signalFD >= 0) {
                        const char byte = 1;
                        (void)write(state->signalFD, &byte, 1);
                    }
                    return noErr;
                }
            }
        }
    }
    return noErr;
}
OSStatus AudioRealtimeConfigureStreams(AudioObjectID device, AudioDeviceIOProcID proc,
                                   AudioObjectPropertyScope scope, uint32_t count, const uint32_t *enabled) {
    if (!proc || !count || count > 64 || !enabled) return kAudioHardwareIllegalOperationError;
    size_t bytes = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + count * sizeof(UInt32);
    AudioHardwareIOProcStreamUsage *usage = calloc(1, bytes);
    if (!usage) return kAudioHardwareUnspecifiedError;
    usage->mIOProc = (void *)proc;
    usage->mNumberStreams = count;
    memcpy(usage->mStreamIsOn, enabled, count * sizeof(UInt32));
    AudioObjectPropertyAddress address = { kAudioDevicePropertyIOProcStreamUsage, scope, kAudioObjectPropertyElementMain };
    OSStatus status = AudioObjectSetPropertyData(device, &address, 0, NULL, (UInt32)bytes, usage);
    if (!status) {
        UInt32 size = (UInt32)bytes;
        status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, usage);
        if (!status && (size != bytes || usage->mNumberStreams != count)) status = kAudioHardwareIllegalOperationError;
        if (!status) for (uint32_t n = 0; n < count; ++n)
            if (!!usage->mStreamIsOn[n] != !!enabled[n]) { status = kAudioHardwareIllegalOperationError; break; }
    }
    free(usage);
    return status;
}
