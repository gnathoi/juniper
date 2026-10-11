#!/usr/bin/env python3
"""List the external commands a bash script can run (issue #50: initramfs completeness).

    script-commands.py FILE...

Prints one name per line, sorted:
  - a bare name (`cryptsetup`) for a literal command word;
  - an absolute path for a literal path, or for `"$var"` whose script sets var=${X:-/path};
  - `$var` for a variable command it can't resolve (callers keep an explicit allowlist).
Builtins, keywords and the script's own functions are left out. The shebang interpreter
counts (`#!/usr/bin/env bash` gives env and bash). Command positions include pipelines,
lists, subshells, $(...), <(...)/>(...), `if`/`while` conditions, case branches, array
values, and the commands that wrappers run: `with_key DISK CMD...` (cryptroot), timeout,
exec, command, env, nohup, setsid, nice, xargs, and trap's handler.

It fails (exit 2) on what it can't parse rather than guess: here-documents, backticks,
eval, and unbalanced quoting or brackets.
"""

import re
import subprocess
import sys

KEYWORDS_CONT = {"if", "then", "else", "elif", "do", "while", "until", "!", "{", "}", "time",
                 "fi", "done", "esac"}
# wrapper: number of plain arguments before the command it runs (after options).
WRAPPERS = {"with_key": 1, "exec": 0, "command": 0, "env": 0, "nohup": 0, "setsid": 0,
            "nice": 0, "xargs": 0, "timeout": 1}
OPT_ARGS = {"timeout": {"-s", "-k", "--signal", "--kill-after"}, "nice": {"-n"},
            "xargs": {"-I", "-n", "-P", "-d", "-a", "-L", "-s", "-E"}, "env": {"-u", "-C"}}
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=")
META = set(" \t\n;&|<>()")


def shell_names():
    out = subprocess.run(["bash", "-c", "compgen -b; compgen -k"], capture_output=True,
                         text=True, check=True).stdout
    return set(out.split())


class ParseError(Exception):
    pass


class Parser:
    def __init__(self, src, name):
        self.s = src
        self.n = len(src)
        self.i = 0
        self.name = name
        self.cmds = []  # raw command words: literal names, paths, or $var
        self.funcs = set()

    def err(self, msg):
        line = self.s.count("\n", 0, self.i) + 1
        raise ParseError(f"{self.name}:{line}: {msg}")

    def ch(self, k=0):
        j = self.i + k
        return self.s[j] if j < self.n else ""

    def startswith(self, t):
        return self.s.startswith(t, self.i)

    # --- whitespace and comments ---
    def skip_blank(self, newlines):
        while self.i < self.n:
            c = self.ch()
            if c in " \t":
                self.i += 1
            elif c == "\\" and self.ch(1) == "\n":
                self.i += 2
            elif c == "#":
                while self.i < self.n and self.ch() != "\n":
                    self.i += 1
            elif c == "\n" and newlines:
                self.i += 1
            else:
                break

    # --- words ---
    def skip_single(self):
        j = self.s.find("'", self.i + 1)
        if j < 0:
            self.err("unterminated single quote")
        self.i = j + 1

    def skip_ansi_c(self):  # $'...'
        self.i += 2
        while self.i < self.n and self.ch() != "'":
            self.i += 2 if self.ch() == "\\" else 1
        if self.i >= self.n:
            self.err("unterminated $'...'")
        self.i += 1

    def skip_arith(self, close):  # after (( or $((: up to the matching ))
        depth = 0
        while self.i < self.n:
            c = self.ch()
            if c == "$" and self.ch(1) == "(" and self.ch(2) != "(":
                self.i += 2
                self.parse_list(")")
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                if depth == 0 and self.startswith(close):
                    self.i += len(close)
                    return
                depth -= 1
            self.i += 1
        self.err("unterminated arithmetic")

    def dollar(self):
        """At '$': consume the expansion. Recurses into command substitutions."""
        n1 = self.ch(1)
        if n1 == "(" and self.ch(2) == "(":
            self.i += 3
            self.skip_arith("))")
        elif n1 == "(":
            self.i += 2
            self.parse_list(")")
        elif n1 == "{":
            self.i += 2
            depth = 1
            while self.i < self.n and depth:
                c = self.ch()
                if c == "\\":
                    self.i += 2
                    continue
                if c == "'":
                    self.skip_single()
                    continue
                if c == '"':
                    self.dquote()
                    continue
                if c == "$":
                    self.dollar()
                    continue
                if c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                self.i += 1
            if depth:
                self.err("unterminated ${")
        elif n1 == "'":
            self.skip_ansi_c()
        else:
            self.i += 1

    def dquote(self):
        self.i += 1
        while self.i < self.n:
            c = self.ch()
            if c == '"':
                self.i += 1
                return
            if c == "\\":
                self.i += 2
            elif c == "$":
                self.dollar()
            elif c == "`":
                self.err("backticks are not supported")
            else:
                self.i += 1
        self.err("unterminated double quote")

    def word(self):
        """Read one word; returns its source text. Recurses into substitutions."""
        start = self.i
        while self.i < self.n:
            c = self.ch()
            if c in META:
                # array value: name=( ... )
                if c == "(" and ASSIGN.match(self.s[start:self.i]) and self.s[self.i - 1] == "=":
                    self.i += 1
                    self.array_body()
                    continue
                # extglob @(...) etc. never occurs here; a '(' ends the word
                break
            if c == "\\":
                self.i += 2
            elif c == "'":
                self.skip_single()
            elif c == '"':
                self.dquote()
            elif c == "$":
                self.dollar()
            elif c == "`":
                self.err("backticks are not supported")
            else:
                self.i += 1
        return self.s[start:self.i]

    def array_body(self):
        while True:
            self.skip_blank(True)
            if self.ch() == ")":
                self.i += 1
                return
            if not self.ch():
                self.err("unterminated array")
            if not self.word():
                self.err("unexpected character in array")

    def dbracket(self):
        """After '[[': up to a ']]' that stands alone. Words aren't commands; $(...) is."""
        while self.i < self.n:
            c = self.ch()
            if self.startswith("]]") and self.s[self.i - 1] in " \t" and \
                    (self.ch(2) == "" or self.ch(2) in " \t\n;&|)"):
                self.i += 2
                return
            if c == "\\":
                self.i += 2
            elif c == "'":
                self.skip_single()
            elif c == '"':
                self.dquote()
            elif c == "$":
                self.dollar()
            elif c == "`":
                self.err("backticks are not supported")
            else:
                self.i += 1
        self.err("unterminated [[")

    # --- redirections ---
    def redirection(self):
        """At a redirection operator (optionally after N or {var}): consume it and its target."""
        m = re.compile(r"(\d+|\{[A-Za-z_][A-Za-z0-9_]*\})?(&>>|&>|<<<|<<|>>|<&|>&|<>|>\||<|>)").match(
            self.s, self.i)
        if not m:
            return False
        if m.group(2) == "<<":
            self.err("here-documents are not supported")
        self.i = m.end()
        self.skip_blank(False)
        if self.ch() in "<>" and self.ch(1) == "(":  # < <(...)
            self.i += 2
            self.parse_list(")")
        else:
            self.word()
        return True

    def at_redirection(self):
        return re.compile(r"(\d+|\{[A-Za-z_][A-Za-z0-9_]*\})?(<|>|&>)").match(self.s, self.i) and \
            not (self.ch() in "<>" and self.ch(1) == "(")

    # --- commands ---
    def record(self, w):
        if w:
            self.cmds.append(w)

    def parse_list(self, end):
        """Commands until `end` (')' for $(...)/<(...)/( ... ), '' for EOF, 'esac' for a case branch).
        For 'esac' it stops before ';;' or a command-position `esac` and returns which."""
        cmd_start = True
        wrap = None  # (name, plain args still to skip)
        while True:
            self.skip_blank(False)
            c = self.ch()
            if not c:
                if end:
                    self.err(f"missing {end!r}")
                return ""
            if end == ")" and c == ")":
                self.i += 1
                return ")"
            if end == "esac" and (self.startswith(";;") or self.startswith(";&")):
                return ";;"
            if c == "\n" or c == ";" or c == "&" or c == "|":
                if c == "&" and self.ch(1) == ">":
                    self.redirection()
                    continue
                self.i += 2 if self.s[self.i:self.i + 2] in ("&&", "||", "|&") else 1
                cmd_start, wrap = True, None
                continue
            if c in "<>" and self.ch(1) == "(":  # process substitution as an argument
                self.i += 2
                self.parse_list(")")
                if cmd_start and not wrap:
                    cmd_start = False
                continue
            if self.at_redirection() and self.redirection():
                continue
            if c == "(":
                if self.ch(1) == "(" and cmd_start:
                    self.i += 2
                    self.skip_arith("))")
                    cmd_start = False
                    continue
                if not cmd_start:
                    self.err("unexpected '('")
                self.i += 1
                self.parse_list(")")
                cmd_start = False
                continue
            if c == ")":
                self.err("unexpected ')'")
            if self.startswith("[[") and cmd_start and (self.ch(2) in " \t"):
                self.i += 2
                self.dbracket()
                cmd_start = False
                continue
            if end == "esac" and cmd_start and self.startswith("esac") and \
                    (self.ch(4) == "" or self.ch(4) in META):
                return "esac"
            w = self.word()
            if not w:
                self.err(f"unexpected character {c!r}")
            if not cmd_start:
                if wrap:
                    name, left = wrap
                    if w.startswith("-") and left >= 0 and name != "with_key":
                        if w in OPT_ARGS.get(name, ()):
                            self.skip_blank(False)
                            self.word()
                        continue
                    if name == "env" and ASSIGN.match(w):
                        continue
                    if left > 0:
                        wrap = (name, left - 1)
                        continue
                    wrap = None
                    self.command_word(w)
                    if self.unq(w) in WRAPPERS:
                        wrap = (self.unq(w), WRAPPERS[self.unq(w)])
                continue
            # command position
            if ASSIGN.match(w):
                continue
            u = self.unq(w)
            if u in KEYWORDS_CONT:
                continue
            if u == "case":
                self.case()
                cmd_start = False
                continue
            if u == "for":
                self.skip_blank(False)
                if self.startswith("(("):
                    self.i += 2
                    self.skip_arith("))")
                else:
                    while True:
                        self.skip_blank(False)
                        if self.ch() in ("", "\n", ";"):
                            break
                        self.word()
                continue
            # function definition: name () compound
            save = self.i
            self.skip_blank(False)
            if self.startswith("()"):
                self.i += 2
                self.funcs.add(u)
                cmd_start = True
                continue
            self.i = save
            if u == "trap":
                self.trap()
                cmd_start = False
                continue
            if u == "eval":
                self.err("eval is not supported")
            self.command_word(w)
            cmd_start = False
            if u in WRAPPERS:
                wrap = (u, WRAPPERS[u])

    def trap(self):
        self.skip_blank(False)
        if self.at_redirection() or self.ch() in ("", "\n", ";", "&", "|", ")"):
            return
        w = self.word()
        body = self.unq(w)
        if w.startswith("'") and w.endswith("'"):
            body = w[1:-1]
        if body not in ("-", "") and not body.startswith("-"):
            sub = Parser(body, f"{self.name}:trap")
            sub.parse_list("")
            self.cmds += sub.cmds
            self.funcs |= sub.funcs

    def case(self):
        self.skip_blank(False)
        self.word()
        self.skip_blank(True)
        if self.word() != "in":
            self.err("case without in")
        while True:
            self.skip_blank(True)
            if self.startswith("esac") and (self.ch(4) == "" or self.ch(4) in META):
                self.i += 4
                return
            if self.ch() == "(":
                self.i += 1
            # the pattern, up to an unquoted ')'
            while True:
                c = self.ch()
                if not c:
                    self.err("unterminated case pattern")
                if c == ")":
                    self.i += 1
                    break
                if c in " \t|":
                    self.i += 1
                    continue
                if not self.word():
                    self.err(f"unexpected {c!r} in a case pattern")
            stop = self.parse_list("esac")
            if stop == ";;":
                self.i += 3 if self.s[self.i:self.i + 3] == ";;&" else 2

    @staticmethod
    def unq(w):
        return w.replace('"', "").replace("'", "")

    def command_word(self, w):
        self.record(self.unq(w))

    def parse(self):
        self.parse_list("")


def commands(path, builtins):
    src = open(path, encoding="utf-8").read()
    p = Parser(src, path)
    p.parse()
    out = set()
    first = src.split("\n", 1)[0]
    if first.startswith("#!"):
        parts = first[2:].split()
        out.add(parts[0].rsplit("/", 1)[-1])
        if parts[0].endswith("/env") and len(parts) > 1:
            out.add(parts[1])
    for w in p.cmds:
        m = re.fullmatch(r"\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}$\"'\s]+)\}", w)
        if m:
            w = m.group(1)
        if w.startswith("$"):
            name = w.strip("${}")
            m = re.search(r"^\s*(?:local\s+)?" + re.escape(name) + r"=\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}$\"'\s]+)\}",
                          src, re.M)
            if m:
                w = m.group(1)
            else:
                out.add("$" + name)
                continue
        if "$" in w:
            out.add(w)
            continue
        if w in builtins or w in p.funcs:
            continue
        out.add(w)
    return out


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    builtins = shell_names()
    result = set()
    try:
        for f in argv[1:]:
            result |= commands(f, builtins)
    except ParseError as e:
        print(f"script-commands: {e}", file=sys.stderr)
        return 2
    for w in sorted(result):
        print(w)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
