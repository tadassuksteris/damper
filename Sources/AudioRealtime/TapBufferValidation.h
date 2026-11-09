#ifndef DAMPER_TAP_BUFFER_VALIDATION_H
#define DAMPER_TAP_BUFFER_VALIDATION_H
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

/// Buffer checks shared by the tap-only probe and measurement callbacks.
/// Both run on the audio thread: no allocation, locks, or runtime calls.
enum { AudioTapMaxBufferBytes = 1024 * 1024, AudioTapMaxOutputBuffers = 64 };

/// Zeroes each bounded output buffer. Returns false if any buffer is out of bounds.
static inline bool AudioTapClearOutputs(AudioBufferList *output) {
    if (!output) return true;
    if (output->mNumberBuffers > AudioTapMaxOutputBuffers) return false;
    bool valid = true;
    for (uint32_t b = 0; b < output->mNumberBuffers; ++b) {
        AudioBuffer *buffer = &output->mBuffers[b];
        if (buffer->mDataByteSize > AudioTapMaxBufferBytes || (buffer->mDataByteSize && !buffer->mData)) {
            valid = false; continue;
        }
        if (buffer->mDataByteSize) memset(buffer->mData, 0, buffer->mDataByteSize);
    }
    return valid;
}

/// One mono/interleaved-stereo buffer, or two mono buffers for planar stereo.
static inline bool AudioTapValidInput(const AudioBufferList *input) {
    if (!input || input->mNumberBuffers < 1 || input->mNumberBuffers > 2) return false;
    uint32_t frames = 0;
    for (uint32_t b = 0; b < input->mNumberBuffers; ++b) {
        const AudioBuffer *buffer = &input->mBuffers[b];
        const uint32_t channels = buffer->mNumberChannels;
        if (channels < 1 || channels > 2 || (input->mNumberBuffers == 2 && channels != 1) ||
            buffer->mDataByteSize > AudioTapMaxBufferBytes ||
            buffer->mDataByteSize % (sizeof(float) * channels) ||
            (buffer->mDataByteSize && (!buffer->mData || (uintptr_t)buffer->mData % _Alignof(float)))) return false;
        const uint32_t bufferFrames = buffer->mDataByteSize / (uint32_t)(sizeof(float) * channels);
        if (b && frames != bufferFrames) return false;
        frames = bufferFrames;
    }
    return true;
}
#endif
