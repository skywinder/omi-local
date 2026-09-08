# omiloc

Личная аудиотека на Mac: записи с Omi CV1, транскрипты и плеер с переходом по фразе.
Записью управляет приложение на iPhone. Аудио передаётся через ngrok;
хранение и распознавание остаются на Mac.

Откройте **[start.command](start.command)** или выполните `./start.command`
из папки проекта. Скрипт подготовит Mac, покажет домен и ключ для iPhone
и откроет аудиотеку. [Инструкция по запуску](docs/START.md).

После настройки команда **`omiloc`** открывает аудиотеку из любой папки в Terminal.
Для приёма новых записей запускайте `start.command`.

Нужны Mac с Apple Silicon, CV1 и отдельно установленное приложение на iPhone.
Установка распознавания с нуля пока не подготовлена. Полная установка на чистом Mac
ещё не проверена; готовность сервисов не означает готовность моделей.

[Подключение iPhone](docs/NGROK.md) · [Распознавание](docs/LOCAL_STT.md) ·
[Ограничения](docs/TEMPORARY_DISABLED_FEATURES.md) · [Для разработчиков](docs/DEVELOPMENT.md).

Основан на [Omi от Based Hardware](https://github.com/BasedHardware/omi).
[Происхождение](UPSTREAM.md) · [MIT](LICENSE) · [Логотип](web-local/assets/omiloc.png).
