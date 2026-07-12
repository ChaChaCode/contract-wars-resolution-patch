# Contract Wars — Resolution Unlock

[![Download](https://img.shields.io/badge/%E2%AC%87%20%D0%A1%D0%9A%D0%90%D0%A7%D0%90%D0%A2%D0%AC%20%2F%20DOWNLOAD-latest-c69c3c?style=for-the-badge)](https://github.com/ChaChaCode/contract-wars-resolution-patch/releases/latest/download/CW-Resolution-Patch-v1.0.3.zip)

Снимает ограничение разрешения **1920×1080** в клиенте Contract Wars. После патча в настройках игры доступны 2K, 4K, 8K и все разрешения вашего монитора.

*Removes the 1920×1080 resolution cap in the Contract Wars client — unlocks 2K/4K/8K in the in-game settings.*

## Как пользоваться

1. **[Скачать ZIP](https://github.com/ChaChaCode/contract-wars-resolution-patch/releases/latest)** → распаковать.
2. Запустить **`PATCH.bat`** → выбрать папку игры (находится сама) → **«ПРИМЕНИТЬ ПАТЧ»**.
3. Запустить игру и выбрать нужное разрешение в настройках.

**Откат:** кнопка «Откатить» в окне или `RESTORE.bat`.

**Если пишет «A=1, B=0»** (другая сборка клиента): нажмите кнопку **«Диагностика»** в окне (лог сразу копируется) и пришлите его в Telegram — **[t.me/Moxy1337](https://t.me/Moxy1337)**. Подгоним патч под вашу версию.

## Как работает

В `Assembly-CSharp.dll` зашиты два ограничения — сброс разрешения при старте (`Utility.FixResolution`) и фильтр списка в меню настроек. Патч поднимает оба потолка. Нужные места ищутся по байт-паттернам, поэтому патч переживает разные сборки клиента; при несовпадении файл не меняется. Оригинал сохраняется в `Assembly-CSharp.dll.orig.bak`.

## Консоль

```
powershell -ExecutionPolicy Bypass -File Patch-CWResolution.ps1 -GamePath "D:\CWClient"
```
Параметры: `-MaxWidth`, `-MaxHeight`, `-Restore`.

## Дисклеймер

Файлы игры не распространяются — патчится только ваша локальная копия. Меняется лишь разрешение экрана, игрового преимущества нет. Используйте на свой риск. MIT.
