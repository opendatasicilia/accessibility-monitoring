#!/bin/bash

# balinkx è un tool (browser based) per estrarre i link di accessibilità da un sito web

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
    --virtual-time-budget=5000 "$url" 2>/dev/null)
    
    local chrome_exit=$?
    
    if [ $chrome_exit -ne 0 ] || [ -z "$html_content" ]; then
        echo "balinkx: Failed to access website: $url"
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
        echo "balinkx: No accessibility links found on website: $url"
        return 3
    else
        echo "$result"
        return 0
    fi
}

# Se lo script viene eseguito direttamente (non sourced), esegui la funzione con gli argomenti forniti
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    balinkx "$@"
fi