# omiloc

Личная аудиотека на Mac: записи с Omi CV1, транскрипты и плеер с переходом по фразе.
Записью управляет приложение на iPhone. Аудио передаётся через ngrok;
хранение и распознавание остаются на Mac.

Откройте **[start.command](start.command)** или выполните `./start.command`
из папки проекта. Скрипт подготовит Mac, покажет домен и ключ для iPhone
и откроет аудиотеку. [Инструкция по запуску](docs/START.md).

После настройки команда **`omiloc`** открывает аудиотеку из любой папки в Terminal.
Для приёма новых записей запускайте `start.command`.

Папки с аудио и транскриптами можно открыть в Finder через свёрнутый пункт
**«Папки»** внизу боковой панели аудиотеки.

Нужны Mac с Apple Silicon, CV1 и отдельно установленное приложение на iPhone.
При первом запуске подготавливаются модели [финального](docs/LOCAL_STT.md) и
[live-распознавания](docs/LIVE_PREVIEW.md); нужны Xcode со Swift 6.0+ и macOS 14+.
Полная установка на чистом Mac ещё не проверена.

[Подключение iPhone](docs/NGROK.md) · [Распознавание](docs/LOCAL_STT.md) ·
[Ограничения](docs/TEMPORARY_DISABLED_FEATURES.md) · [Для разработчиков](docs/DEVELOPMENT.md).

Основан на [Omi от Based Hardware](https://github.com/BasedHardware/omi).
[Происхождение](UPSTREAM.md) · [MIT](LICENSE) · [Логотип](web-local/assets/omiloc.png).
