# Приложение на iPhone

Для записи нужен отдельно установленный локальный вариант Omi.
`start.command` готовит сервисы на Mac, но не устанавливает приложение на телефон.
После установки подключите его по [инструкции ngrok](NGROK.md).

## Подготовка Mac

Нужны Mac с Apple Silicon, Xcode, Flutter, CocoaPods и свой Apple Account.
Привязки к модели iPhone или поколению M-процессора нет. В проекте указан минимум
iOS 15.0; Xcode должен поддерживать версию iOS телефона и работать на вашей macOS.

1. Установите Xcode из App Store, откройте его, примите лицензию и дождитесь
   установки компонентов iOS. В **Settings → Locations → Command Line Tools**
   выберите установленный Xcode.
2. Установите [Flutter для iOS](https://docs.flutter.dev/platform-integration/ios/setup)
   и добавьте его в PATH по инструкции. Нужна версия не ниже 3.44.5.
3. После подготовки Homebrew через `start.command` установите
   [CocoaPods](https://formulae.brew.sh/formula/cocoapods): `brew install cocoapods`.
   Проверьте `flutter doctor -v`: раздел Xcode должен быть без ошибок;
   Android для этой установки не нужен.

## Подпись и телефон

Для установки на свой iPhone достаточно бесплатной **Personal Team**.
Её профиль действует 7 дней: затем приложение нужно заново подписать и установить.
Это [ограничение Apple](https://developer.apple.com/help/account/basics/about-your-developer-account).

1. В Xcode откройте **Settings → Accounts**, добавьте свой Apple Account
   и выберите Personal Team.
2. Откройте **Manage Certificates → + → Apple Development**. Xcode создаст
   сертификат и закрытый ключ на этом Mac; вручную выпускать CSR не требуется.
   Если сертификат уже есть с рабочим закрытым ключом, повторно создавать его не нужно.
   [Инструкция Apple](https://developer.apple.com/documentation/Xcode/sharing-your-teams-signing-certificates).
3. В «Связке ключей» откройте **Мои сертификаты → Apple Development**.
   Под сертификатом должен быть закрытый ключ. Team ID — это 10 символов
   в **Subject Name → Organizational Unit (OU)** в свойствах сертификата.
   Номер в скобках в названии может отличаться —
   [Apple объясняет разницу](https://developer.apple.com/forums/thread/811970).
4. Подключите разблокированный iPhone USB-кабелем для передачи данных и подтвердите
   доверие Mac. В Xcode откройте **Window → Devices and Simulators** и дождитесь
   готовности телефона. На iPhone включите **Настройки → Конфиденциальность
   и безопасность → Режим разработчика**, перезагрузите его и подтвердите включение.

## Установка

Возьмите свежую копию репозитория. Из папки проекта выполните команды ниже;
после приглашения вставьте Team ID и нажмите Enter. Ввод скрыт и не попадает
в историю команд.

```bash
cd app
printf 'Team ID: '
read -r -s OMI_APPLE_TEAM_ID
printf '\n'
export OMI_APPLE_TEAM_ID
bash setup.sh ios personal
```

Скрипт подготавливает зависимости, собирает, устанавливает и запускает приложение.
Если macOS запросит доступ к ключу подписи, разрешите его, введя пароль Mac.
При сообщении о недоверенном разработчике на iPhone откройте **Настройки → Основные
→ VPN и управление устройством** и подтвердите доверие своему разработчику.

Телефон выбирается из подключённых устройств. Если их несколько, скрипт предложит
выбор; для запуска без диалога есть `OMI_IOS_DEVICE_ID`. Если Xcode сообщает,
что идентификатор занят, задайте свой `OMI_PERSONAL_BUNDLE_ID`. Домен и ключ вводятся
в приложении после установки; `OMI_DEV_HOST` нужен только для LAN-режима.
Старые `.local`, `.venv`, `build`, ключи и настройки подписи переносить не нужно.

Физически проверены iPhone 17 Pro с iOS 26.6, Xcode 26.6, Flutter 3.44.5
и CocoaPods 1.16.2. Полный повтор установки на чистом Mac ещё не проверен.

[Повторная установка и проверка сборки](DEVELOPMENT.md#сборка-iphone) ·
[LAN-режим](DEVELOPMENT.md#локальная-сеть) · [Запуск и запись с CV1](START.md).
