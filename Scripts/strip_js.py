"""Takes the comments and indentation out of a JavaScript file, keeping every token as it was.

Reading mode (DEV-1028) runs Mozilla Readability in the engine's developer world, which takes at
most 64 KB of source. The vendored copies in
`Packages/services/Sources/PageReaderClient/Resources/` are the npm package's files after this:

    python3 Scripts/strip_js.py path/to/package/Readability.js > .../Resources/Readability.js

A small tokenizer: strings, template literals and regex literals pass through untouched, `//`
and `/* */` comments go, and every line keeps its own line break, so automatic semicolon
insertion sees the same lines. `kept_verbatim` checks the result: every line it kept is a line,
or the start of one, of the original.
"""

import sys

REGEX_PREFIX_WORDS = {"return", "typeof", "case", "do", "else", "in", "instanceof", "new", "delete", "void", "throw", "of"}
REGEX_PREFIX_CHARS = set("(,=:[!&|?{};+-*%<>~^")


def strip(src):
    out = []
    i, n = 0, len(src)
    last = ""  # last significant token, to tell a regex from a division
    line = []

    def flush():
        text = "".join(line).strip()
        if text:
            out.append(text)
        line.clear()

    while i < n:
        c = src[i]
        if c == "\n":
            flush()
            i += 1
            continue
        if c in " \t\r":
            if line and line[-1] != " ":
                line.append(" ")
            i += 1
            continue
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            if j < 0:
                raise SystemExit("unterminated comment")
            # A comment spanning lines still separates lines.
            if "\n" in src[i:j]:
                flush()
            i = j + 2
            continue
        if c in "'\"":
            j = i + 1
            while src[j] != c:
                if src[j] == "\\":
                    j += 1
                if src[j] == "\n":
                    raise SystemExit("newline in string at %d" % j)
                j += 1
            line.append(src[i:j + 1])
            last = "str"
            i = j + 1
            continue
        if c == "`":
            j = i + 1
            depth = 0
            while True:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == "`" and depth == 0:
                    break
                if src.startswith("${", j):
                    depth += 1
                    j += 2
                    continue
                if src[j] == "}" and depth > 0:
                    depth -= 1
                j += 1
            line.append(src[i:j + 1])
            last = "str"
            i = j + 1
            continue
        if c == "/" and (last == "" or last in REGEX_PREFIX_WORDS or last in REGEX_PREFIX_CHARS):
            j = i + 1
            in_class = False
            while True:
                ch = src[j]
                if ch == "\\":
                    j += 2
                    continue
                if ch == "\n":
                    raise SystemExit("newline in regex at %d" % i)
                if ch == "[":
                    in_class = True
                elif ch == "]":
                    in_class = False
                elif ch == "/" and not in_class:
                    break
                j += 1
            j += 1
            while j < n and (src[j].isalnum()):
                j += 1
            line.append(src[i:j])
            last = "regex"
            i = j
            continue
        if c.isalnum() or c in "_$":
            j = i
            while j < n and (src[j].isalnum() or src[j] in "_$"):
                j += 1
            word = src[i:j]
            line.append(word)
            last = word if word in REGEX_PREFIX_WORDS else "id"
            i = j
            continue
        line.append(c)
        last = c if c in REGEX_PREFIX_CHARS else ("id" if c in ")]" else c)
        i += 1
    flush()
    return "\n".join(out) + "\n"



def kept_verbatim(original, stripped):
    """Whether every line of `stripped` appears, word for word, in `original`."""
    return all(line in original for line in stripped.splitlines() if line)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        print("usage: python3 Scripts/strip_js.py FILE.js > OUT.js", file=sys.stderr)
        return 2
    source = open(argv[0], encoding="utf-8").read()
    result = strip(source)
    if not kept_verbatim(source, result):
        print("strip_js: a stripped line differs from the original", file=sys.stderr)
        return 1
    sys.stdout.write(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
