"""CPU-only multilingual E5 embeddings from verified on-disk model files."""

import hashlib
from pathlib import Path


MODEL_REVISION = '614241f622f53c4eeff9890bdc4f31cfecc418b3'
FILES = {
    'model.onnx': 'ca456c06b3a9505ddfd9131408916dd79290368331e7d76bb621f1cba6bc8665',
    'tokenizer.json': '0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39',
}


class LocalSemanticModel:
    fingerprint = f'intfloat/multilingual-e5-small:{MODEL_REVISION}:mean-v1'
    dimensions = 384

    def __init__(self, directory, *, threads=2):
        if not 1 <= threads <= 8:
            raise ValueError('Invalid semantic CPU thread count')
        directory = Path(directory)
        for name, expected in FILES.items():
            with (directory / name).open('rb') as owned_file:
                if hashlib.file_digest(owned_file, 'sha256').hexdigest() != expected:
                    raise ValueError(f'Local semantic model checksum mismatch: {name}')

        # The ordinary harness and backend do not need these optional dependencies.
        import numpy
        import onnxruntime
        from tokenizers import Tokenizer

        self._np = numpy
        self._tokenizer = Tokenizer.from_file(str(directory / 'tokenizer.json'))
        pad = self._tokenizer.token_to_id('<pad>')
        self._tokenizer.enable_truncation(max_length=512)
        self._tokenizer.enable_padding(pad_id=pad, pad_token='<pad>')
        options = onnxruntime.SessionOptions()
        options.intra_op_num_threads = threads
        options.inter_op_num_threads = 1
        self._session = onnxruntime.InferenceSession(
            str(directory / 'model.onnx'), sess_options=options, providers=['CPUExecutionProvider'],
        )
        self._inputs = {value.name for value in self._session.get_inputs()}

    def encode(self, texts, *, query):
        if not 1 <= len(texts) <= 8 or any(not text.strip() or len(text) > 2500 for text in texts):
            raise ValueError('Invalid semantic text batch')
        np = self._np
        prefix = 'query: ' if query else 'passage: '
        tokens = self._tokenizer.encode_batch([prefix + text for text in texts])
        mask = np.asarray([token.attention_mask for token in tokens], dtype=np.int64)
        data = {
            'input_ids': np.asarray([token.ids for token in tokens], dtype=np.int64),
            'attention_mask': mask,
            'token_type_ids': np.zeros_like(mask),
        }
        hidden, = self._session.run(['last_hidden_state'], {name: data[name] for name in self._inputs})
        pooled = (hidden * mask[:, :, None]).sum(axis=1) / mask.sum(axis=1, keepdims=True)
        # The projection normalizes each vector at its write and query boundary.
        return pooled.tolist()
