#!/bin/bash

# set -x


# -------------------- constants -------------------- #
URL_CSV_ENTI_IPA="https://indicepa.gov.it/ipa-dati/datastore/dump/d09adf99-dc10-4349-8c53-27b1e5aa97b6?bom=True&format=csv"
PATH_CSV_ENTI_IPA="data/enti.csv"
URL_CSV_ANAGRAFICA_COMUNI="https://raw.githubusercontent.com/opendatasicilia/comuni-italiani/refs/heads/main/dati/comuni.csv"
PATH_CSV_ANAGRAFICA_COMUNI="data/comuni.csv"
PATH_CSV_UNREACHABLE_SITES="data/unreachable_sites.csv"  # File di log per i siti non raggiungibili
PATH_CSV_MISSING_ACCESSIBILITY_REFS="data/missing_accessibility_refs.csv"  # File di log per i siti senza riferimenti all'accessibilità in generale

# Configurazione della parallelizzazione - modificare in base alle risorse disponibili
MAX_CONCURRENT_JOBS=5  # Numero massimo di connessioni contemporanee

# Parametri per check_site
MAX_RETRIES=3          # Numero massimo di tentativi
TIMEOUT=10             # Timeout in secondi
RETRY_DELAY=2          # Ritardo tra i tentativi in secondi
LOG_FILE="data/site_checks.log"  # File di log per i controlli

# Parametri per API AGID
API_REQUEST_DELAY=0.5     # Secondi di attesa tra le chiamate API
API_DOMAIN_CHECKED=0    # Flag per verificare se il dominio API è già stato controllato
TOO_MANY_REQUESTS_THRESHOLD=5  # Numero massimo di errori 429 consecutivi prima di interrompere

# -------------------- functions -------------------- #

source scripts/calinkx.sh #curl
source scripts/balinkx.sh #browser


# Funzione per gestire i job paralleli
run_parallel() {
    local job_counter=0
    local total=$1
    local job_pids=()

    shift  # Rimuove il primo argomento (total)
    
    while IFS=',' read -r codice url; do
        if [ -n "$url" ] && [ -n "$codice" ]; then
            ((job_counter++))
            
            # Esegui il comando in background
            ("$@" "$codice" "$url" "$job_counter" "$total") &
            job_pids+=($!)
            
            # Controlla se abbiamo raggiunto il numero massimo di job contemporanei
            if (( ${#job_pids[@]} >= MAX_CONCURRENT_JOBS )); then
                # Attendi che almeno un job termini
                wait -n
                
                # Aggiorna l'elenco dei PID rimuovendo quelli completati
                local active_pids=()
                for pid in "${job_pids[@]}"; do
                    if kill -0 "$pid" 2>/dev/null; then
                        active_pids+=("$pid")
                    fi
                done
                job_pids=("${active_pids[@]}")
            fi
        fi
    done
    
    # Attendi che tutti i job rimanenti vengano completati
    wait
}

check_site() {
  local url=$1
  local attempt=1

  while (( attempt <= MAX_RETRIES )); do
    # Full GET request that follows redirects
    status=$(curl -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36" --location \
                  --silent \
                  --output /dev/null \
                  --write-out "%{http_code}" \
                  --max-time "$TIMEOUT" \
                  "$url")

    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    # Consider 2xx and 3xx responses as success
    if [[ "$status" -ge 200 ]] && [[ "$status" -lt 400 ]] || [[ "$status" -eq 000 ]]; then
      echo "$timestamp [OK]    $url returned $status" >> "$LOG_FILE"
      return 0
    else
      echo "$timestamp [ERROR] $url returned $status (attempt $attempt/$MAX_RETRIES)" >> "$LOG_FILE"
      (( attempt++ ))
      sleep "$RETRY_DELAY"
    fi
  done

  # Dopo tutti i retry falliti
  echo "$timestamp [FAIL]  $url is unreachable after $MAX_RETRIES attempts" >> "$LOG_FILE"
  return 1
}

# Funzione per processare gli URL dei comuni
process_comune_url() {
    local codice="$1"
    local url="$2"
    local current="$3"
    local total="$4"
    local percent=$((current * 100 / total))
    
    echo -ne "Processing [$current/$total] $percent%\r"

    # Controllo di raggiungibilità del sito
    if ! check_site "$url"; then
        echo "Skipping unreachable site: $url"
        echo $(date +"%Y-%m-%d %H:%M:%S"),$codice,$url >> "$PATH_CSV_UNREACHABLE_SITES"
        return 1
    else
        # Site is reachable, get HTML content
        # Prova prima calinkx
        if refs=$(calinkx "$url" 2>/dev/null); then
            echo "$refs" | mlr --j2c put -s codice=$codice '$codice_comune_istat = @codice' > data/accessibility_urls-$codice.csv
        else
            # Se calinkx fallisce, prova balinkx
            if refs=$(balinkx "$url" 2>/dev/null); then
                echo "$refs" | mlr --j2c put -s codice=$codice '$codice_comune_istat = @codice' > data/accessibility_urls-$codice.csv
            else
                echo "Nessun riferimento trovato per: $url"
                echo $(date +"%Y-%m-%d %H:%M:%S"),$codice,$url >> "$PATH_CSV_MISSING_ACCESSIBILITY_REFS"
                return 1
            fi
        fi 
    fi
}

# Funzione per processare le dichiarazioni di accessibilità
process_declaration() {
    # Corretto l'ordine dei parametri
    local href="$2"
    local codice="$1"
    local current="$3"
    local total="$4"
    local percent=$((current * 100 / total))
    
    echo -ne "Processing declaration [$current/$total] $percent%\r"
    
    # Modifica l'URL per l'API
    local api_url=$(echo "$href" | sed 's|form.agid.gov.it/view/|form.agid.gov.it/api/v1/submission/view/|')

    # Delay per evitare troppe chiamate ravvicinate all'API
    sleep "$API_REQUEST_DELAY"
    
    # Esegui la chiamata curl e cattura sia il corpo della risposta che il codice di stato HTTP
    local response=$(curl -s -w "\n%{http_code}" "$api_url")
    local status_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    # Registra il risultato nel log
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "$timestamp [API] $api_url returned HTTP $status_code" >> "$LOG_FILE"
    
    # Controlla se la chiamata è andata a buon fine (codici 2xx)
    if [[ "$status_code" -ge 200 ]] && [[ "$status_code" -lt 300 ]]; then
        # Processa il risultato solo se la chiamata è andata a buon fine
        echo "$body" | \
            jq --arg codice "$codice" '{codice_comune_istat: $codice, idPubblicazione, dataUltimaModifica, specs_version: .datiPubblicati["specs-version"], compliance_status: .datiPubblicati["compliance-status"], reason_42004: .datiPubblicati["reason-42004"], website_cms: .datiPubblicati["website-cms"], website_cms_other: .datiPubblicati["website-cms-other"], people_disabled: .datiPubblicati["people-disabled"], people_desk_disabled: .datiPubblicati["people-desk-disabled"]}' > "data/declaration-${codice}.json"
        # Resetta il contatore degli errori "too many requests" quando una richiesta ha successo
        TOO_MANY_REQUESTS_COUNT=0
        return 0
    elif [[ "$status_code" -eq 429 ]]; then
        # Too many requests error
        echo "$timestamp [ERROR] Rate limit exceeded (HTTP 429) for $api_url" | tee -a "$LOG_FILE"
        # Incrementa il contatore degli errori consecutivi
        ((TOO_MANY_REQUESTS_COUNT++))
        echo "$timestamp [WARN] Consecutive rate limit errors: $TOO_MANY_REQUESTS_COUNT/$TOO_MANY_REQUESTS_THRESHOLD" | tee -a "$LOG_FILE"
        
        if [[ "$TOO_MANY_REQUESTS_COUNT" -ge "$TOO_MANY_REQUESTS_THRESHOLD" ]]; then
            echo "$timestamp [CRITICAL] Reached maximum number of consecutive rate limit errors. Aborting processing." | tee -a "$LOG_FILE"
            return 2  # Codice di ritorno speciale per segnalare che è necessario interrompere tutto
        fi
        return 1
    else
        # Altri errori (non sono "too many requests")
        echo "$timestamp [ERROR] Failed to retrieve $api_url - HTTP status: $status_code" | tee -a "$LOG_FILE"
        # Reset contatore perché non è un errore di rate limit
        TOO_MANY_REQUESTS_COUNT=0
        return 1
    fi
}


# -------------------- main script -------------------- #

# Create log directory if it doesn't exist
mkdir -p data

# Assicurati che il file di log esista
touch "$LOG_FILE"

# setting up csv files
[ -f "$PATH_CSV_UNREACHABLE_SITES" ] && rm "$PATH_CSV_UNREACHABLE_SITES"
touch "$PATH_CSV_UNREACHABLE_SITES"
echo "timestamp,codice_comune_istat,url" > "$PATH_CSV_UNREACHABLE_SITES"

[ -f "$PATH_CSV_MISSING_ACCESSIBILITY_REFS" ] && rm "$PATH_CSV_MISSING_ACCESSIBILITY_REFS"
touch "$PATH_CSV_MISSING_ACCESSIBILITY_REFS"
echo "timestamp,codice_comune_istat,url" > "$PATH_CSV_MISSING_ACCESSIBILITY_REFS"

# scarica ipa e anagrafica comuni
curl -skL "$URL_CSV_ENTI_IPA" > $PATH_CSV_ENTI_IPA
echo "Scaricati i dati IPA"
curl -skL "$URL_CSV_ANAGRAFICA_COMUNI" > $PATH_CSV_ANAGRAFICA_COMUNI
echo "Scaricati i dati anagrafica comuni"

# join con i dati anagrafica comuni pro_com_t di anagrafica è codice_comune_istat di ipa usa mlr
mlr --csv join -f $PATH_CSV_ENTI_IPA -j codice_comune_istat -l Codice_comune_ISTAT -r pro_com_t $PATH_CSV_ANAGRAFICA_COMUNI |\
    mlr --csv rename Codice_natura,codice_natura,Codice_comune_ISTAT,codice_comune_istat,Sito_istituzionale,url then \
    filter '$url != "" && $codice_natura == 2430' then  \
    cut -f comune,codice_comune_istat,url then \
    case -l -f url then \
    put 'if (!($url =~ "^https?://")) {$url = "https://" . $url}' > $PATH_CSV_ENTI_IPA.tmp && mv $PATH_CSV_ENTI_IPA.tmp $PATH_CSV_ENTI_IPA

# echo "Uniti i dati IPA con i dati anagrafica comuni e filtrati per Sicilia e codice natura 2430"
rm $PATH_CSV_ANAGRAFICA_COMUNI

# rimuovo filtro sicilia
# filter '$den_reg == "Sicilia"' then \

# debug
<$PATH_CSV_ENTI_IPA mlr --csv shuffle | head -n 11 > $PATH_CSV_ENTI_IPA.tmp && mv $PATH_CSV_ENTI_IPA.tmp $PATH_CSV_ENTI_IPA

total_urls=$(cat $PATH_CSV_ENTI_IPA | wc -l)
total_urls=$((total_urls - 1)) # Subtract 1 for the header

# Parallelizza la scansione dei siti web dei comuni
echo "Starting parallel crawling of municipality websites..."
<$PATH_CSV_ENTI_IPA mlr --csv --headerless-csv-output cut -f codice_comune_istat,url then shuffle | run_parallel $total_urls process_comune_url

# double check missing
total_urls=$(cat $PATH_CSV_MISSING_ACCESSIBILITY_REFS | wc -l)
total_urls=$((total_urls - 1)) # Subtract 1 for the header
mv $PATH_CSV_MISSING_ACCESSIBILITY_REFS $PATH_CSV_MISSING_ACCESSIBILITY_REFS.tmp && echo "timestamp,codice_comune_istat,url" > "$PATH_CSV_MISSING_ACCESSIBILITY_REFS"
<$PATH_CSV_MISSING_ACCESSIBILITY_REFS.tmp mlr --csv --headerless-csv-output cut -f codice_comune_istat,url then shuffle | run_parallel $total_urls process_comune_url
rm $PATH_CSV_MISSING_ACCESSIBILITY_REFS.tmp

echo "Completed crawling municipality websites"

# wait for keypress
# read -r -p "Press any key to continue..." key

# merge csvs
mlr --csv cat data/accessibility_urls-* then sort -f codice_comune_istat > data/merged-accessibility_urls.csv
rm data/accessibility_urls-* && mv data/merged-accessibility_urls.csv data/accessibility_urls.csv

# rm unnecessary column from enti PATH_CSV_ENTI_IPA
mlr -I --csv cut -x -f url $PATH_CSV_ENTI_IPA

# join comune
mlr --csv join -f data/accessibility_urls.csv -j codice_comune_istat $PATH_CSV_ENTI_IPA > data/accessibility_urls.csv.tmp && mv data/accessibility_urls.csv.tmp data/accessibility_urls.csv

# Verifica iniziale della raggiungibilità del dominio API
if [ "$API_DOMAIN_CHECKED" -eq 0 ]; then
    if ! check_site "https://form.agid.gov.it/"; then
        echo "AGID API domain is not accessible. Aborting declaration processing." | tee -a "$LOG_FILE"
        exit 1
    fi
    API_DOMAIN_CHECKED=1
    echo "AGID API domain is accessible. Starting to process declarations..."
fi

# filtro dichiarazioni univoche
<data/accessibility_urls.csv mlr --csv --headerless-csv-output filter '$href =~ "^https://form.agid"' then cut -f href,codice_comune_istat | uniq > data/form_urls.csv.tmp

# conto le righe
total_urls=$(<data/form_urls.csv.tmp wc -l)
total_urls=$((total_urls - 1)) # Subtract 1 for the header
echo "Total URLs to process: $total_urls"

# Elaborazione sequenziale delle dichiarazioni di accessibilità
echo "Starting sequential retrieval of accessibility declarations..."
current=0
TOO_MANY_REQUESTS_COUNT=0  # Inizializza il contatore

cat data/form_urls.csv.tmp | while IFS=',' read -r href codice; do
    ((current++))
    process_declaration "$href" "$codice" "$current" "$total_urls"
    result=$?
    
    # Controlla se la funzione ha segnalato che è necessario interrompere il ciclo
    if [[ "$result" -eq 2 ]]; then
        echo "Interrupting declarations processing due to rate limiting. Please try again later."
        break
    fi
done

echo "Completed retrieving accessibility declarations"
rm data/form_urls.csv.tmp

# prepara file di output, merge
mlr --j2c cat data/declaration-* then sort -f codice_comune_istat > data/merged-declarations.csv
rm data/declaration-*

# join comune
mlr --csv join -f data/merged-declarations.csv -j codice_comune_istat $PATH_CSV_ENTI_IPA > data/declarations.csv
rm data/merged-declarations.csv

# sorting MISSING_ACCESSIBILITY_REFS e unreachable_sites
mlr -I --csv sort -f codice_comune_istat $PATH_CSV_MISSING_ACCESSIBILITY_REFS 
mlr -I --csv sort -f codice_comune_istat $PATH_CSV_UNREACHABLE_SITES

# rm unnecessary file
rm $PATH_CSV_ENTI_IPA
