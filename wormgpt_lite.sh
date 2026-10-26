#!/data/data/com.termux/files/usr/bin/bash
# Alpha / Zaidon - Termux chat client for ODiRouter's OpenAI-compatible API.
# API keys are stored outside the repository in ~/.config/zaidon/.

set -o pipefail

AI_NAME="alpha 2.7 mini"
CREATOR="THE BLACK PIRATS"
PRIMARY_MODEL="${ODIROUTER_MODEL:-free-gemini-2.5-pro}"
URL_BASE="${ODIROUTER_BASE_URL:-https://api.odirouter.ai/v1}"
URL_BASE="${URL_BASE%/}"
MEMORY_FILE="${ZAIDON_MEMORY_FILE:-$HOME/.nyx_memory.json}"
CONFIG_DIR="$HOME/.config/zaidon"
KEY_FILE="$CONFIG_DIR/odirouter_api_key"
SYSTEM_PROMPT="You are ${AI_NAME}, a helpful technical assistant running in a terminal. Give accurate, practical answers and explain commands before asking the user to run them. You cannot directly execute commands, inspect the device, or download files unless a tool is explicitly provided; never claim that you performed an action you did not perform. Prefer safe, reversible troubleshooting steps."

GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    printf 'Missing dependencies. Run: bash requirements.sh\n' >&2
    exit 1
fi

mkdir -p "$CONFIG_DIR" || exit 1
chmod 700 "$CONFIG_DIR" 2>/dev/null || true
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zaidon.XXXXXX")" || exit 1
trap 'rm -rf "$TEMP_DIR"' EXIT INT TERM
RESPONSE_FILE="$TEMP_DIR/response.json"
CURL_ERROR_FILE="$TEMP_DIR/curl.err"

save_key() {
    umask 077
    if ! printf '%s\n' "$API_KEY" > "$KEY_FILE"; then
        printf 'Could not save the API key to %s\n' "$KEY_FILE" >&2
        return 1
    fi
    chmod 600 "$KEY_FILE" 2>/dev/null || true
}

get_api_key() {
    API_KEY="${ODIROUTER_API_KEY:-}"

    if [[ -z "$API_KEY" && -s "$KEY_FILE" ]]; then
        IFS= read -r API_KEY < "$KEY_FILE" || true
    fi

    # Compatibility with the old script's variable name.
    if [[ -z "$API_KEY" && -n "${NYX_API_KEY:-}" ]]; then
        API_KEY="$NYX_API_KEY"
        save_key || true
    fi

    if [[ -z "$API_KEY" ]]; then
        printf '%bODiRouter API key required (not a Google Gemini key).%b\n' "$YELLOW" "$NC"
        printf 'Paste your ODiRouter API key (input hidden): '
        IFS= read -r -s API_KEY
        printf '\n'
        if [[ -z "$API_KEY" ]]; then
            printf '%bNo API key entered.%b\n' "$RED" "$NC"
            exit 1
        fi
        save_key || exit 1
        printf '%bAPI key saved privately in %s%b\n' "$GREEN" "$KEY_FILE" "$NC"
    fi
}

init_memory() {
    if [[ ! -f "$MEMORY_FILE" ]]; then
        printf '[]\n' > "$MEMORY_FILE" || exit 1
        chmod 600 "$MEMORY_FILE" 2>/dev/null || true
        return
    fi

    if ! jq -e 'type == "array"' "$MEMORY_FILE" >/dev/null 2>&1; then
        local backup="${MEMORY_FILE}.invalid.$(date +%Y%m%d%H%M%S).bak"
        cp -p "$MEMORY_FILE" "$backup" 2>/dev/null || true
        printf '[]\n' > "$MEMORY_FILE"
        printf '%bWarning: invalid memory JSON was backed up to %s%b\n' "$YELLOW" "$backup" "$NC"
        return
    fi

    # Migrate the old Gemini-shaped history format to OpenAI-compatible chat messages.
    if jq -e 'any(.[]; has("parts") or .role == "model")' "$MEMORY_FILE" >/dev/null 2>&1; then
        if jq '[.[] | select(type == "object") |
              {role: (if .role == "assistant" or .role == "model" then "assistant" else "user" end),
               content: (if (.content | type) == "string" then .content
                         elif (.parts | type) == "array" then ([.parts[]?.text // empty] | join("\n"))
                         else "" end)} |
              select(.content != "")]' "$MEMORY_FILE" > "$MEMORY_FILE.tmp"; then
            mv "$MEMORY_FILE.tmp" "$MEMORY_FILE"
            printf '%bMigrated old conversation memory to the new format.%b\n' "$CYAN" "$NC"
        else
            rm -f "$MEMORY_FILE.tmp"
            printf '%bCould not migrate old memory; keeping the original file.%b\n' "$YELLOW" "$NC"
        fi
    fi
    chmod 600 "$MEMORY_FILE" 2>/dev/null || true
}

add_to_history() {
    local role="$1" content="$2"
    jq --arg role "$role" --arg content "$content" \
       '. += [{"role": $role, "content": $content}]' \
       "$MEMORY_FILE" > "$MEMORY_FILE.tmp" && mv "$MEMORY_FILE.tmp" "$MEMORY_FILE"
}

trim_history() {
    jq 'if length > 20 then .[-20:] else . end' \
       "$MEMORY_FILE" > "$MEMORY_FILE.tmp" && mv "$MEMORY_FILE.tmp" "$MEMORY_FILE"
    chmod 600 "$MEMORY_FILE" 2>/dev/null || true
}

show_api_error() {
    local http_code="$1" body_message
    body_message="$(jq -r '(.error.message // .error // .message // .detail // empty) | if type == "string" then . else tostring end' "$RESPONSE_FILE" 2>/dev/null || true)"
    printf '%bAPI request failed (HTTP %s).%b\n' "$RED" "$http_code" "$NC"
    if [[ -n "$body_message" ]]; then
        printf 'Server message: %s\n' "$body_message"
    elif [[ -s "$RESPONSE_FILE" ]]; then
        printf 'Response: '
        head -c 700 "$RESPONSE_FILE"
        printf '\n'
    else
        printf 'No response body received.\n'
    fi
    case "$http_code" in
        401|403) printf 'Check that this is a valid ODiRouter API key.\n' ;;
        402) printf 'The account or route may require available balance/credits.\n' ;;
        404) printf 'Check the model ID and API endpoint. Use /models to inspect available model IDs.\n' ;;
        429) printf 'Rate limit or quota reached; wait or check the provider quota.\n' ;;
    esac
}

list_models() {
    local http_code curl_rc
    printf '%bChecking models available to this API key...%b\n' "$YELLOW" "$NC"
    : > "$RESPONSE_FILE"
    : > "$CURL_ERROR_FILE"
    if http_code="$(curl -sS --connect-timeout 15 --max-time 45 \
        -o "$RESPONSE_FILE" -w '%{http_code}' \
        -H "Authorization: Bearer $API_KEY" \
        -H 'Accept: application/json' \
        "$URL_BASE/models" 2>"$CURL_ERROR_FILE")"; then
        :
    else
        curl_rc=$?
        printf '%bNetwork error (curl exit %s): %s%b\n' "$RED" "$curl_rc" "$(cat "$CURL_ERROR_FILE")" "$NC"
        return 1
    fi
    if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        show_api_error "$http_code"
        return 1
    fi
    if jq -e '.data | type == "array"' "$RESPONSE_FILE" >/dev/null 2>&1; then
        jq -r '.data[]?.id // empty' "$RESPONSE_FILE"
    else
        printf 'The server returned JSON without a .data model list:\n'
        head -c 700 "$RESPONSE_FILE"
        printf '\n'
    fi
}

send_message() {
    local prompt="$1" payload http_code curl_rc ai_text
    payload="$(jq -n \
        --arg model "$PRIMARY_MODEL" \
        --arg sys "$SYSTEM_PROMPT" \
        --arg prompt "$prompt" \
        --slurpfile hist "$MEMORY_FILE" \
        '{model: $model,
          messages: ([{role: "system", content: $sys}] + $hist[0] + [{role: "user", content: $prompt}]),
          temperature: 0.7}')" || {
        printf '%bCould not prepare the JSON request.%b\n' "$RED" "$NC"
        return 1
    }

    : > "$RESPONSE_FILE"
    : > "$CURL_ERROR_FILE"
    printf '%bThinking...%b\n' "$YELLOW" "$NC"

    if http_code="$(curl -sS --connect-timeout 15 --max-time 180 \
        -o "$RESPONSE_FILE" -w '%{http_code}' \
        -X POST "$URL_BASE/chat/completions" \
        -H "Authorization: Bearer $API_KEY" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json' \
        -d "$payload" 2>"$CURL_ERROR_FILE")"; then
        :
    else
        curl_rc=$?
        printf '%bConnection error (curl exit %s).%b\n' "$RED" "$curl_rc" "$NC"
        if [[ -s "$CURL_ERROR_FILE" ]]; then
            printf '%s\n' "$(cat "$CURL_ERROR_FILE")"
        fi
        printf 'Check internet access and ODiRouter base URL.\n'
        return 1
    fi

    if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        show_api_error "$http_code"
        return 1
    fi

    ai_text="$(jq -r '(.choices[0].message.content // empty) |
        if type == "string" then .
        elif type == "array" then map(.text // "") | join("")
        else tostring end' "$RESPONSE_FILE" 2>/dev/null || true)"

    if [[ -z "$ai_text" ]]; then
        printf '%bThe API returned HTTP %s but no assistant text was found.%b\n' "$YELLOW" "$http_code" "$NC"
        jq -r '(.error.message // .message // empty) | if type == "string" then . else tostring end' "$RESPONSE_FILE" 2>/dev/null || true
        printf 'Raw response (first 700 characters):\n'
        head -c 700 "$RESPONSE_FILE"
        printf '\n'
        return 1
    fi

    add_to_history 'user' "$prompt" || {
        printf '%bWarning: could not save the user message to memory.%b\n' "$YELLOW" "$NC"
    }
    add_to_history 'assistant' "$ai_text" || {
        printf '%bWarning: could not save the assistant response to memory.%b\n' "$YELLOW" "$NC"
    }
    trim_history || true
    printf '\n%b%s:%b\n%s\n' "$BLUE" "$AI_NAME" "$NC" "$ai_text"
}

print_help() {
    cat <<HELP
Commands:
  /help          Show this help
  /models        List models visible to your ODiRouter API key
  /model ID      Use a different model for this session
  /key           Replace the saved ODiRouter API key
  /reset         Delete conversation history (does not delete the API key)
  /exit          Exit the assistant
HELP
}

change_api_key() {
    local new_key
    printf 'Enter the new ODiRouter API key (input hidden): '
    IFS= read -r -s new_key
    printf '\n'
    if [[ -z "$new_key" ]]; then
        printf '%bEmpty key; the existing key was kept.%b\n' "$YELLOW" "$NC"
        return 1
    fi
    API_KEY="$new_key"
    save_key || return 1
    printf '%bNew API key saved privately.%b\n' "$GREEN" "$NC"
}

get_api_key
init_memory

printf '%b===========================================%b\n' "$CYAN" "$NC"
printf '%b %s | by %s %b\n' "$GREEN" "$AI_NAME" "$CREATOR" "$NC"
printf '%b===========================================%b\n' "$CYAN" "$NC"
printf 'Engine: %s\nAPI: %s\n' "$PRIMARY_MODEL" "$URL_BASE"
printf 'Type /help for commands. Type /exit to quit.\n\n'

while true; do
    printf '%bYou: %b' "$GREEN" "$NC"
    if ! IFS= read -r user_input; then
        printf '\n'
        break
    fi
    [[ -z "$user_input" ]] && continue

    case "$user_input" in
        /exit|exit|quit)
            printf '%bGoodbye.%b\n' "$CYAN" "$NC"
            break
            ;;
        /help)
            print_help
            continue
            ;;
        /models)
            list_models
            continue
            ;;
        /key)
            change_api_key
            continue
            ;;
        /reset)
            printf '[]\n' > "$MEMORY_FILE" && chmod 600 "$MEMORY_FILE" 2>/dev/null || true
            printf '%bConversation history cleared.%b\n' "$CYAN" "$NC"
            continue
            ;;
        /model\ *)
            new_model="${user_input#/model }"
            if [[ -n "$new_model" ]]; then
                PRIMARY_MODEL="$new_model"
                printf '%bModel for this session: %s%b\n' "$CYAN" "$PRIMARY_MODEL" "$NC"
            else
                printf 'Usage: /model MODEL_ID\n'
            fi
            continue
            ;;
    esac

    send_message "$user_input"
    printf '%b-------------------------------------------%b\n' "$CYAN" "$NC"
done
