---
status: accepted
---

# A AuthKey precisa sobreviver a updates, renomeações e relaunches

A AuthKey é o segredo de pareamento da pulseira e o único estado que o app **não** consegue reconstruir sozinho: perdê-la significa mandar o usuário refazer o onboarding inteiro (extração via Xiaomi Cloud ou cópia manual dos 32 hex). O `BandDevice` no SwiftData é descartável — a pulseira é redescoberta por scan. A chave não é.

O `AuthKeyStore` original tratava o Keychain como um dicionário simples, e três detalhes discretos podiam apagar ou esconder a chave:

1. **O item era indexado pelo bundle id lido em runtime** (`Bundle.main.bundleIdentifier`). Uma renomeação de bundle ou de target faria o app se apresentar como não pareado com a chave intacta no Keychain, sob o nome antigo.
2. **`save` fazia `delete` + `add`.** Se o `add` falhasse, a chave já tinha ido embora — um erro transitório de Keychain virava um re-pareamento.
3. **`isStored` era `(try? load()) != nil`.** Isso colapsa "não existe" e "não dá para ler agora" na mesma resposta. Num relaunch em background — state restoration do CoreBluetooth quando a pulseira volta ao alcance — **antes do primeiro desbloqueio pós-boot**, um item `kSecAttrAccessibleAfterFirstUnlock` existe mas é ilegível. O app respondia "sem chave" e roteava um usuário já pareado de volta para o setup.

## Decisão

- **`service` fixo** (`com.myband.authkey`), deliberadamente desacoplado do `Bundle.main`, com migração automática do item legado (bundle id) na primeira leitura.
- **`save` atualiza no lugar** (`SecItemUpdate`, com `SecItemAdd` só quando o item não existe).
- **Item fixado como não-sincronizável** (`kSecAttrSynchronizable: false`, também na query), para que nenhuma entrada do iCloud Keychain sombreie ou substitua a local.
- **`AuthKeyError.locked` separado de `.notFound`**: `isStored` responde `true` para um Keychain bloqueado. Direção segura — o app se comporta como pareado e a leitura real tenta de novo mais tarde.
- `kSecAttrAccessibleAfterFirstUnlock` continua, e continua obrigatório: sem ele o sync em background não consegue ler a chave.

## Consequências

- **O `service` fixo é agora uma constante de compatibilidade**, não um detalhe. Mudá-la sem migração é a mesma classe de bug que ela corrige.
- **Não há `kSecAttrAccessGroup`.** A chave ainda se perde se o app for reassinado com outro Team ID. Um split multi-target (ex.: uma extensão que precise da chave) exige decidir um access group explícito e migrar de novo.
- **Um Keychain genuinamente quebrado agora aparece como erro de conexão**, não como "configure a chave". É o trade-off do ponto 3 e é o comportamento certo: mandar um usuário pareado para o setup é uma perda de dados disfarçada de tela.
