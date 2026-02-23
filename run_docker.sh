
docker build -t nanobot:local -f Dockerfile .

# 运行时注入 .env（推荐）
docker run --rm \
  --env-file .env \
  -v ~/.nanobot:/root/.nanobot \
  nanobot:local status


docker run -d \
  --name nanobot \
  --env-file .env \
  -v ~/.nanobot:/root/.nanobot \
  -p 18790:18790 \
  -p 20000:22 \
  nanobot:local gateway

docker exec -it nanobot bash

docker logs -f nanobot

# Build the image
docker build -t nanobot .

# Initialize config (first time only)
docker run -v ~/.nanobot:/root/.nanobot --rm nanobot onboard

# Edit config on host to add API keys
vim ~/.nanobot/config.json

# Run gateway (connects to enabled channels, e.g. Telegram/Discord/Mochat)
docker run -v ~/.nanobot:/root/.nanobot -p 18790:18790 nanobot gateway

# Or run a single command
docker run -v ~/.nanobot:/root/.nanobot --rm nanobot agent -m "Hello!"
docker run -v ~/.nanobot:/root/.nanobot --rm nanobot status