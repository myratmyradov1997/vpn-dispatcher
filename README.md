# VPN-dispatcher

Menubar-утилита для macOS: живой статус своих серверов/VPN-нод прямо в строке
меню. Нативный Swift+AppKit, без зависимостей (только системные `ping`, `nc`,
`ifconfig`, `ipconfig`). Потребление CPU в покое < 1%.

```
🛰 🟢   ← техсостояние: 🟢 все отвечают / 🟠 часть / 🔴 никто
├ main — 69 мс · панель
├ innon — 44 мс · нода
└ …
  Проблемы: 1 — innon: диск / занят 92%
  Проверить серверы сейчас (health-check)
  Открыть: <панели из конфига>
  Открыть лог
  Закрыть
```

## Как работает

- Раз в 60 с — проба каждого сервера из конфига; клик по строке — мгновенный
  перепинг именно этого узла.
- **Проба идёт через реальный сетевой интерфейс** (`ipconfig getifaddr en*`,
  приоритет en0), а не через default route. Это принципиально: если на Mac
  работает TUN-VPN (WireGuard/Clash/Surge/Karing…), route default указывает на
  `utun*`, и ping/подключения **врут** — занесённые в тунель ответы возвращаются
  мгновенно (0.3 мс) независимо от того, жив ли хост. с bind к en0 показываются
  реальные миллисекунды.
- Если у узла закрыт ICMP (например, провайдер не пропускает echo) — фоллбэк:
  TCP-проверка ssh-порта 22 с привязкой источника к тому же en0 (`nc -s <ip> -z
  <host> 22`); в меню — «ssh ok».
- Пункт «Проверить сейчас» запускает внешний скрипт checker (`paths.checker`
  из конфига) и обновляет пункт «Проблемы», который в остальное время читает
  файл `problems`.

## Конфиг

`~/.config/vpn-dispatcher/config.json` (см. `config.example.json`):

| Поле | Описание |
|---|---|
| `servers[].{name,host,role}` | узлы для пробы |
| `panels[].{title,url}` | быстрые ссылки в меню |
| `paths.{log,problems,checker}` | лог/файл-проблем/скрипт health-check |

Если конфига нет — показывает placeholder (`example.com`).

## Сборка

```bash
./build.sh
open ~/Applications/VPNDispatcher.app
```

Автозагрузка при логине — LaunchAgent `~/Library/LaunchAgents/ru.myrat.vpn-dispatcher.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist …>
<plist version="1.0"><dict>
  <key>Label</key><string>ru.myrat.vpn-dispatcher</string>
  <key>ProgramArguments</key>
  <array><string>ПУТЬ/К/VPNDispatcher.app/Contents/MacOS/VPNDispatcher</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
```

Перезапуск: `launchctl kickstart -k gui/$(id -u)/ru.myrat.vpn-dispatcher`.

## Подводный камень сборки

Свежий Swift-инструментарий без `-target` пишет в бинарник `LC_BUILD_VERSION
minos 28.0` — тогда LaunchServices отказывается запускать app из Finder
(«Данная версия программы не может быть использована с этой версией macOS»),
хотя прямой запуск исполняемого файла работает. Явный
`-target arm64-apple-macos14.0` в `build.sh` это уже решает — не убирайте.
