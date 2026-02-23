## 使用 whatsapp

>修改 `~/.nanobot/config.json` 配置
```json
"channels": {
    "whatsapp": {
      "enabled": true,
      "bridgeUrl": "ws://localhost:3001", // Docker 启动
      "allowFrom": ["8613251005331"]
    },
}
```