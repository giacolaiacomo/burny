# AI Usage Bar

Un widget nella barra dei menu di macOS che mostra i limiti di utilizzo del tuo abbonamento **Claude Code** (sessione 5h, settimana, settimana per modello, es. Fable) e **Codex / ChatGPT** (sessione 5h, settimana).

- Nella barra: l'icona dell'app e il limite più vicino all'esaurimento; arancione sopra il 75%, rosso sopra il 90%.
- Cliccando: ogni limite con barra di avanzamento, quando si azzera e una tacca che indica dove saresti a ritmo costante.
- Impostazioni (ingranaggio nel pannello): apri al login, mostra/nascondi Claude o Codex nella barra, limite mostrato (più critico / sessione / settimana), percentuale usata o rimasta, frequenza di aggiornamento.

## Installazione

Serve macOS 13+ e il compilatore Swift (`xcode-select --install` se non l'hai).

```sh
git clone <questo repo> && cd ai-usage-bar
./install.sh
```

Compila `~/Applications/AI Usage Bar.app` e lo avvia a ogni login. Per rimuoverlo: `./uninstall.sh`.

## Da dove prende i dati (e perché non c'è rischio ban)

L'app **non fa chiamate di rete, non legge password/token, non consuma messaggi**.

| Servizio | Fonte | Frequenza |
|---|---|---|
| Claude Code | esegue il client ufficiale `claude -p /usage` — la stessa richiesta di quando digiti `/usage`; 0 token, 0 costo, hook disattivati, nessuna sessione salvata | ogni 5 min e all'apertura del pannello |
| Codex | legge i `rate_limits` che la CLI Codex già scrive in `~/.codex/sessions/` | ogni 30 s (solo lettura locale) |

Il piano Claude (Pro / Max) viene letto da `~/.claude.json`. Nessun dato lascia il Mac.

**Limiti:** i numeri di Codex si aggiornano solo quando usi Codex (sono quelli dell'ultima risposta). I limiti dei messaggi nell'app ChatGPT non sono disponibili localmente, quindi non vengono mostrati.

## Requisiti

- `claude` installato e loggato con un abbonamento (cerca in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`)
- per Codex: la CLI/app Codex usata almeno una volta
- le icone arrivano da `/Applications/Claude.app` e `/Applications/ChatGPT.app` se presenti, altrimenti c'è un anello colorato

## Peso

Un solo file Swift nativo (AppKit + SwiftUI), nessuna dipendenza. Binario ~350 KB, ~20 MB di RAM, 0% CPU a riposo.
