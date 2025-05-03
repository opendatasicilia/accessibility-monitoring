#!/bin/bash

# balinkx è un tool (browser based) per estrarre i link di accessibilità da un sito web
#
# DESCRIZIONE:
# Questo script utilizza Chrome in modalità headless per accedere a un sito web
# e cercare link relativi all'accessibilità.
#
# UTILIZZO:
#   balinkx <url>
#
# CODICI DI USCITA:
#   0 - Successo: Trovati link di accessibilità
#   1 - Errore: URL mancante o non valido
#   2 - Errore: Impossibile accedere al sito web
#   3 - Avviso: Nessun link di accessibilità trovato sul sito

balinkx() {
    local url="$1"
    
    if [ -z "$url" ]; then
        echo "Usage: balinkx <url>"
        return 1
    fi

    # Tentativo di accesso al sito
    local html_content
    html_content=$(google-chrome-stable --headless=new --no-sandbox --disable-gpu \
    --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
    (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36" \
    --log-level=3 \
    --dump-dom \
    --virtual-time-budget=5000 --timeout=10000 "$url" 2>/dev/null)
    
    local chrome_exit=$?
    
    if [ $chrome_exit -ne 0 ] || [ -z "$html_content" ]; then
        echo "balinkx: Failed to access website: $url"
        return 2
    fi

    # Privacy error
    if printf '%s' "$html_content" | grep -q -i "<title>Privacy error</title>"; then
        echo "balinkx: Privacy error accessing website: $url"
        return 2
    fi
    
    # Cerca i link di accessibilità nel contenuto HTML
    local result
    result=$(echo "$html_content" | \
    scrape -be "//a[contains(translate(., 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'cessibilit') or contains(., 'form.agid.gov')]" | \
    xq -c '
    def extract_text($obj):
    if $obj|type == "string" then $obj
    elif $obj|type == "array" then ($obj|map(extract_text(.)) | join(" "))
    elif $obj|type == "object" then
        if $obj|has("#text") then $obj."#text"
        else
        ($obj|to_entries|map(
            select(.key|startswith("@")|not) | extract_text(.value)
        )|join(" "))
        end
    else ""
    end;

    (.html?.body?.a // error("ERROR: Link accessibilità non trovato"))
    | if type == "array" then . else [.] end
    | map({
        href: (."@href" // ""),
        text: extract_text(.)
    })
    | .[]' 2>/dev/null)
    
    local xq_exit=$?

    if [ $xq_exit -ne 0 ]; then
        # DOM valido ma nessun link trovato: curl conferma raggiungibilità?
        if ! curl -sSI -f --max-time 5 "$url" >/dev/null; then
            echo "balinkx: Failed to access website (TLS/HTTP error): $url"
            return 2
        else
            echo "balinkx: No accessibility links found on website: $url"
            return 3
        fi
    else
        echo "$result"
        return 0
    fi
}

# Se lo script viene eseguito direttamente (non sourced), esegui la funzione con gli argomenti forniti
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    balinkx "$@"
    exit $?
fi