FROM node:24-alpine
RUN apk add --no-cache ffmpeg
WORKDIR /app
COPY server.mjs ./
USER node
ENV HOST=0.0.0.0 PORT=8787
CMD ["node", "server.mjs"]
