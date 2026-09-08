# Для разработчиков

[Обычный запуск](START.md) · [Сборка iPhone](LOCAL_SETUP.md).
Команды выполняются из корня проекта. Реальные записи, `.local/`, ключи,
сертификаты и результаты сборок не добавляются в Git.

## Проект и проверки

`app/` — приложение, `backend/` — приём и хранение аудио,
`scripts/dev-harness/` — локальные сервисы, `web-local/` — аудиотека и логотип.

- `make test-library` — аудиотека и запуск.
- `make test-offline` — локальный backend и сервисы.
- `make test-transport-app` — приложение и анализатор; нужен Flutter.

Перед iOS-сборкой нужны последние два набора. Физическая запись проверяется
отдельно: начать и остановить запись на CV1, затем прослушать её в аудиотеке.

Установщик использует Homebrew. Python 3.11.15 и зависимости закреплены в
`backend/.python-version` и `backend/pylock.macos.toml`, Firebase CLI — в `package-lock.json`.
Flutter, Xcode, CocoaPods и модели готовятся отдельно.
Вывод установки сохраняется в `.local/install.log`; файл доступен только владельцу
и не входит в Git. Запросы Homebrew остаются видны в терминале, ввод ключей не записывается.
Пути Homebrew определяются автоматически. Для отдельного кеша Firebase можно задать
`FIREBASE_EMULATORS_PATH` перед установкой и запуском.

Backend — `127.0.0.1:20000`, аудиотека — `127.0.0.1:20001`, диагностика ngrok —
`127.0.0.1:16040`. Эмуляторы и аудиотека не открываются через туннель.
Backend требует ключ приложения, кроме `/v1/health`; на Mac хранится его хеш.
Удаление доступно через локальную аудиотеку, нового публичного маршрута нет.

## Модели распознавания

Проверены WhisperX 3.8.6/CPU/float32/batch 1, Parakeet-MLX 0.5.2/GPU/FP32
и pyannote.audio 4.0.7. Для Parakeet нужны Python 3.14.6, Apple Silicon и
[закреплённые зависимости](../scripts/dev-harness/requirements-parakeet-mlx-macos.txt).

Пример `stt-engine.json` для Parakeet:

```json
{
  "engine": "parakeet-mlx",
  "model": "mlx-community/parakeet-tdt-0.6b-v3",
  "language": "auto",
  "device": "gpu",
  "compute_type": "float32",
  "diarization_model": "none"
}
```

Оба движка поддерживают `python` и `library_path`. Библиотеки FFmpeg ищутся автоматически;
проверенному окружению WhisperX нужен FFmpeg 7. Учитываются настройки кеша
`HF_HOME`, `HF_HUB_CACHE` и `TORCH_HOME`. Модели ASR, alignment для WhisperX и, при включении,
pyannote с вложенными моделями должны быть скачаны заранее.

Очередь и результаты: `.local/dev-harness/ngrok/services/local-transcripts/`.
После ошибки выполняются до трёх попыток с паузами 60 и 120 секунд, затем нужен
ручной повтор. При потере состояния эмулятора он восстановит разговор из сохранённого
JSON. После изменения кода адаптера дождитесь окончания обработки и перезапустите
её через `auto-transcribe-off` / `auto-transcribe-on`.

## Локальная сеть

Прежний LAN-режим работает без TLS в доверенной сети. Подготовка:

```bash
bash backend/scripts/sync-python-deps.sh
npm ci
export PATH="$PWD/node_modules/.bin:$PATH"
export PYTHON="$PWD/backend/.venv/bin/python"
export PROVIDER_MODE=offline
export OMI_DEV_HOST="<LAN-адрес Mac>"
make dev-check
```

После успешной проверки: `make dev-up`, `make dev-status`, `make dev-audio-smoke`.
Остановка — `make dev-down`. Backend использует порт 8000, Auth — 9099.
Адрес Mac должен совпадать со встроенным в LAN-сборку приложения.
Не открывайте эти сервисы в интернет.
