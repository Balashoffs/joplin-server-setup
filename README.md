# Joplin Server на VPS — example.com

Self-hosted развёртывание [Joplin Server](https://github.com/laurent22/joplin/tree/dev/packages/server)
на VPS Ubuntu 22.04 с TLS через Let's Encrypt. Спроектировано как «хороший
сосед» для других веб-приложений на том же VPS — см. раздел
[Footprint на VPS](#footprint-на-vps).

**Дизайн-документ:** [`docs/superpowers/specs/2026-05-01-joplin-vps-deploy-design.md`](docs/superpowers/specs/2026-05-01-joplin-vps-deploy-design.md)

## Архитектура

```
[client https]──443──▶[nginx host]──127.0.0.1:22300──▶[joplin-app]──joplin_default──▶[joplin-db]
                          ▲
                          │ certbot.timer (systemd) — auto-renew Let's Encrypt
```

- nginx и certbot — нативно на хосте VPS;
- Joplin Server и PostgreSQL 16 — в Docker Compose (`name: joplin`);
- Joplin публикует порт только на `127.0.0.1:22300` (наружу не торчит);
- Postgres не публикует портов вовсе (только во внутренней docker-сети).

## Структура репозитория

```
.
├── docker-compose.yml            # стек (joplin-server + postgres)
├── .env.example                  # шаблон env-файла
├── .env                          # НЕ КОММИТИТСЯ — секреты, генерируется deploy.sh
├── nginx/
│   ├── example.com.conf # стартовый 80-блок (certbot достроит 443)
│   └── 00-default-fallback.conf  # default-сервер для неизвестных Host
├── scripts/
│   ├── bootstrap.sh              # подготовка VPS (root) — пакеты, Docker, UFW
│   ├── deploy.sh                 # первичный деплой (joplin) — стек + SSL
│   ├── backup.sh                 # ежедневный pg_dump
│   └── restore.sh                # восстановление из дампа
├── logrotate/
│   └── joplin-backup             # ротация /var/log/joplin-backup.log
└── docs/
    └── superpowers/specs/
        └── 2026-05-01-joplin-vps-deploy-design.md
```

## Развёртывание

### 1. Предусловия

- VPS на Ubuntu 22.04 (других версий не поддерживается).
- DNS A-запись `example.com → <IP VPS>` уже создана и распространилась.
- SSH-доступ root (или sudo).
- Клонированный репозиторий на локальной машине.

### 2. Залить проект на VPS

С локальной машины. Подставьте свой SSH-порт, путь к ключу, имя пользователя
и IP/домен VPS:

```bash
SSH_PORT=2222                         # ← ваш нестандартный SSH-порт
SSH_KEY="$HOME/.ssh/id_ed25519"       # ← путь к приватному ключу
VPS_USER=ubuntu                       # ← ваш пользователь на VPS
VPS_HOST=example.com         # ← IP или домен VPS

rsync -av --exclude='.git' --exclude='data/' \
  -e "ssh -p ${SSH_PORT} -i ${SSH_KEY}" \
  ~/Documents/joplin/ \
  "${VPS_USER}@${VPS_HOST}:/tmp/joplin-bootstrap/"
```

Альтернатива — настроить алиас в `~/.ssh/config`:

```sshconfig
Host joplin-vps
    HostName example.com
    User ubuntu
    Port 2222
    IdentityFile ~/.ssh/id_ed25519
```

…тогда команда упрощается:

```bash
rsync -av --exclude='.git' --exclude='data/' \
  ~/Documents/joplin/ \
  joplin-vps:/tmp/joplin-bootstrap/
```

### 3. Первичная подготовка хоста (root)

На VPS:

```bash
sudo mv /tmp/joplin-bootstrap/ /opt/joplin
cd /opt/joplin

# ВАЖНО: откройте scripts/bootstrap.sh и поправьте SSH_PORT,
# если у вас не дефолтный 22.
sudo nano scripts/bootstrap.sh

sudo ./scripts/bootstrap.sh
```

Скрипт:
- проверит, что ОС = Ubuntu 22.04;
- определит фактический порт sshd через `ss -tlnp` и сравнит с `SSH_PORT`
  (защита от self-lockout);
- доустановит недостающие пакеты, Docker Engine + compose plugin;
- создаст пользователя `joplin` и каталоги `/opt/joplin`, `/var/backups/joplin`,
  `/var/www/certbot`. При первичном создании генерирует пароль для `joplin`
  и сохраняет его в `/root/joplin-password.txt` (`0600`, владелец root).
  Повторный запуск пароль не перетирает;
- добавит `joplin` в группу `docker` и установит `/etc/sudoers.d/joplin`
  (`NOPASSWD: ALL`) — `deploy.sh` запускается от joplin и вызывает sudo
  для nginx/certbot/crontab. Реальных прав не повышает: членство в `docker`
  и так эквивалентно root через привилегированный контейнер;
- настроит UFW (если не активен — включит с deny incoming; если активен —
  только добавит правила SSH/80/443 без смены дефолтов).

После завершения смените владельца проекта:

```bash
sudo passwd joplin
su joplin
sudo chown -R joplin:joplin /opt/joplin
```

### 4. Первичный деплой стека (от пользователя joplin)

**Перед запуском проверьте NTP.** Joplin Server при старте сверяет системное
время с NTP, и если сервер недоступен, контейнер уходит в бесконечный
restart-loop с ошибкой `Cannot retrieve the network time`. Многие VPS-провайдеры
блокируют UDP/123 на публичные NTP вроде `pool.ntp.org` — поэтому в `.env.example`
по умолчанию указан NTP, разрешённый провайдером HostKey:

```bash
# Проверка, что NTP из .env достижим с VPS
sudo apt-get install -y ntpdate >/dev/null
NTP_HOST=$(awk -F'[=:]' '/^NTP_SERVER/{print $2}' /opt/joplin/.env)
sudo ntpdate -q "$NTP_HOST"
# Ожидается строка "adjust time server X.X.X.X offset ..."
```

Если провайдер другой — возьмите имя живого NTP из вывода
`chronyc sources` (status `^*`) или `/etc/chrony/chrony.conf` и поправьте
`NTP_SERVER` в `/opt/joplin/.env` до запуска `deploy.sh`. Запуск:

```bash
sudo -u joplin bash -lc 'cd /opt/joplin && ./scripts/deploy.sh'
```

При первом запуске скрипт спросит email для Let's Encrypt. После завершения:

- стек поднят (`docker compose ps`);
- nginx-конфиг установлен в `/etc/nginx/sites-available/`, симлинк в `sites-enabled/`;
- сертификат выпущен (`certbot certificates`);
- установлен **default-fallback** для запросов с неизвестным `Host:` —
  отдаёт стандартную nginx welcome-страницу. Использует тот же сертификат
  (браузер увидит CN-mismatch при заходе на чужой домен — это ожидаемо).
  Стандартный Ubuntu `sites-enabled/default` отключается (файл в
  `sites-available/default` остаётся, можно вернуть);
- cron-задача бэкапа в `crontab -u joplin -l`;
- logrotate-конфиг в `/etc/logrotate.d/joplin-backup`.

### 5. Настройка Joplin

Откройте `https://example.com` — войдите как:

```
admin@localhost / admin
```

**Немедленно** смените email и пароль администратора (профиль → Change password / Email).
Затем создайте обычных пользователей для синхронизации.

### 6. (опционально) Включить HSTS

Только после того как убедились, что HTTPS работает корректно. Простейший
способ — `sudoedit`:

```bash
sudoedit /etc/nginx/sites-available/example.com.conf
# В блоке `server { listen 443 ssl; ... }` добавьте строку:
#   add_header Strict-Transport-Security "max-age=31536000" always;
sudo nginx -t && sudo systemctl reload nginx
```

HSTS на год — необратимо в браузерах клиентов; включайте только когда
уверены в SSL-конфигурации.

## Эксплуатация

### Бэкапы

Автоматически: cron `joplin` запускает `backup.sh` каждый день в 03:17.
Хранение: 7 ежедневных + 4 еженедельных (воскресные копии с префиксом
`weekly-`). Лог: `/var/log/joplin-backup.log` (ротация через logrotate).

Ручной бэкап:
```bash
sudo -u joplin /opt/joplin/scripts/backup.sh
ls -lh /var/backups/joplin/
```

### Восстановление

```bash
sudo -u joplin /opt/joplin/scripts/restore.sh \
  /var/backups/joplin/joplin-2026-05-01_0317.dump.gz
```

Скрипт интерактивно требует подтверждения. **Уничтожает текущие данные.**

Перед DROP схемы скрипт автоматически снимает safety-дамп в
`/var/backups/joplin/pre-restore-<timestamp>.dump.gz` (его путь печатается
в конце). Скрипт берёт тот же `flock` что и `backup.sh`, поэтому с cron
не пересечётся (в случае коллизии — ждёт окончания бэкапа).

При ошибке посередине БД остаётся в полу-восстановленном состоянии.
ERR-trap пытается поднять `app` обратно. Re-run с тем же дампом (или
с safety-дампом) безопасен — `DROP SCHEMA public CASCADE; CREATE SCHEMA public;`
сбрасывает любое промежуточное состояние.

### Обновление версии Joplin Server

```bash
# 1. Бэкап перед апгрейдом
sudo -u joplin /opt/joplin/scripts/backup.sh

# 2. Сверьтесь с changelog
# https://github.com/laurent22/joplin/releases
# и hub.docker.com/r/joplin/server/tags

# 3. Обновите тег в .env
sudo -u joplin nano /opt/joplin/.env  # JOPLIN_VERSION=...

# 4. Применить
cd /opt/joplin
sudo -u joplin docker compose pull
sudo -u joplin docker compose up -d

# 5. Проверка
curl -fsS https://example.com/api/ping
```

Никаких автоматических обновлений — всё руками после прочтения changelog.

### Просмотр логов

```bash
cd /opt/joplin
sudo -u joplin docker compose logs -f app
sudo -u joplin docker compose logs -f db
sudo tail -f /var/log/joplin-backup.log
```

### Где секреты и cron-задача

`POSTGRES_PASSWORD` хранится в `/opt/joplin/.env` (mode `0600`, владелец `joplin`).
Прямой доступ к БД для отладки:

```bash
cd /opt/joplin
sudo -u joplin bash -c 'set -a; source .env; set +a; \
  docker compose exec -e PGPASSWORD="$POSTGRES_PASSWORD" db \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

Cron-задача бэкапа (просмотр):

```bash
sudo crontab -u joplin -l
# Ожидается одна строка:
# 17 3 * * * /opt/joplin/scripts/backup.sh >> /var/log/joplin-backup.log 2>&1
```

## Footprint на VPS

Что стек создаёт и где:

| Путь / ресурс | Создаётся | Назначение |
|---|---|---|
| `/opt/joplin/` | bootstrap + deploy | код, `.env`, `data/postgres/` |
| `/var/backups/joplin/` | bootstrap | дампы pg_dump |
| `/var/log/joplin-backup.log` | первый запуск backup.sh | лог бэкапов |
| `/etc/nginx/sites-available/example.com.conf` + симлинк в `sites-enabled/` | deploy | конфиг nginx |
| `/etc/nginx/sites-available/00-default-fallback.conf` + симлинк в `sites-enabled/` | deploy | default-сервер для неизвестных Host (welcome-страница) |
| `/etc/nginx/sites-enabled/default` (Ubuntu) | удаляется deploy | заменён нашим fallback; файл `sites-available/default` остаётся |
| `/etc/letsencrypt/live/example.com/` | certbot | сертификат |
| `/etc/letsencrypt/renewal/example.com.conf` | certbot | конфиг автообновления |
| crontab пользователя `joplin` | deploy | задача backup.sh |
| `/etc/logrotate.d/joplin-backup` | deploy | ротация логов |
| Системный пользователь `joplin` (uid auto), группа `docker` | bootstrap | владелец стека |
| `/etc/sudoers.d/joplin` | bootstrap | `NOPASSWD: ALL` для пользователя joplin |
| `/root/joplin-password.txt` | bootstrap (первый запуск) | пароль пользователя joplin (`0600`, root) |
| UFW-правила: SSH-порт, 80/tcp, 443/tcp | bootstrap | firewall |
| TCP `127.0.0.1:22300` | docker compose | публикуемый порт Joplin |

Чужие конфиги (`/etc/nginx/sites-enabled/default`, другие compose-проекты,
Docker-сети других стеков) — **не трогаются.**

## Удаление стека

```bash
# 1. Снять стек
cd /opt/joplin
sudo -u joplin docker compose down -v

# 2. Удалить данные и код
# ВНИМАНИЕ: эта команда удалит все исторические дампы. Если хотите их сохранить —
# пропустите /var/backups/joplin (или скопируйте куда-то заранее).
sudo rm -rf /opt/joplin /var/backups/joplin /var/log/joplin-backup.log

# 3. Снять nginx-конфиг + default-fallback
sudo rm -f /etc/nginx/sites-enabled/example.com.conf
sudo rm -f /etc/nginx/sites-available/example.com.conf
sudo rm -f /etc/nginx/sites-enabled/00-default-fallback.conf
sudo rm -f /etc/nginx/sites-available/00-default-fallback.conf
# (опционально) вернуть стандартный Ubuntu default:
[ -f /etc/nginx/sites-available/default ] && \
    sudo ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
sudo systemctl reload nginx

# 4. Удалить сертификат
sudo certbot delete --cert-name example.com

# 5. Удалить cron-задачу
sudo crontab -u joplin -e   # удалить строку с backup.sh

# 6. Удалить logrotate-конфиг
sudo rm -f /etc/logrotate.d/joplin-backup

# 7. (опционально) Удалить пользователя, его sudoers-правило и файл с паролем
sudo rm -f /etc/sudoers.d/joplin /root/joplin-password.txt
sudo userdel -r joplin
```

Пакеты (docker, nginx, certbot, ufw) и UFW-правила 80/443 **не удаляются** —
могут быть нужны другим приложениям.

## Чек-лист приёмки

После первого деплоя:

- [ ] `https://example.com` открывается в браузере, загружается web UI Joplin
- [ ] `curl -fsS https://example.com/api/ping` возвращает 200
- [ ] `curl -sI http://example.com/ | head -1` показывает `301 Moved Permanently`
- [ ] [SSL Labs](https://www.ssllabs.com/ssltest/) для домена показывает A или выше
- [ ] `sudo certbot certificates` показывает expiry > 60 дней
- [ ] `systemctl list-timers | grep certbot` — таймер активен
- [ ] `sudo ufw status verbose` — активен, в правилах SSH, 80, 443
- [ ] Дефолтные креды `admin@localhost` / `admin` сменены через web UI
- [ ] Joplin desktop клиент подключается и синхронизирует тестовую заметку
- [ ] `sudo -u joplin /opt/joplin/scripts/backup.sh` работает, в `/var/backups/joplin/` появляется свежий `.dump.gz`, `gunzip -t` проходит
- [ ] `docker compose down && docker compose up -d` — стек переподнимается без потери данных
