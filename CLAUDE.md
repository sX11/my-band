# CLAUDE.md — My Band

Guia de arquitetura e diretrizes para o projeto **My Band**: app iOS/macOS universal que conecta a Mi Band 10 via BLE usando AuthKey, sincroniza dados de saúde com o Apple Health e suporta Atalhos via App Intents. Os dados de saúde ficam no Apple Health; as exceções são o card Today da Dashboard, com os contadores ao vivo da pulseira (ADR 0005), e a folha Health, com o último valor de cada leitura vindo do último sync (ADR 0006).

---

## Visão Geral do Projeto

| Item | Detalhe |
|---|---|
| Plataformas | iOS 26+ (um único target Xcode; roda no Mac via "Designed for iPad and iPhone", não é target macOS nativo — `IPHONEOS_DEPLOYMENT_TARGET` no pbxproj é a fonte da verdade) |
| Linguagem | Swift 5.10+ |
| UI | SwiftUI, Liquid Glass no chrome/status (`MBStatusPill` etc.) |
| Persistência | SwiftData |
| Bluetooth | CoreBluetooth (BLE apenas — Mi Band 10 não usa Classic BT) |
| Saúde | HealthKit — única superfície de dados armazenados; a Dashboard mostra os contadores ao vivo do dia (ADR 0005) e o último valor de cada leitura do último sync (ADR 0006) |
| Automação | App Intents + Shortcuts |
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
│   ├── WorkoutGpsService.swift   # Handshake GPS durante treinos (band→app workoutOpenWatch)
│   ├── FindPhoneService.swift    # "Encontrar telefone": alarme no iPhone (band→app CMD_FIND_PHONE)
│   ├── CalendarSyncService.swift # Push app→band: idioma, calendário e lembretes (EventKit)
│   ├── WeatherSyncService.swift  # Push app→band: tempo atual + previsão (Open-Meteo)
│   ├── BandSettingsService.swift # Configurações da pulseira (FC, SpO₂, estresse, lembretes, tela): GET/SET + releitura
│   ├── TodayActivityService.swift # Leitura única do realtime stats para o card Today da Dashboard
│   ├── Scale/                    # Balança BLE OKOK/Chipsea (independente da pulseira)
│   │   ├── ScaleManager.swift    # Escuta o anúncio (broadcast-only) e grava peso no Apple Health
│   │   └── ScaleWeightParser.swift # Decode do peso (variante VC0)
│   └── Services/
│       ├── MiBandUUID.swift      # Constantes de UUID dos serviços GATT
│       └── PacketParser/         # Parsers por tipo (sono, diário, manual, treinos+GPS, FC intra-treino)
│
├── Auth/
│   ├── AuthKeyStore.swift        # Armazenamento seguro do AuthKey no Keychain
│   ├── XiaomiCloudAuth.swift     # Extração do AuthKey via Xiaomi Cloud (login usuário/senha → beaconkey/token)
│   └── XiaomiCloudCrypto.swift   # RC4/SHA-1/SHA-256 da API de conta (separado do XiaomiCrypto BLE)
│
├── Health/
│   ├── HealthKitManager.swift    # Autorização e escrita no Apple Health
│   └── HealthSyncService.swift  # Conversão dados Mi Band → tipos HealthKit
│
├── Intents/
│   ├── SyncBandIntent.swift      # App Intent: sincronizar dados agora
│   ├── GetSleepStateIntent.swift # App Intent: "você está dormindo?" (pull, não push — ver nota)
│   ├── CheckBandBatteryIntent.swift # App Intent: notifica só se a bateria estiver abaixo do limite
│   └── BandShortcuts.swift       # AppShortcutsProvider com frases Siri
│
├── MiniApp/                      # (Fase futura) Mini app na pulseira
│   └── README.md                 # Documentação do protocolo de mini apps
│
├── Models/
│   ├── BandDevice.swift          # SwiftData model do dispositivo pareado
│   ├── SleepSession.swift        # SwiftData model de sessão de sono
│   ├── ActivityDay.swift         # SwiftData model de atividade diária
│   ├── LatestMetrics.swift       # Snapshot do último valor de cada leitura, para a folha Health (ADR 0006)
│   └── HeartRateSample.swift     # SwiftData model de amostras de HR
│
└── UI/
    ├── Dashboard/                # Tela principal com resumo de dados
    ├── Setup/                    # Fluxo de configuração (AuthKey + HA)
    ├── Sleep/                    # Visualização detalhada de sono
    ├── Profile/                  # Perfil do usuário (altura → IMC no Apple Health)
    ├── Customize/                # Watch faces e apps RPK
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
| `0000180F-0000-1000-8000-00805F9B34FB` | Battery Service (GATT padrão) — o que o iOS lê para o widget Baterias |
| `00002A19-0000-1000-8000-00805F9B34FB` | Battery Level — `UInt8` 0–100, read + notify (lido **só pós-auth**, ver `CheckBandBatteryIntent`) |

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

> **Primeiro pareamento — o app espera o usuário, por dois prompts e através da queda de link entre eles** (decisão e trade-offs em `docs/adr/0003-patient-band-driven-handshake.md`, incluindo o adendo de 2026-09-09)**.** A primeira conexão pede **duas** confirmações, em ordem e em telas diferentes: a pulseira levanta o próprio diálogo (`auth sub=16`, subtype que o GadgetBridge nem trata) e só depois o iOS levanta a folha de pareamento Bluetooth — e para estabelecer o bond o **iOS derruba a conexão**. Por isso a espera é um **deadline de 180 s (`pairingDeadline`) que atravessa conexões**, não um estado da conexão corrente: `resetState` limpa só o flag por conexão e `startNonceExchange` restaura a espera ao reconectar dentro da janela. Enquanto ela está aberta: HMAC divergente é esperado (a pulseira assina com um bond que ainda não existe) e apenas estende a janela, o watchdog se re-arma, e o orçamento de `retryAuthAfterReconnect` **não é gasto** — um pareamento demorado não pode terminar em `badHMAC` ("AuthKey incorreto"). Uma divergência numa pulseira contra a qual nunca autenticamos (`everAuthenticated`, `UserDefaults`) inicia a espera em vez de contá-la. `CBATTError.insufficientAuthentication` num write **não é falha**: é o iOS avisando que vai pedir o pareamento — é o único sinal concreto do segundo prompt, e antes matava o handshake no instante em que a folha subia. `CBError.peerRemovedPairingInformation` → `AuthError.staleBond` (esquecer o dispositivo em Ajustes › Bluetooth; reconectar nunca resolve). `PairingStage` (`.band` → `.phone`, só avança) alimenta o checklist de dois passos da tela de conexão e **não decide lógica de protocolo**. O `sub=16` e as divergências pré-aceite estão confirmados em hardware (Mi Band 10, 2026-06-19 e 2026-09-05); o caminho **completo do aceite** ainda **não** foi exercitado — os logs vieram de uma pulseira já pareada e de tentativas que falhavam.

> **A pulseira reabre a sessão sozinha — e isso invalida as chaves.** Logo depois do init pós-auth ela manda um novo `session-config-accept`, zera o próprio contador de sequência e refaz o handshake (novo watch-nonce, novo `sub=27`). O GadgetBridge (`XiaomiBleProtocolV2.processPacket`, `PACKET_TYPE_SESSION_CONFIG`) chama `startEncryptedHandshake()` a **todo** pacote de session config, sem olhar estado — é por isso. Ignorar esse pacote deixa o app com as chaves antigas: a pulseira ACKa o frame de transporte e **descarta o comando em silêncio**, então o sync fica pendurado até o timeout com o link parecendo perfeito. `handleSessionConfigResponse` refaz o handshake quando o estado é `.connected` (limite `maxBandSessionRestarts`), e só ignora um repeat que chegue com o handshake ainda em voo (`.authenticating`) — que é onde morava o bug do 005F. Confirmado em hardware (2026-09-05).
>
> **O restart cai exatamente onde o sync começa.** `ensureConnected` resolve na primeira auth, então um sync que abriu o link manda o `FETCH_TODAY` na janela do restart — e ele se perde. `BandManager.onSessionRestart` avisa o `BandSyncer`, que faz a troca de comando em voo falhar na hora (`SyncError.sessionRestarted`) e a reenvia após o re-handshake (`surviveSessionRestart` + `BandManager.awaitSession`), para listagens e arquivos. `ensureConnected` chamado com um handshake em andamento só espera (reconectar por cima refazia a descoberta de serviços e disparava um segundo `authenticate()`). Passado o `maxBandSessionRestarts`, o link é derrubado para o standing reconnect recomeçar limpo.

> **Nonce atrasado ≠ falha.** Depois do `CMD_AUTH`, a banda reemite um watch-nonce próprio — um reinício de handshake do lado dela, não uma resposta ao nosso. Verificá-lo contra o phone-nonce já superado **sempre** falha; a banda confirma o handshake original de qualquer forma. `authStep3Sent` faz o app ignorar nonces com `CMD_AUTH` em voo e esperar o `sub=27`. Pelo mesmo motivo (um nonce já no ar quando o nosso `CMD_NONCE` saiu foi assinado contra um phone-nonce que a banda ainda não viu), `maxNonceMismatches` tolera 2 divergências por troca de nonce antes de escalar — uma AuthKey de fato errada diverge sempre e continua terminando em `AuthError.badHMAC`. Sem isso, o mesmo pacote derrubava um handshake a um passo do sucesso (log de hardware 2026-09-05, onde as duas ordens aparecem: o nonce atrasado antes do `sub=27` matava a conexão, depois do `sub=27` era inofensivo).

> **Watchdog de auth.** `armAuthWatchdog()` — 20 s normal, 120 s durante o pareamento — re-armado por todo pacote de auth que progride. Antes, `AuthError.timeout` só saía de uma desconexão: "Tempo esgotado" na verdade queria dizer "o link caiu" (hoje `AuthError.linkDropped`) e uma banda que emudecesse ficava pendurada. Ao estourar **fora** de um pareamento, o watchdog derruba o link para que o standing reconnect reassuma; dentro da janela de pareamento ele apenas se re-arma (silêncio ali é uma pessoa lendo um diálogo) e só falha quando a janela vence, com `AuthError.pairingNotConfirmed`. `retryAuthAfterReconnect` adia o teardown com atraso crescente (1–4 s) — reconectar na hora gastava as 4 tentativas em segundos.

> O AuthKey (secretKey) tem 16 bytes (hex 32 chars). Keychain com `kSecAttrAccessibleAfterFirstUnlock`. Nunca em SwiftData/UserDefaults/logs. Nonces e HMACs **podem** ser logados em debug (não são segredos); chaves de sessão e AuthKey, nunca.

> **A chave precisa sobreviver a updates, renomeações e relaunches** (ver `docs/adr/0004-authkey-keychain-durability.md`)**.** `AuthKeyStore` indexa o item por um `service` **fixo** (`com.myband.authkey`), não pelo bundle id lido em runtime — senão uma renomeação de bundle/target faria o app se apresentar como não pareado com a chave intacta sob o nome antigo; o item legado (bundle id) é migrado na primeira leitura. `save` atualiza no lugar (o `delete`+`add` anterior perdia a chave se o add falhasse) e o item é fixado como **não-sincronizável**, para que nenhuma entrada do iCloud Keychain sombreie a local. `isStored` distingue `errSecItemNotFound` de `errSecInteractionNotAllowed`: num relaunch em background **antes do primeiro desbloqueio pós-boot** a chave existe mas é ilegível, e responder "não tem chave" ali mandava um usuário já pareado de volta ao setup.

### Comandos de Sincronização

| Command | type | subtype | Descrição |
|---|---|---|---|
| Fetch today | 8 | 1 | Lista os file-ids de atividade pendentes do dia |
| Fetch past | 8 | 2 | Lista o backlog de dias ainda não sincronizados |
| Fetch request | 8 | 3 | Solicita o conteúdo de um file-id (stream em chunks) |
| Fetch ACK | 8 | 5 | Marca um file-id como sincronizado |

### Comandos iniciados pela pulseira (band → app)

Alguns recursos são **push** da pulseira: ela manda o comando e o app reage. `BandManager` os decodifica após auth e dispara callbacks (`onWorkoutOpenWatch`, `onWorkoutStatusWatch`, `onFindPhone`, `onWeatherConditionsRequest`), consumidos por serviços dedicados.

| Comando | type | subtype | Quem trata | Reação |
|---|---|---|---|---|
| `CMD_FIND_PHONE` | 2 (SYSTEM) | 17 | `FindPhoneService` | `system.findDevice` 0=iniciar / ≠0=parar. Alarme: `AVAudioSession.playback` + sirene em loop sintetizada + vibração + notificação. Auto-stop em 45 s. |
| `workoutOpenWatch` | 8 (HEALTH) | 30 | `WorkoutGpsService` | Inicia CoreLocation e responde GPS ready/disabled |
| `workoutStatusWatch` | 8 (HEALTH) | 26 | `WorkoutGpsService` | started/resumed/paused/finished → controla o stream de GPS (paused para de transmitir); ao **finished** dispara `onWorkoutFinished(fileIds)` → `BandSyncer.syncWorkoutFiles` busca os arquivos nomeados (resumo + rota GPS) |
| `CMD_REQUEST_CONDITIONS_FOR_LOCATION` | 10 (WEATHER) | 3 | `WeatherSyncService` | Banda pede o tempo (ao conectar / abrir a tela de tempo) → app responde com push de tempo, ecoando a chave/nome de localização pedida. Ver "Configuração enviada à pulseira". |

> **O fim de treino dispara um sync automático e direcionado.** `workoutStatusWatch` status=finished **carrega os `activityFileIds`** do treino recém-gravado (resumo + rota GPS). `BandManager` os repassa no callback (`onWorkoutStatusWatch(status, fileIds)`) → `WorkoutGpsService.onWorkoutFinished(fileIds)` → `BandSyncer` aguarda ~8 s (flush do arquivo pela pulseira) e roda `syncWorkoutFiles(_:)` se ainda conectado, buscando/parseando/gravando/ACKando **exatamente** esses arquivos — sem relistar o backlog (FETCH_TODAY/PAST). Firmware que omita os ids cai no `syncToHealth()` completo. O loop de processamento por arquivo é compartilhado em `BandSyncer.processActivityFiles`. Totais diários, que o treino também atualiza, ficam para o próximo sync regular.
>
> **Não há trigger equivalente para "acordar".** A Mi Band 10 não envia um evento de fim de sono; o sono só é buscado quando o app roda o fetch (foreground ou `BackgroundSyncManager`). Fora do fim de treino, o modelo continua sendo **pull**: o app reconecta e busca os file-ids pendentes.

### Configuração enviada à pulseira (app → band)

`CalendarSyncService` (idioma/calendário/lembretes) e `WeatherSyncService` (tempo, via Open-Meteo) fazem push cifrado ao final de `BandSyncer.syncToHealth()`, junto com os dados de saúde/exercícios e enquanto o link está ativo (best-effort — não derruba o sync de saúde). Cada seção é independente — uma permissão negada ou falta de rede não bloqueia as outras.

| Dado | type | subtype | Proto | Origem / observações |
|---|---|---|---|---|
| Idioma | 2 (SYSTEM) | 6 `CMD_LANGUAGE` | `system.language.code` | `Locale` → `"pt_br"` minúsculo |
| Calendário | 12 | 1 `CMD_CALENDAR_SET` | `calendar.calendarSync.event[]` | EventKit, próximos 30 dias, ≤50, **substitui** o set na banda |
| Lembrete (listar) | 17 (SCHEDULE) | 14 `CMD_REMINDERS_GET` | `schedule.reminders` | lista da banda (ids, título/hora, `maxReminders`), lida antes de cada push |
| Lembrete (criar) | 17 | 15 `CMD_REMINDERS_CREATE` | `schedule.createReminder` | EventKit, só os que ainda vão disparar (alerta › vencimento › 09:00 se só data), ≤20 e ≤ vagas da banda |
| Lembrete (apagar) | 17 | 18 `CMD_REMINDERS_DELETE` | `schedule.deleteReminder.id[]` | apaga só os lembretes deste app antes de recriar |
| Tempo (localização) | 10 | 7 `CMD_ADD_LOCATION` | `weather.location` | `WeatherSyncService`, chave `accu:<hash>` |
| Tempo (atual) | 10 | 0 `CMD_SET_CURRENT_WEATHER` | `weather.current` | Open-Meteo, Guarapuava |
| Tempo (previsão) | 10 | 1 `CMD_UPDATE_DAILY_FORECAST` | `weather.forecast` | 7 dias (hoje + 6) |

> **O tempo é request-driven — a pulseira pede, o app responde.** A Mi Band 10 envia `CMD_REQUEST_CONDITIONS_FOR_LOCATION` (type=10, subtype=3) ao conectar e ao abrir a tela de tempo; a tela fica **aguardando a resposta a esse request**, então o push proativo (ao fim do `syncToHealth()`) sozinho não popula o widget. `BandManager.handleWeatherCommand` roteia subtype=3 para o callback `onWeatherConditionsRequest`, e `WeatherSyncService` responde com um push completo (location → current → forecast). A resposta **ecoa a chave/nome de localização que a banda pediu** (`requestedKey`/`requestedName`) para que ela vincule os dados; sem request, o push usa a localização padrão com `isCurrentLocation=true`. Status≠0 das respostas da banda aos nossos pushes (subtypes 0/1/7) é logado. Espelha `XiaomiWeatherService.onConditionRequestReceived` do GadgetBridge.

> **Id de lembrete é atribuído pela banda.** O create não carrega id; a banda responde com `schedule.ackId` (type=17, subtype=15). `BandManager.onScheduleAck` captura esses ids, que `CalendarSyncService` persiste (`UserDefaults`) junto com título e hora de cada lembrete enviado. No sync seguinte ele lê a lista da banda (`onReminderList`) e apaga os ids que conhece **e** os que batem em título+hora com o que enviou — um ack perdido não deixa mais um lembrete órfão disparando para sempre, e lembretes criados por outro app não são tocados. Sem a lista, o push é adiado para o próximo sync. `Esquecer pulseira` limpa esse estado (`CalendarSyncService.forgetBand`).

> **Frames > MTU.** Calendário com muitos eventos passa do ATT MTU. `BandManager.writeSPP` fragmenta a frame em chunks do tamanho do MTU (`maximumWriteValueLength`); a banda reassembla pelo comprimento declarado na frame. Pacotes de auth/init cabem em um chunk — caminho do handshake inalterado.

O mesmo mecanismo de file-ids serve **todos** os tipos de dado — cada id de 7 bytes (`XiaomiActivityFileMeta`) declara seu tipo/subtype/detailType, e `BandSyncer.syncToHealth()` roteia para o parser certo:

| Tipo de arquivo | subtype | Parser |
|---|---|---|
| Resumo diário | `0x00` SUMMARY | `DailySummaryParser` |
| Detalhe diário (por minuto) | `0x00` DETAILS | `DailyDetailsParser` |
| Sono (por duração) | `0x08` (qualquer detail) | `SleepDetailsParser` (ver nota) |
| Sono (por transição) | `0x03` DETAILS | `SleepStagesParser` (ver nota) |
| Medições manuais | `0x06` | `ManualSamplesParser` |
| Treino (resumo) | SPORTS · SUMMARY | `WorkoutSummaryParser` |
| Treino (rota GPS) | SPORTS · GPS | `WorkoutGpsParser` |
| Treino (detalhe FC/seg) | SPORTS · DETAILS | `WorkoutDetailsParser` |

> **Série de FC por segundo do treino (`WorkoutDetailsParser`).** Durante o treino a pulseira grava um arquivo `SPORTS · DETAILS` (subtype `0x08`) com **uma amostra de FC por segundo**. O GadgetBridge **não** parseia isso (`XiaomiActivityParser.createForSports` só trata `SUMMARY`/`GPS_TRACK` e descarta o resto), então o layout foi revertido de uma captura real (Mi Band 10, 2026-06-23, version 3) e validado por CRC-32: `[id:7][pad:1][header:11]` com a duração (s) em `u16@10` (== nº de amostras), seguido de `duração` amostras `[fc:u8][flag:u8][00][00]`, 1 Hz a partir do início (fc=0 nos ~18 s de aquisição do sensor; `flag=1` a cada ~12 amostras, um keyframe — ignorado). `BandSyncer` casa a série ao treino pelo timestamp (igual à rota GPS) e `HealthKitManager.writeWorkouts` anexa as amostras ao `HKWorkout` (no builder, antes do `finishWorkout`, sync-id por amostra). Só version 3 confirmada; outras versões → série vazia (o arquivo ainda é ACKado). Para outros subtypes/versões de `SPORTS · DETAILS` (ex.: `0x16`, version 5) o parser devolve vazio e o `else` de `processActivityFiles` apenas ACKa — sem o ACK a pulseira re-oferece o arquivo a cada conexão (re-download perpétuo; um deles tinha 12 KB). Novas fixtures: `dumpActivityFileFixture` (DEBUG).

Sono `0x08`: cada entrada de estágio é UInt16 BE — bits[15:12]=stage (0=awake,1=light,2=deep,3=rem), bits[11:0]=duração_min.

> **Dois formatos de sono.** O GadgetBridge usa `SleepStagesParser` para `0x03` (ACTIVITY_SLEEP_STAGES, layout por **eventos de transição**, códigos de estágio `2=deep,3=light,4=rem,5=awake`) e `SleepDetailsParser` para `0x08` (layout por **duração**). **Validado em hardware (Mi Band 10, 2026-06-21): o fetch real de sono funciona com o `SleepDetailsParser` — a pulseira emite `0x08`.** O `0x03` antes caía no mesmo parser, que lia os bytes nos offsets errados; agora vai para o `SleepStagesParser` portado (só version 2, como no GadgetBridge; coberto por arquivo sintético, **não** por captura real). Versões de `0x08` fora de 1–5 devolvem vazio em vez de adivinhar o layout. `BandSyncer` loga uma linha por arquivo de sono (`Sleep file … N session(s), N phase(s), N HR, N SpO₂`) — é por ela que se vê, no console, se uma noite chegou e em que formato.
>
> **Um arquivo de sono nunca é confirmado sem ser lido nem derruba o resto.** Se a pulseira responde um fetch com outro arquivo ainda sem ACK, esse arquivo é roteado normalmente e só então ACKado (antes era ACKado às cegas, perdendo o conteúdo). A gravação do sono roda isolada em `processActivityFiles`: se ela lança, só os arquivos de sono ficam sem ACK e voltam no próximo sync — manuais, treinos e detalhe diário seguem. O fetch de cada arquivo usa timeout de **inatividade** (10 s sem chunk), não um teto fixo.

### Instalação de watch faces e apps (app → band)

Recurso de personalização (`BLE/Upload/`), portado do GadgetBridge. As mensagens proto já estavam no `xiaomi.pb.swift`. **Não toca em firmware** (`TYPE_FIRMWARE=32`) — risco de brick.

| Camada | type | subtypes | Serviço |
|---|---|---|---|
| Watch faces | 4 | list=0, set=1, delete=2, install=4 | `WatchfaceService` |
| Apps (RPK / quick apps) | 20 | list=0, install=1, installed=2, delete=3 | `AppInstallService` |
| Upload em chunks | 22 | uploadStart=0 | `DataUploadService` |

**Fluxo de install (faces e apps idêntico, só muda o tag de tipo):**
1. App anuncia o arquivo: faces `watchfaceInstallStart{id,size}`; apps `rpkInfo{id,versionCode,size}`.
2. Banda responde com status (faces `watchface.installStatus`; apps `rpk.rpkInstallStart.cmd`). `0` = aceito.
3. App abre o upload: `CMD_UPLOAD_START{type, md5(arquivo), size}` (type **16**=watchface, **64**=rpk).
4. Banda responde `dataUploadAck{unknown2, resumePosition, chunkSize (default 2048)}` — suporta retomada.
5. App monta o envelope e transmite em chunks:
   ```
   envelope = [0x00][type][md5:16][size:u32 LE][bytes do arquivo a partir de resumePosition]
   payload  = envelope + crc32(envelope):u32 LE
   chunk    = [totalParts:u16 LE][parteAtual:u16 LE][fatia de (chunkSize-4) bytes]
   ```
6. Watch face: ao terminar, app envia `set` (ativa) + `list`. App RPK: a banda envia `installed` (sub=2) e o app pede `list`.

> **Chunks de upload vão no canal DATA (2) em texto claro** — `XiaomiSppPacket.buildDataChunk`, opCode PLAINTEXT (GadgetBridge: `CHANNEL_DATA → OPCODE_SEND_PLAINTEXT`). Diferente dos comandos (canal PROTOBUF, AES-CTR): o envelope se protege com md5 + crc32. `BandManager.sendDataChunk` faz **pacing** contra o buffer de `writeWithoutResponse` do CoreBluetooth via `peripheralIsReady(toSendWriteWithoutResponse:)`, senão um upload grande estoura o buffer e perde frames.

> **Formatos de arquivo** (`InstallableFile`): watch face = binário, magic `0x5A 0xA5`, id numérico NUL-terminated em `0x28`, nome em `0x68`. App = ZIP com `manifest.json` (`package`/`name`/`versionCode`), lido por `MiniZip` (Foundation não descompacta entradas de ZIP no iOS) + inflate via framework `Compression` (`COMPRESSION_ZLIB` = raw deflate).

> **A validar em hardware:** o canal exato dos chunks (DATA=2) e o pacing; e se a Mi Band 10 aceita faces da comunidade (pode haver trava de região/modelo). Importação via document picker (Files), download por URL e share sheet (`onOpenURL` + `CFBundleDocumentTypes`).

### Background BLE no iOS

- `bluetooth-central` configurado via `INFOPLIST_KEY_UIBackgroundModes = "bluetooth-central"` no `project.pbxproj` (não em Info.plist separado — ver "Armadilhas Conhecidas")
- `CBCentralManager` instanciado com `CBCentralManagerOptionRestoreIdentifierKey: "com.myband.central"` para state restoration
- Implementar `centralManager(_:willRestoreState:)` para reconectar após o app ser suspenso
- Reconnect automático via `connect(_:options:)` ao receber `didDisconnectPeripheral`, com backoff exponencial (máx. 5 tentativas)

### Orquestração de sincronização

`BackgroundSyncManager` é o **ponto de entrada único** de todo sync (foreground ou background). Todos os gatilhos passam por `syncNow(disconnectWhenDone:)`, que **coalesce** chamadas concorrentes em um único `Task` em voo — botão do Dashboard, App Intent/Siri, BGTask e o acordar por BLE nunca disparam dois fetches ao mesmo tempo. `disconnectWhenDone`: `nil` = só desconecta se o próprio sync abriu o link (link vivo em foreground permanece); `true`/`false` força (acordares em background passam `true` para liberar o rádio). `syncToHealth()`/`syncWorkoutFiles()` também têm guard de reentrância (`!isSyncing`), serializado pelo `@MainActor` (guard + set antes do primeiro `await`).

Gatilhos de background, em ordem de frequência/confiabilidade:
1. **Acordar por BLE (state restoration).** Quando a pulseira volta ao alcance, o CoreBluetooth relança o app; ao autenticar, `BandSyncer.onAuthenticated` chama `syncOnBackgroundWakeIfStale()` — só roda se em background, com throttle por `lastHealthSync` (15 min) e desconexão ao fim. É o caminho mais confiável (o evento BLE é que acorda o app).
2. **`BGAppRefreshTask`** (`com.myband.refresh`) — leve, agendado com frequência pelo SO.
3. **`BGProcessingTask`** (`com.myband.sync`) — pesado/deferível, costuma rodar carregando.

Ambos os BGTasks são registrados em `register()` (do `AppDelegate.didFinishLaunching` — única janela permitida pelo `BGTaskScheduler.register`) e reagendados em `scheduleNext()` ao ir para segundo plano (`scenePhase`). `Info.plist`: os dois ids em `BGTaskSchedulerPermittedIdentifiers` e os background modes `fetch` (app-refresh) + `processing`. Em launch a frio disparado por uma task, `awaitDependencies()` espera o `configure()` da UI. O `expirationHandler` é instalado **no próprio closure do `register`**, na fila do scheduler, antes do pulo para o main actor — esse pulo já levou 6 s num app recém-retomado, e uma tarefa que expira sem handler é completada como falha pelo iOS (que passa a agendar menos). `finish(_:success:)` garante um único `setTaskCompleted`, venha ele do sync ou da expiração.

> O fim de treino tem seu próprio caminho (`handleWorkoutFinished`): espera ~8 s o flush do arquivo e busca os file-ids nomeados via `syncWorkoutFiles`, sem passar pelo `syncNow` (mas protegido pelo mesmo guard `!isSyncing`).

---

## Extração do AuthKey

O onboarding (`UI/Setup/SetupView.swift`) é uma máquina de passos: `intro → choose → (xiaomi | key) → conexão`. A tela `choose` oferece os dois métodos; ambos terminam produzindo um hex de 32 chars que passa por `AuthKeyStore.saveHex` (validação + Keychain) e segue para `ConnectingView` (mesmo `onConnect` no `RootView`).

### Método 1 — Input Manual (`SetupView.keyEntry`)
- Usuário obtém o AuthKey via ferramentas externas (GadgetBridge export, `token_extractor/`, Xiaomi Cloud) e cola no campo
- App exibe campo hex de 32 caracteres com validação
- Salvar no Keychain com `kSecAttrAccessibleAfterFirstUnlock` (acessível em background)
- É o **fallback** de toda falha do método 2 (link "Inserir AuthKey manualmente" em cada etapa)

### Método 2 — Xiaomi Cloud via usuário/senha (`Auth/XiaomiCloudAuth.swift`, `UI/Setup/XiaomiLoginView.swift`)
Porta o `PasswordXiaomiCloudConnector` do `token_extractor/token_extractor.py` — login com o usuário e a senha da conta Xiaomi, digitados nesta tela. Substituiu o fluxo anterior por QR (`QrCodeXiaomiCloudConnector`): **troca consciente** — a versão QR nunca expunha a senha ao app (autenticação inteira do lado da Xiaomi), mas dependia de um segundo aparelho ou de um long-poll frágil enquanto o usuário saía e voltava ao app. Login+senha é mais direto e não depende de mais nada, ao custo de a senha passar pela memória do processo do My Band — nunca persistida, nunca logada, só usada para montar o hash MD5 e o corpo cifrado do POST de login. Fluxo (espelha os steps do Python):

1. `GET serviceLogin` → `_sign` (raramente já vem uma sessão pronta com `ssecurity`)
2. `POST serviceLoginAuth2` com `user` + `hash=MD5(senha)` + `_sign` → `ssecurity`, `userId`, `location`
   - Se vier `captchaUrl`: mostra a imagem, usuário digita o texto, reenvia o POST com `captCode`
   - Se vier `notificationUrl`: é 2FA por e-mail — segue a cadeia `identity/list` → `sendEmailTicket` → usuário digita o código recebido → `verifyEmail` → `identity/result/check` → `Auth2/end` (lê `ssecurity` do header não-padrão `extension-pragma`, por isso essas chamadas usam um delegate que **não segue redirect** — só assim dá pra ler os headers da própria resposta de redirecionamento) → redirect para `sts.api.io.mi.com/sts`, que finalmente grava o cookie `serviceToken`
3. Se o passo 2 não veio com `serviceToken` já (fluxo sem 2FA): `GET location` → cookie `serviceToken` — é a etapa de **confirmação de que o login realmente aconteceu**, antes de seguir para a busca de dispositivos
4. Para cada região (`cn, de, us, ru, tw, sg, in, i2`), chamadas **cifradas**: `get_homes` + `get_dev_cnt` → casas; `get_devices` → dispositivos; a Mi Band 10 é `miwear.watch.*` com `did` numérico (não contém `blt`) e já carrega o AuthKey no campo `token` — só cai no `blt_get_beaconkey` para dispositivos BLE legados sem `token` inline
5. Uma pulseira → auto-seleciona; várias → usuário escolhe; a chave entra no mesmo `onConnect`

- **Máquina de fases** (`XiaomiCloudAuth.Phase`): `idle → enteringCredentials → authenticating → [awaitingCaptcha | awaiting2FA] → confirmingLogin → fetchingDevices → done`. Captcha e 2FA suspendem a `Task` de login numa `CheckedContinuation` guardada na instância; `submitCaptcha`/`submit2FACode` (chamados pela UI) a resolvem — não há polling, é passo a passo.
- **Crypto da API** (`Auth/XiaomiCloudCrypto.swift`, separado do `XiaomiCrypto` do BLE): RC4/ARC4 com o **descarte de 1024 bytes de keystream** do pycryptodome, SHA-1, SHA-256 e MD5 (CryptoKit `Insecure.MD5` — só para compatibilidade com o hash de senha legado do endpoint, não é escolha de segurança nossa). `signedNonce = base64(SHA256(b64dec(ssecurity) || b64dec(nonce)))`; cada param é `base64(RC4(key=b64dec(signedNonce)))`; assinatura `base64(SHA1("POST&path&k=v&...&signedNonce"))` — **ordem das chaves preservada** e codificação **`quote_plus`** (réplica do `requests.urlencode`, senão `+`/`/`/`=` quebram a assinatura ou o `_sign`/hash da senha, que também passam pela query string do login). Path = tudo após o primeiro `"com"`, com `/app/` → `/`.
- **`URLSession` efêmera** com cookie jar próprio em memória — nada do login persiste em disco.
- Logs de debug (`[XiaomiCloud]`, só DEBUG) imprimem status/cookies/presença de token — **nunca** os valores de usuário, senha, `serviceToken` ou beaconkey/token.
- **A validar (conta real):** os endpoints da Xiaomi Cloud são frágeis e dependentes de região/conta, e a cadeia de 2FA por e-mail em particular persegue vários redirects e um header não-padrão — portada fielmente da referência, mas sem validação ao vivo ainda (login simples, com captcha, e com 2FA).
- **Atenção**: o token/beaconkey é o segredo de pareamento — tratado como AuthKey (Keychain, nunca logado/persistido fora dele).

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
| Peso (balança BLE) | `HKQuantityTypeIdentifier.bodyMass` (+ `.bodyMassIndex` derivado de `.height` lida do Health) |
| Esforço físico (METs/min: kcal ativas da pulseira ÷ peso do Health) | `HKQuantityTypeIdentifier.physicalEffort` |
| Esforço do treino, escala 1–10 (FC média ÷ FCmáx por idade, Tanaka) | `.estimatedWorkoutEffortScore` (iOS 18+, via `relateWorkoutEffortSample`) |
| Recuperação cardíaca (pico do fim do treino − FC/min em fim+60 s) | `HKQuantityTypeIdentifier.heartRateRecoveryOneMinute` |
| Velocidade em treino (pontos GPS V2, m/s) | `.runningSpeed` / `.cyclingSpeed` |
| Passada média de corrida (distância ÷ passos) | `HKQuantityTypeIdentifier.runningStrideLength` |
| Distância de remo (iOS 18+; antes caía em distância a pé) | `HKQuantityTypeIdentifier.distanceRowing` |

> **`appleStandHour` NÃO é gravável.** `HKCategoryTypeIdentifier.appleStandHour` é reservado (o sistema o deriva do Apple Watch). Incluí-lo em `requestAuthorization(toShare:)` lança `NSInvalidArgumentException`. A máscara de horas em pé da pulseira fica só local — não há tipo "stand hour" gravável por apps de terceiros. O mesmo vale para `appleExerciseTime`, `appleMoveTime`, `appleStandTime` (anéis de atividade) e `walkingHeartRateAverage` — todos read-only para terceiros, sem contorno.
>
> **Recuperação cardíaca roda no caminho do arquivo diário, não no `writeWorkouts`.** A série 1 Hz do treino termina exatamente no fim do treino (count == duration), então a leitura de fim+60 s só chega no arquivo de detalhe diário seguinte. `writeHeartRateRecoveries` consulta os treinos recentes **do próprio app** no Health (independe de qual sync gravou o treino), casa o pico do último minuto (série 1 Hz, `HKStatisticsQuery` discreteMax) com a leitura por minuto mais próxima de fim+60 s (±30 s) e grava o delta. Best-effort no `BandSyncer` — não bloqueia os ACKs dos arquivos.
>
> **Mobilidade continua exclusiva do iPhone.** `walkingSpeed`/`walkingStepLength` são graváveis, mas alimentariam as métricas de Mobilidade que a reconciliação preserva de propósito — por isso a série de velocidade só é escrita para corrida/ciclismo (`speedType(_:)` devolve nil para caminhada/trilha) e a passada usa `runningStrideLength`, não `walkingStepLength`.

### Permissões (Info.plist)
```
NSHealthUpdateUsageDescription
NSHealthShareUsageDescription
```

### Deduplicação
- Antes de escrever, consultar amostras existentes no período para evitar duplicatas
- Usar `HKQueryAnchor` com persistência em SwiftData para sincronizações incrementais

> **Reconciliação entre fontes (passos / distância / energia ativa).** O iPhone grava essas mesmas grandezas, e o Apple Health **soma** toda fonte de terceiros por cima do iPhone — a dedup privada iPhone+Watch não se estende a terceiros e **não há API** para mudar a agregação nem registrar a pulseira como fonte confiável. Gravar o total da pulseira cru dobra a contagem (caminhada de 200 → 400). Solução (`HealthKitManager.writeReconciledActivity`): grava-se só o **excedente** da pulseira sobre o iPhone, por minuto — `delta = max(0, banda − iPhone)`, com a soma do iPhone obtida via `HKStatisticsCollectionQuery` em buckets de 1 min e predicado `fonte ≠ este app`. O total por minuto vira `max(banda, iPhone)`: sem double-count, **Mobilidade do iPhone preservada** (Assimetria/Comprimento do Passo/Velocidade/Estabilidade ao Caminhar — a pulseira não produz nada disso e elas exigem o Monitoramento de Fitness **ligado**), e passos sem o telefone ainda capturados. Funciona porque a pulseira reporta minutos **já concluídos**: quando o minuto sincroniza, o pedômetro do iPhone já o finalizou, então o delta é estável e o re-sync (idempotente via sync-id) reproduz o mesmo valor — sem necessidade de `HKObserverQuery` para o dia corrente.
>
> **A fonte oficial dessas três grandezas é o arquivo de detalhe diário (por minuto).** `writeDailySummary` deixou de gravar passos/energia (manteria-se somando); ele só escreve extremos band-exclusivos (FC/SpO₂, FC de repouso). Se o usuário **negar a leitura** no HealthKit, os somatórios do iPhone voltam vazios e grava-se o valor cheio da pulseira (direção segura — pulseira como fonte). **SpO₂ fica fora da reconciliação** (o iPhone não tem o sensor) e continua cru por minuto em `writeMinuteSamples`, granularidade intacta.

---

## Balança BLE (OKOK/Chipsea)

`BLE/Scale/` integra uma balança BLE OKOK/Chipsea, **independente da pulseira** (CoreBluetooth próprio). Porta os caminhos de peso da integração [homeassistant-okokscale](https://github.com/rrooggiieerr/homeassistant-okokscale) (Apache-2.0).

- **`ScaleWeightParser`** — decodifica o peso do *manufacturer data* do anúncio BLE (`[companyId:2 LE][payload]`). Variante **VC0** (validada em hardware, balança "Yoda1"): casada pelo **byte baixo do company id = `0xC0`** (espelha o `key & 0xFF == 0xC0` da integração); payload de 13 bytes, peso em `bytes[0..1]` BE, `byte[6]` traz a unidade (`(b>>3)&3`: 0=kg, 2=lb, 3=st:lb) e o **bit-final** (`b&1`). Normaliza tudo para kg.
- **`ScaleManager`** (`@Observable @MainActor NSObject`) — só **escaneia**, nunca conecta. Escreve uma pesagem por vez: qualquer frame zero/não-final **rearma** (`lastFinalWeight = nil`), e um novo frame final não-zero conta como nova pesagem (subir de novo no mesmo peso loga de novo). Grava via `HealthKitManager.writeBodyMass` (`bodyMass` + `bodyMassIndex` quando há `height` no Health), sync-id por timestamp (idempotente).

> **A balança é broadcast-only.** Confirmado em hardware: **não aceita conexão GATT** (todo `connect` dá timeout, mesmo durante a medição) e **não anuncia service UUID**. Consequências: (1) escuta **foreground-only** — scan sem filtro de serviço não funciona em background no iOS (a pulseira, com state restoration por UUID, continua em background normalmente); (2) **só o peso é recuperável**. A impedância **não chega ao telefone** — o anúncio carrega só o peso (bytes 2-3 são um `0x1388` constante, não impedância) e não há GATT. Os números de composição corporal do app OKOK (gordura %, massa magra, água…) são **estimativa a partir de peso + perfil**, não bioimpedância real: validado observando que todas as métricas se movem **monotonicamente com o peso** entre duas pesagens. Por isso o My Band grava só `bodyMass`/`bodyMassIndex` (dado medido), não composição corporal estimada.

---

## App Intents e Atalhos

> **Home Assistant foi cortado do roadmap** (decisão registrada só aqui, nunca chegou a ter código — ver conversa/histórico). A integração REST direta que este documento chegou a especificar não será construída. No lugar dos gatilhos que ela ofereceria (sono detectado, HR acima de limiar), o app expõe **estado via App Intent** e deixa a automação inteiramente a cargo das Automações Pessoais do próprio Atalhos do usuário — sem o app precisar saber nada sobre luzes, cenas ou scripts de terceiros.

### Intents Disponíveis

| Intent | Parâmetros | Retorno |
|---|---|---|
| `SyncBandIntent` | — | Status da sincronização |
| `GetSleepStateIntent` | — | `Bool` (dormindo?) + diálogo com a idade do dado |
| `CheckBandBatteryIntent` | `threshold: Int` (1–100, padrão 30) | `Int?` (nível) + notificação local **só** se abaixo do limite |
| `RunBandMiniAppIntent` | `appId: String` | (Fase futura) |

> **`GetSleepStateIntent` é pull, não push.** A pulseira não tem evento de "dormi"/"acordei" (ver "Comandos iniciados pela pulseira" acima) — sono só é conhecido depois que o app sincroniza. O intent força uma sincronização (`BackgroundSyncManager.shared.syncNow()`, best-effort — falha não é fatal) antes de responder, e considera o dado "dormindo" só se a última sessão sincronizada terminar há menos de 1h e sua última fase não for `.awake`. O diálogo sempre declara a idade do dado ("dormindo, dado de X min atrás"), pra uma Automação Pessoal encadeada nunca agir silenciosamente sobre um estado velho.

> **`CheckBandBatteryIntent` é silencioso por padrão.** Pensado para uma Automação Pessoal "ao conectar o carregador do iPhone": lembrar de pôr a pulseira para carregar junto. Um atalho que falasse a cada execução viraria ruído, então ele **não tem diálogo** — roda o sync completo **segurando o link** (`syncNow(disconnectWhenDone: false)`; com o padrão, o sync desconectava o link que ele mesmo abriu e o pedido abaixo virava código morto), pede uma leitura fresca enquanto o link está aberto (`BandManager.refreshBattery` — o nível em memória pode estar velho numa conexão longa), espera as respostas (teto de 3 s, não um sleep) e só age se `nível < threshold` **e** a pulseira não estiver já no carregador, postando uma notificação local. O nível também sai como valor de retorno, para quem quiser encadear a própria condição. Pulseira fora de alcance → responde com o último nível conhecido em vez de falhar o atalho (e a automação inteira); sem nenhuma leitura → `nil`, sem notificar. O rádio é liberado no fim do intent, e só se não havia link vivo antes dele.
>
> **O nível é o mesmo do widget Baterias do iOS.** Não há API para ler o widget (ele usa o framework privado `BatteryCenter`), mas dá para ler a **mesma fonte**: o Battery Service GATT padrão (`0x180F` / `0x2A19`), que o iOS consulta nos acessórios BLE pareados. `BandManager` o descobre junto com o `FE95` e, quando existe, a `2A19` é dona de `batteryLevel`; o `CMD_BATTERY` do protobuf continua sendo pedido porque só ele traz o estado de carregamento (`battery.state == 1`). Sem o `180F`, o nível volta a vir do protobuf. **Leitura e assinatura da `2A19` só depois da auth**: se a característica exigir criptografia, tocá-la num link ainda sem bond faria o iOS levantar a folha de pareamento *antes* do diálogo da pulseira, invertendo a ordem dos dois prompts em que o ADR 0003 se apoia. Consequência aceita: sem auth não há leitura GATT, mesmo que a pulseira a exponha.

### Frases Siri (AppShortcutsProvider)
- "Sincronizar minha pulseira"
- "Estou dormindo no My Band"
- "Ver se estou dormindo no My Band"
- "Verificar bateria da pulseira no My Band"

---

## UI / Design System

A UI é construída a partir do handoff do **Claude Design** (`My Band — Design System`, bundle exportado de claude.ai/design). Recriar fielmente em SwiftUI — copiar o **resultado visual**, não a estrutura HTML/JSX dos protótipos.

> **O Apple Health é a superfície de dados de saúde** (ADR 0005, que substitui o 0001). A Dashboard mostra estado de conexão, frescor do sync, bateria, alarmes, configurações da pulseira e o card Today — passos, kcal e FC lidos uma vez do realtime stats da pulseira e nunca armazenados; horas em pé vêm do resumo diário do último sync. O card Latest metrics abre a folha Health com o último valor de cada leitura (FC, SpO₂, estresse, temperatura, resumo do dia, última noite, peso), guardado como um único snapshot sobrescrito (ADR 0006). Sem histórico, sem gráficos, e não existe (nem está planejada) uma tela `SleepDetail`/hipnograma; sono continua com o Apple Health e o Atalho `GetSleepStateIntent`.

**Princípios fixos do maker:**
1. **Dark-mode first** — "gosto de modo noturno".
2. **Simples, direto, glanceável** — o app é um *gateway* em segundo plano; a UI serve para status rápido e configuração, não para tempo de tela — levado ao extremo: nem os próprios dados de saúde aparecem em tela.
3. **Native Apple** — SwiftUI, iOS 26+, Liquid Glass no chrome/status (ver ADR 0001), fiel à HIG.

**Fundações visuais:**
- **Paleta midnight** (OLED): base `#0A0B10`, cards `#14161F`, superfícies elevadas `#1A1D27`. Elevação por *lightness + hairline* `rgba(255,255,255,.07)`, não sombra.
- **Accent único**: Aurora indigo `#7C7FFF` (interação, seleção, foco, glow de conexão ativa).
- **Cores de saúde** espelham o Apple Health: HR `#FF5C7A`, passos `#46E0A0`, SpO₂ `#5BC0F8`, energia `#FF9A4C`.
- **Rampa de fases de sono** dusk→deep-night: acordado `#F6A052` → REM `#5BC0F8` → leve `#8A8CFF` → profundo `#4B45C7`.
- **Status**: ok/conectada mint `#46E0A0`, conectando/aviso âmbar `#F6C552`, desconectada/erro rosa `#FF5C6C`.
- **Tipo**: escala iOS, SF Pro on-device (Geist no kit web). Numerais de dados grandes (48–64px), tabular. AuthKey e valores técnicos em **mono**.
- **Cantos** contínuos: cards 16, sheets 20, hero/modal 28, pills redondos. **4-pt grid**, gutter 20, hit target ≥44.
- **Ícones**: SF Symbols (kit web usa Lucide como substituto). Status sempre cor + símbolo, nunca cor sozinha.

**Voz & copy (pt-BR):** sentence case, sem emoji, tratamento por **você**, dispositivo = "a pulseira". Tom calmo e factual ("Sincronizado há 2 min", "42 amostras no Apple Health"). Métrica de saúde só no card Today (ADR 0005) e no card/folha Latest metrics (ADR 0006); fora dele o número é sempre de status/sync. Honestidade técnica: AuthKey/BLE mostrados em mono, AuthKey mascarado por padrão.

**Telas (`ui_kits/app/`):** `Dashboard` (status de conexão, frescor do sync, bateria, sincronizar, alarmes, configurações da pulseira, o card Today — ADR 0005 — e a folha Health — ADR 0006), `Setup` (AuthKey + scan/conexão), `Settings`. **Não existe `SleepDetail`.** Status de conexão + frescor do sync são first-class em toda tela.

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

Versão atual: **1.2.0** — ver `CHANGELOG.md` para o histórico completo. Próxima fase, tudo **a validar em hardware**:

1. O pareamento paciente num pareamento **novo** de verdade (ADR 0003 + adendo) — a janela de 180 s atravessando a queda de link do bonding, o avanço de `PairingStage` para `.phone`, se a folha do iOS realmente produz um `CBATTError.insufficientAuthentication` observável (ou sobe sem rejeitar write nenhum), e o restart de sessão que a pulseira faz depois do aceite. Os logs de 2026-09-05 vieram de uma pulseira já pareada e de tentativas que falhavam, não de um aceite bem-sucedido.
2. O sync completo depois do fix de restart de sessão — se a pulseira reabre a sessão e o app rederiva as chaves, o `FETCH_TODAY` deve finalmente receber resposta em vez de só ACKs. No console, um sync numa conexão nova deve mostrar `FETCH_TODAY cut short by a band session restart — re-sending after re-auth` seguido de `FETCH_TODAY → N file ID(s)`, e cada noite uma linha `Sleep file …`.
3. O login Xiaomi Cloud por usuário/senha com captcha e 2FA (ADR 0002; login simples já confirmado).
4. O `GetSleepStateIntent`.
5. O `CheckBandBatteryIntent` — em especial o `CMD_BATTERY` sob demanda fora do init pós-auth (a resposta chega no mesmo `handleSystemCommand`, mas nunca foi exercitada com o link já aberto há tempo). E se a Mi Band 10 expõe o Battery Service `0x180F` a apps (a linha `Services:` do log da conexão responde), se a `2A19` lê sem erro pós-auth e se o número bate com o widget Baterias — o log imprime os dois (`via GATT 2A19` / `via protobuf — keeping GATT`).

Home Assistant foi cortado do roadmap; UI segue sem histórico nem gráficos de saúde por decisão (ADR 0005, que substitui o 0001, e ADR 0006).

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

### HealthKit — Tipos Reservados dos Anéis do Apple Watch
O HealthKit **proíbe expressamente** que apps de terceiros solicitem permissão de compartilhamento (`toShare`) para identificadores proprietários dos anéis de atividade do Apple Watch:
- `HKCategoryTypeIdentifierAppleStandHour`
- `HKQuantityTypeIdentifierAppleExerciseTime`
- `HKQuantityTypeIdentifierAppleMoveTime`

Passar qualquer um desses tipos em `requestAuthorization(toShare:read:)` lança imediatamente `NSInvalidArgumentException: Authorization to share the following types is disallowed: ...`. O tempo de exercício deve ser contabilizado pelo sistema a partir dos `HKWorkout` gravados, nunca escrito diretamente.

### Sanitização de Pacotes Cumulativos de Sono da Mi Band
A Mi Band 10 envia os estágios de sono (pacotes do tipo 17) de forma cumulativa. Se múltiplos pacotes forem processados sem deduplicação/mesclagem temporal (`sanitizeStages`), os minutos de sono são somados repetidamente no HealthKit, inflando as sessões. Além disso, timestamps brutos da Xiaomi em `firstRecordTime` exigem decodificação sem sinal (`u32`) e validação de época para evitar anos 1928 e 1970.

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

## Agent skills

### Issue tracker

Issues e specs são rastreados como GitHub Issues em `matheusdanoite/my-band`, usando a CLI `gh`. Ver `docs/agents/issue-tracker.md`.

### Triage labels

Vocabulário padrão de labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). Ver `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` na raiz do repo. Ver `docs/agents/domain.md`.

---

## Referências

- `AstroBox-NG-main/` — referência de protocolo BLE para wearables e estrutura de protobufs
- [GadgetBridge Mi Band 8/9/10 source](https://codeberg.org/Freeyourgadget/Gadgetbridge) — implementação de referência do protocolo
- [OpenWRT Mi Band community docs](https://github.com/argrento/huami-token) — extração de AuthKey via Xiaomi Cloud
- HealthKit Developer Documentation — Apple
- App Intents Developer Documentation — Apple
