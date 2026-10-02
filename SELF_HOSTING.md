# Self-Hosting MultivRSS

A guide to running your own long-lived MultivRSS instance. If you only want to run the app briefly to explore the codebase, the shorter [Running locally section in the README](./README.md#running-locally) is enough; this guide goes further (OAuth app registration, running the background worker, exposing the app to the internet, updates).

There is currently no all-in-one `docker compose up` that starts the app itself: `app` runs as a plain Node process outside Docker, with Postgres and Redis in containers. That's a known gap, tracked in the [Roadmap](./ROADMAP.md#infrastructure--scaling). Until then, sections 1–10 are the accurate path on a machine you control. To run the same topology on [Fly.io](https://fly.io), use [section 11](#11-deploying-on-flyio).

## 1. Prerequisites

- Node.js 24+
- Docker (for Postgres and Redis)
- A domain name and a reverse proxy — only if you want the instance reachable from the internet. A purely local instance (`localhost`) skips this entirely.

## 2. Get the code

```bash
git clone git@github.com:trnqeu/multivrss.git
cd multivrss
npm install
npx prisma generate
```

`npm install` alone does not generate the Prisma client — skip `prisma generate` and every route that touches the database fails with `Cannot find module '.prisma/client/default'`.

## 3. Configure the environment

```bash
cp .env.example .env
```

`.env.example` lists every variable with a short comment on where it comes from. A few are worth walking through in more detail:

**GitHub OAuth app** (for "Sign in with GitHub"):
1. [github.com/settings/developers](https://github.com/settings/developers) → "New OAuth App"
2. Homepage URL: `http://localhost:3002` (or your real domain, see step 7)
3. Authorization callback URL: `http://localhost:3002/api/auth/callback/github`
4. Copy the generated Client ID / Client Secret into `GITHUB_ID` / `GITHUB_SECRET`

**Google OAuth app** (for "Sign in with Google"):
1. [console.cloud.google.com/apis/credentials](https://console.cloud.google.com/apis/credentials) → "Create Credentials" → "OAuth client ID" → "Web application"
2. Authorized redirect URI: `http://localhost:3002/api/auth/callback/google`
3. Copy the Client ID / Client Secret into `GOOGLE_ID` / `GOOGLE_SECRET`

Both OAuth providers are optional — email/password sign-in works without either. Leave the corresponding vars blank to disable that provider.

**Resend** (transactional email — password reset, email verification): create an account at [resend.com](https://resend.com), grab an API key from the dashboard, set `RESEND_API_KEY`. Without it, password reset and email verification links won't be sent — registration/login by password still work, but new accounts stay unverified.

**Secrets** (`NEXTAUTH_SECRET`, `CRON_SECRET`, `INTERNAL_SECRET`): generate each with

```bash
openssl rand -base64 32
```

Never reuse the same value across secrets.

## 4. Start Postgres and Redis

```bash
docker compose up -d
npx prisma migrate deploy
```

This brings up Postgres on `localhost:5435` and Redis on `localhost:6379` (see `docker-compose.yml`), then applies the existing schema.

## 5. Start the app

For trying it out:

```bash
npm run dev
```

Open `http://localhost:3002`.

For running it longer-term, a production build is more efficient (no hot-reload overhead, smaller memory footprint):

```bash
npm run build
npm start
```

## 6. Start the background worker

Feed syncing runs in a **separate process**, not inside the web app:

```bash
npm run worker
```

This runs `src/workers/feed-sync.ts`, which processes the BullMQ job queue and periodically re-syncs feeds in the background. Without it running, feeds you add will sit unsynced- `GET /api/cron/sync` still exists, but it's a manual/backup trigger (bearer-token authenticated with `CRON_SECRET`), not a replacement for the worker. Keep this process running alongside the app (a second terminal, a second systemd unit, a second `pm2` process).

## 7. Expose it to the internet (optional)

If you want the instance reachable outside your own machine/network, put a reverse proxy in front of it with your own domain and a TLS certificate. A minimal Nginx front (TLS via certbot, rate limiting on the auth endpoints, everything proxied to the app):

```nginx
limit_req_zone $binary_remote_addr zone=auth:10m rate=5r/m;

server {
    listen 80;
    server_name yourdomain.com www.yourdomain.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name yourdomain.com www.yourdomain.com;

    ssl_certificate     /etc/letsencrypt/live/yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/yourdomain.com/privkey.pem;

    location ~ ^/(login|register|forgot-password|reset-password|api/auth) {
        limit_req zone=auth burst=10 nodelay;
        proxy_pass http://127.0.0.1:3002;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:3002;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Leave the security headers (HSTS, `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`) to the app — `next.config.ts` already sets them; adding `add_header` lines in Nginx just produces conflicting duplicates. For a full container-based production setup (Docker Compose topology, health checks, migrations before code swap), see `docker-compose.prod.yml` and the workflows in `.github/workflows/`. For the same topology on Fly.io, see [section 11](#11-deploying-on-flyio).

Remember to update `NEXTAUTH_URL` and the OAuth callback URLs (steps 3 above) to your real domain once you have one — mismatched values break OAuth login and session cookies.

## 8. First login

Register a normal account through the app's `/register` page. If `RESEND_API_KEY` is set, you'll need to verify your email before logging in; if it's unset, verification is effectively skipped (no email can be sent).

For a faster local account that skips email verification entirely:

```bash
npx tsx --tsconfig tsconfig.test.json scripts/create-test-users.ts 1 MyPassword1!
```

This talks directly to the database and refuses to run against anything but `localhost`/`127.0.0.1` — safe for local use, not something to run against a real deployment.

## 9. Keeping it updated

```bash
git pull
npm install
npx prisma migrate deploy
npm run build   # if running the production build
```

Restart the app and worker processes after updating.

## 10. Troubleshooting

`GET /api/health` reports the status of both backing services:

```bash
curl http://localhost:3002/api/health
# {"status":"ok","db":"ok","redis":"ok"}
```

A `"degraded"` status with `db` or `redis` not `"ok"` means Postgres or Redis isn't reachable — check `docker compose ps` and that `DATABASE_URL`/`REDIS_HOST`/`REDIS_PORT` in `.env` match the containers' actual ports.

## 11. Deploying on Fly.io

`fly.toml` and `fly.redis.toml` reproduce the production topology: the Next.js server and the feed-sync worker are two process groups of one app (same image as `docker-compose.prod.yml`), Redis is a private Machine with a volume, and Postgres is a Fly Postgres cluster on the private network. The hosted SSH deploy in `.github/workflows/` is unchanged — this path is for running your own instance.

Install [flyctl](https://fly.io/docs/flyctl/install/) and `fly auth login` first. If you belong to more than one org, pass `-o <org>` on the commands below. App names are global. If `multivrss` or `multivrss-redis` is taken, rename `app` in the matching toml. `REDIS_HOST` in `fly.toml` must stay `<redis-app-name>.internal`, and `primary_region` must be the same in both files (`fly platform regions` lists codes). The steps below use the names and region already in the files (`ams`).

### Redis

Redis listens with no password, same as `docker-compose.prod.yml`. `fly.redis.toml` publishes no service. Leave it that way, and do not allocate a public IP. The image is `redis:8-alpine` via `Dockerfile.redis`: the Fly volume mounts root-owned, and the stock image runs as user `redis`, so it exits immediately with `Can't open or create append-only dir appendonlydir: Permission denied`. The wrapper entrypoint chowns `/data` first.

```bash
fly apps create multivrss-redis
fly deploy -c fly.redis.toml --ha=false
fly status -a multivrss-redis     # STATE must be started before the app deploy
fly ips list -a multivrss-redis   # expect no addresses
```

`multivrss-redis.internal` exists only while that Machine is started. A stopped Redis (for example after a crash loop) makes `/api/health` fail, and `fly deploy` of the app waits on that check until it times out. If status says `stopped`, run `fly machine start -a multivrss-redis` and wait until status says `started`.

`initial_size` creates the `redis_data` volume on that first deploy. If deploy stops because the volume is missing:

```bash
fly volumes create redis_data --size 1 --region ams -a multivrss-redis -y
fly deploy -c fly.redis.toml --ha=false
```

### Postgres

`fly postgres create` provisions an unmanaged Fly Postgres app (Fly's own docs point production teams at Managed Postgres instead). Any Postgres the app can reach with a `postgresql://` `DATABASE_URL` works, including Managed Postgres — skip `attach` below and set `DATABASE_URL` yourself if you use that.

```bash
fly postgres create \
  --name multivrss-db \
  --region ams \
  --initial-cluster-size 1 \
  --vm-size shared-cpu-1x \
  --volume-size 1
```

Save the password it prints. It is shown once.

### App secrets

Create the app before attaching the database or setting secrets. `fly postgres attach` writes `DATABASE_URL` for you.

```bash
fly apps create multivrss
fly postgres attach multivrss-db --app multivrss

fly secrets set --app multivrss \
  NEXTAUTH_URL="https://multivrss.fly.dev" \
  NEXTAUTH_SECRET="$(openssl rand -base64 32)" \
  CRON_SECRET="$(openssl rand -base64 32)" \
  INTERNAL_SECRET="$(openssl rand -base64 32)"
```

OAuth and email are optional, same as section 3. Set them when you want that provider, and register the callback URLs against the public origin (`https://multivrss.fly.dev`, or your domain from the next section):

- GitHub: `https://multivrss.fly.dev/api/auth/callback/github`
- Google: `https://multivrss.fly.dev/api/auth/callback/google`

```bash
fly secrets set --app multivrss \
  GITHUB_ID="..." \
  GITHUB_SECRET="..." \
  GOOGLE_ID="..." \
  GOOGLE_SECRET="..." \
  RESEND_API_KEY="..."
```

`NEXT_PUBLIC_SENTRY_DSN` is baked in at image build, not read at runtime. Pass it as a build arg when you want browser error reporting: `fly deploy --build-arg NEXT_PUBLIC_SENTRY_DSN="..."`. `SENTRY_DSN` is a normal runtime secret.

### Deploy

```bash
fly deploy --ha=false
```

`--ha=false` keeps a single `app` Machine and a single `worker` Machine. Without it, Fly also creates a second app Machine and a worker standby.

Each deploy runs `npx prisma migrate deploy` in a temporary Machine before traffic moves (`release_command` in `fly.toml`). That applies the SQL already in `prisma/migrations`. Use that command for this database. `prisma migrate dev` is for local development and will corrupt the full-text indexes (see the Prisma gotcha in `CLAUDE.md`).

`fly deploy` starts one `app` Machine and one `worker` Machine. The worker is what syncs feeds. Confirm both:

```bash
fly status
fly scale count app=1 worker=1   # only if a count has drifted to 0
```

Then:

```bash
curl https://multivrss.fly.dev/api/health
# {"status":"ok","db":"ok","redis":"ok"}
```

A `503` with `"degraded"` means the app is up but Postgres or Redis is not. `fly logs` shows the release command and both processes. The worker Machine has no HTTP service, so it does not autostop.

### Custom domain

```bash
fly certs add yourdomain.com
```

Add the DNS records that command prints, then point the app at the new origin:

```bash
fly secrets set --app multivrss NEXTAUTH_URL="https://yourdomain.com"
```

Update the OAuth callback URLs to that origin too. Sessions and OAuth break when `NEXTAUTH_URL` and the callback URLs disagree with the host people actually use.

### Updating

```bash
git pull
fly deploy --ha=false
```

`fly deploy` rebuilds the image, migrates, then rolls the `app` and `worker` Machines. Restart is part of the deploy. Redis and Postgres stay as they are; redeploy Redis only when `fly.redis.toml` changes:

```bash
fly deploy -c fly.redis.toml --ha=false
```
