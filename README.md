# Joplin Server на VPS — owl.hello-vanilla.ru

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
│   └── owl.hello-vanilla.ru.conf # стартовый 80-блок (certbot достроит 443)
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
- DNS A-запись `owl.hello-vanilla.ru → <IP VPS>` уже создана и распространилась.
- SSH-доступ root (или sudo).
- Клонированный репозиторий на локальной машине.

### 2. Залить проект на VPS

```bash
# с локальной машины
rsync -av --exclude='.git' --exclude='data/' \
  /Users/bau/Documents/joplin/ \
  user@VPS_IP:/tmp/joplin-bootstrap/
```

### 3. Первичная подготовка хоста (root)

На VPS:

```bash
sudo mv /tmp/joplin-bootstrap /opt/joplin
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
  `/var/www/certbot`;
- настроит UFW (если не активен — включит с deny incoming; если активен —
  только добавит правила SSH/80/443 без смены дефолтов).

После завершения смените владельца проекта:

```bash
sudo chown -R joplin:joplin /opt/joplin
```

### 4. Первичный деплой стека (от пользователя joplin)

```bash
sudo -u joplin bash -lc 'cd /opt/joplin && ./scripts/deploy.sh'
```

При первом запуске скрипт спросит email для Let's Encrypt. После завершения:

- стек поднят (`docker compose ps`);
- nginx-конфиг установлен в `/etc/nginx/sites-available/`, симлинк в `sites-enabled/`;
- сертификат выпущен (`certbot certificates`);
- cron-задача бэкапа в `crontab -u joplin -l`;
- logrotate-конфиг в `/etc/logrotate.d/joplin-backup`.

### 5. Настройка Joplin

Откройте `https://owl.hello-vanilla.ru` — войдите как:

```
admin@localhost / admin
```

**Немедленно** смените email и пароль администратора (профиль → Change password / Email).
Затем создайте обычных пользователей для синхронизации.

### 6. (опционально) Включить HSTS

Только после того как убедились, что HTTPS работает корректно:

```bash
sudo sed -i '/listen 443 ssl/a \    add_header Strict-Transport-Security "max-age=31536000" always;' \
  /etc/nginx/sites-available/owl.hello-vanilla.ru.conf
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
curl -fsS https://owl.hello-vanilla.ru/api/ping
```

Никаких автоматических обновлений — всё руками после прочтения changelog.

### Просмотр логов

```bash
cd /opt/joplin
sudo -u joplin docker compose logs -f app
sudo -u joplin docker compose logs -f db
sudo tail -f /var/log/joplin-backup.log
```

## Footprint на VPS

Что стек создаёт и где:

| Путь / ресурс | Создаётся | Назначение |
|---|---|---|
| `/opt/joplin/` | bootstrap + deploy | код, `.env`, `data/postgres/` |
| `/var/backups/joplin/` | bootstrap | дампы pg_dump |
| `/var/log/joplin-backup.log` | первый запуск backup.sh | лог бэкапов |
| `/etc/nginx/sites-available/owl.hello-vanilla.ru.conf` + симлинк в `sites-enabled/` | deploy | конфиг nginx |
| `/etc/letsencrypt/live/owl.hello-vanilla.ru/` | certbot | сертификат |
| `/etc/letsencrypt/renewal/owl.hello-vanilla.ru.conf` | certbot | конфиг автообновления |
| crontab пользователя `joplin` | deploy | задача backup.sh |
| `/etc/logrotate.d/joplin-backup` | deploy | ротация логов |
| Системный пользователь `joplin` (uid auto), группа `docker` | bootstrap | владелец стека |
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
sudo rm -rf /opt/joplin /var/backups/joplin /var/log/joplin-backup.log

# 3. Снять nginx-конфиг
sudo rm -f /etc/nginx/sites-enabled/owl.hello-vanilla.ru.conf
sudo rm -f /etc/nginx/sites-available/owl.hello-vanilla.ru.conf
sudo systemctl reload nginx

# 4. Удалить сертификат
sudo certbot delete --cert-name owl.hello-vanilla.ru

# 5. Удалить cron-задачу
sudo crontab -u joplin -e   # удалить строку с backup.sh

# 6. Удалить logrotate-конфиг
sudo rm -f /etc/logrotate.d/joplin-backup

# 7. (опционально) Удалить пользователя
sudo userdel -r joplin
```

Пакеты (docker, nginx, certbot, ufw) и UFW-правила 80/443 **не удаляются** —
могут быть нужны другим приложениям.

## Чек-лист приёмки

После первого деплоя:

- [ ] `https://owl.hello-vanilla.ru` открывается в браузере, загружается web UI Joplin
- [ ] `curl -fsS https://owl.hello-vanilla.ru/api/ping` возвращает 200
- [ ] `curl -sI http://owl.hello-vanilla.ru/ | head -1` показывает `301 Moved Permanently`
- [ ] [SSL Labs](https://www.ssllabs.com/ssltest/) для домена показывает A или выше
- [ ] `sudo certbot certificates` показывает expiry > 60 дней
- [ ] `systemctl list-timers | grep certbot` — таймер активен
- [ ] `sudo ufw status verbose` — активен, в правилах SSH, 80, 443
- [ ] Дефолтные креды `admin@localhost` / `admin` сменены через web UI
- [ ] Joplin desktop клиент подключается и синхронизирует тестовую заметку
- [ ] `sudo -u joplin /opt/joplin/scripts/backup.sh` работает, в `/var/backups/joplin/` появляется свежий `.dump.gz`, `gunzip -t` проходит
- [ ] `docker compose down && docker compose up -d` — стек переподнимается без потери данных
