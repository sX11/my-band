# CLAUDE.md — My Band

Guia de arquitetura e diretrizes para o projeto **My Band**: app iOS/macOS universal que conecta a Mi Band 10 via BLE usando AuthKey, sincroniza dados de saúde com o Apple Health, integra com Home Assistant e suporta Atalhos via App Intents.

---

## Visão Geral do Projeto

| Item | Detalhe |
|---|---|
| Plataformas | iOS 17+ e macOS 14+ (destino universal, um único target Xcode) |
| Linguagem | Swift 5.10+ |
| UI | SwiftUI |
| Persistência | SwiftData |
| Bluetooth | CoreBluetooth (BLE apenas — Mi Band 10 não usa Classic BT) |
| Saúde | HealthKit |
| Automação | App Intents + Shortcuts |
| Home Assistant | REST API via HTTP/HTTPS (local + túnel Cloudflare) |
| Distribuição | Uso pessoal — sideload via Apple Developer Program pessoal (sem App Store) |

---

## Arquitetura de Módulos

```
My Band/
├── App/
│   ├── My_BandApp.swift          # Entry point, injeção de dependências globais
│   └── AppDelegate.swift         # Ciclo de vida background BLE no iOS
│
├── BLE/
│   ├── BandManager.swift         # Orquestrador central BLE (@Observable @MainActor NSObject)
│   ├── BandScanner.swift         # Descoberta e filtragem de dispositivos Mi Band
│   ├── BandAuthenticator.swift   # Handshake AES-128 com AuthKey
│   ├── BandProtocol.swift        # Encoder/decoder de pacotes do protocolo Mi Band
│   ├── BandSyncer.swift          # Sincronização de dados históricos (sono, steps, HR)
│   └── Services/
│       ├── MiBandUUID.swift      # Constantes de UUID dos serviços GATT
│       └── PacketParser/         # Parsers por tipo de dado (sono, diário, manual, treinos+GPS)
│
├── Auth/
│   ├── AuthKeyStore.swift        # Armazenamento seguro do AuthKey no Keychain
│   ├── ManualAuthKeyView.swift   # Tela de input manual do AuthKey (hex 32 chars)
│   └── XiaomiCloudAuth.swift    # Extração do AuthKey via Xiaomi Cloud API
│
├── Health/
│   ├── HealthKitManager.swift    # Autorização e escrita no Apple Health
│   └── HealthSyncService.swift  # Conversão dados Mi Band → tipos HealthKit
│
├── HomeAssistant/
│   ├── HAClient.swift            # Cliente REST genérico (local + Cloudflare fallback)
│   ├── HAConfig.swift            # Configuração: URL local, URL remota, token
│   └── HATriggers.swift          # Gatilhos predefinidos (sono detectado, HR, etc.)
│
├── Intents/
│   ├── SyncBandIntent.swift      # App Intent: sincronizar dados agora
│   ├── GetSleepDataIntent.swift  # App Intent: retornar dados de sono
│   ├── TriggerHAIntent.swift     # App Intent: disparar ação no Home Assistant
│   └── BandShortcuts.swift       # AppShortcutsProvider com frases Siri
│
├── MiniApp/                      # (Fase futura) Mini app na pulseira
│   └── README.md                 # Documentação do protocolo de mini apps
│
├── Models/
│   ├── BandDevice.swift          # SwiftData model do dispositivo pareado
│   ├── SleepSession.swift        # SwiftData model de sessão de sono
│   ├── ActivityDay.swift         # SwiftData model de atividade diária
│   └── HeartRateSample.swift     # SwiftData model de amostras de HR
│
└── UI/
    ├── Dashboard/                # Tela principal com resumo de dados
    ├── Setup/                    # Fluxo de configuração (AuthKey + HA)
    ├── Sleep/                    # Visualização detalhada de sono
    └── Settings/                 # Configurações gerais
```

---

## Protocolo BLE da Mi Band 10

> **Protocolo confirmado via GadgetBridge** (`XiaomiSppPacketV2`, `XiaomiAuthService`, `MiBand10Coordinator`).
> Implementação anterior (AES-128-ECB + UUIDs FEE0/FEE1) era para Mi Band 5/6 e foi descartada.

### Serviços e Características (BLE V2)

| UUID | Função |
|---|---|
| `0000FE95-0000-1000-8000-00805F9B34FB` | Xiaomi BLE V2 Service (único serviço relevante) |
| `0000005E-0000-1000-8000-00805F9B34FB` | TX — write (app → banda, sem resposta) |
| `0000005F-0000-1000-8000-00805F9B34FB` | RX — notify (banda → app) |
| `0000180D-0000-1000-8000-00805F9B34FB` | Heart Rate Service (GATT padrão) |

### Formato de Frame — XiaomiSppPacketV2

Cabeçalho de 8 bytes (confirmado em `XiaomiSppPacketV2.java`; ver `BandProtocol.swift`):

```
[0xA5][0xA5]   preamble (2 bytes)
[type]         lower 4 bits = packetType: 1=ACK, 2=SESSION_CONFIG, 3=DATA
[seqNum]       contador de sequência (UInt8)
[lenLo][lenHi] comprimento do payload (UInt16 LE)
[crcLo][crcHi] CRC-16/ARC do PAYLOAD apenas (poly=0x8005, refin/refout, init=0)
[payload...]   bytes do payload
```

Payload de um pacote DATA (dentro do payload acima):
```
[channel]  lower 4 bits: 1=PROTOBUF, 2=DATA, 5=ACTIVITY
[opCode]   1=PLAINTEXT, 2=ENCRYPTED (AES-CTR, encryptV2/decryptV2 com IV=key)
[bytes...] Command protobuf (ou bytes cifrados, se opCode=2)
```

**Transporte confiável (janela/ACK).** O SPP V2 negocia `TX_WIN` e numera os pacotes. **Toda frame DATA recebida da pulseira precisa ser confirmada** com um pacote ACK (`type=1`) carregando o mesmo `seqNum` (`BandManager.sendAck`). Sem ACK, a pulseira assume perda e retransmite o handshake inteiro a cada ~6 s. Pacotes DATA enviados pelo app usam um contador próprio incremental (`nextSeq`).

**Protobuf via SwiftProtobuf.** As mensagens `Command`, `Auth`, `WatchNonce`, `Health`, `System`, etc. vêm dos tipos gerados em `BLE/Protocol/xiaomi.pb.swift` (gerados do `xiaomi.proto` do GadgetBridge). `XiaomiProto.swift` é só a camada fina de builders/parsers.

### Fluxo de Autenticação (HMAC-SHA256 V2)

1. **Conectar** ao dispositivo BLE (nome `Xiaomi Smart Band 10 XXXX`)
2. **Descobrir** serviço `FE95` → características `005E` (TX) e `005F` (RX)
3. **Habilitar notificações** em `005F`
4. **Session config**: enviar `Command{type=0, sub=1, payload={mtu=512, version=2}}` no canal COMMAND
5. **CMD_NONCE** (type=1, sub=26): enviar 16 bytes de nonce aleatório do app
6. **Banda responde**: `watchNonce(16) + HMAC-SHA256(watchNonce+phoneNonce, secretKey)(32)`
7. **Verificar HMAC** da banda
8. **Derivar chaves de sessão**:
   ```
   prk = HMAC-SHA256(phoneNonce + watchNonce, secretKey)
   keys[0..63] = HKDF-expand(prk, "miwear-auth", 64)
   decryptionKey  = keys[0..15]
   encryptionKey  = keys[16..31]
   decryptionNonce = keys[32..35]
   encryptionNonce = keys[36..39]
   ```
9. **CMD_AUTH** (type=1, sub=27): `authStep3 { encryptedNonces = HMAC-SHA256(phoneNonce+watchNonce, encKey), encryptedDeviceInfo = AES-128-CCM(authDeviceInfo) }`
   - CCM nonce = `encryptionNonce(4) || zeros(4) || counter=0(4)`
   - Comunicação pós-auth usa AES-CTR com peculiaridade V2: **IV = key** (GadgetBridge: "I wish I was kidding")
10. **Banda responde** `sub=27` → **Autenticado**, comunicação cifrada
11. **Init pós-auth obrigatório** (`sendPostAuthInit`): `setCurrentTime` + `device info (2/2)` + `device state (2/78)` + `battery (2/1)`. Sem isso a banda re-dispara auth a cada ~6 s.

> **Primeiro pareamento.** Na primeira conexão a banda envia `sub=16` e o primeiro watch-nonce **sempre falha o HMAC**; apenas uma reconexão limpa autentica. `BandManager.retryAuthAfterReconnect()` derruba e reconecta automaticamente (limite `maxAuthRetries`). Confirmado em hardware (Mi Band 10, 2026-06-19).

> O AuthKey (secretKey) tem 16 bytes (hex 32 chars). Keychain com `kSecAttrAccessibleAfterFirstUnlock`. Nunca em SwiftData/UserDefaults/logs. Nonces e HMACs **podem** ser logados em debug (não são segredos); chaves de sessão e AuthKey, nunca.

### Comandos de Sincronização

| Command | type | subtype | Descrição |
|---|---|---|---|
| Fetch today | 8 | 2 | Lista os file-ids de atividade pendentes do dia |
| Fetch past | 8 | 3 | Lista o backlog de dias ainda não sincronizados |
| Fetch request | 8 | 3 | Solicita o conteúdo de um file-id (stream em chunks) |
| Fetch ACK | 8 | 5 | Marca um file-id como sincronizado |

O mesmo mecanismo de file-ids serve **todos** os tipos de dado — cada id de 7 bytes (`XiaomiActivityFileMeta`) declara seu tipo/subtype/detailType, e `BandSyncer.syncToHealth()` roteia para o parser certo:

| Tipo de arquivo | subtype | Parser |
|---|---|---|
| Resumo diário | `0x00` SUMMARY | `DailySummaryParser` |
| Detalhe diário (por minuto) | `0x00` DETAILS | `DailyDetailsParser` |
| Sono | `0x03` / `0x08` | `SleepDetailsParser` (ver nota) |
| Medições manuais | `0x06` | `ManualSamplesParser` |
| Treino (resumo) | SPORTS · SUMMARY | `WorkoutSummaryParser` |
| Treino (rota GPS) | SPORTS · GPS | `WorkoutGpsParser` |

Sono `0x08`: cada entrada de estágio é UInt16 BE — bits[15:12]=stage (0=awake,1=light,2=deep,3=rem), bits[11:0]=duração_min.

> **Dois formatos de sono.** O GadgetBridge usa `SleepStagesParser` para `0x03` (ACTIVITY_SLEEP_STAGES, layout por **eventos de transição**, códigos de estágio `2=deep,3=light,4=rem,5=awake`) e `SleepDetailsParser` para `0x08` (layout por **duração**). Hoje roteamos ambos para o `SleepDetailsParser`, o que está correto só para `0x08` — um arquivo `0x03` produz sessão vazia silenciosamente. Confirmar em hardware qual subtype a Mi Band 10 emite antes de portar o `SleepStagesParser`.

### Background BLE no iOS

- `bluetooth-central` configurado via `INFOPLIST_KEY_UIBackgroundModes = "bluetooth-central"` no `project.pbxproj` (não em Info.plist separado — ver "Armadilhas Conhecidas")
- `CBCentralManager` instanciado com `CBCentralManagerOptionRestoreIdentifierKey: "com.myband.central"` para state restoration
- Implementar `centralManager(_:willRestoreState:)` para reconectar após o app ser suspenso
- Reconnect automático via `connect(_:options:)` ao receber `didDisconnectPeripheral`, com backoff exponencial (máx. 5 tentativas)

---

## Extração do AuthKey

### Método 1 — Input Manual
- Usuário obtém o AuthKey via ferramentas externas (GadgetBridge export, Xiaomi Cloud scraper Python)
- App exibe campo hex de 32 caracteres com validação
- Salvar no Keychain com `kSecAttrAccessibleAfterFirstUnlock` (acessível em background)

### Método 2 — Xiaomi Cloud API
- Endpoint: `https://account.xiaomi.com` → login → token de sessão
- Com o token, chamar a API de dispositivos para obter `encryptedAuthKey`
- Descriptografar com a senha do usuário (AES derivado de MD5 da senha)
- Referência de implementação: `AstroBox-NG-main/abtools.py` (método `get_auth_key`)
- **Atenção**: armazenar credenciais Xiaomi apenas na Keychain; nunca logar ou persistir a senha

---

## HealthKit

### Tipos de Dados a Escrever

| Dado Mi Band | Tipo HealthKit |
|---|---|
| Sono (início/fim/fases) | `HKCategoryTypeIdentifier.sleepAnalysis` |
| Passos | `HKQuantityTypeIdentifier.stepCount` |
| Frequência cardíaca | `HKQuantityTypeIdentifier.heartRate` |
| SpO2 | `HKQuantityTypeIdentifier.oxygenSaturation` |
| Calorias ativas | `HKQuantityTypeIdentifier.activeEnergyBurned` |
| Distância caminhada | `HKQuantityTypeIdentifier.distanceWalkingRunning` |
| FC de repouso | `HKQuantityTypeIdentifier.restingHeartRate` |
| Temperatura corporal (medição manual) | `HKQuantityTypeIdentifier.bodyTemperature` |
| VO₂máx (treino) | `HKQuantityTypeIdentifier.vo2Max` |
| Distância ciclismo / natação (treino) | `HKQuantityTypeIdentifier.distanceCycling` / `.distanceSwimming` |
| Braçadas (natação) | `HKQuantityTypeIdentifier.swimmingStrokeCount` |
| Treino | `HKObjectType.workoutType()` via `HKWorkoutBuilder` (mapeado para `HKWorkoutActivityType`) |
| Rota de treino (GPS) | `HKSeriesType.workoutRoute()` via `HKWorkoutRouteBuilder` |

> **`appleStandHour` NÃO é gravável.** `HKCategoryTypeIdentifier.appleStandHour` é reservado (o sistema o deriva do Apple Watch). Incluí-lo em `requestAuthorization(toShare:)` lança `NSInvalidArgumentException`. A máscara de horas em pé da pulseira fica só local — não há tipo "stand hour" gravável por apps de terceiros.

### Permissões (Info.plist)
```
NSHealthUpdateUsageDescription
NSHealthShareUsageDescription
```

### Deduplicação
- Antes de escrever, consultar amostras existentes no período para evitar duplicatas
- Usar `HKQueryAnchor` com persistência em SwiftData para sincronizações incrementais

---

## Home Assistant

### Configuração
- URL local: ex. `http://homeassistant.local:8123`
- URL remota: URL do túnel Cloudflare configurado no HA
- Token: Long-Lived Access Token (armazenado no Keychain)
- Lógica de seleção: tentar local primeiro (timeout 2s), fallback para Cloudflare

### Gatilhos Predefinidos

| Evento Mi Band | Ação HA sugerida |
|---|---|
| Sono detectado (início) | `light.turn_off` em grupo de luzes do quarto |
| Sono encerrado (acordou) | `light.turn_on` com cena de manhã |
| HR acima de limiar | Notificação push via HA |
| Botão mini app pressionado | `script.run` com script configurável |

### Chamada REST

```swift
// POST /api/services/{domain}/{service}
// Authorization: Bearer {token}
// Content-Type: application/json
```

---

## App Intents e Atalhos

### Intents Disponíveis

| Intent | Parâmetros | Retorno |
|---|---|---|
| `SyncBandIntent` | — | Status da sincronização |
| `GetSleepDataIntent` | `date: Date` | `SleepSummary` (duração, eficiência, fases) |
| `GetHeartRateIntent` | `period: DateInterval` | `[HeartRateSample]` |
| `TriggerHAActionIntent` | `actionId: String` | Resultado da chamada |
| `RunBandMiniAppIntent` | `appId: String` | (Fase futura) |

### Frases Siri (AppShortcutsProvider)
- "Sincronizar minha pulseira"
- "Como foi meu sono?"
- "Qual minha frequência cardíaca?"

---

## UI / Design System

A UI é construída a partir do handoff do **Claude Design** (`My Band — Design System`, bundle exportado de claude.ai/design). Recriar fielmente em SwiftUI — copiar o **resultado visual**, não a estrutura HTML/JSX dos protótipos.

**Princípios fixos do maker:**
1. **Dark-mode first** — "gosto de modo noturno".
2. **Simples, direto, glanceável** — o app é um *gateway* em segundo plano; a UI serve para status rápido e configuração, não para tempo de tela.
3. **Native Apple** — SwiftUI, iOS 17+/macOS 14+, fiel à HIG.

**Fundações visuais:**
- **Paleta midnight** (OLED): base `#0A0B10`, cards `#14161F`, superfícies elevadas `#1A1D27`. Elevação por *lightness + hairline* `rgba(255,255,255,.07)`, não sombra.
- **Accent único**: Aurora indigo `#7C7FFF` (interação, seleção, foco, glow de conexão ativa).
- **Cores de saúde** espelham o Apple Health: HR `#FF5C7A`, passos `#46E0A0`, SpO₂ `#5BC0F8`, energia `#FF9A4C`.
- **Rampa de fases de sono** dusk→deep-night: acordado `#F6A052` → REM `#5BC0F8` → leve `#8A8CFF` → profundo `#4B45C7`.
- **Status**: ok/conectada mint `#46E0A0`, conectando/aviso âmbar `#F6C552`, desconectada/erro rosa `#FF5C6C`.
- **Tipo**: escala iOS, SF Pro on-device (Geist no kit web). Numerais de dados grandes (48–64px), tabular. AuthKey e valores técnicos em **mono**.
- **Cantos** contínuos: cards 16, sheets 20, hero/modal 28, pills redondos. **4-pt grid**, gutter 20, hit target ≥44.
- **Ícones**: SF Symbols (kit web usa Lucide como substituto). Status sempre cor + símbolo, nunca cor sozinha.

**Voz & copy (pt-BR):** sentence case, sem emoji, tratamento por **você**, dispositivo = "a pulseira". Tom calmo e factual ("Sincronizado há 2 min", "Eficiência 91%"). Número é o herói. Honestidade técnica: AuthKey/BLE/HA mostrados em mono, AuthKey mascarado por padrão.

**Telas (`ui_kits/app/`):** `Dashboard` (sono em destaque + status), `SleepDetail` (hipnograma), `Setup` (AuthKey + scan/conexão), `Settings`. **Status de conexão + frescor do sync são first-class em toda tela.**

**Componentes do kit** (`components/`): core (`Button`, `IconButton`, `StatusPill`, `Badge`), forms (`Switch`, `TextField`, `SegmentedControl`), data (`ListRow`, `Card`, `MetricTile`, `SectionHeader`, `SleepBar`). Cada um tem `.prompt.md` e `.d.ts` descrevendo props/variantes.

---

## SwiftData — Modelos Principais

```swift
@Model class BandDevice {
    var id: UUID
    var name: String
    var peripheralIdentifier: String  // UUID do CBPeripheral
    var lastSyncDate: Date?
    // AuthKey armazenado NO KEYCHAIN, não aqui
}

@Model class SleepSession {
    var id: UUID
    var startDate: Date
    var endDate: Date
    var phases: [SleepPhase]          // Codable embedded
    var healthKitSynced: Bool
    var device: BandDevice?
}

@Model class ActivityDay {
    var date: DateComponents           // apenas ano/mês/dia
    var steps: Int
    var calories: Double
    var distanceMeters: Double
    var healthKitSynced: Bool
}
```

---

## Changelog

O projeto segue [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) e [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**Toda mudança notável deve ser registrada em `CHANGELOG.md` antes do commit**, nas categorias:

| Categoria | Quando usar |
|---|---|
| `Added` | Nova funcionalidade |
| `Changed` | Mudança em funcionalidade existente |
| `Deprecated` | Funcionalidade a ser removida em versão futura |
| `Removed` | Funcionalidade removida |
| `Fixed` | Correção de bug |
| `Security` | Correção de vulnerabilidade |

Entradas pendentes de release ficam sob `## [Unreleased]`. Ao lançar uma versão, mover para `## [X.Y.Z] - YYYY-MM-DD`.

Versão atual: **0.1.0** (camada BLE completa: auth HMAC-SHA256 validada em hardware, SwiftProtobuf, transporte com ACK, init pós-auth; modelos SwiftData; sincronização com Apple Health cobrindo sono, atividade diária, medições manuais e treinos com rota GPS). Próxima fase: UI (SleepDetail/Settings) e validação em hardware dos parsers de treino/medição manual.

---

## Convenções de Código

- **Nenhum comentário óbvio** — nomear bem, não comentar o que é evidente
- **Comentar apenas WHY não-óbvios**: invariantes de protocolo BLE, workarounds de hardware
- **@Observable** em vez de ObservableObject (Swift 5.9+)
- **async/await** para todas as operações BLE e de rede — sem callbacks aninhados
- **`BandManager` é `@Observable @MainActor NSObject`** — não um Swift `actor` puro. CBCentralManagerDelegate exige NSObject; configurar `CBCentralManager` com `queue: .main` faz os callbacks chegarem na main thread, alinhado com `@MainActor` sem bridging extra
- **Nenhum force-unwrap** — tratar erros explicitamente
- Mínimo iOS 17 / macOS 14 — usar APIs modernas sem shims de compatibilidade

---

## Armadilhas Conhecidas

### Xcode 16 — PBXFileSystemSynchronizedRootGroup
O projeto usa sincronização automática de pasta (`PBXFileSystemSynchronizedRootGroup`): **qualquer arquivo criado dentro de `My Band/My Band/` é incluído automaticamente no build**.
- **Não criar `Info.plist` dentro de `My Band/My Band/`** — causará "Multiple commands produce Info.plist".
- O Info.plist do projeto fica em **`$(SRCROOT)/Info.plist`** (raiz do projeto, fora da pasta sincronizada). `GENERATE_INFOPLIST_FILE = NO` e `INFOPLIST_FILE = "Info.plist"` no pbxproj.
- Ao criar subpastas (`BLE/`, `Auth/`, etc.), usar `XcodeMakeDir` do MCP do Xcode para que sejam registradas corretamente no projeto.

### INFOPLIST_KEY_UIBackgroundModes gera `<string>`, não `<array>`
`INFOPLIST_KEY_UIBackgroundModes = "bluetooth-central"` com `GENERATE_INFOPLIST_FILE = YES` gera o tipo errado no plist — `<string>` em vez de `<array>`. `CBCentralManager` valida o tipo em runtime e lança `NSInternalInconsistencyException: State restoration of CBCentralManager is only allowed for applications that have specified the "bluetooth-central" background mode`. **Sempre usar o Info.plist manual** com `<array><string>bluetooth-central</string></array>`.

### CBCentralManagerOptionRestoreIdentifierKey no Simulator
O iOS Simulator não suporta state restoration do CoreBluetooth. Envolver em `#if !targetEnvironment(simulator)` para evitar crash no simulator.

### CommonCrypto — Exclusividade de acesso Swift
Ao usar `Data.withUnsafeMutableBytes`, capturar `data.count` em uma variável local **antes** do closure para evitar o erro de exclusividade:
```swift
let capacity = output.count          // capturar ANTES
output.withUnsafeMutableBytes { buf in
    CCCrypt(..., buf.baseAddress, capacity, ...)  // usar variável
}
```

### BandManager.startScan() — Race condition com CBCentralManager
`CBCentralManager` é inicializado de forma assíncrona. Se `startScan()` for chamado (ex: de `.onAppear`) antes de `centralManagerDidUpdateState(.poweredOn)` disparar, o guard `central.state == .poweredOn` falha silenciosamente e o scan nunca inicia.
Solução implementada: flag `pendingScan` em `BandManager`. Se BT não estiver pronto, `pendingScan = true`; `centralManagerDidUpdateState` consome o flag e chama `startScan()` quando o BT ficar `poweredOn`.

### ModelContainer — fatalError após watchdog kill
Watchdog kills (app em background excedendo tempo de handlers) podem corromper o arquivo SQLite do SwiftData. No próximo launch, `ModelContainer(for:configurations:)` falha e a versão original chamava `fatalError` imediatamente, aparecendo como "Message from debugger: killed" sem nenhum log útil.
Solução implementada: se `ModelContainer` falhar, deletar os arquivos `.store`, `.store-shm` e `.store-wal` e tentar novamente antes de chamar `fatalError`. Perda de dados locais aceitável em desenvolvimento; em produção trocar por migração.

### dyld AVPlayerView — Erro de debug no Mac
Ao rodar o app no Mac (iOS app via camada `/System/iOSSupport/`), o debugger do Xcode carrega `libViewDebuggerSupport.dylib` da plataforma MacOSX, que tenta resolver `_OBJC_CLASS_$_AVPlayerView` no AVKit iOS onde a classe não existe. Resulta em "Message from debugger: killed" sem log do app.
**Não é um bug do app.** Solução: rodar no iPhone físico. Para BLE, o iPhone físico é obrigatório de qualquer forma — o Simulator e o Mac não se conectam com a Mi Band.

### BandManager.handleAuthPayload — Roteamento heurístico
Durante autenticação, `handleCommandChannelPacket` tenta decodificar o header proto para rotear, mas os primeiros pacotes de resposta de auth podem não seguir o formato esperado. O fallback atual trata qualquer pacote no canal COMMAND durante estado `authenticating` como resposta de auth. **Verificar com hardware real e ajustar se necessário.**

---

## Build e Testes

```bash
# Compilar (requer Xcode 16+)
xcodebuild -scheme "My Band" -destination "platform=iOS Simulator,name=iPhone 15 Pro"

# Testes unitários (parsers de protocolo, conversão HealthKit)
xcodebuild test -scheme "My Band" -destination "platform=iOS Simulator,name=iPhone 15 Pro"
```

- Testar lógica de protocolo BLE com dados capturados reais (fixtures em `Tests/Fixtures/`)
- Não mockar `CBCentralManager` em testes de unidade — testar apenas camadas de parsing/conversão
- Testes de integração BLE apenas em dispositivo físico

---

## Referências

- `AstroBox-NG-main/` — referência de protocolo BLE para wearables e estrutura de protobufs
- [GadgetBridge Mi Band 8/9/10 source](https://codeberg.org/Freeyourgadget/Gadgetbridge) — implementação de referência do protocolo
- [OpenWRT Mi Band community docs](https://github.com/argrento/huami-token) — extração de AuthKey via Xiaomi Cloud
- HealthKit Developer Documentation — Apple
- App Intents Developer Documentation — Apple
