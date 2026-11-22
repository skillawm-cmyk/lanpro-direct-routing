# LANPRO Direct Routing

Один [список доменов](stash/direct-rules.yaml) для Mihomo на Windows и Stash. Зоны `.ru` и `.su`, LANPRO, Maily, AI-OS и отдельные домены из списка используют `DIRECT`. Для остальных соединений, которые обрабатывает профиль, конечное правило `MATCH,USA-SOCKS` не имеет прямого резерва: при отказе SOCKS соединение не открывается.

Правила работают по доменам, а не по общим IP CDN. Никаких записей в системный `hosts`, постоянных маршрутов, фоновых заданий или запуска скачанных скриптов с правами администратора. Профиль Mihomo включает TUN для трафика приложений на время работы ядра; это не системный kill switch при остановке Mihomo.

## Второй Windows

1. Возьмите [официальный Mihomo v1.19.34](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.34) для архитектуры компьютера. Сверьте `Get-FileHash -Algorithm SHA256 <архив>` перед распаковкой: x64 compatible `cd6738d4648cc1a5f48049a1343b697ab510889d648f045c5c780fc1ab443a79`, ARM64 `076cb04a21377675bcf009b8d1dd83006ce2464aa537e37bce1faf6d3504f554`.
2. В обычном PowerShell, в каталоге этого репозитория, подготовьте профиль. Введите Tailscale IPv4 вашего USA-SOCKS, а не публичный IP сервера. По умолчанию порт `1080`.

   ```powershell
   $Socks = Read-Host 'Tailscale IPv4 of USA-SOCKS'
   powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\windows\New-DirectProfile.ps1 -SocksAddress $Socks
   ```

3. В PowerShell **от имени администратора под тем же пользователем**, в каталоге распакованного Mihomo, выполните проверку и запуск. Это единственный шаг, которому нужны права администратора для TUN.

   ```powershell
   $homeDir = Join-Path $env:LOCALAPPDATA 'LANPRO-Mihomo'
   $core = (Get-ChildItem -File -Filter 'mihomo*.exe' | Select-Object -First 1).FullName
   if (-not $core) { throw 'Open the folder containing the verified Mihomo executable.' }
   $config = Join-Path $homeDir 'config.json'
   & $core -t -d $homeDir -f $config
   if ($LASTEXITCODE -ne 0) { throw 'Mihomo did not validate the profile.' }
   & $core -d $homeDir -f $config
   ```

При первом обращении через `USA-SOCKS` Mihomo покажет ссылку входа Tailscale. Войдите в тот же Tailnet и одобрите устройство, если это требует ваша политика. Отдельная установка Tailscale не нужна для этого профиля: Tailnet встроен в Mihomo и используется как транспорт к SOCKS. Не включайте отдельный Tailscale Exit Node, другой VPN или системный прокси поверх этого профиля: они могут перехватить прямой маршрут или создать петлю.

**Проверка на ПК.** Откройте `https://lanpro.uz/` и `https://example.com/`; в окне Mihomo первый должен показать `DIRECT`, второй `USA-SOCKS`. Сравните внешний IP на обоих выходах, если уже пользуетесь доверенным сервисом проверки адреса. Если `USA-SOCKS` недоступен, сначала проверьте вход и доступ Tailnet к SOCKS. Не выбирайте в клиенте режим Global или Direct. Этот SOCKS-профиль не пересылает UDP; приложения без TCP-резерва могут не работать для проксируемых адресов. Для отката закройте Mihomo через `Ctrl+C`.

## Stash

Добавьте `lanpro-direct` из [фрагмента профиля](stash/config-snippet.yaml) и поставьте `RULE-SET,lanpro-direct,DIRECT` перед `MATCH,USA-SOCKS`. Фрагмент дополняет существующий `USA-SOCKS`, не переопределяет его. Объединяйте секции `dns`, `rules` и `rule-providers` с существующими, не создавая дубликатов YAML-ключей. Для DNS Stash использует прямые запросы при `follow-rule: false`; это касается и DNS-запросов проксируемых сайтов, но не их соединений. В Windows-профиле выше DNS по умолчанию идёт через SOCKS, а для выбранных доменов задан отдельный прямой DoH.

## Обновления и старый установщик

Меняйте только `stash/direct-rules.yaml`. Клиенты запрашивают обновление каждые 30 минут. Windows-профиль начинает с локальной копии и обновляет её через `USA-SOCKS`; без доступного сервера новая версия не загрузится. Не публикуйте в этом репозитории IP Tailnet, ключи, ссылки входа или папку состояния Mihomo.

Старые `install-windows.ps1` и `install-macos.sh` выведены из эксплуатации. Если старый установщик уже выполнялся, не запускайте скачанное ранее удаление: оно не различало свои и пользовательские маршруты. Перед переходом отдельно проверьте, есть ли задача `LANPRO Direct Routing` (`Get-ScheduledTask -TaskName 'LANPRO Direct Routing' -ErrorAction SilentlyContinue`) или macOS LaunchDaemon `uz.lanpro.direct-routing`. Не удаляйте вручную добавленный маршрут LANPRO. Новый профиль их не меняет.
