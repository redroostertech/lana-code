#!/usr/bin/env bash
# API communication with llama-server

# ── Build API payload ────────────────────────────────

_api_build_payload() {
    local messages_json="$1"
    local stream="${2:-false}"
    local tools_json
    tools_json=$(get_tool_definitions)

    local payload
    payload=$(jq -n \
        --arg model_name "$API_MODEL" \
        --argjson messages "$messages_json" \
        --argjson tools "$tools_json" \
        --argjson temperature "$TEMPERATURE" \
        --argjson max_tokens "$MAX_TOKENS" \
        --argjson frequency_penalty "$FREQUENCY_PENALTY" \
        --argjson presence_penalty "$PRESENCE_PENALTY" \
        --argjson stream "$stream" \
        '{
            "model": $model_name,
            "messages": $messages,
            "tools": $tools,
            "tool_choice": "auto",
            "temperature": $temperature,
            "max_tokens": $max_tokens,
            "frequency_penalty": $frequency_penalty,
            "presence_penalty": $presence_penalty,
            "stream": $stream
        }')

    # For streaming, request usage stats in the final chunk
    if [[ "$stream" == "true" ]]; then
        payload=$(echo "$payload" | jq '. + {"stream_options": {"include_usage": true}}')
    fi

    echo "$payload"
}

# ── Non-streaming chat completion (fallback) ─────────

api_chat_completion() {
    local messages_json="$1"

    local payload
    payload=$(_api_build_payload "$messages_json" "false")

    # Debug: log payload
    if [[ "${LANA_DEBUG:-false}" == "true" || "${LANA_DEBUG:-0}" == "1" ]]; then
        printf "\n${C_DIM}[debug] ── API Request ──${C_RESET}\n" >/dev/tty
        echo "$payload" | jq '.' >/dev/tty 2>/dev/null
    fi

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "${API_URL}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        --max-time 300)

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    # Debug: log response
    if [[ "${LANA_DEBUG:-false}" == "true" || "${LANA_DEBUG:-0}" == "1" ]]; then
        printf "\n${C_DIM}[debug] ── API Response (HTTP %s) ──${C_RESET}\n" "$http_code" >/dev/tty
        echo "$body" | jq '.' >/dev/tty 2>/dev/null
    fi

    if [[ "$http_code" != "200" ]]; then
        local error_msg
        error_msg=$(echo "$body" | jq -r '.error.message // .error // "Unknown error"' 2>/dev/null)
        echo "{\"error\": \"HTTP $http_code: $error_msg\"}"
        return 1
    fi

    # Validate response structure
    if ! echo "$body" | jq -e '.choices[0]' >/dev/null 2>&1; then
        echo "{\"error\": \"Invalid response: missing choices array\"}"
        return 1
    fi

    echo "$body"
}

# ── Streaming chat completion ────────────────────────
# Streams text to /dev/tty in real-time, accumulates tool calls.
# Writes the fully assembled response JSON to stdout when done.

api_chat_completion_stream() {
    local messages_json="$1"
    local output_file="$SESSION_DIR/stream_response.json"

    local payload
    payload=$(_api_build_payload "$messages_json" "true")

    if [[ "${LANA_DEBUG:-false}" == "true" || "${LANA_DEBUG:-0}" == "1" ]]; then
        printf "\n${C_DIM}[debug] ── API Request (streaming) ──${C_RESET}\n" >/dev/tty
        echo "$payload" | jq '.' >/dev/tty 2>/dev/null
    fi

    # Quick connection test — fail fast if server is unreachable
    if ! curl -s -o /dev/null -w "" "${API_URL}/health" --max-time 2 2>/dev/null; then
        echo '{"error": "Server unreachable at '"${API_URL}"'"}'
        return 1
    fi

    # Stream the response and process chunks with perl
    # Perl script: prints text to /dev/tty in real-time, outputs assembled JSON to stdout
    curl -sN \
        -X POST "${API_URL}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        --max-time 300 2>/dev/null | perl -e '
        use JSON::PP;
        use IO::Select;
        no warnings;
        $| = 1;  # autoflush stdout
        my $json = JSON::PP->new->utf8->allow_nonref;

        # Open /dev/tty for display output
        open(my $tty, ">", "/dev/tty") or die "Cannot open /dev/tty: $!";
        select($tty); $| = 1; select(STDOUT);  # autoflush tty

        # Set up non-blocking ESC key detection from /dev/tty
        my ($tty_in, $sel, $can_detect_keys, $saved_termios);
        eval {
            require POSIX;
            open($tty_in, "<", "/dev/tty") or die;
            $saved_termios = POSIX::Termios->new();
            $saved_termios->getattr(fileno($tty_in));
            my $raw = POSIX::Termios->new();
            $raw->getattr(fileno($tty_in));
            my $lflag = $raw->getlflag();
            $lflag &= ~(POSIX::ICANON() | POSIX::ECHO());
            $raw->setlflag($lflag);
            $raw->setcc(POSIX::VMIN(), 0);
            $raw->setcc(POSIX::VTIME(), 0);
            $raw->setattr(fileno($tty_in), POSIX::TCSANOW());
            $sel = IO::Select->new($tty_in);
            $can_detect_keys = 1;
        };

        my $content = "";
        my @tool_calls;
        my $finish_reason = "stop";
        my $prompt_tokens = 0;
        my $completion_tokens = 0;
        my $model = $ENV{LANA_API_MODEL} // "local-model";
        my $first_text = 1;
        my $in_think = 0;
        my $in_code_block = 0;
        my $line_buf = "";
        my %line_count;          # track line repetitions
        my $repetition_limit = 3; # abort after this many identical lines
        my $aborted = 0;
        my $input_buf = "";      # buffer for sysread data

        # Braille spinner animation
        my @spinner = ("\xe2\xa0\x8b", "\xe2\xa0\x99", "\xe2\xa0\xb9", "\xe2\xa0\xb8", "\xe2\xa0\xbc", "\xe2\xa0\xb4", "\xe2\xa0\xa6", "\xe2\xa0\xa7", "\xe2\xa0\x87", "\xe2\xa0\x8f");
        my $spin_idx = 0;

        # ANSI color codes — matches ui.sh palette
        my $C_RESET   = "\033[0m";
        my $C_BOLD    = "\033[1m";
        my $C_DIM     = "\033[2m";
        my $C_WHITE   = "\033[1;37m";
        my $C_CYAN    = "\033[0;36m";
        my $C_BCYAN   = "\033[1;36m";
        my $C_GREEN   = "\033[0;32m";
        my $C_BGREEN  = "\033[1;32m";
        my $C_BBLUE   = "\033[1;34m";
        my $C_YELLOW  = "\033[0;33m";
        my $C_GRAY    = "\033[0;90m";

        # Box drawing characters
        my $BOX_TL = "\xe2\x95\xad";  # top-left
        my $BOX_BL = "\xe2\x95\xb0";  # bottom-left
        my $BOX_V  = "\xe2\x94\x82";  # vertical
        my $BOX_H  = "\xe2\x94\x80";  # horizontal

        # Render a complete line with markdown formatting
        sub render_line {
            my ($tty, $ln) = @_;

            # Code block fence
            if ($ln =~ /^```(.*)/) {
                if ($in_code_block) {
                    print $tty "  ${C_DIM}${BOX_BL}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${C_RESET}\n";
                    $in_code_block = 0;
                } else {
                    my $lang = $1;
                    if ($lang) {
                        print $tty "  ${C_DIM}${BOX_TL}${BOX_H}${BOX_H} ${lang} ${BOX_H}${BOX_H}${BOX_H}${C_RESET}\n";
                    } else {
                        print $tty "  ${C_DIM}${BOX_TL}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${C_RESET}\n";
                    }
                    $in_code_block = 1;
                }
                return;
            }

            if ($in_code_block) {
                print $tty "  ${C_DIM}${BOX_V}${C_RESET} ${C_GREEN}${ln}${C_RESET}\n";
                return;
            }

            # Headers
            if ($ln =~ /^### (.*)/) {
                print $tty "  ${C_BOLD}${C_BCYAN}   $1${C_RESET}\n";
            } elsif ($ln =~ /^## (.*)/) {
                print $tty "  ${C_BOLD}${C_BCYAN}  $1${C_RESET}\n";
            } elsif ($ln =~ /^# (.*)/) {
                print $tty "\n  ${C_BOLD}${C_BCYAN} $1${C_RESET}\n";
            # Bullet points
            } elsif ($ln =~ /^(\s*)[-*]\s+(.*)/) {
                my ($indent, $text) = ($1, $2);
                $text =~ s/\*\*([^*]+)\*\*/${C_BOLD}$1${C_RESET}/g;
                $text =~ s/`([^`]+)`/${C_CYAN}$1${C_RESET}/g;
                print $tty "  ${indent}${C_DIM}  \xe2\x80\xa2${C_RESET} ${text}\n";
            } else {
                # Inline bold: **text**
                $ln =~ s/\*\*([^*]+)\*\*/${C_BOLD}$1${C_RESET}/g;
                # Inline code: `text`
                $ln =~ s/`([^`]+)`/${C_CYAN}$1${C_RESET}/g;
                print $tty "  $ln\n";
            }
        }

        # Process a single SSE line
        sub process_sse_line {
            my ($line) = @_;
            return unless $line =~ /^data:\s*(.+)/;
            my $data = $1;
            return if $data eq "[DONE]";

            my $chunk;
            eval { $chunk = $json->decode($data); };
            return if $@;

            $model = $chunk->{model} if $chunk->{model};

            if ($chunk->{usage}) {
                $prompt_tokens = $chunk->{usage}{prompt_tokens} // 0;
                $completion_tokens = $chunk->{usage}{completion_tokens} // 0;
            }

            my $delta = $chunk->{choices}[0]{delta};
            return unless $delta;

            $finish_reason = $chunk->{choices}[0]{finish_reason}
                if defined $chunk->{choices}[0]{finish_reason};

            # Text content delta
            if (defined $delta->{content} && $delta->{content} ne "") {
                my $text = $delta->{content};

                # Track <think> blocks — display dimmed, strip from content
                if ($text =~ /<think>/) {
                    $in_think = 1;
                    my $before = $text;
                    $before =~ s/<think>.*//s;
                    # Show "thinking..." label on first think block
                    if ($first_text) {
                        print $tty "\r\033[K\n${C_BBLUE}assistant${C_RESET} ${C_DIM}(thinking)${C_RESET}\n";
                        $first_text = 0;
                    } else {
                        print $tty "\n${C_DIM}thinking...${C_RESET}\n";
                    }
                    $text = $before;
                }
                if ($in_think) {
                    if ($text =~ /<\/think>(.*)$/s) {
                        # Show the thinking content before </think> dimmed
                        my $think_text = $text;
                        $think_text =~ s/<\/think>.*//s;
                        if ($think_text =~ /\S/) {
                            for my $tl (split /\n/, $think_text) {
                                print $tty "  ${C_DIM}$tl${C_RESET}\n" if $tl =~ /\S/;
                            }
                        }
                        print $tty "${C_DIM}${BOX_H}${BOX_H}${BOX_H}${C_RESET}\n";
                        $in_think = 0;
                        $text = $1;
                    } else {
                        # Still inside think block — show dimmed
                        for my $tl (split /\n/, $text) {
                            print $tty "  ${C_DIM}$tl${C_RESET}\n" if $tl =~ /\S/;
                        }
                        return;
                    }
                }

                return if $text eq "";
                $content .= $text;

                # Clear spinner and show assistant label on first text
                if ($first_text) {
                    print $tty "\r\033[K\n${C_BBLUE}assistant${C_RESET}\n";
                    $first_text = 0;
                }

                # Line-buffered rendering
                $line_buf .= $text;
                while ($line_buf =~ /\n/) {
                    my $idx = index($line_buf, "\n");
                    my $complete_line = substr($line_buf, 0, $idx);
                    $line_buf = substr($line_buf, $idx + 1);

                    # Repetition detection
                    if ($complete_line =~ /\S/) {
                        $line_count{$complete_line}++;
                        if ($line_count{$complete_line} >= $repetition_limit) {
                            print $tty "\n  ${C_YELLOW}\xe2\x9a\xa0 output truncated \xe2\x80\x94 repetition detected${C_RESET}\n";
                            $finish_reason = "stop";
                            $aborted = 1;
                            return;
                        }
                    }

                    render_line($tty, $complete_line);
                }
            }

            # Tool call deltas
            if ($delta->{tool_calls}) {
                # Clear spinner on first tool call
                if ($first_text) {
                    print $tty "\r\033[K";
                    $first_text = 0;
                }
                for my $tc_delta (@{$delta->{tool_calls}}) {
                    my $idx = $tc_delta->{index} // 0;

                    if (!defined $tool_calls[$idx]) {
                        $tool_calls[$idx] = {
                            id => $tc_delta->{id} // "call_$idx",
                            type => "function",
                            function => { name => "", arguments => "" }
                        };
                    }

                    if ($tc_delta->{function}) {
                        $tool_calls[$idx]{function}{name} .= $tc_delta->{function}{name} // "";
                        $tool_calls[$idx]{function}{arguments} .= $tc_delta->{function}{arguments} // "";
                    }
                }
            }
        }

        # ── Main event loop with animated spinner ──
        my $stdin_sel = IO::Select->new(\*STDIN);

        while (1) {
            last if $aborted;

            # Check for ESC key (non-blocking)
            if ($can_detect_keys && $sel->can_read(0)) {
                my $buf;
                sysread($tty_in, $buf, 16);
                if (defined $buf && $buf =~ /\x1b/) {
                    print $tty "\r\033[K" if $first_text;
                    print $tty "\n  ${C_YELLOW}\xe2\x9c\x95 interrupted${C_RESET}\n";
                    $aborted = 1;
                    last;
                }
            }

            # Wait for data with 100ms timeout (allows spinner animation)
            if ($stdin_sel->can_read(0.1)) {
                my $bytes = sysread(STDIN, my $chunk, 8192);
                last if !defined $bytes || $bytes == 0;  # EOF
                $input_buf .= $chunk;

                # Process complete lines from buffer
                while ($input_buf =~ s/^(.*?\n)//) {
                    process_sse_line($1 =~ s/\s+$//r);
                    last if $aborted;
                }
            } else {
                # No data yet — animate spinner while waiting
                if ($first_text) {
                    my $frame = $spinner[$spin_idx++ % scalar @spinner];
                    print $tty "\r\033[K  ${C_DIM}${frame} ${C_CYAN}thinking${C_RESET}";
                }
            }
        }

        # Flush remaining line buffer
        if ($line_buf ne "") {
            render_line($tty, $line_buf);
        }
        # Close any unclosed code block
        if ($in_code_block) {
            print $tty "  ${C_DIM}${BOX_BL}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${C_RESET}\n";
        }
        print $tty "\n" unless $first_text;

        # Restore terminal settings
        if ($can_detect_keys) {
            $saved_termios->setattr(fileno($tty_in), POSIX::TCSANOW());
            close($tty_in);
        }

        close($tty);

        # Output assembled response as JSON to stdout
        my $message = { role => "assistant" };
        $message->{content} = $content if $content ne "";
        $message->{tool_calls} = \@tool_calls if @tool_calls;

        my $response = {
            choices => [{ message => $message, finish_reason => $finish_reason }],
            model => $model,
            usage => {
                prompt_tokens => $prompt_tokens,
                completion_tokens => $completion_tokens,
                total_tokens => $prompt_tokens + $completion_tokens
            }
        };

        print STDOUT $json->encode($response);
    '
}

# ── Parse response ─────────────────────────────────────

api_has_tool_calls() {
    local response="$1"
    local tool_calls
    tool_calls=$(echo "$response" | jq -r '.choices[0].message.tool_calls // empty')
    [[ -n "$tool_calls" && "$tool_calls" != "null" && "$tool_calls" != "[]" ]]
}

api_get_content() {
    local response="$1"
    echo "$response" | jq -r '.choices[0].message.content // empty'
}

api_get_tool_calls() {
    local response="$1"
    echo "$response" | jq -c '.choices[0].message.tool_calls // []'
}

api_get_finish_reason() {
    local response="$1"
    echo "$response" | jq -r '.choices[0].finish_reason // "unknown"'
}

api_get_usage() {
    local response="$1"
    echo "$response" | jq -c '{
        prompt_tokens: (.usage.prompt_tokens // 0),
        completion_tokens: (.usage.completion_tokens // 0),
        total_tokens: (.usage.total_tokens // 0)
    }' 2>/dev/null
}

# ── Text-based tool call fallback parser ────────────────
# Some models output tool calls as <tool_call>JSON</tool_call> in text
# instead of structured tool_calls. This extracts and converts them.

api_parse_text_tool_calls() {
    local content="$1"

    # Quick check — skip if no tags present
    [[ "$content" != *'<tool_call>'* ]] && return 1

    # Extract JSON objects between <tool_call> tags using perl, convert with jq
    local result
    result=$(printf '%s' "$content" | perl -0777 -ne '
        my @jsons;
        while (/<tool_call>\s*(.*?)\s*<\/tool_call>/gs) {
            push @jsons, $1;
        }
        print join("\n", @jsons);
    ' | jq -s '
        [to_entries[] | .value as $tc | {
            id: ("call_text_" + (.key | tostring)),
            type: "function",
            function: {
                name: $tc.name,
                arguments: ($tc.arguments | tostring)
            }
        }]
    ' 2>/dev/null)

    [[ -z "$result" || "$result" == "[]" || "$result" == "null" ]] && return 1

    echo "$result"
}

# Strip <tool_call> tags from content for display
api_strip_tool_call_tags() {
    local content="$1"
    printf '%s' "$content" | perl -0777 -pe 's/<tool_call>.*?<\/tool_call>//gs; s/^\s*\n//gm'
}

# ── Shell code block → tool call converter ────────────
# When the model outputs ```sh/```bash code blocks instead of calling
# the bash tool, extract the commands and convert to tool calls.

api_parse_shell_code_blocks() {
    local content="$1"

    # Quick check — must contain a shell code block
    if ! echo "$content" | grep -qE '```(bash|sh|shell|zsh)'; then
        return 1
    fi

    # Extract commands from shell code blocks using perl
    local result
    result=$(printf '%s' "$content" | perl -0777 -ne '
        use JSON::PP;
        my $json = JSON::PP->new->utf8;
        my @calls;
        my $idx = 0;
        while (/```(?:bash|sh|shell|zsh)\s*\n(.*?)```/gs) {
            my $cmd = $1;
            $cmd =~ s/^\s+|\s+$//g;  # trim
            next if $cmd eq "";
            push @calls, {
                id => "call_block_$idx",
                type => "function",
                function => {
                    name => "bash",
                    arguments => $json->encode({command => $cmd})
                }
            };
            $idx++;
        }
        print $json->encode(\@calls) if @calls;
    ' 2>/dev/null)

    [[ -z "$result" || "$result" == "[]" || "$result" == "null" ]] && return 1

    echo "$result"
}

# Strip shell code blocks from content (they'll be executed as tool calls)
api_strip_shell_code_blocks() {
    local content="$1"
    printf '%s' "$content" | perl -0777 -pe 's/```(?:bash|sh|shell|zsh)\s*\n.*?```//gs; s/^\s*\n//gm'
}

# ── Natural language tool intention parser ─────────────
# Fallback 3: When the model describes tool calls in plain English
# ("I'll use file_tree", "Let me read the README") but doesn't emit
# structured calls, parse the intention and create tool calls.

api_parse_nl_tool_intentions() {
    local content="$1"
    local work_dir="$2"

    # Build tool calls from natural language patterns
    local calls="[]"
    local idx=0
    local _added_paths=""  # track files already added to avoid duplicates

    # Pattern: file_tree / directory tree mentions
    if echo "$content" | grep -qiE "(file_tree|directory tree|project (layout|structure|tree)|folder structure)"; then
        local tree_path="${work_dir:-.}"
        calls=$(echo "$calls" | jq --arg p "$tree_path" --arg id "call_nl_$idx" \
            '. + [{"id": $id, "type": "function", "function": {"name": "file_tree", "arguments": ("{\"path\": \"" + $p + "\", \"depth\": 3}")}}]')
        idx=$((idx + 1))
    fi

    # Pattern: read README
    if echo "$content" | grep -qiE "(read.*README|README\.(md|txt|rst))"; then
        # Try to find a README
        local readme=""
        for f in "$work_dir/README.md" "$work_dir/README.txt" "$work_dir/README.rst" "$work_dir/README"; do
            if [[ -f "$f" ]]; then
                readme="$f"
                break
            fi
        done
        if [[ -n "$readme" ]]; then
            calls=$(echo "$calls" | jq --arg p "$readme" --arg id "call_nl_$idx" \
                '. + [{"id": $id, "type": "function", "function": {"name": "read_file", "arguments": ("{\"path\": \"" + $p + "\"}")}}]')
            _added_paths="$_added_paths $readme"
            idx=$((idx + 1))
        fi
    fi

    # Pattern: read a specific file path mentioned in the text
    # Catches both absolute (/foo/bar.py) and relative (src/bar.py, ./bar.py) paths
    local mentioned_path
    mentioned_path=$(echo "$content" | grep -oE '(read(ing)?|open(ing)?|check(ing)?|look(ing)? at|examin(e|ing))[^.;]*[a-zA-Z0-9_/.-]+\.[a-zA-Z0-9]+' | grep -oE '[a-zA-Z0-9_./-]+\.[a-zA-Z0-9]+' | head -1)
    if [[ -n "$mentioned_path" ]]; then
        # Resolve relative paths against work_dir
        if [[ "$mentioned_path" != /* && -n "$work_dir" ]]; then
            if [[ -f "$work_dir/$mentioned_path" ]]; then
                mentioned_path="$work_dir/$mentioned_path"
            fi
        fi
        # Skip if already added (e.g. README matched by both patterns)
        if [[ -f "$mentioned_path" ]] && ! echo "$_added_paths" | grep -qF "$mentioned_path"; then
            calls=$(echo "$calls" | jq --arg p "$mentioned_path" --arg id "call_nl_$idx" \
                '. + [{"id": $id, "type": "function", "function": {"name": "read_file", "arguments": ("{\"path\": \"" + $p + "\"}")}}]')
            _added_paths="$_added_paths $mentioned_path"
            idx=$((idx + 1))
        fi
    fi

    # Pattern: glob/find files
    if echo "$content" | grep -qiE "(glob_find|find files|search for files|look for.*files)"; then
        calls=$(echo "$calls" | jq --arg p "**/*" --arg id "call_nl_$idx" \
            '. + [{"id": $id, "type": "function", "function": {"name": "glob_find", "arguments": ("{\"pattern\": \"" + $p + "\"}")}}]')
        idx=$((idx + 1))
    fi

    # Pattern: grep/search
    local search_term
    search_term=$(echo "$content" | grep -oiE '(grep_search|search for|grep)[^.]*"([^"]+)"' | grep -oE '"[^"]+"' | head -1 | tr -d '"')
    if [[ -n "$search_term" ]]; then
        calls=$(echo "$calls" | jq --arg p "$search_term" --arg id "call_nl_$idx" \
            '. + [{"id": $id, "type": "function", "function": {"name": "grep_search", "arguments": ("{\"pattern\": \"" + $p + "\"}")}}]')
        idx=$((idx + 1))
    fi

    [[ "$calls" == "[]" ]] && return 1
    echo "$calls"
}

# ── Thinking block stripper ────────────────────────────
# Qwen3 models may output <think>...</think> blocks

api_strip_thinking() {
    local content="$1"
    printf '%s' "$content" | perl -0777 -pe 's/<think>.*?<\/think>//gs; s/^\s*\n//gm'
}

# ── Server health check ───────────────────────────────

api_health_check() {
    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" "${API_URL}/health" --max-time 5 2>/dev/null)
    [[ "$response" == "200" ]]
}

api_wait_for_server() {
    local max_wait=600   # 10 minutes — large models (17GB+) need time to load
    local waited=0
    spinner_start "waiting for llama-server to load model"
    while ! api_health_check; do
        sleep 2
        waited=$((waited + 2))
        # Check if server process is still alive
        if [[ -n "$LLAMA_SERVER_PID" ]] && ! kill -0 "$LLAMA_SERVER_PID" 2>/dev/null; then
            spinner_stop
            ui_error "llama-server process died during startup"
            return 1
        fi
        if (( waited >= max_wait )); then
            spinner_stop
            ui_error "llama-server failed to start within ${max_wait}s"
            return 1
        fi
        # Progress indicator every 30s
        if (( waited % 30 == 0 && waited > 0 )); then
            spinner_stop
            ui_dim "  still loading... (${waited}s)"
            spinner_start "waiting for llama-server to load model"
        fi
    done
    spinner_stop
    return 0
}
