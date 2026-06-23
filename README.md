# My Band

App iOS/macOS universal que conecta a **Mi Band 10** via Bluetooth Low Energy usando o AuthKey do dispositivo, eliminando a dependência do app da Xiaomi. Sincroniza dados de saúde com o Apple Health, dispara automações no Home Assistant e expõe funcionalidades via Atalhos e Siri.

---

## Funcionalidades

| Status | Funcionalidade |
|---|---|
| ✅ | Conexão BLE V2 com autenticação HMAC-SHA256 via AuthKey — **validada em hardware (Mi Band 10)** |
| ✅ | Protocolo protobuf via SwiftProtobuf (tipos gerados do GadgetBridge) |
| ✅ | Transporte confiável com ACK + init pós-auth + retry de primeiro pareamento |
| ✅ | Armazenamento seguro do AuthKey no Keychain |
| ✅ | Reconexão automática com backoff exponencial |
| ✅ | Background BLE (pulseira permanece conectada com app suspenso) |
| ✅ | State restoration do CBCentralManager após suspensão pelo sistema |
| ✅ | Sincronização de dados de sono (parser XiaomiSppPacketV2) |
| ✅ | Persistência local com SwiftData (BandDevice, SleepSession, ActivityDay) |
| ✅ | Reassembly de frames BLE fragmentados (arquivos de atividade > MTU) |
| ✅ | Leitura de bateria (nível + carregando) |
| ✅ | UI de Setup (AuthKey + scan/conexão) e Dashboard (bateria, última sync, botão sincronizar) via Claude Design |
| ✅ | Envio ao Apple Health — sono (estágios) e atividade diária (passos, calorias, distância, FC + FC de repouso, SpO₂) — **validado em hardware (Mi Band 10)** |
| ✅ | Sincronização em segundo plano via `BGProcessingTask` (reconecta, sincroniza e reagenda com o app suspenso) — **validada em hardware** |
| ✅ | Medições manuais no Apple Health (FC, SpO₂) — **validado em hardware (Mi Band 10)** |
| 🚧 | Treinos no Apple Health (`HKWorkout` + rota GPS + VO₂máx) e handshake GPS com o iPhone (CoreLocation → `workoutLocation` stream) — implementado, **a confirmar em hardware** |
| 🔜 | Telas SleepDetail (hipnograma) + Settings |
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
- Dependência SPM: **SwiftProtobuf** (`apple/swift-protobuf`) — resolvida automaticamente pelo Xcode

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
│   │   └── XiaomiCrypto.swift    # HMAC-SHA256, HKDF-expand, AES-CTR/CCM (CommonCrypto)
│   ├── Protocol/
│   │   ├── XiaomiProto.swift     # Builders/parsers (camada fina sobre SwiftProtobuf)
│   │   └── xiaomi.pb.swift       # Tipos gerados do xiaomi.proto (GadgetBridge)
│   └── PacketParser/
│       ├── SleepPacketParser.swift     # Sono 0x08 (estágios FB FA FC FF + HR/SpO₂)
│       ├── DailySummaryParser.swift    # Totais do dia + LEReader compartilhado
│       ├── DailyDetailsParser.swift    # Série por minuto (HR/SpO₂/distância/estresse)
│       ├── ManualSamplesParser.swift   # Medições manuais (FC/SpO₂/estresse/temperatura)
│       ├── WorkoutSummaryParser.swift  # Resumos de treino (blueprint por subtype/versão)
│       ├── WorkoutGpsParser.swift      # Trilha GPS de treino (V1/V2)
│       └── XiaomiActivityFile.swift    # Meta do id de 7 bytes + roteamento
│
├── Auth/
│   └── AuthKeyStore.swift        # Keychain: leitura/escrita/deleção do AuthKey
│
├── Models/                       # SwiftData
│   ├── BandDevice.swift          # Dispositivo pareado
│   ├── SleepSession.swift        # Sessão de sono + fases (light/deep/REM/awake)
│   └── ActivityDay.swift         # Passos, calorias, distância por dia
│
├── Health/
│   └── HealthKitManager.swift    # Escrita no Apple Health (sono/atividade/treinos/rota)
├── HomeAssistant/                # REST API local + Cloudflare tunnel (em desenvolvimento)
├── Intents/                      # App Intents + Shortcuts (em desenvolvimento)
└── UI/                           # SwiftUI (em desenvolvimento)
```

Detalhes completos de arquitetura, protocolo BLE e convenções em [`CLAUDE.md`](CLAUDE.md).

---

## Protocolo BLE — Mi Band 10 V2

A Mi Band 10 utiliza o protocolo **XiaomiSppPacketV2** sobre BLE (confirmado via GadgetBridge).

**Serviço:** `0000FE95` | **TX (write):** `0000005E` | **RX (notify):** `0000005F`

**Frame (cabeçalho de 8 bytes; CRC-16/ARC do payload):**
```
[0xA5][0xA5] preamble
[type][seqNum][lenLo][lenHi][crcLo][crcHi]
[payload...]      # DATA: [channel][opCode][bytes]
```

**Autenticação (HMAC-SHA256):**
1. Session config (binário) → resposta da banda
2. `CMD_NONCE` (type=1, sub=26) com 16 bytes aleatórios do app
3. Banda responde: `watchNonce(16) + HMAC-SHA256(watchNonce+phoneNonce, decKey)(32)`
4. Verificar HMAC → derivar 4 chaves de sessão via HKDF-expand("miwear-auth", 64)
5. `CMD_AUTH` (type=1, sub=27) com `authStep3` (HMAC dos nonces + device info em AES-128-CCM)
6. Init pós-auth (time + device info/state/battery) — sem isso a banda re-dispara auth

> **Transporte confiável:** toda frame DATA recebida da banda é confirmada com um ACK (mesmo `seqNum`), ou a banda retransmite o handshake a cada ~6 s.
> **Primeiro pareamento:** o primeiro watch-nonce sempre falha o HMAC; o app reconecta automaticamente e autentica na 2ª tentativa.
> O AuthKey (secretKey) tem 16 bytes. Fica **apenas no Keychain** — nunca em logs, SwiftData ou UserDefaults.

---

## Interface (UI)

A UI está sendo construída a partir de um **design system dark-mode-first** entregue pelo Claude Design — paleta *midnight* otimizada para OLED, accent Aurora indigo, cores de saúde espelhando o Apple Health e uma rampa de fases de sono. Copy em **pt-BR**, foco em status glanceável e configuração rápida (o app é um gateway em segundo plano). Detalhes de tokens, componentes e telas em [`CLAUDE.md`](CLAUDE.md#ui--design-system).

---

## Referências

- [GadgetBridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) — implementação de referência do protocolo Mi Band 10 V2
- [huami-token](https://github.com/argrento/huami-token) — extração de AuthKey via Xiaomi Cloud
- [AstroBox-NG](AstroBox-NG-main/) — referência de protocolo BLE para wearables (incluído no repositório)
- [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) / [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

---

## Changelog

Ver [`CHANGELOG.md`](CHANGELOG.md).
