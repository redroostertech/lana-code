#!/usr/bin/env python3
"""
LANA CODE — readline-based input reader.

Provides line editing (history, arrow keys, Ctrl shortcuts) with
@ detection for the file picker.

Protocol (single line on fd 3, then process exits):
    LINE:<text>          Normal input
    @                    Bare @ (triggers file picker)
    @MID:<text_before>   Input ending with " @" (triggers file picker mid-line)
    EOF                  Ctrl+D on empty line
    INT                  Ctrl+C

Usage:
    python3 input_reader.py <prompt> <history_file> [history_size]

The caller must open fd 3 for writing (e.g., 3>file) so the result
doesn't interfere with terminal I/O.
"""
import os
import readline
import sys


def main():
    if len(sys.argv) < 3:
        print("Usage: input_reader.py <prompt> <history_file> [history_size]",
              file=sys.stderr)
        sys.exit(1)

    prompt_text = sys.argv[1]
    history_file = sys.argv[2]
    max_size = int(sys.argv[3]) if len(sys.argv) > 3 else 500

    # Preserve fd 3 for result output
    result_fd = os.dup(3)

    # Redirect stdin/stdout to /dev/tty (in case bash has pipes/redirects)
    tty_r = os.open("/dev/tty", os.O_RDONLY)
    tty_w = os.open("/dev/tty", os.O_WRONLY)
    os.dup2(tty_r, 0)
    os.dup2(tty_w, 1)
    os.close(tty_r)
    os.close(tty_w)
    sys.stdin = open(0, "r", closefd=False)
    sys.stdout = open(1, "w", closefd=False)

    # Load history
    try:
        readline.read_history_file(history_file)
    except (FileNotFoundError, OSError):
        pass
    readline.set_history_length(max_size)

    # Disable default tab completion (interferes with shell)
    readline.parse_and_bind("tab: self-insert")

    def write_result(msg):
        os.write(result_fd, (msg + "\n").encode("utf-8"))

    try:
        text = input(prompt_text)

        # Save to history
        try:
            os.makedirs(os.path.dirname(history_file), exist_ok=True)
            readline.write_history_file(history_file)
        except OSError:
            pass

        # Detect @ patterns
        if text.strip() == "@":
            write_result("@")
        elif text.endswith(" @"):
            write_result("@MID:" + text[:-2])
        else:
            write_result("LINE:" + text)
    except EOFError:
        write_result("EOF")
    except KeyboardInterrupt:
        write_result("INT")
    finally:
        os.close(result_fd)


if __name__ == "__main__":
    main()
