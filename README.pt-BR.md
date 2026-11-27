<p align="center">
  <img src="docs/images/sloth.png" alt="Sloth" width="250">
</p>

# <p align="center">Unlazier</p>

<p align="center">
  <a href="README.md">English</a> | <b>Português (Brasil)</b> | <a href="README.es.md">Español</a>
</p>

> Esta é uma tradução do [README em inglês](README.md), que é a versão oficial e pode estar mais atualizada.

Assistentes de IA para programação são poderosos, mas costumam pegar atalhos. Eles adivinham o que você quis dizer em vez de perguntar, escrevem mais código do que o necessário, mexem em coisas que você não pediu e deixam trabalho pela metade.

O Unlazier é um conjunto de regras que faz esses assistentes trabalharem com mais cuidado. Você instala uma vez, e todas as ferramentas de IA para programação que você usa passam a seguir as mesmas regras em todos os projetos.

- **Uma instalação, nove ferramentas:** Claude Code, Codex CLI, Gemini CLI, Devin, Kiro, Cline, OpenCode, Amp e GitHub Copilot CLI, no Linux, no macOS e no Windows.
- **Regras que continuam valendo:** em toda ferramenta que permite, um lembrete curto as repete a cada mensagem, para que sessões longas não se desviem.
- **Ritmo de acordo com os seus limites de uso:** o assistente trabalha em paralelo quando há folga e desacelera à medida que as suas janelas de 5 horas e semanal vão enchendo. No Claude Code, ele então espera sozinho pelo reinício e retoma o trabalho, e hooks impõem cada etapa.
- **Alertas sonoros:** três bipes quando o assistente precisa de você ou termina a vez dele.
- **Seguro para testar:** ele acrescenta às suas configurações em vez de substituí-las, e o desinstalador remove só o que adicionou.

## Índice

- [O que você ganha](#o-que-você-ganha)
- [Ferramentas suportadas](#ferramentas-suportadas)
- [Instalação](#instalação)
- [O que muda no seu computador](#o-que-muda-no-seu-computador)
- [Limites de uso e trabalho em paralelo](#limites-de-uso-e-trabalho-em-paralelo)
- [Alertas sonoros](#alertas-sonoros)
- [Desinstalação](#desinstalação)
- [Atualizando da versão 1](#atualizando-da-versão-1)
- [Notas para cada ferramenta](#notas-para-cada-ferramenta)
- [As regras](#as-regras)
- [Personalização](#personalização)
- [Para contribuidores](#para-contribuidores)
- [Licença](#licença)

## O que você ganha

O Unlazier adiciona quatro camadas a cada ferramenta. Todas as ferramentas recebem as mesmas quatro camadas; só muda o lugar onde cada uma guarda as próprias configurações.

| Camada | O que faz | Por que importa |
|--------|-----------|-----------------|
| **1. Regras** | Coloca as regras na pasta de regras da ferramenta, um arquivo pequeno por regra, ou no arquivo de instruções globais quando a ferramenta não tem pasta de regras. O assistente as lê no início de cada sessão. | O assistente sabe o que se espera dele desde a primeira mensagem. |
| **2. Lembrete** | Reenvia um resumo curto das regras a cada mensagem sua, e os princípios principais de novo depois que a conversa é compactada (o Claude Code recarrega os arquivos de regras sozinho, então nele só o resumo volta). Quando o projeto tem o próprio arquivo de regras (`CLAUDE.md`, `AGENTS.md` ou `GEMINI.md`), também cita esse arquivo e as seções dele. | Em sessões longas, as instruções do início perdem peso conforme a conversa cresce. O lembrete mantém as regras frescas. |
| **3. Uso** | Acrescenta ao lembrete uma linha dizendo quanto dos seus limites de uso de 5 horas e semanal já foi consumido, e qual faixa de uso se aplica. | O assistente pode rodar tarefas em paralelo quando há folga, desacelerar antes de você atingir um limite e, no Claude Code, esperar o reinício e continuar. |
| **4. Alertas** | Toca três bipes curtos quando o assistente pede sua permissão, faz uma pergunta ou termina a vez dele. | Você pode fazer outra coisa enquanto ele trabalha e voltar quando ele precisar de você. |

## Ferramentas suportadas

| Ferramenta | 1. Regras | 2. Lembrete | 3. Uso | 4. Alertas |
|------------|:---------:|:-----------:|:------:|:----------:|
| Claude Code | Sim | Sim | Sim, pela status line | Sim |
| Codex CLI | Sim | Sim (precisa de uma aprovação, veja as [notas](#codex-cli)) | Sim, lido do próprio log de sessão do Codex | Sim (mesma aprovação) |
| Gemini CLI | Sim | Sim | Não disponível | Sim |
| Devin Desktop (antigo Windsurf) | Sim | Sim | Não disponível | Sim |
| Kiro | Sim | Sim | Não disponível | Só no fim da vez |
| Cline | Sim | Sim no Linux e no macOS (precisa de uma configuração, veja as [notas](#cline)) | Não disponível | Perguntas e fim da tarefa, no Linux e no macOS |
| OpenCode | Sim | Sim | Não disponível | Sim |
| Amp | Sim | Sim | Não disponível | Só no fim da vez |
| GitHub Copilot CLI | Sim | Não disponível | Não disponível | Sim |

"Não disponível" ou uma entrada parcial sempre significa que a própria ferramenta não oferece um jeito de fazer aquilo: o Copilot CLI ignora o que um hook de prompt imprime, só o Claude Code e o Codex expõem os limites de uso num formato que um programa consegue ler, o Kiro e o Amp só avisam o fim da vez, e o Cline não avisa pedidos de permissão. O Cursor não é suportado porque guarda as regras globais nas próprias configurações, e não num arquivo.

## Instalação

### Linux e macOS

Abra um terminal e rode:

```bash
curl -fsSL https://github.com/fco3lho/unlazier/releases/latest/download/install.sh | bash
```

As camadas de lembrete e de uso precisam do **jq**, uma pequena ferramenta de JSON. Se ele não estiver instalado, o instalador instala as regras mesmo assim e mostra o comando exato para instalar o jq no seu sistema (por exemplo `brew install jq` no macOS ou `sudo apt-get install -y jq` no Ubuntu). Instale o jq e rode o instalador de novo.

### Windows

Abra o **PowerShell** e rode:

```powershell
irm https://github.com/fco3lho/unlazier/releases/latest/download/install.ps1 | iex
```

No Windows não é preciso instalar mais nada.

### Conferindo o script antes

Cada versão publicada traz seus scripts com um arquivo `SHA256SUMS`. Para conferir um script antes de ele rodar, baixe-o junto com o `SHA256SUMS`, verifique-o e rode a cópia conferida:

```bash
# Linux and macOS (if sha256sum is missing, use shasum -a 256)
curl -fsSLO https://github.com/fco3lho/unlazier/releases/latest/download/install.sh
curl -fsSLO https://github.com/fco3lho/unlazier/releases/latest/download/SHA256SUMS
sha256sum --check --ignore-missing SHA256SUMS && bash install.sh
```

```powershell
# Windows
$base = 'https://github.com/fco3lho/unlazier/releases/latest/download'
Invoke-WebRequest "$base/install.ps1" -OutFile install.ps1 -UseBasicParsing
Invoke-WebRequest "$base/SHA256SUMS" -OutFile SHA256SUMS -UseBasicParsing
$expected = (Select-String -Path SHA256SUMS -Pattern ' install\.ps1$').Line.Split(' ')[0]
if ((Get-FileHash install.ps1).Hash -eq $expected) { & ([scriptblock]::Create((Get-Content -Raw install.ps1))) } else { Write-Error 'install.ps1 does not match SHA256SUMS' }
```

Opções como `--harness claude` ou `--uninstall` vão depois de `bash install.sh` (no Windows: `-Harness claude` ou `-Uninstall`, logo depois de `)))`).

### Escolhendo suas ferramentas

O instalador mostra uma lista numerada com todas as ferramentas suportadas e marca com `*` as que encontrou no seu computador. As mensagens do instalador aparecem em inglês:

```
Choose the tools to install Unlazier for (* = found on this computer):
  1) * Claude Code
  2)   OpenCode
  3) * Codex CLI
  ...
Type numbers separated by spaces, "all", or press Enter for the tools marked with *:
```

Aperte **Enter** para instalar nas ferramentas marcadas com `*`, ou digite os números que quiser (por exemplo `1 3`).

### Sem o menu

Para escolher as ferramentas no próprio comando, o que é útil em scripts:

```bash
# Linux and macOS, from a downloaded copy of this repository
./install.sh --harness claude,codex

# Linux and macOS, without downloading
curl -fsSL https://github.com/fco3lho/unlazier/releases/latest/download/install.sh | bash -s -- --harness claude,codex
```

```powershell
# Windows
& ([scriptblock]::Create((irm https://github.com/fco3lho/unlazier/releases/latest/download/install.ps1))) -Harness claude,codex
```

Nomes das ferramentas: `claude`, `opencode`, `codex`, `copilot`, `gemini`, `amp`, `kiro`, `cline`, `devin` ou `all`. Acrescente `--yes` (no Windows: `-Yes`) para responder "sim" às perguntas automaticamente.

Depois de instalar, **reinicie suas ferramentas** para que elas carreguem as mudanças.

## O que muda no seu computador

O instalador nunca substitui as suas configurações e nunca cria cópias de backup.

- **Seus arquivos continuam seus.** As ferramentas que leem uma pasta de regras (Claude Code, Devin, Kiro, Cline) recebem arquivos próprios nela, todos com o nome `unlazier-*.md`, e o seu arquivo de instruções não é alterado. As outras ferramentas leem um único arquivo de instruções, então as regras ficam dentro de um bloco marcado, que começa com `<!-- unlazier:start -->` e termina com `<!-- unlazier:end -->`; nada do que você escreveu fora desse bloco é alterado. Instalar de novo só atualiza esses arquivos e blocos.
- **Os arquivos de configuração recebem acréscimos, não substituições.** Os hooks são adicionados ao lado dos que você já tem. Um arquivo de configuração que não pode ser lido com segurança (por exemplo, um com comentários) fica como está, e o instalador avisa você.
- **Todo o resto fica numa pasta por ferramenta**, chamada `unlazier`, ao lado das configurações da própria ferramenta.

No Windows, `~` significa a sua pasta de usuário (`C:\Users\<você>`).

| Ferramenta | Regras | Lembrete e alertas | Pasta |
|------------|--------|----------|-------|
| Claude Code | `~/.claude/rules/unlazier-*.md` | hooks em `~/.claude/settings.json`; status line se você não tiver uma | `~/.claude/unlazier/` |
| Codex CLI | `~/.codex/AGENTS.md` | `~/.codex/hooks.json` | `~/.codex/unlazier/` |
| Gemini CLI | `~/.gemini/GEMINI.md` | hook em `~/.gemini/settings.json` | `~/.gemini/unlazier/` |
| Devin Desktop | `~/.devin/rules/unlazier-*.md` | hook em `~/.config/devin/config.json` (Windows: `%APPDATA%\devin\config.json`) | `~/.devin/unlazier/` |
| Kiro | `~/.kiro/steering/unlazier-*.md` | `~/.kiro/hooks/unlazier.json` e `unlazier-alert.json` | `~/.kiro/unlazier/` |
| Cline | `~/Documents/Cline/Rules/unlazier-*.md` | `UserPromptSubmit`, `PreToolUse` e `TaskComplete` em `~/Documents/Cline/Hooks/` | `~/Documents/Cline/unlazier/` |
| OpenCode | `~/.config/opencode/AGENTS.md` | `~/.config/opencode/plugins/unlazier.ts` | `~/.config/opencode/unlazier/` |
| Amp | `~/.config/amp/AGENTS.md` | `~/.config/amp/plugins/unlazier.ts` | `~/.config/amp/unlazier/` |
| GitHub Copilot CLI | `~/.copilot/copilot-instructions.md` | `~/.copilot/hooks/unlazier.json` (só alertas) | `~/.copilot/unlazier/` |

Se você mudou o lugar das configurações de uma ferramenta com a variável de ambiente dela (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `COPILOT_HOME`, `GEMINI_CLI_HOME`, `KIRO_HOME`), o instalador usa esse lugar.

## Limites de uso e trabalho em paralelo

Assinaturas como as do Claude e do ChatGPT limitam quanto você pode usar numa janela de 5 horas e numa semana. O Unlazier coloca cada janela numa de quatro faixas, e a mais restritiva das duas define como o assistente trabalha:

| Faixa | Janela de 5 horas | Janela semanal | O que o assistente faz |
|-------|-------------------|----------------|------------------------|
| 1 | até 70% | até 90% | Roda em paralelo o máximo de trabalho que conseguir |
| 2 | até 85% | até 95% | Só inicia um novo agente auxiliar enquanto houver menos de 2 rodando |
| 3 | até 95% | até 98% | Trabalha sozinho, sem agentes auxiliares |
| 4 | acima de 95% | acima de 98% | Não inicia nada novo; os agentes auxiliares ainda em execução encerram num ponto consistente e reportam; depois ele espera o reinício |

Agentes auxiliares iniciados numa faixa anterior continuam rodando até terminar. Sem uma leitura de uso, vale a faixa 2. Nas faixas 1 a 3, o uso nunca é motivo para o assistente encerrar o turno.

**Espera pelo reinício (Claude Code):** na faixa 4, o assistente inicia em segundo plano o processo de espera do Unlazier e encerra o turno. O processo de espera calcula quando a janela cheia reinicia, dorme uma única vez até 3 minutos depois disso e então acorda a sessão, que retoma o plano. Ele não precisa de nenhuma configuração do Claude Code (o Unlazier não usa `autoContinueAtUsageLimit` nem `/rate-limit-options`), mas a sessão precisa continuar aberta e o computador acordado: um computador suspenso acorda a sessão com atraso, e fechar o terminal encerra a espera. Em execuções com `claude -p`, o Claude Code encerra comandos em segundo plano após 30 minutos por padrão, então a espera não funciona nelas. As demais ferramentas não conseguem acordar uma sessão, então nelas o assistente termina o passo atual, avisa você e espera por você.

**Imposto, não só pedido (Claude Code):** hooks mantêm as faixas sem depender da memória do assistente.

- Um hook nos agentes auxiliares bloqueia os que a faixa não permite, contando os que ainda estão rodando.
- Um hook após cada chamada de ferramenta, no assistente e nos agentes auxiliares dele, acrescenta a linha de uso quando a faixa muda e, na faixa 4, diz aos agentes auxiliares para encerrar. Fora isso, ele não imprime nada, então não gasta tokens.
- Um hook no fim do turno impede que a faixa 4 termine sem o processo de espera e segura o turno uma vez quando o assistente tenta encerrá-lo por causa do uso nas faixas 2 e 3. Nas faixas 1 a 3, também segura o turno uma vez quando ainda há agentes auxiliares rodando, para o assistente procurar trabalho independente antes de esperar; os mesmos agentes auxiliares nunca o seguram duas vezes.

No Codex CLI, o hook nos agentes auxiliares os bloqueia nas faixas 3 e 4.

Quando paraleliza, ele prefere, nesta ordem e só entre tarefas que não entram em conflito: agentes auxiliares para partes da mesma tarefa, depois tarefas diferentes do mesmo pedido, depois pedidos diferentes.

**De onde vêm os números:**

- **Claude Code** envia o uso só para a status line (a barra na parte de baixo da tela). Se você não tem status line, o instalador adiciona uma que mostra as duas janelas e as salva para o lembrete. Ela se atualiza a cada minuto, não só quando você envia uma mensagem:

    ```
    Session 5h: [██░░░░░░░░] 24% · resets in 2h 2m
    Weekly    : [████░░░░░░] 38% · resets in 3d 11h 30m
    ```

    Se você já tem a sua, ela é mantida. Para alimentar o lembrete, faça a sua status line salvar a parte `rate_limits` do que o Claude Code envia para ela em `~/.claude/state/rate_limits.json`, neste formato:

    ```json
    {"captured_at": 1794668291, "five_hour": {"used_percentage": 24, "resets_at": 1794683400}, "seven_day": {"used_percentage": 60, "resets_at": 1794978000}}
    ```

    `captured_at` é o horário atual em segundos. Os dados de uso só existem nos planos de assinatura do Claude, não com chave de API. A linha de uso também chega após qualquer chamada de ferramenta que mude a faixa, então o assistente vê o uso subir durante um turno longo.
- **Codex CLI** grava o uso no próprio log de sessão, que o lembrete lê. Não é preciso configurar nada. A linha de uso também chega após cada chamada de subagente.
- **As outras ferramentas** não expõem o uso, então o lembrete diz `Usage: unknown`, e vale a faixa 2.

Uma leitura com mais de 15 minutos conta como desconhecida. Uma janela cujo horário de reinício já passou conta como 0% até a próxima leitura.

## Alertas sonoros

O Unlazier toca três bipes curtos quando o assistente precisa de você: quando pede permissão para fazer algo, quando faz uma pergunta e quando termina a vez dele. Você pode cuidar de outra coisa e voltar quando ouvir.

- **Windows e WSL:** o bipe vem do Windows.
- **macOS:** o som do sistema "Tink".
- **Linux:** o som "button pressed" do ambiente gráfico, ou o sino do terminal quando não há player de som.

Algumas ferramentas avisam menos momentos; veja a coluna Alertas em [Ferramentas suportadas](#ferramentas-suportadas).

## Desinstalação

Linux e macOS:

```bash
curl -fsSL https://github.com/fco3lho/unlazier/releases/latest/download/uninstall.sh | bash
```

Windows (PowerShell):

```powershell
irm https://github.com/fco3lho/unlazier/releases/latest/download/uninstall.ps1 | iex
```

O desinstalador mostra o mesmo menu e remove só o que o Unlazier adicionou: os arquivos de regras `unlazier-*.md`, os blocos marcados, os hooks, os plugins, a status line (só se for a que o Unlazier instalou) e as pastas `unlazier`. Um arquivo que fica vazio depois que o bloco é removido é apagado. Suas configurações, seu histórico e suas credenciais continuam lá.

## Atualizando da versão 1

A versão 1 copiava os arquivos dela por cima da sua configuração em `~/.claude` e `~/.config/opencode`. Quando você instala a versão 2, o instalador procura esses arquivos antigos, mostra a lista e pergunta antes de removê-los. Os arquivos antigos de regras e de skills só são oferecidos para remoção se estiverem exatamente como a versão 1 os deixou; um arquivo que você editou é mantido.

O antigo `~/.claude/CLAUDE.md` (ou `~/.config/opencode/AGENTS.md`) só é reconhecido enquanto continua idêntico ao arquivo que a versão 1 gravou. Se você acrescentou anotações suas nele, o instalador não oferece removê-lo: a versão 1 substituía o arquivo inteiro, então mova suas anotações para outro arquivo e apague as regras antigas você mesmo.

A versão 2.0 se chamava Unlazier AI e usava `unlazier-ai` nos nomes de arquivos e pastas. Instalar de novo remove esses itens e grava os novos nomes `unlazier` no lugar.

> **Não rode o desinstalador da versão 1.** Ele apagava as pastas `~/.claude` e `~/.config/opencode` inteiras, incluindo suas configurações e credenciais. O desinstalador da versão 2 remove só o que o Unlazier adicionou.

## Notas para cada ferramenta

### Claude Code

As regras vão para `~/.claude/rules/`, e não para o `~/.claude/CLAUDE.md`: a Anthropic recomenda manter cada CLAUDE.md com menos de 200 linhas, e cada arquivo de regra conta como um arquivo separado e curto. As regras dessa pasta são carregadas no início de cada sessão, como o CLAUDE.md. A versão 2.0 colocava as regras num bloco dentro do CLAUDE.md; instalar de novo as move e remove esse bloco.

O Claude Code pede que você confie numa pasta antes de rodar hooks nela; o lembrete começa a funcionar depois que você aceita. Os dados de uso precisam de uma assinatura do Claude e de uma status line (veja [Limites de uso](#limites-de-uso-e-trabalho-em-paralelo)).

### Codex CLI

O Codex só roda um hook novo depois que você o aprova. Abra o Codex, digite `/hooks` e aprove os hooks do Unlazier uma única vez. Se existir um arquivo chamado `AGENTS.override.md` em `~/.codex`, o Codex ignora o `AGENTS.md`, e o instalador avisa você. Por padrão, o Codex lê no máximo 32 KiB de instruções no total; as regras do Unlazier ocupam cerca de 18 KiB, então instruções de projeto muito longas podem ser cortadas. Você pode aumentar o limite com `project_doc_max_bytes` em `~/.codex/config.toml`.

### Gemini CLI

O Gemini reenvia o arquivo de instruções a cada mensagem, então não precisa de nenhum passo extra depois da compactação. O Google substituiu o Gemini CLI pelo Antigravity CLI para usuários gratuitos e do Google One em 18 de junho de 2026; o Antigravity CLI ainda não é suportado.

### Devin Desktop (antigo Windsurf)

O Devin limita cada arquivo de regras a 12.000 caracteres; cada arquivo de regra do Unlazier fica bem abaixo disso. O Devin também roda os hooks que encontra em `~/.claude/settings.json`; desligar isso desligaria também as suas regras do Claude Code dentro do Devin, então o Unlazier deixa como está. Com as duas ferramentas instaladas, você pode ouvir o bipe de fim da vez duas vezes no Devin. O Devin não documenta nenhum jeito de adicionar texto depois da compactação, então só o lembrete a cada mensagem é usado.

### Kiro

O lembrete depois da compactação precisa do Kiro CLI 3.1.0 ou mais recente. O Kiro não oferece evento para pedidos de permissão nem para perguntas, então só bipa no fim da vez.

### Cline

Os hooks vêm desligados. Ligue **Enable Hooks** nas Feature Settings do Cline. O Cline só suporta hooks no Linux e no macOS, então no Windows o Cline recebe as regras sem o lembrete e sem os alertas. O Cline não repassa pedidos de permissão para os hooks, então ele bipa nas perguntas e no fim da tarefa.

### OpenCode

O plugin funciona com o OpenCode 1.18.29 ou mais recente, incluindo a versão 2. O OpenCode recarrega os arquivos de instruções sozinho depois da compactação. Depois que `~/.config/opencode/AGENTS.md` existe, o OpenCode para de ler `~/.claude/CLAUDE.md` como alternativa; o instalador avisa você quando isso se aplica.

### Amp

O plugin é carregado em threads novas. Numa thread em andamento, recarregue os plugins com `Ctrl+O` e depois `plugins: reload`. O Amp não oferece evento para pedidos de permissão nem para perguntas, então só bipa no fim da vez.

### GitHub Copilot CLI

O Copilot ignora o que um hook de prompt imprime, então recebe as regras e os alertas sem o lembrete. A extensão do Copilot no VS Code também pode ler `~/.claude/CLAUDE.md` quando a configuração `chat.useClaudeMdFile` está ligada, o que carregaria as regras duas vezes se você usar os dois.

## As regras

Os princípios em [`AGENTS.md`](AGENTS.md) definem como o assistente trabalha:

1. **Think Before Coding** (pensar antes de codar): explicitar as suposições e perguntar quando algo não está claro (uma pergunta por vez, com uma resposta recomendada).
2. **Simplicity First** (simplicidade primeiro): a menor mudança que resolve o problema, sem abstrações especulativas.
3. **Surgical Changes** (mudanças cirúrgicas): mexer só no que o pedido exige e seguir o estilo que já existe.
4. **Goal-Driven Execution** (execução guiada por objetivos): definir como o sucesso é verificado e verificar antes de dizer que terminou.
5. **Commit Messages** (mensagens de commit): seguir o formato Conventional Commits.
6. **Communication Brevity** (comunicação breve): respostas curtas e diretas, sem enrolação.

> **Atribuição:** Os quatro primeiros princípios vêm das [observações de Andrej Karpathy](https://x.com/karpathy/status/2015883857489522876) sobre as armadilhas de LLMs ao programar, popularizadas pelo repositório [andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills).

As regras por tema em [`rules/`](rules/) trazem mais detalhes, cada uma com um exemplo ruim e um bom:

| Regra | Foco |
|-------|------|
| [`structure.md`](rules/structure.md) | Código legível, uma função para cada tarefa, funções pequenas |
| [`correctness.md`](rules/correctness.md) | Tratamento de erros, casos extremos, segurança |
| [`style.md`](rules/style.md) | Formatação, consistência, tom profissional |
| [`completeness.md`](rules/completeness.md) | Sem placeholders, código morto ou restos de depuração |
| [`performance.md`](rules/performance.md) | Evitar consultas e processamento desnecessários |
| [`testability.md`](rules/testability.md) | Código fácil de testar, testes que verificam comportamento |
| [`async.md`](rules/async.md) | Lidar com trabalho assíncrono e com a liberação de recursos |
| [`naming.md`](rules/naming.md) | Nomes claros, que seguem as convenções de cada linguagem |
| [`documentation.md`](rules/documentation.md) | Comentários que explicam o porquê, e instruções de execução |
| [`parallelism.md`](rules/parallelism.md) | Dosar o trabalho em paralelo pelos limites de uso, e o que delegar |

O lembrete enviado a cada mensagem está em [`reminder.md`](reminder.md).

## Personalização

- **Suas próprias regras globais:** escreva-as no arquivo de instruções da sua ferramenta (por exemplo `~/.claude/CLAUDE.md`), fora de qualquer bloco do Unlazier, ou em arquivos seus na pasta de regras com nomes que não comecem com `unlazier`. Elas sobrevivem a atualizações e desinstalações.
- **Mudar as regras do Unlazier:** edite os arquivos numa cópia deste repositório e rode `./install.sh` (ou `.\install.ps1`) a partir dessa cópia. Edições feitas direto nos arquivos `unlazier-*.md` instalados ou dentro do bloco instalado são substituídas na próxima instalação.
- **Regras de projeto:** cada ferramenta também lê instruções da pasta do seu projeto (por exemplo `AGENTS.md` ou `CLAUDE.md`); elas valem por cima das regras globais.

## Para contribuidores

Organização do repositório:

| Caminho | Função |
|---------|--------|
| `AGENTS.md`, `rules/` | As regras (camada 1). `CLAUDE.md` é um link para `AGENTS.md`. |
| `reminder.md` | O lembrete curto (camada 2). |
| `hooks/inject.sh`, `hooks/inject.ps1` | Imprime o lembrete e a linha de uso (camadas 2 e 3) no formato que cada ferramenta espera; no Claude Code e no Codex CLI, também bloqueia os agentes auxiliares que a faixa de uso não permite, e no Claude Code mantém os hooks das faixas e roda o processo de espera. |
| `hooks/alert.sh`, `hooks/alert.ps1` | Toca os bipes de alerta (camada 4). |
| `statusline/` | Status line do Claude Code que salva o uso para o lembrete. |
| `plugins/` | Plugins do OpenCode e do Amp, que chamam o mesmo script de hook. |
| `install.sh`, `install.ps1` | Instaladores; cada ferramenta é um adaptador numa mesma tabela. Os `uninstall.*` chamam os instaladores no modo de desinstalação. |
| `scripts/` | O `build-release-assets.sh` fixa os instaladores e desinstaladores na tag de uma versão e gera o `SHA256SUMS`; o `.github/workflows/release.yml` roda esse script e envia o resultado quando uma versão é publicada. |
| `tests/` | Testes do instalador, do hook e dos arquivos de cada versão; `tests/fixtures/v1/` guarda arquivos da versão 1 para os testes de atualização. |

Para rodar os testes:

```bash
bash tests/install_test.sh        # Linux and macOS, needs jq
bash tests/release_assets_test.sh # Linux and macOS
```

```powershell
./tests/install_test.ps1          # Windows PowerShell 5.1 or PowerShell 7
```

Os testes usam uma pasta pessoal temporária e nunca mexem na sua configuração real. O GitHub Actions roda os testes no Ubuntu, no macOS e no Windows, além do `shellcheck` nos scripts de shell.

O [`README.md`](README.md) em inglês é a versão oficial. Este arquivo e o [`README.es.md`](README.es.md) são traduções dele; quem alterar o README em inglês deve atualizá-los na mesma mudança.

## Licença

MIT
