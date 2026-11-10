# PMail + Gophish Modified deployment

This repository contains deployment scripts for the PMail + Gophish mail/phishing drill stack.

## Current source versions

| Component | Repository | Branch | Required fix |
|---|---|---|---|
| PMail | https://github.com/0clickjacking0/PMail | `mine` | Contains `64f93ae` (inline CID) plus current local development changes |
| Gophish | https://github.com/0clickjacking0/GophisModified | `mine` | Contains `ef953b4` (inline QR) plus current local development changes |

The two QR/CID fixes are complementary. Deploy both together if inline QR images are expected in email bodies.

## Files

- `deploy.sh` — public/internet deployment with Nginx SNI routing.
- `deploy-intranet.sh` — intranet/offline-oriented deployment helper.
- `DEPLOY_GUIDE.md` — original field-by-field deployment guide.

## Security notes

- Do not commit `mail_env`, databases, DKIM keys, TLS keys, certificates, API credentials, or container logs.
- The deployment script generates runtime keys on the target server only.
- Read `DEPLOY_GUIDE.md` before running the script.

