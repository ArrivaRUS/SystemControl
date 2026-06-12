# 🔥 Heat Control

*by Alex Kovalev*

[![Release](https://img.shields.io/github/v/release/ArrivaRUS/HeatControl?color=ff6b2c)](https://github.com/ArrivaRUS/HeatControl/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20Silicon-lightgrey)

Нативная menu bar утилита для macOS: показывает, **кто жрёт энергию и греет MacBook**, температуры CPU/GPU — и позволяет прибить виновника в один клик.

![Главная панель](assets/preview_main.png)

## Возможности

- **Топ энергопрожорливых процессов и приложений** — потребление CPU усредняется
  за выбранное окно (**10 секунд / 1 минута / 5 минут**), поэтому список не прыгает,
  как в Activity Monitor, а показывает, кто реально грел машину последнюю минуту.
- **Группировка по приложениям** — хелперы Chrome/Safari и т.п. собираются под родительское
  приложение (как в Activity Monitor), либо режим плоского списка процессов (Apps / Procs).
- **Kill в один клик** — наведи на строку → крестик → `Quit` (вежливый terminate / SIGTERM)
  или `Force` (SIGKILL).
- **Температуры CPU и GPU** + общая загрузка, с кольцевыми гейджами и спарклайнами истории.
  Цвет меняется от мятного (прохладно) до малинового (критично).
- **Температура CPU прямо в menu bar** рядом с иконкой-пламенем (отключается в настройках).
- **Режим "поверх всех окон"** — кнопка 📌 открепляет панель в плавающее окошко,
  которое висит над всеми окнами и во всех Spaces. Закрыть — Esc или 📌.
- **Автозапуск при логине**, настройка частоты обновления (1/2/5 с).
- **Полный список термосенсоров** (сотни датчиков SoC) — в настройках.

## Скачать

Готовый `HeatControl.app` — на [странице релизов](https://github.com/ArrivaRUS/HeatControl/releases).
Приложение подписано ad-hoc (не нотаризовано), поэтому при первом запуске:
правый клик по приложению → **Открыть**.

## Сборка из исходников

```bash
./build.sh                                # соберёт dist/HeatControl.app
cp -R dist/HeatControl.app /Applications/ # установить
open /Applications/HeatControl.app
```

Иконка-пламя появится в правом верхнем углу menu bar.

## Как это работает

| Что | Как |
|---|---|
| Энергия процессов | CPU-время всех процессов через `libproc` (`proc_pid_rusage`), дельты по кольцевой истории снапшотов → среднее за окно |
| Группировка | `responsibility_get_pid_responsible_for_pid` — тот же механизм, что у Activity Monitor |
| Температура CPU | HID-сенсоры SoC (`IOHIDEventSystemClient`, usage page `0xff00`) — датчики `PMU tdie*` |
| Температура GPU | SMC-ключи `Tg*` через `AppleSMC` |
| Загрузка CPU | `host_statistics` |

Утилита сама потребляет ~0.1% CPU и не требует root.

## Диагностика

```bash
.build/release/HeatControl --probe     # все сенсоры + топ процессов в терминал
.build/release/HeatControl --snapshot  # рендер панели в PNG без показа окна
```

Переключить плавающую панель извне (для Shortcuts / скриптов):

```bash
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.arrivarus.heatcontrol.togglePanel"), object: nil, userInfo: nil, deliverImmediately: true)'
```

## Ограничения

- «Энергия» считается по CPU-времени — основному фактору нагрева. GPU/диск/сеть
  в метрику не входят (их честный учёт требует root, как `powermetrics`).
- `kernel_task` не показывается (ядро не отдаёт rusage обычному процессу).
  Если греется именно он — это троттлинг, смотри на температуры.
- Температурные API приватные (HID/SMC) — имена датчиков подобраны под Apple Silicon
  (проверено на M4 Max); на других чипах CPU/GPU определяются паттернами с фолбэками.
- Системные процессы других пользователей убить нельзя — утилита честно скажет
  «No permission».

## Лицензия

MIT © 2026 [Alex Kovalev](https://github.com/ArrivaRUS)

---
*Swift + SwiftUI, без зависимостей. Сделано с Claude.*
