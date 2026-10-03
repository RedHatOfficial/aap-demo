FROM node:24-alpine AS build

WORKDIR /extension-source

COPY package*.json ./
RUN npm ci

COPY . .
RUN npm run build

FROM scratch

LABEL org.opencontainers.image.title="AAP Demo Podman Desktop extension" \
      org.opencontainers.image.description="Podman Desktop extension for the local AAP Demo environment" \
      org.opencontainers.image.vendor="Red Hat" \
      org.opencontainers.image.version="0.1.0" \
      io.podman-desktop.api.version=">= 1.12.0"

COPY --from=build /extension-source/package.json /extension/package.json
COPY --from=build /extension-source/dist /extension/dist
COPY --from=build /extension-source/media /extension/media
