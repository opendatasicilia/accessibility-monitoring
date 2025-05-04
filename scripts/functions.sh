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
      echo "$timestamp [OK]    $url returned $status" >> "$PATH_LOG_FILE"
      return 0
    else
      echo "$timestamp [ERROR] $url returned $status (attempt $attempt/$MAX_RETRIES)" >> "$PATH_LOG_FILE"
      (( attempt++ ))
      sleep "$RETRY_DELAY"
    fi
  done

  # Dopo tutti i retry falliti
  echo "$timestamp [FAIL]  $url is unreachable after $MAX_RETRIES attempts" >> "$PATH_LOG_FILE"
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
            balinkx_result=$(balinkx "$url" 2>/dev/null)
            balinkx_exit=$?
            
            if [ $balinkx_exit -eq 0 ]; then
                # Successo: Trovati link di accessibilità
                echo "$balinkx_result" | mlr --j2c put -s codice=$codice '$codice_comune_istat = @codice' > data/accessibility_urls-$codice.csv
            elif [ $balinkx_exit -eq 2 ]; then
                # Errore: Impossibile accedere al sito web
                echo "Sito non raggiungibile: $url"
                echo $(date +"%Y-%m-%d %H:%M:%S"),$codice,$url >> "$PATH_CSV_UNREACHABLE_SITES"
                return 1
            elif [ $balinkx_exit -eq 3 ]; then
                # Avviso: Nessun link di accessibilità trovato sul sito
                echo "Nessun riferimento di accessibilità trovato per: $url"
                echo $(date +"%Y-%m-%d %H:%M:%S"),$codice,$url >> "$PATH_CSV_MISSING_ACCESSIBILITY_REFS"
                return 1
            else
                # Altri errori (incluso codice 1 - URL mancante o non valido)
                echo "Errore durante l'analisi del sito: $url"
                echo $(date +"%Y-%m-%d %H:%M:%S"),$codice,$url >> "$PATH_CSV_UNREACHABLE_SITES"
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
    echo "$timestamp [API] $api_url returned HTTP $status_code" >> "$PATH_LOG_FILE"
    
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
        echo "$timestamp [ERROR] Rate limit exceeded (HTTP 429) for $api_url" | tee -a "$PATH_LOG_FILE"
        # Incrementa il contatore degli errori consecutivi
        ((TOO_MANY_REQUESTS_COUNT++))
        echo "$timestamp [WARN] Consecutive rate limit errors: $TOO_MANY_REQUESTS_COUNT/$TOO_MANY_REQUESTS_THRESHOLD" | tee -a "$PATH_LOG_FILE"
        
        if [[ "$TOO_MANY_REQUESTS_COUNT" -ge "$TOO_MANY_REQUESTS_THRESHOLD" ]]; then
            echo "$timestamp [CRITICAL] Reached maximum number of consecutive rate limit errors. Aborting processing." | tee -a "$PATH_LOG_FILE"
            return 2  # Codice di ritorno speciale per segnalare che è necessario interrompere tutto
        fi
        return 1
    else
        # Altri errori (non sono "too many requests")
        echo "$timestamp [ERROR] Failed to retrieve $api_url - HTTP status: $status_code" | tee -a "$PATH_LOG_FILE"
        # Reset contatore perché non è un errore di rate limit
        TOO_MANY_REQUESTS_COUNT=0
        return 1
    fi
}