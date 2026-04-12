# Nebula Gateway OneClick

One-click оркестратор развёртывания VPN/anti-censorship стека по SSH.

Поддерживаются два режима:
- `single` — классический деплой одного NL gateway (выбор primary транспорта: `vless` или `naiveproxy`) + Hysteria2 + MTProxy
- `chain` — цепочка `Home -> NL` на VLESS (Home как bridge, NL как exit через x-ui inbound `xhttp+packet-up`)

## Что поднимает проект

### `single` mode
- primary transport (выбирается через `SINGLE_TRANSPORT`):
  - `vless`: `Xray VLESS + Reality` на `TCP 443`
  - `naiveproxy`: `Caddy forwardproxy (naive)` на `TCP 8443` (+ `TCP 80` для ACME)
- `Hysteria2` на `UDP 443`
- `MTProxy (FakeTLS)` на `TCP 7443`
- опционально `Happ/Voxi-compatible subscription feed`

### `chain` mode
- на `HOME` сервере:
  - обновляет Xray-конфиг bridge-узла,
  - сохраняет текущую identity `phone-in` (UUID при `CHAIN_KEEP_HOME_CLIENT_UUID=1`),
  - настраивает outbound `to-nl` как `vless + reality + xhttp(packet-up)`,
  - включает full tunnel для клиентского входа (`phone-in -> to-nl`) c тех-исключениями (`localhost/private/tailscale`),
  - выполняет smoke через локальный `socks`.
- на `EXIT (NL)` сервере:
  - ничего не перезаписывает,
  - только read-only проверяет x-ui inbound по `CHAIN_XUI_INBOUND_REMARK`.

## Структура репозитория

- `deploy.py` — локальный кроссплатформенный оркестратор
- `scripts/rebuild_nl_gateway.sh` — удалённый bootstrap для `single`
- `scripts/rebuild_home_chain_bridge.sh` — удалённый bootstrap для `chain` (HOME)
- `.env.example` — пример конфигурации
- `requirements.txt` — зависимости локального оркестратора

## Требования

- Локально: Python 3.9+
- На серверах: Linux + `systemd` + SSH доступ
- Для `single` нужны открытые порты на NL VPS: `443/TCP`, `443/UDP`, `7443/TCP`
- Для `chain`:
  - HOME должен быть доступен извне по клиентскому порту (обычно `443/TCP`),
  - на EXIT в x-ui должен существовать отдельный inbound с `network=xhttp`, `xhttpSettings.mode=packet-up` и отдельным портом (не `443`),
  - inbound remark по умолчанию: `HOME-CHAIN-XHTTP`.

## Быстрый старт

1. Скопируй `.env.example` в `.env` (опционально).
2. Выбери режим через `DEPLOY_MODE=single|chain`.
3. Запусти:

```bash
python deploy.py
```

Если обязательных полей не хватает и есть TTY, `deploy.py` спросит их интерактивно.

После выполнения:
- лог идёт в консоль,
- summary-файл скачивается в `LOCAL_ARTIFACTS_DIR` (`./artifacts` по умолчанию).

## Настройка `.env`

### Общие
- `DEPLOY_MODE=single|chain`
- `AUTO_INSTALL_PARAMIKO=1`
- `LOCAL_ARTIFACTS_DIR=./artifacts`

### `single` mode (legacy)
- SSH: `SSH_HOST`, `SSH_USER`, `SSH_PASSWORD|SSH_PRIVATE_KEY`
- опционально: `SUDO_PASSWORD`, `REMOTE_SCRIPT_PATH`
- выбор primary транспорта:
  - `SINGLE_TRANSPORT=vless|naiveproxy`
- параметры для `vless`:
  - `VLESS_UUID`, `REALITY_*`, `HY2_*`, `MTPROXY_*`
- параметры для `naiveproxy`:
  - `NAIVE_DOMAIN`, `NAIVE_PORT`, `NAIVE_USER`, `NAIVE_PASS`, `NAIVE_EMAIL`, `NAIVE_UPSTREAM`
  - если `NAIVE_DOMAIN` пуст, скрипт сгенерирует случайный `*.sslip.io`
- optional подписка: `HAPP_*`
- optional backup hooks: `SKIP_PREFLIGHT_BACKUP`, `RESTIC_*`, `BORG_*`

### `chain` mode
- HOME SSH:
  - `HOME_SSH_HOST`, `HOME_SSH_USER`, `HOME_SSH_PASSWORD|HOME_SSH_PRIVATE_KEY`
- EXIT SSH:
  - `EXIT_SSH_HOST`, `EXIT_SSH_USER`, `EXIT_SSH_PASSWORD|EXIT_SSH_PRIVATE_KEY`
- EXIT precheck (x-ui):
  - `CHAIN_EXIT_PROVIDER=xui`
  - `CHAIN_XUI_DB_PATH=/etc/x-ui/x-ui.db`
  - `CHAIN_XUI_INBOUND_REMARK=HOME-CHAIN-XHTTP`
- chain transport contract:
  - `CHAIN_XHTTP_MODE=packet-up`
  - `CHAIN_XHTTP_PATH=/`
- behavior toggles:
  - `CHAIN_FULL_TUNNEL=1`
  - `CHAIN_KEEP_HOME_CLIENT_UUID=1`

## Подробный сценарий `deploy.py`

### `single`
1. Читает `.env`, валидирует SSH.
2. Загружает `scripts/rebuild_nl_gateway.sh` на target.
3. Пробрасывает single-переменные в окружение удалённого скрипта (включая `SINGLE_TRANSPORT`).
4. Запускает provisioning под `root/sudo`.
5. Скачивает summary.

### `chain`
1. Читает `.env`, валидирует SSH для `HOME` и `EXIT`.
2. Подключается к `EXIT` и делает read-only проверку x-ui inbound:
   - remark совпадает,
   - `network=xhttp`, `security=reality`,
   - `xhttpSettings.mode=packet-up`,
   - путь совпадает,
   - порт выделенный (не `443`),
   - есть usable client UUID,
   - из private key выводится public key для outbound bridge.
3. Загружает `scripts/rebuild_home_chain_bridge.sh` на `HOME`.
4. Пробрасывает chain-параметры (полученные из EXIT + `.env`) в HOME-скрипт.
5. Применяет HOME bridge-конфиг, делает smoke, скачивает summary.

## Важные замечания

- `chain` режим специально не перезаписывает x-ui DB/конфиги на EXIT.
- Если precheck EXIT не проходит — deploy завершится ошибкой до изменений на HOME.
- Для прод-использования фиксируй доступ по SSH-ключам.
- Для Windows запуск обычно: `py deploy.py`.

## Пример запуска с явным env

```bash
ENV_FILE=/absolute/path/to/.env python deploy.py
```

## Локальная проверка синтаксиса

```bash
python -m py_compile deploy.py
bash -n scripts/rebuild_nl_gateway.sh
bash -n scripts/rebuild_home_chain_bridge.sh
```
