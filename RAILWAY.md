# Deploying Wolf Host on Railway

`shart.sh` makes this one-command. Railway auto-injects `$PORT`, `$DATABASE_URL`
and `$REDIS_URL`, and `shart.sh` rewrites them to what the backend needs.

## 1. Create two services (monorepo)

In your Railway project add the repo as a GitHub source, then create **two**
services from the same repo:

| Service   | Source dir | Build    | Start command              |
|-----------|------------|----------|----------------------------|
| `wolf-backend` | `/`   | Dockerfile `docker/backend/Dockerfile`  | `bash shart.sh backend`  |
| `wolf-frontend`| `/`   | Dockerfile `docker/frontend/Dockerfile` | `bash shart.sh frontend` |

`shart.sh` also auto-detects the role from the service name, so the explicit
`backend` / `frontend` argument is optional.

## 2. Add plugins

- Add **PostgreSQL** plugin to the **backend** service → sets `$DATABASE_URL`.
- Add **Redis** plugin to the **backend** service → sets `$REDIS_URL`.

## 3. Service variables (backend)

```
SECRET_KEY=<long random string>      # persist so logins survive restarts
CORS_ORIGINS=https://<frontend-domain>
ADMIN_EMAIL=admin@yourdomain.com
ADMIN_PASSWORD=strong-password
WEB_CONCURRENCY=1                    # keep low on the free/hobby plan
```

## 4. Service variables (frontend)

```
NEXT_PUBLIC_API_URL=https://<backend-domain>   # where the browser calls the API
BACKEND_URL=https://<backend-domain>           # fallback used by shart.sh
```

## 5. Deploy

Railway builds each Dockerfile and runs `shart.sh`, which runs migrations +
seed and starts the server on the injected `$PORT`. Done.

> Note: the backend uses a Docker socket to launch user bots
> (`/var/run/docker.sock`). That capability is not available on Railway, so
> core API/auth/billing work, but on-demand bot container launching will not.
> Run the full stack with Docker (`./shart.sh` locally) if you need that.
