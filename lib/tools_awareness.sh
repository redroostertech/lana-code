#!/usr/bin/env bash
# Project awareness tools: project_detect, memory, git_smart, task_plan
# Bash 3.2 compatible — NO associative arrays, NO read -a, NO readarray

# ── Awareness tool definitions JSON ───────────────────

get_awareness_tool_definitions() {
    cat << 'AWARENESS_TOOLS_EOF'
[
  {
    "type": "function",
    "function": {
      "name": "project_detect",
      "description": "Auto-detect the project type, language, framework, build system, and key configuration from the current working directory. Call this at the start of any session to understand what you're working with. Returns structured information about the project.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Directory to analyze (defaults to working directory)"
          }
        },
        "required": []
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "memory",
      "description": "Read or write persistent project memory. Memory persists across sessions in .lana/memory.json. Use 'read' to load all memories at session start. Use 'write' to save important facts about the project (conventions, commands, patterns, warnings). Use 'delete' to remove outdated memories.",
      "parameters": {
        "type": "object",
        "properties": {
          "action": {
            "type": "string",
            "enum": ["read", "write", "delete"],
            "description": "Action to perform"
          },
          "key": {
            "type": "string",
            "description": "Memory key (e.g., 'build_command', 'code_style', 'db_migration'). Required for write and delete."
          },
          "value": {
            "type": "string",
            "description": "Value to store. Required for write."
          }
        },
        "required": ["action"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "git_smart",
      "description": "Get structured git information about the repository. Returns parsed, concise information about branch status, uncommitted changes, recent history, and conflicts. Much more context-efficient than running raw git commands.",
      "parameters": {
        "type": "object",
        "properties": {
          "action": {
            "type": "string",
            "enum": ["status", "log", "diff", "conflicts", "stash"],
            "description": "What git information to retrieve"
          },
          "args": {
            "type": "string",
            "description": "Optional arguments (e.g., file path for diff, number for log count)"
          }
        },
        "required": ["action"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "task_plan",
      "description": "Create and manage multi-step task plans. Plans are saved to .lana/current_plan.json and persist across context resets. Use this for complex tasks that require multiple steps. The plan keeps you on track even if context gets long.",
      "parameters": {
        "type": "object",
        "properties": {
          "action": {
            "type": "string",
            "enum": ["create", "status", "complete", "fail", "clear"],
            "description": "Action: create a new plan, check status, mark step complete, mark step failed, or clear plan"
          },
          "goal": {
            "type": "string",
            "description": "The overall goal (required for 'create')"
          },
          "steps": {
            "type": "string",
            "description": "Newline-separated list of steps (required for 'create')"
          },
          "step": {
            "type": "integer",
            "description": "Step number to mark complete or failed (1-indexed)"
          },
          "note": {
            "type": "string",
            "description": "Optional note to attach to a completed/failed step"
          }
        },
        "required": ["action"]
      }
    }
  }
]
AWARENESS_TOOLS_EOF
}

# ── Tool 1: project_detect ────────────────────────────

tool_project_detect() {
    local args="$1"
    local path
    path=$(echo "$args" | jq -r '.path // empty')

    [[ -z "$path" ]] && path="$WORK_DIR"
    [[ "$path" != /* ]] && path="$WORK_DIR/$path"

    if [[ ! -d "$path" ]]; then
        echo "Error: directory not found: $path"
        return 1
    fi

    ui_tool_call "project_detect" "$path"

    local project_name
    project_name=$(basename "$path")

    local languages=""
    local frameworks=""
    local build_systems=""
    local package_managers=""
    local test_frameworks=""
    local platform=""
    local bundle_id=""
    local entry_point=""
    local module_name=""

    # ── Swift Package ──
    if [[ -f "$path/Package.swift" ]]; then
        languages="${languages}Swift, "
        build_systems="${build_systems}Swift Package Manager, "
        # Check for Xcode project alongside
        local xcproj
        xcproj=$(find "$path" -maxdepth 1 -name "*.xcodeproj" -type d 2>/dev/null | head -1)
        if [[ -n "$xcproj" ]]; then
            build_systems="${build_systems}Xcode, "
        fi
        # Try to detect executable vs library
        if grep -q '\.executableTarget' "$path/Package.swift" 2>/dev/null; then
            frameworks="${frameworks}CLI executable, "
        fi
        if grep -q '\.libraryTarget\|\.library' "$path/Package.swift" 2>/dev/null; then
            frameworks="${frameworks}Library, "
        fi
    fi

    # ── Xcode project ──
    local xcproj_file
    xcproj_file=$(find "$path" -maxdepth 1 -name "*.xcodeproj" -type d 2>/dev/null | head -1)
    if [[ -n "$xcproj_file" ]]; then
        local pbxproj="$xcproj_file/project.pbxproj"
        if [[ -f "$pbxproj" ]]; then
            languages="${languages}Swift, "
            build_systems="${build_systems}Xcode, "
            # Detect platform from SDKROOT
            if grep -q 'iphoneos' "$pbxproj" 2>/dev/null; then
                platform="iOS"
                # Try to extract deployment target
                local ios_target
                ios_target=$(grep 'IPHONEOS_DEPLOYMENT_TARGET' "$pbxproj" 2>/dev/null | head -1 | sed 's/.*= *\([0-9.]*\).*/\1/')
                [[ -n "$ios_target" ]] && platform="iOS $ios_target"
            elif grep -q 'macosx' "$pbxproj" 2>/dev/null; then
                platform="macOS"
                local mac_target
                mac_target=$(grep 'MACOSX_DEPLOYMENT_TARGET' "$pbxproj" 2>/dev/null | head -1 | sed 's/.*= *\([0-9.]*\).*/\1/')
                [[ -n "$mac_target" ]] && platform="macOS $mac_target"
            fi
            # Try to extract bundle ID
            bundle_id=$(grep 'PRODUCT_BUNDLE_IDENTIFIER' "$pbxproj" 2>/dev/null | head -1 | sed 's/.*= *"\{0,1\}\([^";]*\).*/\1/')
            # Detect SwiftUI vs UIKit
            if grep -rq 'import SwiftUI' "$path" --include="*.swift" 2>/dev/null; then
                frameworks="${frameworks}SwiftUI, "
            elif grep -rq 'import UIKit' "$path" --include="*.swift" 2>/dev/null; then
                frameworks="${frameworks}UIKit, "
            fi
            # Detect test target
            if grep -q 'XCTest' "$pbxproj" 2>/dev/null; then
                test_frameworks="${test_frameworks}XCTest, "
            fi
            # Detect entry point
            local app_file
            app_file=$(find "$path" -name "*App.swift" -not -path "*Test*" 2>/dev/null | head -1)
            if [[ -n "$app_file" ]]; then
                entry_point="${app_file#$path/}"
            fi
        fi
    fi

    # ── Cargo.toml (Rust) ──
    if [[ -f "$path/Cargo.toml" ]]; then
        languages="${languages}Rust, "
        build_systems="${build_systems}Cargo, "
        package_managers="${package_managers}Cargo, "
        if grep -q '\[\[bin\]\]' "$path/Cargo.toml" 2>/dev/null || [[ -f "$path/src/main.rs" ]]; then
            frameworks="${frameworks}Binary, "
            entry_point="src/main.rs"
        fi
        if grep -q '\[lib\]' "$path/Cargo.toml" 2>/dev/null || [[ -f "$path/src/lib.rs" ]]; then
            frameworks="${frameworks}Library, "
            [[ -z "$entry_point" ]] && entry_point="src/lib.rs"
        fi
        if [[ -d "$path/tests" ]]; then
            test_frameworks="${test_frameworks}Rust tests, "
        fi
    fi

    # ── go.mod (Go) ──
    if [[ -f "$path/go.mod" ]]; then
        languages="${languages}Go, "
        build_systems="${build_systems}Go modules, "
        module_name=$(grep '^module ' "$path/go.mod" 2>/dev/null | head -1 | awk '{print $2}')
        if [[ -f "$path/main.go" ]]; then
            entry_point="main.go"
        fi
        if find "$path" -name "*_test.go" -maxdepth 3 2>/dev/null | grep -q .; then
            test_frameworks="${test_frameworks}Go testing, "
        fi
    fi

    # ── package.json (Node.js) ──
    if [[ -f "$path/package.json" ]]; then
        languages="${languages}JavaScript/TypeScript, "
        package_managers="${package_managers}npm, "
        # Check for yarn/pnpm
        [[ -f "$path/yarn.lock" ]] && package_managers="${package_managers}Yarn, "
        [[ -f "$path/pnpm-lock.yaml" ]] && package_managers="${package_managers}pnpm, "
        # Detect framework from dependencies
        local pkg_deps
        pkg_deps=$(jq -r '(.dependencies // {}) + (.devDependencies // {}) | keys[]' "$path/package.json" 2>/dev/null) || true
        if echo "$pkg_deps" | grep -qw 'next'; then
            frameworks="${frameworks}Next.js, "
        elif echo "$pkg_deps" | grep -qw 'react'; then
            frameworks="${frameworks}React, "
        fi
        if echo "$pkg_deps" | grep -qw 'vue'; then
            frameworks="${frameworks}Vue, "
        fi
        if echo "$pkg_deps" | grep -qw 'svelte'; then
            frameworks="${frameworks}Svelte, "
        fi
        if echo "$pkg_deps" | grep -qw '@angular/core'; then
            frameworks="${frameworks}Angular, "
        fi
        if echo "$pkg_deps" | grep -qw 'express'; then
            frameworks="${frameworks}Express, "
        fi
        if echo "$pkg_deps" | grep -qw 'fastify'; then
            frameworks="${frameworks}Fastify, "
        fi
        # Detect TypeScript
        if echo "$pkg_deps" | grep -qw 'typescript'; then
            languages="${languages}TypeScript, "
        fi
        # Detect test framework
        if echo "$pkg_deps" | grep -qw 'jest'; then
            test_frameworks="${test_frameworks}Jest, "
        fi
        if echo "$pkg_deps" | grep -qw 'vitest'; then
            test_frameworks="${test_frameworks}Vitest, "
        fi
        if echo "$pkg_deps" | grep -qw 'mocha'; then
            test_frameworks="${test_frameworks}Mocha, "
        fi
        # Build system
        if echo "$pkg_deps" | grep -qw 'vite'; then
            build_systems="${build_systems}Vite, "
        elif echo "$pkg_deps" | grep -qw 'webpack'; then
            build_systems="${build_systems}Webpack, "
        fi
        # Entry point from package.json
        local pkg_main
        pkg_main=$(jq -r '.main // empty' "$path/package.json" 2>/dev/null)
        [[ -n "$pkg_main" ]] && entry_point="$pkg_main"
    fi

    # ── pyproject.toml (Python) ──
    if [[ -f "$path/pyproject.toml" ]]; then
        languages="${languages}Python, "
        build_systems="${build_systems}pyproject.toml, "
        # Detect framework from deps (read the raw file since toml parsing is limited)
        local pyproj_content
        pyproj_content=$(cat "$path/pyproject.toml" 2>/dev/null) || true
        if echo "$pyproj_content" | grep -qi 'django'; then
            frameworks="${frameworks}Django, "
        fi
        if echo "$pyproj_content" | grep -qi 'flask'; then
            frameworks="${frameworks}Flask, "
        fi
        if echo "$pyproj_content" | grep -qi 'fastapi'; then
            frameworks="${frameworks}FastAPI, "
        fi
        if echo "$pyproj_content" | grep -qi 'torch\|pytorch'; then
            frameworks="${frameworks}PyTorch, "
        fi
        # Detect test framework
        if echo "$pyproj_content" | grep -qi 'pytest'; then
            test_frameworks="${test_frameworks}pytest, "
        fi
        # Package manager
        if echo "$pyproj_content" | grep -qi 'poetry'; then
            package_managers="${package_managers}Poetry, "
        fi
        if [[ -f "$path/uv.lock" ]]; then
            package_managers="${package_managers}uv, "
        fi
    fi

    # ── requirements.txt (Python) ──
    if [[ -f "$path/requirements.txt" ]]; then
        languages="${languages}Python, "
        package_managers="${package_managers}pip, "
        local req_content
        req_content=$(cat "$path/requirements.txt" 2>/dev/null) || true
        if echo "$req_content" | grep -qi 'django'; then
            frameworks="${frameworks}Django, "
        fi
        if echo "$req_content" | grep -qi 'flask'; then
            frameworks="${frameworks}Flask, "
        fi
        if echo "$req_content" | grep -qi 'fastapi'; then
            frameworks="${frameworks}FastAPI, "
        fi
        if echo "$req_content" | grep -qi 'torch\|pytorch'; then
            frameworks="${frameworks}PyTorch, "
        fi
        if echo "$req_content" | grep -qi 'pytest'; then
            test_frameworks="${test_frameworks}pytest, "
        fi
    fi

    # ── Gemfile (Ruby) ──
    if [[ -f "$path/Gemfile" ]]; then
        languages="${languages}Ruby, "
        package_managers="${package_managers}Bundler, "
        if grep -q 'rails' "$path/Gemfile" 2>/dev/null; then
            frameworks="${frameworks}Rails, "
            build_systems="${build_systems}Rails, "
        fi
        if grep -q 'rspec' "$path/Gemfile" 2>/dev/null; then
            test_frameworks="${test_frameworks}RSpec, "
        fi
    fi

    # ── pom.xml (Java/Maven) ──
    if [[ -f "$path/pom.xml" ]]; then
        languages="${languages}Java, "
        build_systems="${build_systems}Maven, "
        package_managers="${package_managers}Maven, "
    fi

    # ── build.gradle / build.gradle.kts (Gradle) ──
    if [[ -f "$path/build.gradle" || -f "$path/build.gradle.kts" ]]; then
        build_systems="${build_systems}Gradle, "
        package_managers="${package_managers}Gradle, "
        local gradle_file="$path/build.gradle"
        [[ -f "$path/build.gradle.kts" ]] && gradle_file="$path/build.gradle.kts"
        if grep -q 'com.android' "$gradle_file" 2>/dev/null; then
            languages="${languages}Kotlin, "
            frameworks="${frameworks}Android, "
            platform="Android"
        elif grep -q 'kotlin' "$gradle_file" 2>/dev/null; then
            languages="${languages}Kotlin, "
        else
            languages="${languages}Java, "
        fi
    fi

    # ── composer.json (PHP) ──
    if [[ -f "$path/composer.json" ]]; then
        languages="${languages}PHP, "
        package_managers="${package_managers}Composer, "
        if jq -r '(.require // {}) | keys[]' "$path/composer.json" 2>/dev/null | grep -q 'laravel'; then
            frameworks="${frameworks}Laravel, "
        fi
    fi

    # ── CMakeLists.txt ──
    if [[ -f "$path/CMakeLists.txt" ]]; then
        languages="${languages}C/C++, "
        build_systems="${build_systems}CMake, "
    fi

    # ── Makefile ──
    if [[ -f "$path/Makefile" ]]; then
        build_systems="${build_systems}Make, "
    fi

    # ── Docker ──
    if [[ -f "$path/docker-compose.yml" || -f "$path/docker-compose.yaml" ]]; then
        build_systems="${build_systems}Docker Compose, "
    fi
    if [[ -f "$path/Dockerfile" ]]; then
        build_systems="${build_systems}Docker, "
    fi

    # ── Terraform ──
    if find "$path" -maxdepth 2 -name "*.tf" 2>/dev/null | grep -q .; then
        languages="${languages}Terraform/HCL, "
        build_systems="${build_systems}Terraform, "
    fi

    # ── Git info ──
    local git_info="Not a git repository"
    if [[ -d "$path/.git" ]] || (cd "$path" && git rev-parse --git-dir >/dev/null 2>&1); then
        local branch
        branch=$(cd "$path" && git rev-parse --abbrev-ref HEAD 2>/dev/null) || true
        local dirty=""
        if (cd "$path" && git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null); then
            dirty="clean"
        else
            dirty="dirty"
        fi
        git_info="$branch branch, $dirty"
    fi

    # ── README ──
    local readme_file=""
    for candidate in README.md README.rst README.txt README; do
        if [[ -f "$path/$candidate" ]]; then
            readme_file="$candidate"
            break
        fi
    done

    # ── Test directory ──
    local test_dir=""
    for candidate in tests test spec __tests__ Tests; do
        if [[ -d "$path/$candidate" ]]; then
            test_dir="$candidate/"
            break
        fi
    done
    # Also check for Xcode test targets
    if [[ -z "$test_dir" ]]; then
        local xc_test
        xc_test=$(find "$path" -maxdepth 1 -name "*Tests" -type d 2>/dev/null | head -1)
        if [[ -n "$xc_test" ]]; then
            test_dir="$(basename "$xc_test")/"
        fi
    fi

    # ── Clean up trailing commas and deduplicate ──
    _dedup_list() {
        local input="$1"
        # Remove trailing ", " and deduplicate
        input="${input%, }"
        if [[ -z "$input" ]]; then
            echo ""
            return
        fi
        # Deduplicate comma-separated values
        local result=""
        local seen=""
        local IFS=","
        local item
        for item in $input; do
            item=$(echo "$item" | sed 's/^ *//;s/ *$//')
            if [[ -n "$item" && " $seen " != *" $item "* ]]; then
                [[ -n "$result" ]] && result="$result, "
                result="$result$item"
                seen="$seen $item"
            fi
        done
        echo "$result"
    }

    languages=$(_dedup_list "$languages")
    frameworks=$(_dedup_list "$frameworks")
    build_systems=$(_dedup_list "$build_systems")
    package_managers=$(_dedup_list "$package_managers")
    test_frameworks=$(_dedup_list "$test_frameworks")

    # ── Build output ──
    local output=""
    output="Project: $project_name"
    [[ -n "$languages" ]] && output="$output
Language: $languages"
    [[ -n "$frameworks" ]] && output="$output
Framework: $frameworks"
    [[ -n "$build_systems" ]] && output="$output
Build System: $build_systems"
    [[ -n "$platform" ]] && output="$output
Platform: $platform"
    [[ -n "$bundle_id" ]] && output="$output
Bundle ID: $bundle_id"
    [[ -n "$module_name" ]] && output="$output
Module: $module_name"
    [[ -n "$package_managers" ]] && output="$output
Package Manager: $package_managers"
    [[ -n "$test_frameworks" && -n "$test_dir" ]] && output="$output
Tests: $test_frameworks ($test_dir)"
    [[ -n "$test_frameworks" && -z "$test_dir" ]] && output="$output
Tests: $test_frameworks"
    [[ -z "$test_frameworks" && -n "$test_dir" ]] && output="$output
Tests: $test_dir"
    output="$output
Git: $git_info"
    [[ -n "$readme_file" ]] && output="$output
README: $readme_file"
    [[ -n "$entry_point" ]] && output="$output
Entry Point: $entry_point"

    # If nothing was detected
    if [[ -z "$languages" && -z "$build_systems" && -z "$frameworks" ]]; then
        output="$output
Note: No recognized project configuration files found. This may be an empty or non-standard project."
    fi

    echo "$output"
}

# ── Tool 2: memory ────────────────────────────────────

tool_memory() {
    local args="$1"
    local action key value
    action=$(echo "$args" | jq -r '.action // empty')
    key=$(echo "$args" | jq -r '.key // empty')
    value=$(echo "$args" | jq -r '.value // empty')

    if [[ -z "$action" ]]; then
        echo "Error: action is required (read, write, delete)"
        return 1
    fi

    local memory_file="$WORK_DIR/.lana/memory.json"

    case "$action" in
        read)
            ui_tool_call "memory" "read"

            if [[ ! -f "$memory_file" ]]; then
                echo "No memories stored yet. Use memory with action 'write' to save project facts."
                return 0
            fi

            local count
            count=$(jq 'length' "$memory_file" 2>/dev/null) || count=0

            if [[ "$count" -eq 0 ]]; then
                echo "No memories stored yet."
                return 0
            fi

            local output="Project Memories ($count entries):"
            # Iterate over keys using jq (bash 3.2 compatible — no readarray)
            local keys_list
            keys_list=$(jq -r 'keys[]' "$memory_file" 2>/dev/null) || true

            while IFS= read -r k; do
                [[ -z "$k" ]] && continue
                local v
                v=$(jq -r --arg k "$k" '.[$k]' "$memory_file" 2>/dev/null) || true
                output="$output
  $k: \"$v\""
            done <<< "$keys_list"

            echo "$output"
            ;;

        write)
            if [[ -z "$key" ]]; then
                echo "Error: key is required for write"
                return 1
            fi
            if [[ -z "$value" ]]; then
                echo "Error: value is required for write"
                return 1
            fi

            ui_tool_call "memory" "write $key"

            if ! ui_confirm "Save memory '$key'?" "n" "mutation"; then
                echo "Memory write cancelled."
                return 1
            fi

            # Create .lana directory if needed
            mkdir -p "$WORK_DIR/.lana"

            # Create file if it doesn't exist
            if [[ ! -f "$memory_file" ]]; then
                echo '{}' > "$memory_file"
            fi

            # Add/update key-value using jq
            local tmp="$SESSION_DIR/memory_tmp_$$"
            jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$memory_file" > "$tmp" 2>/dev/null
            if [[ -s "$tmp" ]]; then
                mv "$tmp" "$memory_file"
                echo "Memory saved: $key = \"$value\""
            else
                rm -f "$tmp"
                echo "Error: failed to write memory"
                return 1
            fi
            ;;

        delete)
            if [[ -z "$key" ]]; then
                echo "Error: key is required for delete"
                return 1
            fi

            if [[ ! -f "$memory_file" ]]; then
                echo "No memories stored yet."
                return 1
            fi

            # Check if key exists
            local exists
            exists=$(jq --arg k "$key" 'has($k)' "$memory_file" 2>/dev/null) || exists="false"
            if [[ "$exists" != "true" ]]; then
                echo "Error: memory key '$key' not found"
                return 1
            fi

            ui_tool_call "memory" "delete $key"

            if ! ui_confirm "Delete memory '$key'?" "n" "mutation"; then
                echo "Memory delete cancelled."
                return 1
            fi

            local tmp="$SESSION_DIR/memory_tmp_$$"
            jq --arg k "$key" 'del(.[$k])' "$memory_file" > "$tmp" 2>/dev/null
            if [[ -s "$tmp" ]]; then
                mv "$tmp" "$memory_file"
                echo "Memory deleted: $key"
            else
                rm -f "$tmp"
                echo "Error: failed to delete memory"
                return 1
            fi
            ;;

        *)
            echo "Error: unknown action '$action' (expected: read, write, delete)"
            return 1
            ;;
    esac
}

# ── Tool 3: git_smart ─────────────────────────────────

tool_git_smart() {
    local args="$1"
    local action ga
    action=$(echo "$args" | jq -r '.action // empty')
    ga=$(echo "$args" | jq -r '.args // empty')

    if [[ -z "$action" ]]; then
        echo "Error: action is required (status, log, diff, conflicts, stash)"
        return 1
    fi

    # Check if we're in a git repo
    if ! (cd "$WORK_DIR" && git rev-parse --git-dir >/dev/null 2>&1); then
        echo "Error: not a git repository (working directory: $WORK_DIR)"
        return 1
    fi

    ui_tool_call "git_smart" "$action${ga:+ $ga}"

    case "$action" in
        status)
            # Parse git status --porcelain -b for compact summary
            local status_output
            status_output=$(cd "$WORK_DIR" && git status --porcelain -b 2>/dev/null) || true

            # Extract branch info from the first line (## branch...tracking)
            local branch_line
            branch_line=$(echo "$status_output" | head -1)
            local branch_name=""
            local tracking_info=""

            if [[ "$branch_line" == "## "* ]]; then
                # Remove "## " prefix
                branch_line="${branch_line#\#\# }"
                # Split on "..." to get branch and tracking
                if [[ "$branch_line" == *"..."* ]]; then
                    branch_name="${branch_line%%...*}"
                    local remote_part="${branch_line#*...}"
                    # Extract ahead/behind from tracking info
                    local ahead=0 behind=0
                    if [[ "$remote_part" == *"ahead "* ]]; then
                        ahead=$(echo "$remote_part" | sed 's/.*ahead \([0-9]*\).*/\1/')
                    fi
                    if [[ "$remote_part" == *"behind "* ]]; then
                        behind=$(echo "$remote_part" | sed 's/.*behind \([0-9]*\).*/\1/')
                    fi
                    local remote_name="${remote_part%% *}"
                    remote_name="${remote_name%%\[*}"
                    if (( ahead > 0 || behind > 0 )); then
                        tracking_info=" (ahead $ahead, behind $behind of $remote_name)"
                    fi
                else
                    branch_name="$branch_line"
                fi
            fi

            # Count file statuses (skip the branch line)
            local staged_modified=0 staged_new=0 staged_deleted=0
            local unstaged_modified=0 unstaged_deleted=0
            local untracked=0

            local file_lines
            file_lines=$(echo "$status_output" | tail -n +2)

            while IFS= read -r fline; do
                [[ -z "$fline" ]] && continue
                local idx_status="${fline:0:1}"
                local wt_status="${fline:1:1}"

                # Staged (index) changes
                case "$idx_status" in
                    M) staged_modified=$((staged_modified + 1)) ;;
                    A) staged_new=$((staged_new + 1)) ;;
                    D) staged_deleted=$((staged_deleted + 1)) ;;
                    R) staged_modified=$((staged_modified + 1)) ;;  # rename counts as modified
                esac

                # Unstaged (working tree) changes
                case "$wt_status" in
                    M) unstaged_modified=$((unstaged_modified + 1)) ;;
                    D) unstaged_deleted=$((unstaged_deleted + 1)) ;;
                esac

                # Untracked
                if [[ "$idx_status" == "?" ]]; then
                    untracked=$((untracked + 1))
                fi
            done <<< "$file_lines"

            local staged_total=$((staged_modified + staged_new + staged_deleted))
            local unstaged_total=$((unstaged_modified + unstaged_deleted))

            # Build output
            local output="Branch: ${branch_name}${tracking_info}"

            if (( staged_total > 0 )); then
                local staged_detail=""
                (( staged_modified > 0 )) && staged_detail="${staged_modified} modified"
                (( staged_new > 0 )) && { [[ -n "$staged_detail" ]] && staged_detail="$staged_detail, "; staged_detail="${staged_detail}${staged_new} new"; }
                (( staged_deleted > 0 )) && { [[ -n "$staged_detail" ]] && staged_detail="$staged_detail, "; staged_detail="${staged_detail}${staged_deleted} deleted"; }
                output="$output
Staged: $staged_total files ($staged_detail)"
            else
                output="$output
Staged: none"
            fi

            if (( unstaged_total > 0 )); then
                local unstaged_detail=""
                (( unstaged_modified > 0 )) && unstaged_detail="${unstaged_modified} modified"
                (( unstaged_deleted > 0 )) && { [[ -n "$unstaged_detail" ]] && unstaged_detail="$unstaged_detail, "; unstaged_detail="${unstaged_detail}${unstaged_deleted} deleted"; }
                output="$output
Unstaged: $unstaged_total files ($unstaged_detail)"
            else
                output="$output
Unstaged: none"
            fi

            if (( untracked > 0 )); then
                output="$output
Untracked: $untracked files"
            else
                output="$output
Untracked: none"
            fi

            echo "$output"
            ;;

        log)
            local count=10
            [[ -n "$ga" && "$ga" =~ ^[0-9]+$ ]] && count="$ga"

            local log_output
            log_output=$(cd "$WORK_DIR" && git log --oneline --format="%h  %cr  %s (%an)" -n "$count" 2>/dev/null) || true

            if [[ -z "$log_output" ]]; then
                echo "No commits yet."
            else
                echo "Recent commits (last $count):"
                while IFS= read -r logline; do
                    echo "  $logline"
                done <<< "$log_output"
            fi
            ;;

        diff)
            local diff_output=""

            if [[ -n "$ga" ]]; then
                # Diff for a specific file
                local fpath="$ga"
                [[ "$fpath" != /* ]] && fpath="$WORK_DIR/$fpath"

                local file_diff
                file_diff=$(cd "$WORK_DIR" && git diff -- "$fpath" 2>/dev/null) || true
                local cached_diff
                cached_diff=$(cd "$WORK_DIR" && git diff --cached -- "$fpath" 2>/dev/null) || true

                if [[ -z "$file_diff" && -z "$cached_diff" ]]; then
                    echo "No changes for: $ga"
                    return 0
                fi

                diff_output=""
                [[ -n "$cached_diff" ]] && diff_output="Staged changes:
$cached_diff"
                [[ -n "$file_diff" ]] && diff_output="$diff_output${diff_output:+

}Unstaged changes:
$file_diff"

                echo "$diff_output"
            else
                # Summary of all changes
                local staged_stat unstaged_stat
                staged_stat=$(cd "$WORK_DIR" && git diff --cached --stat 2>/dev/null) || true
                unstaged_stat=$(cd "$WORK_DIR" && git diff --stat 2>/dev/null) || true

                if [[ -z "$staged_stat" && -z "$unstaged_stat" ]]; then
                    echo "No changes."
                    return 0
                fi

                # Parse diff --numstat for structured output
                local numstat_staged numstat_unstaged
                numstat_staged=$(cd "$WORK_DIR" && git diff --cached --numstat 2>/dev/null) || true
                numstat_unstaged=$(cd "$WORK_DIR" && git diff --numstat 2>/dev/null) || true

                local total_add=0 total_del=0
                local file_count=0
                local file_lines=""

                # Process staged files
                while IFS= read -r nline; do
                    [[ -z "$nline" ]] && continue
                    local nadd ndel nfile
                    nadd=$(echo "$nline" | awk '{print $1}')
                    ndel=$(echo "$nline" | awk '{print $2}')
                    nfile=$(echo "$nline" | awk '{print $3}')
                    [[ "$nadd" == "-" ]] && nadd=0
                    [[ "$ndel" == "-" ]] && ndel=0
                    file_count=$((file_count + 1))
                    total_add=$((total_add + nadd))
                    total_del=$((total_del + ndel))
                    file_lines="$file_lines
  M $nfile     +$nadd -$ndel  [staged]"
                done <<< "$numstat_staged"

                # Process unstaged files
                while IFS= read -r nline; do
                    [[ -z "$nline" ]] && continue
                    local nadd ndel nfile
                    nadd=$(echo "$nline" | awk '{print $1}')
                    ndel=$(echo "$nline" | awk '{print $2}')
                    nfile=$(echo "$nline" | awk '{print $3}')
                    [[ "$nadd" == "-" ]] && nadd=0
                    [[ "$ndel" == "-" ]] && ndel=0
                    file_count=$((file_count + 1))
                    total_add=$((total_add + nadd))
                    total_del=$((total_del + ndel))
                    file_lines="$file_lines
  M $nfile     +$nadd -$ndel"
                done <<< "$numstat_unstaged"

                if (( file_count > 0 )); then
                    echo "Changed files ($file_count):$file_lines
Total: +$total_add -$total_del"
                else
                    echo "No changes."
                fi
            fi
            ;;

        conflicts)
            local conflict_files
            conflict_files=$(cd "$WORK_DIR" && git diff --name-only --diff-filter=U 2>/dev/null) || true

            if [[ -z "$conflict_files" ]]; then
                echo "No merge conflicts."
                return 0
            fi

            local conflict_count=0
            local conflict_output=""

            while IFS= read -r cfile; do
                [[ -z "$cfile" ]] && continue
                conflict_count=$((conflict_count + 1))
                local regions=0
                if [[ -f "$WORK_DIR/$cfile" ]]; then
                    regions=$(grep -c '<<<<<<<' "$WORK_DIR/$cfile" 2>/dev/null) || regions=0
                fi
                conflict_output="$conflict_output
  $cfile: $regions conflict region(s)"
            done <<< "$conflict_files"

            echo "Conflicts ($conflict_count files):$conflict_output"
            ;;

        stash)
            local stash_list
            stash_list=$(cd "$WORK_DIR" && git stash list 2>/dev/null) || true

            if [[ -z "$stash_list" ]]; then
                echo "No stashes."
                return 0
            fi

            local stash_count
            stash_count=$(echo "$stash_list" | wc -l | tr -d ' ')

            local stash_output="Stashes ($stash_count):"
            while IFS= read -r sline; do
                [[ -z "$sline" ]] && continue
                stash_output="$stash_output
  $sline"
            done <<< "$stash_list"

            echo "$stash_output"
            ;;

        *)
            echo "Error: unknown action '$action' (expected: status, log, diff, conflicts, stash)"
            return 1
            ;;
    esac
}

# ── Tool 4: task_plan ─────────────────────────────────

tool_task_plan() {
    local args="$1"
    local action goal steps step note
    action=$(echo "$args" | jq -r '.action // empty')
    goal=$(echo "$args" | jq -r '.goal // empty')
    steps=$(echo "$args" | jq -r '.steps // empty')
    step=$(echo "$args" | jq -r '.step // empty')
    note=$(echo "$args" | jq -r '.note // empty')

    if [[ -z "$action" ]]; then
        echo "Error: action is required (create, status, complete, fail, clear)"
        return 1
    fi

    local plan_file="$WORK_DIR/.lana/current_plan.json"

    case "$action" in
        create)
            if [[ -z "$goal" ]]; then
                echo "Error: goal is required for create"
                return 1
            fi
            if [[ -z "$steps" ]]; then
                echo "Error: steps is required for create (newline-separated list)"
                return 1
            fi

            # Check if plan already exists
            if [[ -f "$plan_file" ]]; then
                echo "Error: a plan already exists. Use action 'clear' first, then create a new plan."
                echo ""
                # Show current plan status
                _task_plan_show_status "$plan_file"
                return 1
            fi

            ui_tool_call "task_plan" "create: $goal"

            if ! ui_confirm "Create this plan?" "n" "mutation"; then
                echo "Plan creation cancelled."
                return 1
            fi

            # Create .lana directory if needed
            mkdir -p "$WORK_DIR/.lana"

            # Build steps array from newline-separated input
            local created_date
            created_date=$(date +%Y-%m-%dT%H:%M:%S)

            # Build the steps JSON array (bash 3.2 compatible — no readarray)
            local steps_json="["
            local first_step=true
            local is_first_step=true

            while IFS= read -r sline; do
                # Trim whitespace
                sline=$(echo "$sline" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                # Skip empty lines and lines that are just numbers/bullets
                [[ -z "$sline" ]] && continue
                # Strip leading "1. ", "- ", "* " etc.
                sline=$(echo "$sline" | sed 's/^[0-9]*\. *//;s/^[-*] *//')
                [[ -z "$sline" ]] && continue

                local step_status="pending"
                if $is_first_step; then
                    step_status="in_progress"
                    is_first_step=false
                fi

                if ! $first_step; then
                    steps_json="$steps_json,"
                fi
                first_step=false

                # Escape the step text for JSON
                local escaped_sline
                escaped_sline=$(printf '%s' "$sline" | jq -Rs '.')
                steps_json="$steps_json{\"text\":$escaped_sline,\"status\":\"$step_status\"}"
            done <<< "$steps"

            steps_json="$steps_json]"

            # Build the plan JSON
            local plan_json
            plan_json=$(jq -n \
                --arg goal "$goal" \
                --arg created "$created_date" \
                --argjson steps "$steps_json" \
                '{"goal": $goal, "created": $created, "steps": $steps}')

            printf '%s' "$plan_json" > "$plan_file"

            echo "Plan created: $goal"
            echo ""
            _task_plan_show_status "$plan_file"
            ;;

        status)
            ui_tool_call "task_plan" "status"

            if [[ ! -f "$plan_file" ]]; then
                echo "No active plan. Use action 'create' to start one."
                return 0
            fi

            _task_plan_show_status "$plan_file"
            ;;

        complete)
            if [[ -z "$step" ]]; then
                echo "Error: step number is required for complete (1-indexed)"
                return 1
            fi

            if [[ ! -f "$plan_file" ]]; then
                echo "Error: no active plan"
                return 1
            fi

            ui_tool_call "task_plan" "complete step $step"

            local step_idx=$((step - 1))
            local total_steps
            total_steps=$(jq '.steps | length' "$plan_file" 2>/dev/null) || total_steps=0

            if (( step < 1 || step > total_steps )); then
                echo "Error: step $step is out of range (plan has $total_steps steps)"
                return 1
            fi

            # Mark step as complete
            local tmp="$SESSION_DIR/plan_tmp_$$"
            if [[ -n "$note" ]]; then
                jq --argjson idx "$step_idx" --arg note "$note" \
                    '.steps[$idx].status = "complete" | .steps[$idx].note = $note' \
                    "$plan_file" > "$tmp" 2>/dev/null
            else
                jq --argjson idx "$step_idx" \
                    '.steps[$idx].status = "complete"' \
                    "$plan_file" > "$tmp" 2>/dev/null
            fi

            # Auto-advance: set next pending step to in_progress
            if [[ -s "$tmp" ]]; then
                # Find next pending step
                local next_pending
                next_pending=$(jq '[.steps | to_entries[] | select(.value.status == "pending")] | .[0].key // -1' "$tmp" 2>/dev/null) || next_pending=-1
                if (( next_pending >= 0 )); then
                    jq --argjson idx "$next_pending" \
                        '.steps[$idx].status = "in_progress"' \
                        "$tmp" > "${tmp}.2" 2>/dev/null && mv "${tmp}.2" "$tmp"
                fi
                mv "$tmp" "$plan_file"
            else
                rm -f "$tmp"
                echo "Error: failed to update plan"
                return 1
            fi

            local step_text
            step_text=$(jq -r --argjson idx "$step_idx" '.steps[$idx].text' "$plan_file" 2>/dev/null)
            echo "Step $step completed: $step_text"
            [[ -n "$note" ]] && echo "  Note: $note"
            echo ""
            _task_plan_show_status "$plan_file"
            ;;

        fail)
            if [[ -z "$step" ]]; then
                echo "Error: step number is required for fail (1-indexed)"
                return 1
            fi

            if [[ ! -f "$plan_file" ]]; then
                echo "Error: no active plan"
                return 1
            fi

            ui_tool_call "task_plan" "fail step $step"

            local step_idx=$((step - 1))
            local total_steps
            total_steps=$(jq '.steps | length' "$plan_file" 2>/dev/null) || total_steps=0

            if (( step < 1 || step > total_steps )); then
                echo "Error: step $step is out of range (plan has $total_steps steps)"
                return 1
            fi

            local tmp="$SESSION_DIR/plan_tmp_$$"
            if [[ -n "$note" ]]; then
                jq --argjson idx "$step_idx" --arg note "$note" \
                    '.steps[$idx].status = "failed" | .steps[$idx].note = $note' \
                    "$plan_file" > "$tmp" 2>/dev/null
            else
                jq --argjson idx "$step_idx" \
                    '.steps[$idx].status = "failed"' \
                    "$plan_file" > "$tmp" 2>/dev/null
            fi

            if [[ -s "$tmp" ]]; then
                mv "$tmp" "$plan_file"
            else
                rm -f "$tmp"
                echo "Error: failed to update plan"
                return 1
            fi

            local step_text
            step_text=$(jq -r --argjson idx "$step_idx" '.steps[$idx].text' "$plan_file" 2>/dev/null)
            echo "Step $step failed: $step_text"
            [[ -n "$note" ]] && echo "  Reason: $note"
            echo ""
            _task_plan_show_status "$plan_file"
            ;;

        clear)
            if [[ ! -f "$plan_file" ]]; then
                echo "No active plan to clear."
                return 0
            fi

            ui_tool_call "task_plan" "clear"

            if ! ui_confirm "Clear the current plan?" "n" "mutation"; then
                echo "Plan clear cancelled."
                return 1
            fi

            rm -f "$plan_file"
            echo "Plan cleared."
            ;;

        *)
            echo "Error: unknown action '$action' (expected: create, status, complete, fail, clear)"
            return 1
            ;;
    esac
}

# Helper: display plan status
_task_plan_show_status() {
    local plan_file="$1"

    local goal
    goal=$(jq -r '.goal' "$plan_file" 2>/dev/null)

    local total_steps
    total_steps=$(jq '.steps | length' "$plan_file" 2>/dev/null) || total_steps=0

    local complete_count
    complete_count=$(jq '[.steps[] | select(.status == "complete")] | length' "$plan_file" 2>/dev/null) || complete_count=0

    local failed_count
    failed_count=$(jq '[.steps[] | select(.status == "failed")] | length' "$plan_file" 2>/dev/null) || failed_count=0

    local output="Plan: $goal"

    local i=0
    while (( i < total_steps )); do
        local text status snote
        text=$(jq -r --argjson i "$i" '.steps[$i].text' "$plan_file" 2>/dev/null)
        status=$(jq -r --argjson i "$i" '.steps[$i].status' "$plan_file" 2>/dev/null)
        snote=$(jq -r --argjson i "$i" '.steps[$i].note // empty' "$plan_file" 2>/dev/null)

        local step_num=$((i + 1))
        local marker=""
        case "$status" in
            complete)    marker="+" ;;
            in_progress) marker=">" ;;
            failed)      marker="X" ;;
            pending)     marker="o" ;;
        esac

        local line="  $marker $step_num. $text"
        [[ -n "$snote" ]] && line="$line ($snote)"

        output="$output
$line"

        i=$((i + 1))
    done

    output="$output
Progress: $complete_count/$total_steps complete"
    (( failed_count > 0 )) && output="$output, $failed_count failed"

    echo "$output"
}
