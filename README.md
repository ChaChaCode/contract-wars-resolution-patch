# Contract Wars — Resolution Unlock Patch

Снимает ограничение разрешения экрана **1920×1080** в клиенте Contract Wars (CWClient).
После патча в настройках игры появляются все разрешения вашего монитора — 2560×1440 (2K), 3840×2160 (4K) и выше.

*Removes the 1920×1080 resolution cap in the Contract Wars standalone client. After patching, the in-game settings list shows all resolutions your monitor supports — including 2K and 4K. English instructions below.*

## Почему игра не даёт выбрать 2K/4K

В коде клиента (`Assembly-CSharp.dll`) зашиты два ограничения:

1. `Utility.FixResolution()` — при каждом запуске принудительно сбрасывает разрешение, если экран больше 1920×1080.
2. Меню настроек показывает только разрешения с шириной от 800 до 1920.

Патч поднимает оба потолка (по умолчанию до 7680×4320), после чего игра сама корректно определяет монитор.

## Установка

1. Скачайте файлы патча (Code → Download ZIP) и распакуйте куда угодно.
2. Запустите **PATCH.bat** двойным кликом — откроется окно программы:
   - папка игры находится автоматически (или выберите её кнопкой **«Обзор...»** — нужна папка, где лежит `CWClient.exe`);
   - выберите потолок разрешения (по умолчанию — универсальный, подходит для любого монитора вплоть до 8K);
   - нажмите **«ПРИМЕНИТЬ ПАТЧ»**.
3. Запустите игру через **CWClient.exe** (не через лаунчер — он может перекачать файл и снять патч).
4. В настройках игры выберите нужное разрешение и примените. Оно сохранится в вашем профиле.

Для консоли: `powershell -ExecutionPolicy Bypass -File Patch-CWResolution.ps1 -GamePath "D:\Path\To\CWClient"` (параметры `-MaxWidth`, `-MaxHeight`, `-Restore`).

## Откат

Нажмите **«Откатить патч»** в окне программы (или запустите **RESTORE.bat**) — вернётся оригинальная DLL из бэкапа (`Assembly-CSharp.dll.orig.bak`), который патч создаёт автоматически.

## Как это работает

Скрипт ищет в DLL два участка IL-кода по их байтовой структуре (не по фиксированным адресам, поэтому переживает мелкие различия версий клиента) и заменяет константы `1920`/`1080` на новый потолок. Если структура кода не совпала однозначно — файл не изменяется.

## Дисклеймер

- Патч изменяет только файл на вашем компьютере; файлы игры в репозитории не распространяются.
- Это модификация клиента. Изменение касается только разрешения экрана и не даёт игровых преимуществ, но используйте на свой страх и риск.
- Проверено на клиенте Contract Wars (Unity 4.1.5).

---

## English

**Install:** download this repo and run `PATCH.bat` — a window opens where you pick the game folder (the one containing `CWClient.exe`, auto-detected when possible), choose the resolution cap, and click the patch button. CLI is also available: `powershell -ExecutionPolicy Bypass -File Patch-CWResolution.ps1 -GamePath "D:\CWClient"`. Then launch the game via `CWClient.exe` (not the launcher — it may re-download the DLL) and pick your resolution in the in-game settings.

**Uninstall:** run `RESTORE.bat` — restores the original DLL from the automatic backup.

**How it works:** the script locates two IL code sites in `Assembly-CSharp.dll` by byte-pattern (the startup resolution clamp in `Utility.FixResolution()` and the settings-menu resolution list filter) and raises the hardcoded 1920×1080 cap to 7680×4320. If the patterns don't match exactly once, nothing is modified.

**Disclaimer:** no game files are distributed; the patch only modifies your local copy. Display-resolution change only, no gameplay advantage. Use at your own risk.
