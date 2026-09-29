# My Band

> A Xiaomi fez a Mi Band. Eu a transformei em My Band.

App nativo **iOS/macOS** (SwiftUI + SwiftData) que conecta o iPhone a uma **Mi Band 10** via Bluetooth Low Energy e sincroniza os dados de saúde com o **Apple Health** — sem a nuvem da Xiaomi no caminho, direto da pulseira para um local centralizado e agnóstico. Também expõe estado e ações via Atalhos e Siri, para automações do próprio iPhone.

O app oficial da Mi Band 10 não envia todas as métricas coletadas pelo gadget ao Apple Health. O My Band existe para preencher essa lacuna — e para que os dados de saúde sejam de fato do usuário.

---

## Destaques de engenharia

Este é um projeto pessoal que serviu de laboratório para BLE, criptografia aplicada e integração profunda com o HealthKit. O que o torna interessante do ponto de vista técnico:

- **🔐 Autenticação criptográfica revertida e validada em hardware.** Handshake da Mi Band 10 implementado do zero em Swift: troca de nonce, HMAC-SHA256, derivação de chaves de sessão via HKDF e comunicação cifrada com AES (CTR/CCM). Testado em uma pulseira física, com dados reais.
- **📡 Engenharia reversa de protocolo binário.** Formato de pacotes (frames, CRC-16/ARC, transporte confiável com ACK, protobuf) e parsers para sono, treinos e rota GPS. Inclusive uma **série de frequência cardíaca por segundo que a implementação de referência open-source (GadgetBridge) não decodifica** — layout revertido a partir de capturas reais e validado por CRC-32.
- **❤️ Integração profunda com HealthKit.** Sono, passos, FC, SpO₂, treinos com rota GPS, esforço físico, esforço de treino e recuperação cardíaca. Passos, distância e energia vão crus por minuto; o Apple Health mescla os minutos em comum com o iPhone pela ordem de Fontes de Dados.
- **🏗️ Concorrência moderna e disciplina de arquitetura.** Swift 5.10, `async/await`, `@Observable`, `@MainActor`, BLE em segundo plano com state restoration, testes unitários com fixtures de dados reais e um AuthKey que nunca sai do Keychain.

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
| ✅ | UI de Setup (AuthKey + scan/conexão) e Dashboard (bateria, última sync, botão sincronizar, próximo alarme, configurações da pulseira card Today — passos, kcal, horas em pé, FC — e folha Health com a última leitura de cada métrica) via Claude Design |
| ✅ | Envio ao Apple Health — sono (estágios) e atividade diária (passos, calorias, distância, FC + FC de repouso, SpO₂) — **validado em hardware (Mi Band 10)** |
| ✅ | Sincronização em segundo plano via `BGProcessingTask` (reconecta, sincroniza e reagenda com o app suspenso) — **validada em hardware** |
| ✅ | Medições manuais no Apple Health (FC, SpO₂) — **validado em hardware (Mi Band 10)** |
| ✅ | Treinos no Apple Health (`HKWorkout` + rota GPS + VO₂máx) e handshake GPS com o iPhone (CoreLocation → `workoutLocation` stream) — **validado em hardware** |
| ✅ | Série de FC por segundo do treino anexada ao `HKWorkout` (gráfico de FC dentro do treino) — **validada em hardware** |
| ✅ | Métricas ricas no Apple Health — esforço físico (METs/min), esforço de treino (iOS 18+), recuperação cardíaca, velocidade/passada e distância de remo, derivadas de medições reais |
| ✅ | Passos/distância/energia crus por minuto, mesclados pelo Apple Health conforme a ordem de Fontes de Dados (coloque o iPhone acima de My Band) — **ainda não validado no hardware** |
| ✅ | Balança BLE OKOK/Chipsea (broadcast-only) → peso + IMC no Apple Health, com perfil de altura — **validada em hardware** |
| ✅ | Extração do AuthKey via Xiaomi Cloud (login por QR, sem app Xiaomi) |
| ✅ | Target de testes unitários (Swift Testing, 23 testes) com fixtures reais — **validado no iPhone** |
| ✅ | Integração com Atalhos via App Intents e frases Siri — **validada em hardware** |
| ✅ | Atalho de bateria da pulseira com limite configurável — notifica só abaixo do limite, feito para a automação "ao plugar o iPhone no carregador" (v1.2) |
| ✅ | Sanitização e deduplicação de estágios de sono e validação fisiológica de sinais vitais (v1.1) |
| 🔜 | Telas SleepDetail (hipnograma) + Settings |
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

- **Via o próprio app** — o Setup guia a extração via **Xiaomi Cloud com login por QR** (sem digitar senha no app; a autenticação ocorre do lado da Xiaomi). O app percorre as regiões Xiaomi e recupera o *beaconkey* da pulseira, que é o AuthKey. Fluxo portado do `token_extractor.py`, **ainda a validar com uma conta real**.
- **Via Python** — [`huami-token`](https://github.com/argrento/huami-token): faz login na conta Xiaomi e extrai o token
- **Via GadgetBridge** — exportar o AuthKey do banco de dados do app no Android

### 2. Inserir o AuthKey no app

No primeiro uso, o app abre a tela de **Setup** quando não há AuthKey no Keychain: informe os 32 caracteres hex do AuthKey (campo seguro, mascarado) e toque em **Conectar pulseira**. O app valida e armazena a chave no Keychain com acesso após o primeiro desbloqueio (`kSecAttrAccessibleAfterFirstUnlock`), permitindo sync em background. A chave **nunca** é gravada em código, logs, SwiftData ou UserDefaults.

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
> **Primeiro pareamento:** a pulseira anuncia com `auth sub=16` e só emite um watch-nonce verificável depois que você aceita **na pulseira e no iPhone**. O app espera esse aceite em vez de tratar os nonces anteriores como chave errada (ver [ADR 0003](docs/adr/0003-patient-band-driven-handshake.md)).
> O AuthKey (secretKey) tem 16 bytes. Fica **apenas no Keychain** — nunca em logs, SwiftData ou UserDefaults.

---

## Interface (UI)

A UI está sendo construída a partir de um **design system dark-mode-first** entregue pelo Claude Design — paleta *midnight* otimizada para OLED, accent Aurora indigo, cores de saúde espelhando o Apple Health e uma rampa de fases de sono. Copy em **pt-BR**, foco em status glanceável e configuração rápida (o app é um gateway em segundo plano). Detalhes de tokens, componentes e telas em [`CLAUDE.md`](CLAUDE.md#ui--design-system).

---

## Referências

- [GadgetBridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) — implementação de referência do protocolo Mi Band 10 V2 (auth, parsers de atividade/treino, watch faces/RPK, tempo)
- [huami-token](https://github.com/argrento/huami-token) — extração de AuthKey via Xiaomi Cloud
- [homeassistant-okokscale](https://github.com/rrooggiieerr/homeassistant-okokscale) (Apache-2.0) — referência do decode da balança BLE OKOK/Chipsea (variante VC0)
- [Open-Meteo](https://open-meteo.com/) — previsão do tempo enviada à pulseira (grátis, sem chave)
- AstroBox-NG — referência de protocolo BLE para wearables (não incluída no repositório público)
- [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) / [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

> Este projeto porta trechos de protocolo do GadgetBridge e do homeassistant-okokscale (engenharia reversa de formatos BLE). Os créditos a esses projetos estão acima; nenhum AuthKey, credencial ou segredo é incluído no repositório.

---

## Changelog

Ver [`CHANGELOG.md`](CHANGELOG.md).
