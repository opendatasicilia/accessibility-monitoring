#!/bin/bash

# questo script rintraccia e scarica le dichiarazioni di accessibilità dei siti web dei comuni italiani

# constants
URL_CSV_ENTI_IPA="https://indicepa.gov.it/ipa-dati/datastore/dump/d09adf99-dc10-4349-8c53-27b1e5aa97b6?bom=True&format=csv"
PATH_CSV_ENTI_IPA="data/enti.csv"
URL_CSV_ANAGRAFICA_COMUNI="https://raw.githubusercontent.com/opendatasicilia/comuni-italiani/refs/heads/main/dati/comuni.csv"
PATH_CSV_ANAGRAFICA_COMUNI="data/comuni.csv"

# Configurazione della parallelizzazione - modificare in base alle risorse disponibili
MAX_CONCURRENT_JOBS=8  # Numero massimo di connessioni contemporanee

# scarica ipa e anagrafica comuni
curl -skL "$URL_CSV_ENTI_IPA" > $PATH_CSV_ENTI_IPA
echo "Scaricati i dati IPA"
curl -skL "$URL_CSV_ANAGRAFICA_COMUNI" > $PATH_CSV_ANAGRAFICA_COMUNI
echo "Scaricati i dati anagrafica comuni"

# join con i dati anagrafica comuni pro_com_t di anagrafica è codice_comune_istat di ipa usa mlr
mlr --csv join -f $PATH_CSV_ENTI_IPA -j codice_comune_istat -l Codice_comune_ISTAT -r pro_com_t $PATH_CSV_ANAGRAFICA_COMUNI |\
    mlr --csv rename Codice_natura,codice_natura,Codice_IPA,codice_ipa,Denominazione_ente,denominazione_ente,Codice_comune_ISTAT,codice_comune_istat,Sito_istituzionale,url then \
    filter '$den_reg == "Sicilia"' then \
    filter '$codice_natura == 2430' then  \
    cut -f codice_ipa,denominazione_ente,codice_comune_istat,url then \
    case -l -f url then \
    put 'if (!($url =~ "^https?://")) {$url = "https://" . $url}' > $PATH_CSV_ENTI_IPA.tmp && mv $PATH_CSV_ENTI_IPA.tmp $PATH_CSV_ENTI_IPA

echo "Uniti i dati IPA con i dati anagrafica comuni e filtrati per Sicilia e codice natura 2430"
rm $PATH_CSV_ANAGRAFICA_COMUNI

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

# Funzione per processare gli URL dei comuni
process_comune_url() {
    local codice="$1"
    local url="$2"
    local current="$3"
    local total="$4"
    local percent=$((current * 100 / total))
    
    echo -ne "Processing [$current/$total] $percent% - $url with code $codice\r"
    crwl "$url" -c "exclude_external_links=false,follow_redirects=true" | \
        jq '[.links[][] | {href,text,title}]' | \
        mlr --j2c filter '$text =~ "accessibilit"i' then \
        put -s codice=$codice '$codice_comune_istat = @codice' > "data/accessibility-urls-${codice}.csv"
}

# Funzione per processare le dichiarazioni di accessibilità
process_declaration() {
    local codice="$2"
    local url="$1"
    local current="$3"
    local total="$4"
    local percent=$((current * 100 / total))
    
    echo -ne "Processing [$current/$total] $percent% - $url for code: $codice\r"
    local api_url=$(echo "$url" | sed 's|form.agid.gov.it/view/|form.agid.gov.it/api/v1/submission/view/|')
    curl -s "$api_url" | \
        jq '{idPubblicazione, dataUltimaModifica, specs_version: .datiPubblicati["specs-version"], compliance_status: .datiPubblicati["compliance-status"], reason_42004: .datiPubblicati["reason-42004"], website_cms: .datiPubblicati["website-cms"], website_cms_other: .datiPubblicati["website-cms-other"], people_disabled: .datiPubblicati["people-disabled"], people_desk_disabled: .datiPubblicati["people-desk-disabled"]}' > \
        "data/declaration-${codice}.json"
}

# provare ad aggiungere | mlr --json put -s codice=$codice '$codice_comune_istat = @codice' per avere il codice comune istat nel json

# Count total URLs for progress tracking
total_urls=$(cat $PATH_CSV_ENTI_IPA | wc -l)
total_urls=$((total_urls - 1)) # Subtract 1 for the header

# Parallelizza la scansione dei siti web dei comuni
echo "Starting parallel crawling of municipality websites..."
<$PATH_CSV_ENTI_IPA mlr --csv --headerless-csv-output cut -f codice_comune_istat,url | run_parallel $total_urls process_comune_url
echo -e "\nCompleted crawling municipality websites"

# merge csv with mlr
mlr --csv cat data/accessibility-urls-* > data/merged-accessibility-urls.csv
rm data/accessibility-urls-*
mv data/merged-accessibility-urls.csv data/accessibility-urls.csv
# questo file mi serve per capire quanti comuni hanno esposto la dichiarazione in modo corretto

total_urls=$(<data/accessibility-urls.csv mlr --csv --headerless-csv-output filter '$href =~ "^https://form.agid"' | wc -l)

# Parallelizza il recupero delle dichiarazioni di accessibilità
echo "Starting parallel retrieval of accessibility declarations..."
<data/accessibility-urls.csv mlr --csv --headerless-csv-output filter '$href =~ "^https://form.agid"' then cut -f href,codice_comune_istat | run_parallel $total_urls process_declaration
echo -e "\nCompleted retrieving accessibility declarations"

# prepara file di output
mlr --j2c cat data/declaration-* > data/merged-declarations.csv

rm data/declaration-*
mv data/merged-declarations.csv data/declarations.csv
