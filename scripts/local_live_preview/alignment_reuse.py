"""Process-local reuse of native decode features for the same alignment window."""
import threading


class _AlignmentModel:
    def __init__(self, model, features):
        self.model = model
        self.features = features

    def __getattr__(self, name):
        return getattr(self.model, name)

    def forward_with_cross_qk(self, mel, tokens):
        logits, _, cross_qk = self.model.decoder(tokens, self.features[None, :])
        return logits, cross_qk


class AlignmentReuse:
    """Scoped to one fixed model; mismatched windows use the unchanged path."""
    def __init__(self, native, model):
        self.native = native
        self.model = model
        self.hits = 0
        self.fallbacks = 0
        self.local = threading.local()

    def __enter__(self):
        self.decode = self.model.decode
        self.words = self.native.add_word_timestamps

        def decode(mel, *args, **kwargs):
            self.local.entry = None
            result = self.decode(mel, *args, **kwargs)
            features = getattr(result, 'audio_features', None)
            if features is not None and getattr(mel, 'ndim', None) == 2:
                self.local.entry = (mel, features)
            return result

        def words(*args, **kwargs):
            entry = getattr(self.local, 'entry', None)
            self.local.entry = None
            if (entry is not None and not args
                    and kwargs.get('model') is self.model
                    and kwargs.get('mel') is entry[0]):
                self.hits += 1
                kwargs = dict(kwargs, model=_AlignmentModel(self.model, entry[1]))
            else:
                self.fallbacks += 1
            return self.words(*args, **kwargs)

        self.model.decode = decode
        self.native.add_word_timestamps = words
        return self

    def __exit__(self, *exc):
        self.model.decode = self.decode
        self.native.add_word_timestamps = self.words
        self.local = threading.local()
