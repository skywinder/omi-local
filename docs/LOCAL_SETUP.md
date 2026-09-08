# Приложение iOS и LAN-режим

Здесь описаны требования к iOS-приложению и прежний LAN-сценарий.
Для связи через мобильную сеть и установки backend используйте
[инструкцию ngrok](NGROK.md). Полная установка на втором чистом Mac не проверялась.

## Окружение

- macOS на Apple Silicon, Xcode с iOS SDK и настроенной Apple Development identity.
- Flutter 3.44.5, CocoaPods 1.16.2.
- Python 3.11.15; закреплённые зависимости находятся в `backend/pylock*.toml`.
- `uv`, Node.js/npm, Java для Firebase emulators, Redis, native `libopus`, FFmpeg, `jq`.
- iPhone 17 Pro с Developer Mode и data-capable USB; общая с Mac LAN нужна только для LAN-режима.
- Omi CV1, firmware 3.0.21.

Физический путь проверялся с Xcode 26.6 и iOS 26.6. Это проверенная конфигурация,
а не обещание совместимости со всеми более новыми версиями.

## Backend в LAN-режиме

Команды выполняются из корня репозитория. Подготовка зависимостей требует сети;
`offline` описывает работу локального сценария, а не установку пакетов.

```bash
bash backend/scripts/sync-python-deps.sh
npm ci
export PATH="$PWD/node_modules/.bin:$PATH"
export PYTHON="$PWD/backend/.venv/bin/python"
export PROVIDER_MODE=offline
```

Задайте `OMI_DEV_HOST` в текущем терминале: это LAN-адрес Mac, доступный телефону.
Не записывайте значение в отслеживаемые файлы. Один и тот же адрес нужен backend
и приложению; у приложения он входит в параметры сборки.

```bash
make dev-check
```

Продолжайте только после успешной проверки. Она проверяет необходимые инструменты
и создание Opus decoder в окружении backend. Затем:

```bash
make dev-up
make dev-status
make dev-audio-smoke
```

В offline-режиме запускаются Firestore/Auth emulators, Redis и mobile backend.
Smoke-тест отправляет синтетический Opus-поток и проверяет сохранённый WAV.
Он создаёт локальные тестовые файлы. API использует порт 8000, Auth emulator —
9099. Не открывайте эти сервисы в интернет.

## Приложение iOS

В текущей версии `app/setup.sh ios personal` объединяет подготовку, сборку,
установку и запуск через `flutter run`. Это существующий entrypoint, а не
раздельная процедура установки; безопасный build-only bootstrap ещё предстоит
выделить. Не запускайте wrapper как способ повторной установки готового artifact.

Для первой сборки необходимы `OMI_DEV_HOST` и `OMI_APPLE_TEAM_ID`, заданные локально;
при необходимости — собственный `OMI_PERSONAL_BUNDLE_ID`. Generated signing
configuration исключена из Git. Допускается сочетание `dev + local_dev + offline`,
конфигурация `Profile-dev-iphoneos`. Production iOS wrapper блокирует.

Перед сборкой сравните исходники, lock-файлы, toolchain, signing и compile-time
endpoints. При неизменных входах переиспользуйте аттестованный artifact. Backend
или USB-сбой сам по себе не требует пересборки; clean нужен только при релевантной
смене signing/native dependencies/toolchain либо доказанном повреждении cache.

Перед установкой отдельно проверьте commit/configuration, SHA-256 executable,
подпись и entitlements точного artifact:

```text
app/build/ios/Profile-dev-iphoneos/Runner.app
```

Старый flavorless `app/build/ios/iphoneos/Runner.app` может относиться к другой
сборке. Новая копия репозитория не содержит ни готового artifact, ни signing identity.

## Запись с CV1

1. Запустите backend и установленное offline-приложение; подключите CV1 по Bluetooth.
2. Нажмите **▶ Начать запись** на карточке CV1. Нижний `+` временно неактивен.
3. Запишите 10–30 секунд тестовой речи.
4. Нажмите **■ Остановить запись**: поток закрывается, WAV передаётся автообработчику.
   Мьют только приостанавливает звук внутри записи и не завершает файл.
   В сборках без временных кнопок для завершения требовалось закрывать приложение.
5. В локальном хранилище harness найдите `listen-captures/<session>/audio.wav`
   и `metadata.json`. После штатного завершения `.part`-файлов быть не должно.
6. Проверьте длительность, `decode_errors=0` и прослушайте WAV локально.

В исходном LAN-сценарии подтверждена запись 14,9 секунды, PCM16 mono 16 kHz.
Отдельные проверки через мобильную сеть описаны в [инструкции ngrok](NGROK.md).

## Проверки для разработки

```bash
make test-offline
```

Команда использует подготовленный Python и запускает тесты offline-backend,
capture и конфигурации harness без запуска сервисов. Flutter-тесты находятся
в `app/test/`; их запуск требует Flutter dependencies и generated files.

Рабочие журналы, `.local/`, реальные записи, `.env`, ключи, сертификаты и build
outputs исключены из публикации. В исходниках остаются синтетические данные тестов
и публичные upstream-константы; они не заменяют личные credentials. Не добавляйте
реальные значения в fixtures и не используйте принудительное добавление ignored файлов.
