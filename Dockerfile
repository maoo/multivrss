FROM node:24-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

FROM node:24-alpine AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
ARG GIT_COMMIT=unknown
ARG NEXT_PUBLIC_SENTRY_DSN
ENV NEXT_PUBLIC_SENTRY_DSN=$NEXT_PUBLIC_SENTRY_DSN
COPY . .
RUN npx prisma generate
RUN npm run build
RUN npx esbuild src/workers/feed-sync.ts \
    --bundle \
    --platform=node \
    --target=node24 \
    --external:@prisma/client \
    --outfile=dist/worker.js

FROM node:24-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=3000
COPY --from=deps /app/node_modules ./node_modules
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public
COPY --from=builder /app/dist/worker.js ./dist/worker.js
# Fly's release_command runs `prisma migrate deploy` in this image.
COPY --from=builder /app/prisma ./prisma
COPY --from=builder /app/prisma.config.ts ./prisma.config.ts
COPY docker-entrypoint.sh ./
RUN chmod +x docker-entrypoint.sh


EXPOSE 3000
CMD ["sh", "./docker-entrypoint.sh"]

