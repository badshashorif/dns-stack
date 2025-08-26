# DNS Stack: dnsdist + Unbound + Apache Guacamole

Two production-ready deployment options:

- **Method A — Native (Bash script):** Installs dnsdist, Unbound, and Guacamole natively on Ubuntu/Debian.
- **Method B — Docker Compose:** Runs dnsdist, three Unbound resolvers, and Guacamole (guacd + MariaDB) with a single command.

> Target OS for native: Ubuntu 22.04/24.04 or Debian 12.  
> Default ports: DNS 53/udp,tcp; Guacamole 8080/tcp (reverse-proxy recommended).

---

## Quick Start (Docker Compose)

```bash
cd method2-docker
cp .env.example .env
# (Optional) Edit ACL_RANGES and INTERNAL_NETS in .env

docker compose up -d
# Validate
dig @127.0.0.1 -p 5353 openai.com
# Guacamole at http://<host>:8080/guacamole  (default creds inside README below)
```

## Quick Start (Native Bash)

```bash
cd method1-baremetal
sudo bash install.sh
# Validate
dig @127.0.0.1 openai.com
# Guacamole at http://<host>:8080/guacamole
```

---

## What You Get

- **dnsdist** as a smart DNS load balancer with packet cache, ACLs, and safe defaults.
- **Unbound** as high-performance validating recursive resolver(s).
- **Guacamole** web terminal (SSH/RDP/VNC) to centralize server access.
- Ready-to-tune configs, healthchecks, and basic security hardening.
- **GitHub-ready docs** + scripts for quick deployment.

---

## Layout

```
dns-stack/
├─ README.md
├─ method1-baremetal/
│  ├─ install.sh
│  └─ config/
│     ├─ dnsdist.conf
│     └─ unbound.conf
└─ method2-docker/
   ├─ docker-compose.yml
   ├─ .env.example
   ├─ dnsdist/
   │  └─ dnsdist.conf
   └─ unbound/
      ├─ unbound-1.conf
      ├─ unbound-2.conf
      └─ unbound-3.conf
```

---

## Default Networks / ACLs

By default, only **RFC1918** ranges are allowed plus loopback.  
Edit ACL lists in configs (or `.env`) to add your public blocks.

- Loopback: `127.0.0.1/32`
- RFC1918: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`

> If you're Dot Internet, add your AS blocks to the ACL lists.

---

## Post-Deploy Validation

### DNSdist path

```bash
# Should return an A record and small latency
dig @127.0.0.1 -p 5353 openai.com

# Repeat to see cache working (latency should drop)
dig @127.0.0.1 -p 5353 openai.com

# Test TCP
dig +tcp @127.0.0.1 -p 5353 openai.com
```

### Unbound direct (docker method)
```bash
dig @127.0.0.1 -p 5311 openai.com
dig @127.0.0.1 -p 5312 openai.com
dig @127.0.0.1 -p 5313 openai.com
```

### Guacamole
- URL: `http://<host>:8080/guacamole`
- Default admin user (docker): `guacadmin` / `guacadmin`. **Change immediately.**
- For native method you'll set DB creds during install (prompts shown by script).

---

## Production Tips

- Put Guacamole behind Nginx/Caddy with HTTPS and SSO/2FA.
- Keep `dnsdist` admin/web endpoints bound to `127.0.0.1` and use SSH tunnel.
- Consider Anycast VIP for the `dnsdist` listener to reduce latency per PoP.
- Set up Prometheus exporters later for deep metrics (dnsdist + Unbound + node).
- Enable alerts for latency, SERVFAIL rate, and cache hit ratio.

---

## License

MIT — do whatever you want; no warranty.

