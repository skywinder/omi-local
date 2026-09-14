"""Keep a preview hypothesis when LocalAgreement resets its audio window."""


class PreviewResetRetention:
    """Per-session adapter; retained text remains a draft, never final ASR.

    A recognizer rejection still clears its hypothesis normally. Only tokens
    still present at an explicit processor reset are carried to WLK history.
    """

    def __init__(self, online):
        self.online = online
        self.pending = []
        self.reset_flushes = 0
        self.retained_tokens = 0
        self._init = online.init
        self._process_iter = online.process_iter
        self._get_buffer = online.get_buffer
        self._finish = online.finish
        online.init = self._reset
        online.process_iter = self._process
        online.get_buffer = self._buffer
        online.finish = self._end

    def _reset(self, *args, **kwargs):
        tokens = list(self.online.transcript_buffer.buffer)
        if tokens:
            self.pending.extend(tokens)
            self.reset_flushes += 1
            self.retained_tokens += len(tokens)
        return self._init(*args, **kwargs)

    def _drain(self, result):
        tokens, processed_upto = result
        retained, self.pending = self.pending, []
        return retained + (tokens or []), processed_upto

    def _process(self):
        return self._drain(self._process_iter())

    def _buffer(self):
        if self.pending:
            return self.online.concatenate_tokens(self.pending + list(self.online.transcript_buffer.buffer))
        return self._get_buffer()

    def _end(self):
        return self._drain(self._finish())
