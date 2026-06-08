# My Band

App iOS/macOS universal que conecta a **Mi Band 10** via Bluetooth Low Energy usando o AuthKey do dispositivo, eliminando a dependência do app da Xiaomi. Sincroniza dados de saúde com o Apple Health, dispara automações no Home Assistant e expõe funcionalidades via Atalhos e Siri.

---

## Funcionalidades

| Status | Funcionalidade |
|---|---|
| ✅ | Conexão BLE V2 com autenticação HMAC-SHA256 via AuthKey |
| ✅ | Armazenamento seguro do AuthKey no Keychain |
| ✅ | Reconexão automática com backoff exponencial |
| ✅ | Background BLE (pulseira permanece conectada com app suspenso) |
| ✅ | State restoration do CBCentralManager após suspensão pelo sistema |
| ✅ | Sincronização de dados de sono (parser XiaomiSppPacketV2) |
| ✅ | Persistência local com SwiftData (BandDevice, SleepSession, ActivityDay) |
| 🔜 | Interface de configuração do AuthKey + dashboard de status |
| 🔜 | Visualização de dados de sono (fases, eficiência, histórico) |
| 🔜 | Envio de dados ao Apple Health (HealthKit) |
| 🔜 | Automações no Home Assistant (dormir → apagar luzes) |
| 🔜 | Integração com Atalhos via App Intents |
| 🔜 | Extração do AuthKey via Xiaomi Cloud (sem app Xiaomi) |
| 🔜 | Mini app customizado na pulseira com botões acionáveis |

---

## Requisitos

- **Xcode 16+**
- **iOS 17+** / **macOS 14+**
- Apple Developer Program pessoal (sideload — não publicado na App Store)
- Mi Band 10 com AuthKey conhecido

---

## Configuração inicial

### 1. Obter o AuthKey

O AuthKey é uma chave de 16 bytes (32 caracteres hex) vinculada ao seu dispositivo. Métodos para obtê-lo:

- **Via Python** — [`huami-token`](https://github.com/argrento/huami-token): faz login na conta Xiaomi e extrai o token
- **Via GadgetBridge** — exportar o AuthKey do banco de dados do app no Android
- **Via o próprio app** (futuro) — o My Band incluirá um fluxo de extração via Xiaomi Cloud

### 2. Inserir o AuthKey no app

Na tela de configuração (em desenvolvimento), insira os 32 caracteres hex do AuthKey. O app os armazena no Keychain com acesso após o primeiro desbloqueio, permitindo sync em background.

Ou via código (para testes):
```swift
try AuthKeyStore.saveHex("sua_chave_aqui_32_chars")
```

### 3. Parear a pulseira

O app escaneia automaticamente dispositivos com nome `Xiaomi Smart Band 10`. Ao encontrar, inicia o handshake HMAC-SHA256 V2 e mantém a conexão persistente.

> **Nota:** testes de BLE requerem um iPhone físico. O Simulator e o Mac não têm o stack BLE necessário para conectar com a pulseira.

---

## Arquitetura

```
My Band/
├── BLE/
│   ├── BandManager.swift         # Orquestrador @Observable @MainActor — scan, connect, auth
│   ├── BandAuthenticator.swift   # Handshake HMAC-SHA256 V2 (puro, testável)
│   ├── BandSyncer.swift          # Sync de dados → SwiftData
│   ├── BandScanner.swift         # Filtros de descoberta BLE
│   ├── BandProtocol.swift        # Encoding XiaomiSppPacketV2 + CRC-16/ARC
│   ├── Crypto/
│   │   └── XiaomiCrypto.swift    # HMAC-SHA256, HKDF-expand, AES-CTR (CommonCrypto)
│   ├── Protocol/
│   │   └── XiaomiProto.swift     # Encoder/decoder protobuf mínimo (zero dependências)
│   └── PacketParser/
│       └── SleepPacketParser.swift  # Parser binário de dados de sono (2-byte entries)
│
├── Auth/
│   └── AuthKeyStore.swift        # Keychain: leitura/escrita/deleção do AuthKey
│
├── Models/                       # SwiftData
│   ├── BandDevice.swift          # Dispositivo pareado
│   ├── SleepSession.swift        # Sessão de sono + fases (light/deep/REM/awake)
│   └── ActivityDay.swift         # Passos, calorias, distância por dia
│
├── Health/                       # HealthKit (em desenvolvimento)
├── HomeAssistant/                # REST API local + Cloudflare tunnel (em desenvolvimento)
├── Intents/                      # App Intents + Shortcuts (em desenvolvimento)
└── UI/                           # SwiftUI (em desenvolvimento)
```

Detalhes completos de arquitetura, protocolo BLE e convenções em [`CLAUDE.md`](CLAUDE.md).

---

## Protocolo BLE — Mi Band 10 V2

A Mi Band 10 utiliza o protocolo **XiaomiSppPacketV2** sobre BLE (confirmado via GadgetBridge).

**Serviço:** `0000FE95` | **TX (write):** `0000005E` | **RX (notify):** `0000005F`

**Frame:**
```
[0xA5][0xA5] preamble
[type][channel][seqNum][lenLo][lenHi][flags][crcLo][crcHi]
[payload...]
```

**Autenticação (HMAC-SHA256):**
1. Session config → `Command{type=0, sub=1}`
2. `CMD_NONCE` (type=1, sub=26) com 16 bytes aleatórios do app
3. Banda responde: `watchNonce(16) + HMAC-SHA256(watchNonce+phoneNonce, secretKey)(32)`
4. Verificar HMAC → derivar 4 chaves de sessão via HKDF-expand("miwear-auth", 64)
5. `CMD_AUTH` (type=1, sub=27) com confirmação cifrada em AES-CTR

> O AuthKey (secretKey) tem 16 bytes. Fica **apenas no Keychain** — nunca em logs, SwiftData ou UserDefaults.

---

## Referências

- [GadgetBridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) — implementação de referência do protocolo Mi Band 10 V2
- [huami-token](https://github.com/argrento/huami-token) — extração de AuthKey via Xiaomi Cloud
- [AstroBox-NG](AstroBox-NG-main/) — referência de protocolo BLE para wearables (incluído no repositório)
- [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) / [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

---

## Changelog

Ver [`CHANGELOG.md`](CHANGELOG.md).
