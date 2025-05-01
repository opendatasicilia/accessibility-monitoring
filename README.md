# Monitoraggio accessibilità 

Questo progetto implementa il monitoraggio dell'accessibilità per i siti web degli enti pubblici italiani, in conformità con le normative vigenti in materia di accessibilità digitale.

## Dichiarazioni di accessibilità

Il progetto attualmente si concentra sul monitoraggio delle dichiarazioni di accessibilità che gli enti pubblici italiani sono obbligati a pubblicare. Le dichiarazioni vengono raccolte e analizzate automaticamente tramite lo script `monitoring-declarations_v2.sh`.

In futuro, il monitoraggio sarà esteso per includere anche la valutazione dell'accessibilità web (web accessibility evaluation) attraverso test automatizzati delle WCAG (Web Content Accessibility Guidelines).

## Struttura del progetto

Il progetto è organizzato nel modo seguente:

```
accessibility-declarations/
│
├── data/
│   ├── accessibility-urls.csv - URL delle pagine di dichiarazione di accessibilità
│   ├── declarations.csv - Dati estratti dalle dichiarazioni di accessibilità
│   └── enti.csv - Elenco degli enti pubblici monitorati
│
└── scripts/
    └── monitoring-declarations.sh - Script principale per il monitoraggio delle dichiarazioni
```

### Descrizione delle cartelle e dei file:

- **data/**: Contiene tutti i dati utilizzati e generati dal monitoraggio
  - `accessibility-urls.csv`: Contiene gli URL delle pagine dove sono pubblicate le dichiarazioni di accessibilità
  - `declarations.csv`: Contiene i dati estratti dalle dichiarazioni di accessibilità degli enti
  - `enti.csv`: Elenco completo degli enti pubblici soggetti al monitoraggio

- **scripts/**: Contiene gli script utilizzati per il processo di monitoraggio
  - `monitoring-declarations.sh`: Script principale che si occupa della raccolta e dell'analisi delle dichiarazioni di accessibilità

## Come funziona

Il monitoraggio delle dichiarazioni di accessibilità viene eseguito automaticamente dallo script `monitoring-declarations.sh`, che:

1. Recupera l'elenco degli enti pubblici dall'indice della Pubblica Amministrazione (IPA) `enti.csv`
2. Per ciascun ente, controlla la presenza della dichiarazione di accessibilità
3. Analizza il contenuto delle dichiarazioni trovate
4. Genera i dati di output nel file `declarations.csv`

## Sviluppi futuri

I prossimi passi del progetto prevedono l'implementazione di una piattaforma di monitoraggio completa che includerà:

- Test automatizzati per la verifica delle conformità WCAG
- Dashboard per la visualizzazione dei risultati
- Sistema di notifica per gli enti non conformi



