# WGvpn

umask 077
wg genkey | tee privatekey | wg pubkey > publickey
