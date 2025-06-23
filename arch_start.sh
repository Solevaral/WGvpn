#!/bin/bash

# WireGuard Auto-Setup Script for Arch Linux (Fixed Version)
# Version 2.0 - Debugged
# Run as root!

if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root. Use sudo!" 1>&2
    exit 1
fi

echo -e "\n\033[1;34m=== WireGuard Server Setup for Arch Linux ===\033[0m\n"

# Установка зависимостей
echo "Installing dependencies..."
pacman -Sy --noconfirm wireguard-tools qrencode iptables &>/dev/null || {
    echo "Error: Failed to install packages!"
    exit 1
}

# Определение сетевого интерфейса
INTERFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
if [ -z "$INTERFACE" ]; then
    echo "Warning: Cannot detect network interface! Using eth0"
    INTERFACE="eth0"
fi

# Определение публичного IP
PUBLIC_IP=$(curl -4 icanhazip.com 2>/dev/null)
if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP=$(ip -4 addr show $INTERFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
fi

# Запрос порта
read -p "Enter WireGuard port [51820]: " PORT
PORT=${PORT:-51820}

# Генерация ключей
echo "Generating keys..."
mkdir -p /etc/wireguard
cd /etc/wireguard
umask 077
wg genkey | tee privatekey | wg pubkey > publickey

# Создание конфига сервера
echo "Creating server config..."
cat > wg0.conf <<EOF
[Interface]
Address = 10.8.0.1/24
ListenPort = $PORT
PrivateKey = $(cat privatekey)
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o $INTERFACE -j MASQUERADE
EOF

# Включение форвардинга
echo "Enabling IP forwarding..."
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
sysctl -p /etc/sysctl.d/99-wireguard.conf &>/dev/null

# Настройка фаервола
echo "Configuring firewall..."
iptables -A INPUT -p udp --dport $PORT -j ACCEPT
iptables -A FORWARD -j ACCEPT
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $INTERFACE -j MASQUERADE

# Сохранение правил iptables
echo "Saving iptables rules..."
mkdir -p /etc/iptables
iptables-save > /etc/iptables/iptables.rules

# Создание сервиса для сохранения правил
cat > /etc/systemd/system/iptables-restore.service <<EOF
[Unit]
Description=Restore iptables rules
Before=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/iptables-restore /etc/iptables/iptables.rules

[Install]
WantedBy=multi-user.target
EOF

systemctl enable iptables-restore

# Запуск сервиса WireGuard
echo "Starting WireGuard..."
systemctl enable --now wg-quick@wg0 &>/dev/null
sleep 3

# Проверка статуса
if ! systemctl is-active --quiet wg-quick@wg0; then
    echo "Error: WireGuard service failed to start!"
    journalctl -u wg-quick@wg0 -n 10 --no-pager
    exit 1
fi

# Создание клиентского конфига
echo "Creating client config..."
CLIENT_IP="10.8.0.2"
CLIENT_PRIVKEY=$(wg genkey)
CLIENT_PUBKEY=$(echo $CLIENT_PRIVKEY | wg pubkey)

cat > /etc/wireguard/client.conf <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVKEY
Address = $CLIENT_IP/24
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = $(cat publickey)
Endpoint = $PUBLIC_IP:$PORT
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
EOF

# Добавление клиента на сервер
wg set wg0 peer $CLIENT_PUBKEY allowed-ips $CLIENT_IP
wg-quick save wg0

# Генерация QR-кода
echo -e "\n\033[1;36m=== Client QR Code ===\033[0m"
qrencode -t ansiutf8 < /etc/wireguard/client.conf

# Диагностическая информация
echo -e "\n\033[1;32m=== Setup Complete! ===\033[0m"
echo -e "\nServer Config: /etc/wireguard/wg0.conf"
echo -e "Client Config: /etc/wireguard/client.conf"
echo -e "\n\033[1;33mDiagnostic Information:\033[0m"
echo "Public IP: $PUBLIC_IP"
echo "Interface: $INTERFACE"
echo "WireGuard Status:"
wg show

echo -e "\n\033[1;33mRun these commands for diagnostics:\033[0m"
echo "sudo wg show"
echo "sudo iptables -t nat -L -v"
echo "sudo ping -c 3 10.8.0.2"
echo "journalctl -u wg-quick@wg0 -f"