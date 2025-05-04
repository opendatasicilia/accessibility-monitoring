#!/bin/bash


# set -x


# -------------------- constants -------------------- #

# PATHS INPUT
URL_CSV_ENTI_IPA="https://indicepa.gov.it/ipa-dati/datastore/dump/d09adf99-dc10-4349-8c53-27b1e5aa97b6?bom=True&format=csv"
PATH_CSV_ENTI_IPA="data/enti.csv"
URL_CSV_ANAGRAFICA_COMUNI="https://raw.githubusercontent.com/opendatasicilia/comuni-italiani/refs/heads/main/dati/comuni.csv"
PATH_CSV_ANAGRAFICA_COMUNI="data/comuni.csv"

# PATH OUTPUT
PATH_CSV_ACCESSIBILITY_URLS="data/accessibility_urls.csv"                  # File CSV con la lista degli URL associati ai riferimenti di accessibilità  
PATH_CSV_DECLARATIONS="data/declarations.csv"                              # File CSV con i dati contenuti nelle dichiarazioni di accessibilità
PATH_CSV_UNREACHABLE_SITES="data/unreachable_sites.csv"                    # File di log per i siti non raggiungibili
PATH_CSV_MISSING_ACCESSIBILITY_REFS="data/missing_accessibility_refs.csv"  # File di log per i siti senza riferimenti all'accessibilità in generale (cioè in cui non è presente la stringa "cessibilit" oppure la stringa "form.agid.gov")
PATH_LOG_FILE="data/site_checks.log"                                       # File di log per i controlli head

# PARAMETERS
MAX_CONCURRENT_JOBS=5     # Numero massimo di connessioni contemporanee (per la ricerca delle dichiarazioni, non per lo scraping delle dichiarazioni)
MAX_RETRIES=3             # Numero massimo di tentativi per check_site
TIMEOUT=10                # Timeout in secondi per check_site
RETRY_DELAY=2             # Ritardo tra i tentativi in secondi per check_site
API_REQUEST_DELAY=0.5     # Secondi di attesa tra le chiamate API AGID
API_DOMAIN_CHECKED=0      # Flag per verificare se il dominio API è già stato controllato
TOO_MANY_REQUESTS_THRESHOLD=5  # Numero massimo di errori 429 API AGID consecutivi prima di interrompere


# -------------------- functions -------------------- #

source scripts/calinkx.sh   #curl
source scripts/balinkx.sh   #browser
source scripts/functions.sh #other functions


# -------------------- main script -------------------- #

# Create log directory if it doesn't exist
mkdir -p data

# Assicurati che il file di log esista
touch "$PATH_LOG_FILE"

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

# force head for debug mode
# <$PATH_CSV_ENTI_IPA mlr --csv shuffle | head -n 11 > $PATH_CSV_ENTI_IPA.tmp && mv $PATH_CSV_ENTI_IPA.tmp $PATH_CSV_ENTI_IPA

total_urls=$(cat $PATH_CSV_ENTI_IPA | wc -l)
total_urls=$((total_urls - 1)) # Subtract 1 for the header

# Parallelizza la scansione dei siti web dei comuni
echo "Starting parallel crawling of municipality websites..."
<$PATH_CSV_ENTI_IPA mlr --csv --headerless-csv-output cut -f codice_comune_istat,url then shuffle | run_parallel $total_urls process_comune_url

# double check missing
echo "Starting double check for missing accessibility references..."
total_urls=$(cat $PATH_CSV_MISSING_ACCESSIBILITY_REFS | wc -l)
total_urls=$((total_urls - 1)) # Subtract 1 for the header
mv $PATH_CSV_MISSING_ACCESSIBILITY_REFS $PATH_CSV_MISSING_ACCESSIBILITY_REFS.tmp
echo "timestamp,codice_comune_istat,url" > $PATH_CSV_MISSING_ACCESSIBILITY_REFS
<$PATH_CSV_MISSING_ACCESSIBILITY_REFS.tmp mlr --csv --headerless-csv-output cut -f codice_comune_istat,url then shuffle | run_parallel $total_urls process_comune_url
mv $PATH_CSV_MISSING_ACCESSIBILITY_REFS.tmp $PATH_CSV_MISSING_ACCESSIBILITY_REFS

echo "Completed crawling municipality websites"

# wait for keypress
# read -r -p "Press any key to continue..." key

# merge csvs
mlr --csv cat data/accessibility_urls-* then sort -f codice_comune_istat > data/merged-accessibility_urls.csv
rm data/accessibility_urls-* && mv data/merged-accessibility_urls.csv $PATH_CSV_ACCESSIBILITY_URLS

# rm unnecessary column from enti PATH_CSV_ENTI_IPA
mlr -I --csv cut -x -f url $PATH_CSV_ENTI_IPA

# join comune
mlr --csv join -f $PATH_CSV_ACCESSIBILITY_URLS -j codice_comune_istat $PATH_CSV_ENTI_IPA > $PATH_CSV_ACCESSIBILITY_URLS.tmp && mv $PATH_CSV_ACCESSIBILITY_URLS.tmp $PATH_CSV_ACCESSIBILITY_URLS

# Verifica iniziale della raggiungibilità del dominio API
if [ "$API_DOMAIN_CHECKED" -eq 0 ]; then
    if ! check_site "https://form.agid.gov.it/"; then
        echo "AGID API domain is not accessible. Aborting declaration processing." | tee -a "$PATH_LOG_FILE"
        exit 1
    fi
    API_DOMAIN_CHECKED=1
    echo "AGID API domain is accessible. Starting to process declarations..."
fi

# filtro dichiarazioni univoche
<$PATH_CSV_ACCESSIBILITY_URLS mlr --csv --headerless-csv-output filter '$href =~ "^https://form.agid"' then cut -f href,codice_comune_istat | uniq > data/form_urls.csv.tmp

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
mlr --csv join -f data/merged-declarations.csv -j codice_comune_istat $PATH_CSV_ENTI_IPA > $PATH_CSV_DECLARATIONS
rm data/merged-declarations.csv

# sorting MISSING_ACCESSIBILITY_REFS e unreachable_sites
mlr -I --csv sort -f codice_comune_istat $PATH_CSV_MISSING_ACCESSIBILITY_REFS 
mlr -I --csv sort -f codice_comune_istat $PATH_CSV_UNREACHABLE_SITES

# rm unnecessary file
rm $PATH_CSV_ENTI_IPA
