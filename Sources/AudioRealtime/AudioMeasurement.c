#include "AudioMeasurement.h"
#include "TapBufferValidation.h"
#include <math.h>
#include <stdlib.h>

struct AudioMeasurement {
    double sumSquares;
    uint64_t samples;
    bool valid;
};

static void invalidate(AudioMeasurement *state) {
    if (!state) return;
    state->sumSquares = 0;
    state->samples = 0;
    state->valid = false;
}

AudioMeasurement *AudioMeasurementCreate(void) {
    AudioMeasurement *state = calloc(1, sizeof *state);
    if (state) state->valid = true;
    return state;
}

void AudioMeasurementDestroy(AudioMeasurement *state) { free(state); }

void AudioMeasurementProcess(AudioMeasurement *state, const AudioBufferList *input) {
    if (!state || !state->valid) return;
    if (!AudioTapValidInput(input)) { invalidate(state); return; }

    uint64_t addedSamples = 0;
    for (uint32_t index = 0; index < input->mNumberBuffers; ++index)
        addedSamples += input->mBuffers[index].mDataByteSize / sizeof(float);

    double addedSquares = 0;
    for (uint32_t index = 0; index < input->mNumberBuffers; ++index) {
        const AudioBuffer *buffer = &input->mBuffers[index];
        const float *samples = buffer->mData;
        for (uint32_t sample = 0; sample < buffer->mDataByteSize / sizeof(float); ++sample) {
            const double value = samples[sample];
            if (!isfinite(value)) { invalidate(state); return; }
            addedSquares += value * value;
        }
    }
    state->sumSquares += addedSquares;
    state->samples += addedSamples;
}

double AudioMeasurementRMS(const AudioMeasurement *state) {
    if (!state || !state->valid || !state->samples) return 0;
    return sqrt(state->sumSquares / (double)state->samples);
}

uint64_t AudioMeasurementSampleCount(const AudioMeasurement *state) {
    return state && state->valid ? state->samples : 0;
}

bool AudioMeasurementValid(const AudioMeasurement *state) { return state && state->valid; }

OSStatus AudioMeasurementIOProc(AudioObjectID device, const AudioTimeStamp *now,
                                 const AudioBufferList *input, const AudioTimeStamp *inputTime,
                                 AudioBufferList *output, const AudioTimeStamp *outputTime,
                                 void *context) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    AudioMeasurement *state = context;
    if (!AudioTapClearOutputs(output)) { invalidate(state); return noErr; }
    AudioMeasurementProcess(state, input);
    return noErr;
}
