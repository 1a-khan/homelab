# miak-it.com Cloudflare DNS Migration

Goal: keep the existing website, email, and VPS-hosted apps working while moving DNS authority from IONOS nameservers to Cloudflare nameservers.

This is a nameserver/DNS migration, not a domain transfer.

## Current Public DNS Snapshot

Collected on 2026-08-17.

### Nameservers

```text
ns1065.ui-dns.de
ns1079.ui-dns.biz
ns1074.ui-dns.com
ns1083.ui-dns.org
```

### Website / Root

```text
miak-it.com A    217.160.0.95
miak-it.com AAAA 2001:8d8:100f:f000::200
```

### Mail

```text
miak-it.com MX 10 mx00.ionos.de
miak-it.com MX 10 mx01.ionos.de
miak-it.com TXT "v=spf1 include:_spf-eu.ionos.com ~all"
_dmarc.miak-it.com TXT "v=DMARC1; p=none;"
```

### Known App Subdomains

```text
n8n.miak-it.com      A 116.203.131.147
windmill.miak-it.com A 116.203.131.147
openbao.miak-it.com  A 116.203.131.147
grafana.miak-it.com  A 116.203.131.147
```

## Migration Steps

1. In Cloudflare, add a new website:

```text
miak-it.com
```

2. Let Cloudflare scan/import DNS records.

3. Before changing nameservers at IONOS, verify Cloudflare has at least these records:

```text
A     miak-it.com        217.160.0.95
AAAA  miak-it.com        2001:8d8:100f:f000::200
A     n8n                116.203.131.147
A     windmill           116.203.131.147
A     openbao            116.203.131.147
A     grafana            116.203.131.147
MX    miak-it.com        mx00.ionos.de priority 10
MX    miak-it.com        mx01.ionos.de priority 10
TXT   miak-it.com        "v=spf1 include:_spf-eu.ionos.com ~all"
TXT   _dmarc             "v=DMARC1; p=none;"
```

4. Also check IONOS for DKIM/autodiscover records that may not appear in public quick checks. Preserve any records related to:

```text
DKIM
autodiscover
autoconfig
imap
smtp
pop
webmail
verification TXT records
```

5. Keep mail-related records DNS-only in Cloudflare. Mail records should not be proxied.

6. For app and website records, start with DNS-only during migration. After everything works, decide which HTTP services should be proxied.

7. Cloudflare will provide two nameservers. In IONOS, replace the four IONOS nameservers with the two Cloudflare nameservers.

8. Verify after nameserver change:

```bash
dig NS miak-it.com
dig A miak-it.com
dig AAAA miak-it.com
dig MX miak-it.com
dig TXT miak-it.com
dig A n8n.miak-it.com
dig A windmill.miak-it.com
dig A openbao.miak-it.com
```

## Migration Strategy For Apps

At first, keep these app subdomains pointed to the Hetzner VPS:

```text
n8n.miak-it.com
windmill.miak-it.com
openbao.miak-it.com
grafana.miak-it.com
```

After the Kubernetes replacement app is ready on the mini PC:

1. Deploy the app in k3s.
2. Create Kubernetes Ingress for the same hostname.
3. Add the hostname to the Cloudflare Tunnel config.
4. Change the DNS record from the Hetzner VPS IP to the Cloudflare Tunnel CNAME.
5. Test login, data, background jobs, webhooks, and backups.
6. Only then stop the old VPS container.

## Do Not Break Email

Before changing nameservers, compare IONOS and Cloudflare DNS records carefully.

Email depends mostly on:

```text
MX
SPF TXT
DKIM TXT/CNAME
DMARC TXT
autodiscover/autoconfig records
```

If email records are copied correctly, `support@miak-it.com` can keep working while DNS is served by Cloudflare.

