#!/bin/bash

get_myip() {
    local ip=""
    ip=$(curl -s --max-time 2 ipv4.icanhazip.com 2>/dev/null)
    [ -z "$ip" ] && ip=$(curl -s --max-time 2 ipinfo.io/ip 2>/dev/null)
    [ -z "$ip" ] && ip=$(curl -s --max-time 2 ifconfig.me 2>/dev/null)
    [ -z "$ip" ] && ip=$(curl -s --max-time 2 api.ipify.org 2>/dev/null)
    
    echo "$ip"
}

export MYIP=$(get_myip)
export uuid=$(cat /proc/sys/kernel/random/uuid)
export domain=$(cat /etc/xray/domain)

install_packages() {
    apt update
    apt install -y iptables iptables-persistent
    apt install -y curl socat xz-utils wget apt-transport-https gnupg gnupg2 gnupg1 dnsutils lsb-release
    apt install -y socat cron bash-completion ntpdate
}

setup_time() {
    ntpdate pool.ntp.org
    apt -y install chrony
    timedatectl set-ntp true
    systemctl enable chronyd && systemctl restart chronyd
    systemctl enable chrony && systemctl restart chrony
    timedatectl set-timezone Asia/Kuala_Lumpur
    chronyc sourcestats -v
    chronyc tracking -v
    date
}

setup_xray_dirs() {
    mkdir -p /etc/xray
    mkdir -p /var/log/xray
    touch /var/log/xray/access.log
    touch /var/log/xray/error.log
}

install_packages
setup_time
setup_xray_dirs


get_xray_version() {
    version="$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases \
    | grep tag_name \
    | sed -E 's/.*"v(.*)".*/\1/' \
    | head -n 1)"
}

install_xray() {
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" \
    @ install -u www-data --version ${version}
}

setup_ssl() {
    systemctl stop nginx

    mkdir -p /root/.acme.sh

    curl https://acme-install.netlify.app/acme.sh \
    -o /root/.acme.sh/acme.sh

    chmod +x /root/.acme.sh/acme.sh

    /root/.acme.sh/acme.sh --upgrade --auto-upgrade
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    /root/.acme.sh/acme.sh --issue \
        -d $domain -d $domain \
        --standalone -k ec-256 --listen-v6

    ~/.acme.sh/acme.sh --installcert \
        -d $domain -d $domain \
        --fullchainpath /etc/xray/xray.crt \
        --keypath /etc/xray/xray.key \
        --ecc

    chmod 755 /etc/xray/xray.key
}

restart_services() {
    systemctl restart nginx
    sleep 1
    clear
}

get_xray_version
install_xray
setup_ssl
restart_services

cat> /etc/xray/config.json << END
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "info"
  },
  "stats": {},
  "api": {
    "services": ["StatsService"],
    "tag": "api"
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserDownlink": true,
        "statsUserUplink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true
    }
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10086,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      },
      "tag": "api"
    },
    # HTTPS 443
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "level": 0
          }
        ],
        "decryption": "none",
        "fallbacks": [
          {
            "name": "${domain}",
            "dest": 2091,
            "xver": 1
          },
          {
            "path": "/vmess",
            "dest": 1211,
            "xver": 1
          },
          {
            "path": "/vless",
            "dest": 1212,
            "xver": 1
          },
          {
            "path": "/hvless",
            "dest": 1213,
            "xver": 1
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["http/1.1"],
          "certificates": [
            {
              "certificateFile": "/etc/xray/xray.crt",
              "keyFile": "/etc/xray/xray.key"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    # HTTP 80 
    {
      "port": 80,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}"
          }
        ],
        "decryption": "none",
        "fallbacks": [
          {
            "dest": 2092,
            "xver": 1
          },
          {
            "path": "/vmess",
            "dest": 1301,
            "xver": 1
          },
          {
            "path": "/vless",
            "dest": 1302,
            "xver": 1
          },
          {
            "path": "/hvless",
            "dest": 1303,
            "xver": 1
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    # VLESS WS HTTPS
    {
      "port": 1212,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "level": 0
#vless
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "acceptProxyProtocol": true,
          "path": "/vless"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    # VLESS WS HTTP
    {
      "port": 1302,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          {
            "id": "${uuid}"
#vless            
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "acceptProxyProtocol": true,
          "path": "/vless"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    # VMESS WS HTTPS
    {
      "port": 1211,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0,
            "level": 0
#vmess            
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "acceptProxyProtocol": true,
          "path": "/vmess"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    # VMESS WS HTTP
    {
      "port": 1301,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0
#vmess            
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "acceptProxyProtocol": true,
          "path": "/vmess"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    # VLESS HTTPUPGRADE HTTPS
    {
      "port": 1213,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "level": 0
#vless            
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "httpupgrade",
        "security": "none",
        "httpupgradeSettings": {
          "path": "/hvless",
          "acceptProxyProtocol": true
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    # VLESS HTTPUPGRADE HTTP
    {
      "port": 1303,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          {
            "id": "${uuid}"
#vless            
          }
        ]
      },
      "streamSettings": {
        "network": "httpupgrade",
        "httpupgradeSettings": {
          "path": "/hvless",
          "acceptProxyProtocol": true
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {},
      "tag": "direct"
    },
    {
      "protocol": "socks",
      "tag": "warp",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": 40000
          }
        ]
      }
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    },
    {
      "protocol": "freedom",
      "settings": {},
      "tag": "api"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api"],
        "outboundTag": "api"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "ip": [
          "0.0.0.0/8",
          "10.0.0.0/8",
          "100.64.0.0/10",
          "169.254.0.0/16",
          "172.16.0.0/12",
          "192.0.0.0/24",
          "192.0.2.0/24",
          "192.168.0.0/16",
          "198.18.0.0/15",
          "198.51.100.0/24",
          "203.0.113.0/24",
          "::1/128",
          "fc00::/7",
          "fe80::/10"
        ],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "domain": ["domain:example.net"],
        "outboundTag": "direct"
      }
    ]
  }
}
END

iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport 443 -j ACCEPT
iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport 80 -j ACCEPT
iptables -I INPUT -m state --state NEW -m udp -p udp --dport 443 -j ACCEPT
iptables -I INPUT -m state --state NEW -m udp -p udp --dport 80 -j ACCEPT

iptables-save > /etc/iptables.up.rules
iptables-restore -t < /etc/iptables.up.rules
netfilter-persistent save
netfilter-persistent reload

systemctl daemon-reload
systemctl enable xray
systemctl restart xray
