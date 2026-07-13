# Contract Wars — Tweaks Patch

[![Download](https://img.shields.io/badge/%E2%AC%87%20%D0%A1%D0%9A%D0%90%D0%A7%D0%90%D0%A2%D0%AC%20%2F%20DOWNLOAD-latest-c69c3c?style=for-the-badge)](https://github.com/ChaChaCode/contract-wars-resolution-patch/releases/latest/download/CW-Tweaks-Patch-v2.0.0.zip)

Набор улучшений для клиента Contract Wars. Патчи выбираются галочками в окне программы:

- **Разрешение** — снимает ограничение 1920×1080, открывает 2K / 4K / 8K и все разрешения монитора.
- **Надёжный клик входа** — чинит баг, когда клик на экране загрузки «не срабатывает» и приходится перезаходить.
- **Автоспавн** — сразу закидывает в бой без клика «ЛКМ для вступления» (Deathmatch и Team Elimination).

*A tweaks patch for the Contract Wars client: unlock 2K/4K/8K resolution, fix the unreliable "click to start" bug, and optional auto-spawn (no click to join). Toggle each in the app window.*

## Как пользоваться

1. **[Скачать ZIP](https://github.com/ChaChaCode/contract-wars-resolution-patch/releases/latest)** → распаковать целиком (не запускать из архива).
2. Запустить **`PATCH.bat`** → выбрать папку игры (находится сама) → отметить нужные патчи → **«ПРИМЕНИТЬ ПАТЧ»**.
3. Запустить игру.

**Откат:** кнопка «Откатить» в окне (или `RESTORE.bat`) — возвращает оригинальный `Assembly-CSharp.dll` из бэкапа.

**Если патч не находит место в коде** (другая сборка клиента): нажмите **«Диагностика»** — лог сразу копируется — и пришлите его в Telegram **[t.me/Moxy1337](https://t.me/Moxy1337)**.

## Что делает каждый патч

| Патч | Суть |
|------|------|
| Разрешение | Поднимает потолок в `Utility.FixResolution` и в фильтре списка настроек. |
| Клик входа | На экране «READY!» заменяет одноразовую проверку нажатия на удержание — клик перестаёт «теряться». |
| Автоспавн | В коде спавна (Deathmatch, Team Elimination) вход в бой больше не требует клика. Таймер респауна и выбор стороны соблюдаются. Tactical Conquest / Target Designation используют выбор точки на карте — не затрагиваются. |

Патчи ищут места **по именам методов и байт-паттернам**, поэтому переживают разные сборки клиента; при несовпадении файл не меняется. Оригинал сохраняется в `Assembly-CSharp.dll.orig.bak`.

## Состав архива

`PATCH.bat`, `RESTORE.bat`, `Patch-CWResolution.ps1`, `CWPatchCore.ps1`, `Diagnose.ps1`, `dnlib.dll` (нужна для патчей клика/автоспавна), `README.md`, `LICENSE`, `dnlib-LICENSE.txt`.

## Дисклеймер

Файлы игры не распространяются — патчится только ваша локальная копия. Это модификация клиента онлайн-игры: патч разрешения безобиден, а клик/автоспавн меняют клиентское поведение (без игрового преимущества — таймеры и правила соблюдаются). Используйте на свой риск. Библиотека `dnlib` — стороняя, под лицензией MIT (см. `dnlib-LICENSE.txt`). Код патчера — MIT.
