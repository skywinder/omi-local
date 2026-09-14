# Speech fixture

`speech-check.wav` contains synthetic Russian speech generated with the built-in
macOS Milena voice. It is PCM16, mono, 16 kHz. It contains no user recordings.

Spoken text: “Это проверка локальной записи. Сегодня хорошая погода.
Мы проверяем звук и текст”.

English meaning: “This is a local recording test. The weather is nice today.
We are checking the audio and text.”

The installer checks word recognition and timestamps with network access denied.
The file's checksum is pinned in `../whisperx-models.json`.
