import unittest
from types import SimpleNamespace

from .reset_retention import PreviewResetRetention
from .serve import snapshot_with_words


class Online:
    """Controllable reset/rejection seam with the pinned online processor API."""
    def __init__(self):
        self.init()
        self.reset_on_process = False
        self.reject_on_process = False

    def init(self, offset=0):
        self.transcript_buffer = SimpleNamespace(buffer=[])

    def process_iter(self):
        if self.reject_on_process:
            self.transcript_buffer.buffer = []
        if self.reset_on_process:
            self.init(offset=16)
        return [], 16

    def concatenate_tokens(self, tokens):
        return SimpleNamespace(text=' '.join(tokens))

    def get_buffer(self):
        return self.concatenate_tokens(self.transcript_buffer.buffer)

    def finish(self):
        tokens = self.transcript_buffer.buffer
        self.transcript_buffer.buffer = []
        return tokens, 20


class RetentionTests(unittest.TestCase):
    def test_snapshot_words_preserve_session_times_and_exact_text_after_reset(self):
        online = Online()
        PreviewResetRetention(online)
        tokens = [SimpleNamespace(text=' Первая', start=23.25, end=23.7),
                  SimpleNamespace(text=' фраза.', start=23.7, end=24.1)]
        online.transcript_buffer.buffer = tokens
        online.init(offset=30)
        retained, _ = online.process_iter()
        self.assertEqual(retained, tokens)
        line = SimpleNamespace(text=' Первая фраза.', speaker=1, tokens=retained)
        response = SimpleNamespace(lines=[line], to_dict=lambda: {
            'lines': [{'text': line.text, 'speaker': 1, 'start': '0:00:23.25', 'end': '0:00:24.10'}],
            'buffer_transcription': ''})
        message = snapshot_with_words(response)
        self.assertEqual(message['lines'][0]['words'], [
            {'word': ' Первая', 'start': 23.25, 'end': 23.7},
            {'word': ' фраза.', 'start': 23.7, 'end': 24.1}])
        self.assertEqual(message['lines'][0]['text'], line.text)
        self.assertNotIn('words', response.to_dict()['lines'][0])

    def test_invalid_words_are_not_published_with_misleading_timestamps(self):
        line = SimpleNamespace(text='word', speaker=1,
                               tokens=[SimpleNamespace(text='word', start=2, end=1)])
        response = SimpleNamespace(lines=[line], to_dict=lambda: {'lines': [{'text': line.text}]})
        with self.assertRaisesRegex(ValueError, 'Invalid live word timing'):
            snapshot_with_words(response)

    def test_stall_reset_publishes_draft_once(self):
        online = Online()
        retention = PreviewResetRetention(online)
        online.transcript_buffer.buffer = ['Synthetic', 'draft']
        online.reset_on_process = True
        self.assertEqual(online.process_iter(), (['Synthetic', 'draft'], 16))
        self.assertEqual(online.process_iter(), ([], 16))
        self.assertEqual(retention.reset_flushes, 1)
        self.assertEqual(retention.retained_tokens, 2)

    def test_silence_reset_keeps_pending_visible_until_next_output_and_finish(self):
        online = Online()
        PreviewResetRetention(online)
        online.transcript_buffer.buffer = ['Earlier']
        online.init(offset=20)
        self.assertEqual(online.get_buffer().text, 'Earlier')
        online.transcript_buffer.buffer = ['Later']
        self.assertEqual(online.get_buffer().text, 'Earlier Later')
        self.assertEqual(online.process_iter()[0], ['Earlier'])
        self.assertEqual(online.get_buffer().text, 'Later')
        self.assertEqual(online.finish()[0], ['Later'])
        self.assertEqual(online.finish()[0], [])

    def test_rejected_hypothesis_is_not_resurrected_on_reset(self):
        online = Online()
        retention = PreviewResetRetention(online)
        online.transcript_buffer.buffer = ['Rejected']
        online.reject_on_process = online.reset_on_process = True
        self.assertEqual(online.process_iter()[0], [])
        self.assertEqual(online.get_buffer().text, '')
        self.assertEqual(retention.retained_tokens, 0)
        other = Online()
        PreviewResetRetention(other)
        self.assertEqual(other.get_buffer().text, '')


if __name__ == '__main__':
    unittest.main()
