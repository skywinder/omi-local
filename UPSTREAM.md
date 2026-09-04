# Происхождение

Исходный проект: [BasedHardware/omi](https://github.com/BasedHardware/omi).
Upstream baseline: `2ce52f13f4724eee989158da6318dc6f27aa744e`.

Снимок включает локальные изменения Personal Team/offline
(`8bbf848d905b32de395e8ee2fc9840e96ff9d0ee`) и запись WAV
(`bae122dbb48d0fe46bcab384736dee239328234f`). Это ссылки на исходные локальные
коммиты для сопоставления; они не являются предками новой истории.

При подготовке удалены компоненты вне MVP, материалы демонстраций и deployment
workflows; обновлены README и команды верхнего уровня. Встроенные upstream Team ID
заменены переменной `OMI_APPLE_TEAM_ID`, Firebase presets — локальными emulator
fixtures; исключён deployment verification token upstream и generated Custom.xcconfig. Логика приёма CV1, записи WAV и ограничения сети сохранена.

Сохранены [лицензия MIT и уведомление Based Hardware Contributors](LICENSE),
а также исходные component agent guides. Лицензии зависимостей и сторонних
ресурсов продолжают применяться к соответствующим компонентам.
