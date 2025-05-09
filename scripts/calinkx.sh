#!/bin/bash

# calinkx è un tool (curl based) per estrarre i link di accessibilità da un sito web

calinkx() {
    local url="$1"
    
    if [ -z "$url" ]; then
        echo "Usage: alinkx <url>"
        return 1
    fi

    curl -skL -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36" "$url" |\
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
        | .[]' 2>/dev/null

    # check exit code
    if [ $? -ne 0 ]; then
        echo "calinkx: Failed to extract accessibility references: $url"
        return 1
    fi
}

# Se lo script viene eseguito direttamente (non sourced), esegui la funzione con gli argomenti forniti
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    calinkx "$@"
fi