"""One request of RAM-only reuse for a fixed deterministic ASR instance."""
from copy import deepcopy
from threading import Lock

import numpy as np


class LastAudioResult:
    def __init__(self, backend):
        self.backend = backend
        self.hits = 0
        self.misses = 0
        self._entry = None
        self._lock = Lock()

    def clear(self):
        with self._lock:
            self._entry = None

    def __call__(self, audio, init_prompt=""):
        with self._lock:
            entry = self._entry
            if (entry is not None and entry[1] == init_prompt
                    and entry[0].dtype == audio.dtype
                    and entry[0].shape == audio.shape
                    and np.array_equal(entry[0], audio)):
                self.hits += 1
                return deepcopy(entry[2])
            self.misses += 1
            self._entry = None
            snapshot = np.array(audio, copy=True)
            result = self.backend(audio, init_prompt=init_prompt)
            self._entry = (snapshot, init_prompt, deepcopy(result))
            return result
