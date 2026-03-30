## 使用 whatsapp

#### 清除历史 bridge
Using WhatsApp? Rebuild the local bridge after upgrading:
```sh
rm -rf ~/.nanobot/bridge
nanobot channels login

rm -rf ~/.nanobot/whatsapp-auth

```

#### 修改 `~/.nanobot/config.json` 配置
>Docker 启动
```json
"channels": {
    "whatsapp": {
      "enabled": true,
      "bridgeUrl": "ws://localhost:3001", // Docker 启动
      "allowFrom": ["8613251005331"]
    },
}
```

>本地启动
```json

```