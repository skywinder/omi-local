"""Reject an entire repetitive preview hypothesis before LocalAgreement."""


def is_repetitive(segments, threshold=2.4):
    return any(segment.get('compression_ratio', 0) > threshold for segment in segments)


class RepetitionGuard:
    def __init__(self, backend, threshold=2.4):
        self.backend = backend
        self.threshold = threshold
        self.accepted = 0
        self.rejected = 0

    def __call__(self, audio, init_prompt=''):
        segments = self.backend(audio, init_prompt=init_prompt)
        if is_repetitive(segments, self.threshold):
            self.rejected += 1
            return []
        self.accepted += 1
        return segments
