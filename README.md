# 🔥 System Control

*by Alex Kovalev*

[![Release](https://img.shields.io/github/v/release/ArrivaRUS/SystemControl?color=ff6b2c)](https://github.com/ArrivaRUS/SystemControl/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20Silicon-lightgrey)

Нативная menu bar утилита для macOS: показывает, **кто жрёт энергию и греет MacBook**, температуры CPU/GPU — и позволяет прибить виновника в один клик.

| Энергия | Батарея |
|---|---|
| ![Главная панель](assets/preview_main.png) | ![Батарея](assets/preview_battery.png) |

## Возможности

- **Топ энергопрожорливых процессов и приложений** — потребление CPU усредняется
  за выбранное окно (**10 / 30 секунд / 1 минута**, по умолчанию 30 секунд),
  поэтому список не прыгает, как в Activity Monitor, а показывает,
  кто реально грел машину в последнее время.
- **Группировка по приложениям** — хелперы Chrome/Safari и т.п. собираются под родительское
  приложение (как в Activity Monitor), либо режим плоского списка процессов (Apps / Procs).
- **Kill в один клик** — наведи на строку → крестик → `Quit` (вежливый terminate / SIGTERM)
  или `Force` (SIGKILL).
- **Температуры CPU и GPU** с кольцевыми гейджами и спарклайнами истории.
  Цвет меняется от мятного (прохладно) до малинового (критично).
- **Загрузка CPU и GPU на одном сдвоенном индикаторе** — внешнее кольцо CPU,
  внутреннее GPU, с общей историей.
- **Живой статус прямо в menu bar**: температура CPU, а на внешнем питании —
  мощность, потребляемая от адаптера (⚡96W). Каждый элемент отключается
  в настройках.
- **Режим "поверх всех окон"** — кнопка 📌 открепляет панель в плавающее окошко,
  которое висит над всеми окнами и во всех Spaces. Закрыть — Esc или 📌.
- **Вкладка Battery** — здоровье и использование батареи в духе coconutBattery:
  заряд, здоровье (фактическая/проектная ёмкость), циклы, температура батареи,
  напряжение и ток, мощность батареи со знаком, реальное потребление системы
  (из телеметрии SMC), прогноз времени работы при текущей нагрузке, параметры
  адаптера питания, дата производства и производитель ячеек, серийник.
- **Автозапуск при логине**, настройка частоты обновления (1/2/5/10 с).
- **Полный список термосенсоров** (сотни датчиков SoC) — в настройках.

## Скачать

**[SystemControl-1.1.0.dmg](https://github.com/ArrivaRUS/SystemControl/releases/latest)** —
открыть образ и перетащить `System Control` в `Applications`.

Приложение подписано ad-hoc (не нотаризовано), поэтому при первом запуске:
правый клик по приложению → **Открыть**.

Сборка DMG из исходников: `./build.sh && scripts/make_dmg.sh`.

## Сборка из исходников

```bash
./build.sh                                # соберёт "dist/System Control.app"
cp -R "dist/System Control.app" /Applications/ # установить
open "/Applications/System Control.app"
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
| Загрузка GPU | `IOAccelerator` → `PerformanceStatistics` («Device Utilization %») |
| Батарея | реестр `AppleSmartBattery` (ёмкости, циклы, электрика, телеметрия, адаптер) |

Утилита сама потребляет ~0.1% CPU и не требует root.

## Диагностика

```bash
.build/release/SystemControl --probe     # все сенсоры + топ процессов в терминал
.build/release/SystemControl --snapshot  # рендер панели в PNG без показа окна
```

Переключить плавающую панель извне (для Shortcuts / скриптов):

```bash
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.arrivarus.systemcontrol.togglePanel"), object: nil, userInfo: nil, deliverImmediately: true)'
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
