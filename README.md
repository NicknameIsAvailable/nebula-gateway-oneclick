# Nebula Gateway OneClick

One-click разворачивание VPN/anti-censorship шлюза на удалённом сервере по SSH.

Проект поднимает **три независимых транспорта**:
- `Xray VLESS + Reality` на `TCP 443`
- `Hysteria2` на `UDP 443`
- `MTProxy (FakeTLS)` на `TCP 7443`

Опционально можно включить **Happ/Voxi-compatible subscription feed**:
- токенизированная `txt/json` подписка,
- отдельный HTTP feed-сервис (`systemd`) на настраиваемом порту.

Цель: иметь устойчивый доступ, даже если один из транспортов/ASN режется.

## Структура репозитория

- `deploy.py` — локальный кроссплатформенный оркестратор (запускается у пользователя на ПК)
- `scripts/rebuild_nl_gateway.sh` — удалённый bootstrap-скрипт (выполняется на VPS)
- `.env.example` — пример конфигурации
- `requirements.txt` — зависимости локального оркестратора

## Требования

- Локально: Python 3.9+
- На сервере: Linux + `systemd` + `sudo`/`root` доступ + интернет
- Открытые порты на VPS: `443/TCP`, `443/UDP`, `7443/TCP`
- Если включаешь `HAPP_COMPAT_MODE=1`: дополнительно открой `HAPP_SUBSCRIPTION_PORT/TCP` (по умолчанию `18080`).

## Поддержка дистрибутивов

Скрипт пытается работать на популярных Linux-дистрибутивах (best-effort):
- Ubuntu / Debian (`apt`)
- Fedora / RHEL / Alma / Rocky (`dnf`/`yum`)
- Arch (`pacman`)
- openSUSE (`zypper`)

Проверено руками на:
- **Ubuntu 24.04** (эталонная среда)

Если на твоём дистрибутиве что-то не взлетело:
- сделай патч и закинь PR,
- мы посмотрим и вольём качественные изменения.

## Быстрый старт (Windows / macOS / Linux)

1. Скопируй `.env.example` в `.env` (опционально).
2. Запусти:

```bash
python deploy.py
```

Если `.env` пустой/неполный, скрипт сам спросит нужные параметры в начале.

После выполнения:
- в консоли будут выведены клиентские URI/ссылки,
- локально появится файл с итоговыми параметрами в `./artifacts`.

## Настройка `.env`

### Обязательные

- `SSH_HOST` — IP/домен VPS
- `SSH_USER` — обычно `root`
- `SSH_PASSWORD` **или** `SSH_PRIVATE_KEY`

### Часто полезные

- `SUDO_PASSWORD` — нужен, если `SSH_USER` не `root`
- `AUTO_INSTALL_PARAMIKO=1` — автоустановка python-зависимости
- `LOCAL_ARTIFACTS_DIR=./artifacts` — куда сохранять итоговый отчёт
- `SKIP_PREFLIGHT_BACKUP=0` — запускать ли preflight backup перед изменениями

### Happ/Voxi-compatible layer (опционально)

- `HAPP_COMPAT_MODE=1` — включает генерацию подписочного feed
- `HAPP_PROFILE_NAME=nebula-gateway` — имя профиля в json
- `HAPP_SUBSCRIPTION_TOKEN=` — токен (если пусто, сгенерируется)
- `HAPP_SUBSCRIPTION_PORT=18080` — порт feed-сервиса
- `HAPP_SUBSCRIPTION_PATH=/sub/nebula` — путь подписки (без домена)
- `HAPP_PUBLIC_HOST=` — домен/IP для публичных URL (если пусто, используется обнаруженный IP сервера)
- `HAPP_PUSH_URL=` — optional webhook для синка со внешней панелью
- `HAPP_PUSH_AUTH_HEADER=` — optional auth header для webhook (например `Authorization: Bearer ...`)

### Для восстановления старых профилей (Disaster Recovery)

Если хочешь после переезда на новый VPS сохранить прежние клиентские профили, задай те же значения:
- `VLESS_UUID`
- `REALITY_PRIVATE_KEY`
- `REALITY_SHORT_ID`
- `HY2_PASSWORD`
- `MTPROXY_SECRET`

Если не задавать — значения будут сгенерированы заново.

### Preflight backup (опционально)

Перед изменениями серверный скрипт пытается сделать backup:
1. `restic` (если есть `RESTIC_REPOSITORY` + `RESTIC_PASSWORD`)
2. `borg` (если есть `BORG_REPO` + `BORG_PASSPHRASE`)
3. `timeshift` (если установлен и настроен)

Если подходящий backup tool не найден/не настроен, шаг будет пропущен с предупреждением.

## Подробный сценарий работы `deploy.py`

1. Читает `.env`.
2. Проверяет обязательные SSH параметры.
3. Устанавливает `paramiko` (если отсутствует и `AUTO_INSTALL_PARAMIKO=1`).
4. Подключается по SSH к VPS.
5. Загружает `scripts/rebuild_nl_gateway.sh` на VPS.
6. Выставляет исполняемые права скрипту.
7. Пробрасывает переменные из `.env` в окружение удалённого скрипта.
8. Запускает удалённый скрипт под `root`/`sudo`.
9. Потоково показывает лог выполнения в твоей локальной консоли.
10. На VPS удалённый скрипт:
    - определяет дистрибутив и пакетный менеджер,
    - пытается сделать preflight backup (best-effort),
    - ставит системные пакеты,
    - ставит Xray,
    - генерирует/восстанавливает Reality-ключи,
    - пишет конфиг Xray и стартует сервис,
    - ставит и настраивает Hysteria2,
    - собирает/настраивает MTProxy,
    - (опционально) поднимает Happ-compatible subscription feed,
    - включает автозапуск всех сервисов,
    - печатает клиентские ссылки.
11. `deploy.py` ищет путь к summary-файлу в выводе.
12. Скачивает summary-файл с VPS в локальную папку `artifacts`.
13. Завершает работу с кодом `0` при успехе.

## Важные замечания

- Скрипт рассчитан на **чистый/контролируемый VPS**. На сервере с уже установленным альтернативным VPN-стеком может быть конфликт портов.
- Если у провайдера/оператора режется конкретный ASN/IP, используй второй VPS и такой же деплой.
- После успешного деплоя рекомендуется сменить SSH-пароль и перейти на ключевую авторизацию.
- Для Windows запуск обычно: `py deploy.py` (если `python` не прописан в PATH).
- `HAPP_COMPAT_MODE` не является “официальной интеграцией VoxiProxy”, а совместимым слоем с подпиской/линками, который можно подключить к своему клиентскому флоу.
- В текущей версии подписка выдаётся по `http://` (без TLS). Для production лучше повесить её за reverse-proxy с HTTPS.

## Пример команды с явным env-файлом

```bash
ENV_FILE=/absolute/path/to/.env python deploy.py
```

## Локальная проверка синтаксиса

```bash
python -m py_compile deploy.py
bash -n scripts/rebuild_nl_gateway.sh
```
