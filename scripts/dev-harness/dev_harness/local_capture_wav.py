"""Read ordinary WAVs or the canonical RF64 PCM16 files produced by local capture."""
import os
import struct
import wave
from contextlib import contextmanager


class _CaptureRf64:
    def __init__(self, source):
        self.source = source
        # Canonical EBU Tech 3306 layout. Accept exactly our mono PCM format;
        # the ordinary RIFF path still accepts all layouts supported by wave.
        header = struct.Struct('<4sI4s4sIQQQI4sIHHIIHH4sI')
        data = source.read(header.size)
        if len(data) != header.size:
            raise wave.Error('Incomplete RF64 header')
        fields = header.unpack(data)
        (marker, sentinel, shape, ds64, size, container_bytes, pcm_bytes, frames, table,
         fmt, fmt_size, codec, channels, rate, byte_rate, align, bits, samples, data_size) = fields
        if ((marker, sentinel, shape, ds64, size, table) != (b'RF64', 0xffffffff, b'WAVE', b'ds64', 28, 0)
                or (fmt, fmt_size, codec, channels, rate, byte_rate, align, bits, samples, data_size)
                != (b'fmt ', 16, 1, 1, 16000, 32000, 2, 16, b'data', 0xffffffff)
                or frames * align != pcm_bytes or container_bytes != pcm_bytes + header.size - 8
                or source.seek(0, os.SEEK_END) != pcm_bytes + header.size):
            raise wave.Error('Invalid local RF64 PCM')
        self.frames, self.offset = frames, header.size
        self.setpos(0)

    def getnframes(self):
        return self.frames

    def getframerate(self):
        return 16000

    def getnchannels(self):
        return 1

    def getsampwidth(self):
        return 2

    def getcomptype(self):
        return 'NONE'

    def setpos(self, frame):
        if not 0 <= frame <= self.frames:
            raise wave.Error('Wave position out of range')
        self.source.seek(self.offset + frame * 2)

    def readframes(self, frames):
        return self.source.read(frames * 2)


@contextmanager
def read_wave(source):
    marker = source.read(4)
    source.seek(0)
    if marker == b'RF64':
        yield _CaptureRf64(source)
    else:
        with wave.open(source, 'rb') as wav:
            yield wav
