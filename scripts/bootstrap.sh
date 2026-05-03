#!/usr/bin/env bash
# scripts/bootstrap.sh — однократная подготовка VPS Ubuntu 22.04.
# Запускать от root: sudo ./scripts/bootstrap.sh
# Идемпотентен: повторный запуск ничего не ломает.
set -euo pipefail

# === Параметры ===
SSH_PORT=2315                 # ВАЖНО: подставьте ваш фактический SSH-порт
JOPLIN_USER=joplin

# === Пред-проверки ===
if [[ $EUID -ne 0 ]]; then
    echo "Запускайте от root: sudo $0" >&2
    exit 1
fi

OS_VERSION=$(lsb_release -rs 2>/dev/null || echo "unknown")
if [[ "$OS_VERSION" != "22.04" ]]; then
    echo "Требуется Ubuntu 22.04, найдено: $OS_VERSION" >&2
    exit 1
fi

# Защита от self-lockout
ACTUAL_SSH_PORT=$(ss -tlnp 2>/dev/null \
    | awk '/sshd/ {split($4,a,":"); print a[length(a)]; exit}')
if [[ -n "${ACTUAL_SSH_PORT:-}" && "$ACTUAL_SSH_PORT" != "$SSH_PORT" ]]; then
    cat >&2 <<EOF
ОШИБКА: SSH_PORT в скрипте ($SSH_PORT) не совпадает с фактическим
портом sshd ($ACTUAL_SSH_PORT). Откройте $0 и поправьте SSH_PORT.
UFW не настраивается до устранения расхождения.
EOF
    exit 1
fi

# === apt + базовые пакеты ===
echo "==> apt update"
apt-get update -qq

echo "==> Проверка пакетов"
PACKAGES=(
    ca-certificates curl gnupg lsb-release
    nginx certbot python3-certbot-nginx
    ufw cron gzip openssl
)
for pkg in "${PACKAGES[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        echo "  $pkg — уже установлен"
    else
        echo "  ставлю $pkg"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg"
    fi
done

# --- Docker (engine + buildx + compose plugin) ---------------------------
# Если уже стоит — пропускаем; иначе ставим официальный docker-ce из репозитория Docker.
if ! command -v docker >/dev/null 2>&1; then
  say "Устанавливаем Docker Engine"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | tee /etc/apt/sources.list.d/docker.list >/dev/null
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi

# --- Docker rights: ставим $DOCKER_USER в группу docker ------------------
# Без этого `docker version` от имени SSH-юзера падает с
#   "permission denied while trying to connect to the docker API at unix:///var/run/docker.sock"
if [[ -n "$DOCKER_USER" ]] && id "$DOCKER_USER" >/dev/null 2>&1; then
  if ! id -nG "$DOCKER_USER" | tr ' ' '\n' | grep -qx docker; then
    say "Добавляем пользователя ${DOCKER_USER} в группу docker"
    usermod -aG docker "$DOCKER_USER"
    DOCKER_GROUP_ADDED=1
  else
    say "Пользователь ${DOCKER_USER} уже в группе docker"
    DOCKER_GROUP_ADDED=0
  fi
else
  echo "ВНИМАНИЕ: не указан пользователь для группы docker." >&2
  echo "Передайте имя как первый аргумент: sudo bash $0 <username>" >&2
  DOCKER_GROUP_ADDED=0
fi

# === Пользователь joplin ===
if ! id "$JOPLIN_USER" >/dev/null 2>&1; then
    echo "==> Создание пользователя $JOPLIN_USER"
    useradd -m -s /bin/bash "$JOPLIN_USER"
fi
if ! id -nG "$JOPLIN_USER" | tr ' ' '\n' | grep -qx docker; then
    usermod -aG docker "$JOPLIN_USER"
    echo "  $JOPLIN_USER добавлен в группу docker"
fi

# === Каталоги ===
install -d -o "$JOPLIN_USER" -g "$JOPLIN_USER" -m 0750 /opt/joplin
install -d -o "$JOPLIN_USER" -g "$JOPLIN_USER" -m 0750 /var/backups/joplin
install -d -o www-data -g www-data -m 0755 /var/www/certbot

# === UFW ===
echo "==> Настройка UFW"
UFW_STATUS=$(ufw status | head -1 | awk '{print $2}')
if [[ "$UFW_STATUS" == "inactive" ]]; then
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${SSH_PORT}/tcp" comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    ufw --force enable
else
    # UFW уже активен (другими сервисами) — только добавляем нужные правила,
    # дефолтные политики не трогаем.
    ufw allow "${SSH_PORT}/tcp" comment 'SSH' || true
    ufw allow 80/tcp comment 'HTTP' || true
    ufw allow 443/tcp comment 'HTTPS' || true
fi

# === Summary ===
echo
echo "==> Готово"
echo "  Docker:  $(docker --version)"
echo "  Compose: $(docker compose version)"
echo "  Nginx:   $(nginx -v 2>&1)"
echo "  Certbot: $(certbot --version 2>&1)"
echo "  UFW:     $(ufw status | head -1)"
nginx -t || echo "  ВНИМАНИЕ: nginx -t не прошёл (см. вывод выше)"
systemctl is-active nginx || echo "  ВНИМАНИЕ: nginx не активен"
docker info >/dev/null 2>&1 \
    && echo "  Docker daemon: активен" \
    || echo "  ВНИМАНИЕ: docker info упал"
echo
echo "Дальше: переключитесь на пользователя joplin, скопируйте проект"
echo "в /opt/joplin/ и запустите ./scripts/deploy.sh"
