# LANPRO Direct Routing

Централизованный список сайтов, которые должны идти напрямую, даже когда включён VPN. Остальной трафик продолжает идти по последнему правилу `MATCH,USA-SOCKS`.

## Что включено

- Все домены зон `.ru` и `.su` через `DOMAIN-SUFFIX`.
- Правила Bitrix24, CiscoShop, банки, Avito, Ozon, Госуслуги, LovePlanet и parking.mos.ru.
- Yandex, МойСклад, Timeweb, S4B, Контур, IHC, TeraPC, Goofish, WeChat и Dzen.
- Фиксированные прямые маршруты из активного профиля v2RayTun/Stash, включая LANPRO.
- Автоматическая синхронизация на Windows и macOS каждые 30 минут.

Главный файл для добавления сайтов: [`direct-sites.json`](direct-sites.json). После изменения нужно синхронно обновить `stash/direct-rules.yaml`; тест не позволит опубликовать рассинхронизированные файлы.

## Подключение Stash / Mihomo

Добавьте блоки из [`stash/config-snippet.yaml`](stash/config-snippet.yaml) в профиль. Правило

```yaml
- RULE-SET,lanpro-direct,DIRECT
```

должно находиться выше `MATCH,USA-SOCKS`. Stash обновляет список каждые 1800 секунд без ручного редактирования профиля.

## Windows

Откройте PowerShell от имени администратора:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/skillawm-cmyk/lanpro-direct-routing/main/install-windows.ps1 -OutFile $env:TEMP\install-lanpro-routing.ps1
powershell -ExecutionPolicy Bypass -File $env:TEMP\install-lanpro-routing.ps1
```

Команды после установки:

```powershell
& "$env:ProgramData\LanproDirectRouting\direct-sites.ps1" status
& "$env:ProgramData\LanproDirectRouting\direct-sites.ps1" sync
& "$env:ProgramData\LanproDirectRouting\direct-sites.ps1" test lanpro.uz
& "$env:ProgramData\LanproDirectRouting\direct-sites.ps1" uninstall
```

## macOS

```bash
curl -fL https://raw.githubusercontent.com/skillawm-cmyk/lanpro-direct-routing/main/install-macos.sh -o /tmp/install-lanpro-routing.sh
sudo sh /tmp/install-lanpro-routing.sh
```

Команды после установки:

```bash
sudo "/Library/Application Support/LanproDirectRouting/direct-sites.sh" sync
"/Library/Application Support/LanproDirectRouting/direct-sites.sh" status
"/Library/Application Support/LanproDirectRouting/direct-sites.sh" test lanpro.uz
sudo "/Library/Application Support/LanproDirectRouting/direct-sites.sh" uninstall
```

## Как добавить сайт

1. Добавьте правило в `rules` файла `direct-sites.json`.
2. Добавьте соответствующую строку без `,DIRECT` в `stash/direct-rules.yaml`.
3. Для сервера с постоянным IP при необходимости добавьте запись в `fixed_routes`.
4. Запустите `bash tests/validate-config.sh && bash tests/package-check.sh`.

Клиенты полностью проверяют новый JSON до применения. При ошибке или недоступности GitHub используется последняя корректная копия.
