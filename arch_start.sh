#!/bin/bash

# WireGuard Auto-Setup Script for Arch Linux
# Version 1.0
# Run as root!

if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root. Use sudo!" 1>&2
    exit 1
fi

echo -e "\n\033[1;34m=== WireGuard Server Setup for Arch Linux ===\033[0m\n"

# Установка зависимостей
pacman -Sy --noconfirm wireguard-tools qrencode

# Определение сетевого интерфейса
INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
if [ -z "$INTERFACE" ]; then
    echo "Error: Cannot detect network interface!"
    exit 1
fi

# Запрос порта
read -p "Enter WireGuard port [51820]: " PORT
PORT=${PORT:-51820}

# Генерация ключей
mkdir -p /etc/wireguard
cd /etc/wireguard
umask 077
wg genkey | tee privatekey | wg pubkey > publickey

# Создание конфига сервера
cat > wg0.conf <<EOF
[Interface]
Address = 10.0.0.1/24
ListenPort = $PORT
PrivateKey = $(cat privatekey)
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o $INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.0.0.0/24 -o $INTERFACE -j MASQUERADE
EOF

# Включение форвардинга
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.d/99-wireguard.conf
sysctl --system

# Настройка фаервола (nftables)
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0;
        ct state established,related accept
        iifname "lo" accept
        tcp dport $PORT accept comment "WireGuard"
        reject
    }
    chain forward {
        type filter hook forward priority 0;
        accept
    }
    chain output {
        type filter hook output priority 0;
        accept
    }
}
EOF

systemctl enable --now nftables

# Запуск сервиса WireGuard
systemctl enable --now wg-quick@wg0
sleep 2

# Создание клиентского конфига
CLIENT_IP="10.0.0.2"
cat > /etc/wireguard/client.conf <<EOF
[Interface]
PrivateKey = $(wg genkey)
Address = $CLIENT_IP/24
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = $(cat publickey)
Endpoint = $(curl -4 icanhazip.com 2>/dev/null):$PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

# Генерация QR-кода
qrencode -t ansiutf8 < /etc/wireguard/client.conf

echo -e "\n\033[1;32m=== Setup Complete! ===\033[0m"
echo -e "\nServer Config: /etc/wireguard/wg0.conf"
echo -e "Client Config: /etc/wireguard/client.conf"
echo -e "\nUse this QR code for mobile clients"
echo -e "\n\033[1;33mNote: For persistent iptables rules, install iptables-services:\n"
echo -e "pacman -S iptables-services"
echo -e "systemctl enable --now iptables\033[0m"

# Перезапуск WireGuard
systemctl restart wg-quick@wg0

# Просмотр статуса
wg show