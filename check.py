#!/usr/bin/env python3
"""check.py [FILE...] -- the repo's one guardrail. The loader serves games/ straight from GitHub main, so a bad push is live at once.

  python3 check.py                lint the games changed against origin/main, plus the loader/README consistency
  python3 check.py games/x.lua    lint just those files (zb dev does this before it pushes a script into the game)
  python3 check.py --all          lint every game
  python3 check.py --skills       the local bridge skill: lessons.md caps, games.md names every game, its pointers resolve

Per file, only what the edit introduces fails (the old games already ship some of both; those print as warnings):
  ImplicitReturn / SyntaxError from luau-analyze   a function that falls off the end of a value-returning path
                                                   crashes at runtime (tostring(f()) of zero values throws)
  non-ASCII bytes outside a comment                Opiumware mangles UTF-8 in a paste; write \\ddd escapes
"New" is measured against the origin/main copy of the file; a script origin/main doesn't have yet is all new.
Executor globals and Roblox types luau-analyze doesn't know (Unknown global / Unknown type) are filtered out.
Whole repo (always): every loader.lua row's file exists, no PlaceId twice, every PlaceId has a README row.
"""
import collections, os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))
NOISE = re.compile(r"Unknown global|UnknownGlobal|Unknown type|UnknownType")
FATAL = re.compile(r"ImplicitReturn|SyntaxError")
TRAILING_COMMENT = re.compile(r"\s--[^\"']*$")
errors, warnings = [], []


def baseline(rel):
	"""the origin/main text of a file, or '' when the script is new"""
	r = subprocess.run(["git", "-C", ROOT, "show", "origin/main:" + rel], capture_output=True)
	return r.stdout.decode("utf-8", "replace") if r.returncode == 0 else ""


def diagnostics(path):
	try:
		r = subprocess.run(["luau-analyze", path], capture_output=True, text=True)
	except FileNotFoundError:
		warnings.append("luau-analyze not installed: skipped the lint")
		return []
	return [l.replace("./", "", 1) for l in (r.stdout + r.stderr).splitlines() if l.strip() and not NOISE.search(l)]


def shape(diag):
	"""a diagnostic without its path, position and line references, so it matches the same one in the old copy"""
	return re.sub(r"line \d+", "line N", re.sub(r"^.*?\(\d+,\d+\):\s*", "", diag))


def ascii_lines(text):
	for line in text.splitlines():
		if not line.strip().startswith("--") and re.search(r"[^\x00-\x7f]", TRAILING_COMMENT.sub("", line)):
			yield line.strip()


def lint(path):
	rel = os.path.relpath(path, ROOT)
	old = baseline(rel)
	old_shapes = collections.Counter()
	if old:
		with tempfile.TemporaryDirectory() as d:
			p = os.path.join(d, "old.lua")
			open(p, "w", encoding="utf-8").write(old)
			old_shapes = collections.Counter(shape(x) for x in diagnostics(p) if FATAL.search(x))
	for diag in diagnostics(path):
		if not FATAL.search(diag):
			warnings.append(diag)
		elif old_shapes[shape(diag)] > 0:
			old_shapes[shape(diag)] -= 1
			warnings.append(diag + "  (already in origin/main)")
		else:
			errors.append(diag)
	known = collections.Counter(ascii_lines(old))
	for n, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
		stripped = line.strip()
		if stripped.startswith("--") or not re.search(r"[^\x00-\x7f]", TRAILING_COMMENT.sub("", line)):
			continue
		msg = f"{rel}:{n}: non-ASCII outside a comment (use a \\ddd escape)"
		if known[stripped] > 0:
			known[stripped] -= 1
			warnings.append(msg + "  (already in origin/main)")
		else:
			errors.append(msg)


def loader_rows():
	text = open(os.path.join(ROOT, "loader.lua"), encoding="utf-8").read()
	rows = re.findall(r'\["(\d+)"\]\s*=\s*"([^"]+)"', text)
	readme = open(os.path.join(ROOT, "README.md"), encoding="utf-8").read()
	ids = [i for i, _ in rows]
	for i in {i for i in ids if ids.count(i) > 1}:
		errors.append(f"loader.lua: PlaceId {i} appears twice")
	for i, f in rows:
		if not os.path.exists(os.path.join(ROOT, "games", f)):
			errors.append(f"loader.lua: {i} -> games/{f} does not exist (that game 404s)")
		if i not in readme:
			errors.append(f"README.md: no row for PlaceId {i} ({f})")
	listed = {f for _, f in rows}
	for f in sorted(os.listdir(os.path.join(ROOT, "games"))):
		if f.endswith(".lua") and f not in listed:
			warnings.append(f"games/{f} is not in the loader")


def skills():
	"""the local bridge skill's own consistency: size caps, games.md coverage, files and section numbers that its pointers name.
	The skill folder is not in the repo (it stays local), so a clone without it skips this."""
	base = os.path.join(ROOT, ".claude", "skills", "zegion-dump-to-script")
	if not os.path.isdir(base):
		warnings.append("skills: .claude/skills/zegion-dump-to-script not present, skipped")
		return

	def read(name):
		return open(os.path.join(base, name), encoding="utf-8").read()

	lessons = read("lessons.md")
	rows = len(re.findall(r"^\| \d+ \|", lessons, re.M))
	if rows > 25 or len(lessons.splitlines()) > 80:
		errors.append(f"lessons.md: {rows} rows / {len(lessons.splitlines())} lines (caps 25 / 80): graduate or merge a row")
	games_md = read("games.md")
	for f in sorted(os.listdir(os.path.join(ROOT, "games"))):
		if f.endswith(".lua") and f[:-4] not in games_md:
			errors.append(f"games.md: games/{f} is not named (add it to its shape row)")
	names = os.listdir(base)
	for name in sorted(set(re.findall(r"^\| `([\w.-]+\.md)` \|", read("SKILL.md"), re.M))):
		if name not in names:
			errors.append(f"SKILL.md: the file table names {name}, which does not exist")
	sections = {
		"inspect": set(re.findall(r"^## (\d+)\.", read("inspect.md"), re.M)),
		"new-game": set(re.findall(r"^## (\d+)\.", read("new-game.md"), re.M)),
	}
	pointer = {
		"inspect": re.compile(r"inspect\.md`?\s+(?:sections?\s+)?(\d+)"),
		"new-game": re.compile(r"new-game\.md`?\s+step\s+(\d+)"),
	}
	for name in sorted(n for n in names if n.endswith(".md")):
		text = read(name)
		for key, rx in pointer.items():
			for n in rx.findall(text):
				if n not in sections[key]:
					errors.append(f"{name}: points at {key} section {n}, which does not exist")


def changed():
	r = subprocess.run(["git", "-C", ROOT, "diff", "--name-only", "--diff-filter=d", "origin/main", "--", "games"], capture_output=True, text=True)
	u = subprocess.run(["git", "-C", ROOT, "ls-files", "--others", "--exclude-standard", "games"], capture_output=True, text=True)
	return [os.path.join(ROOT, f) for f in r.stdout.split() + u.stdout.split() if f.endswith(".lua")]


if __name__ == "__main__":
	args = sys.argv[1:]
	if args == ["--all"]:
		files = [os.path.join(ROOT, "games", f) for f in sorted(os.listdir(os.path.join(ROOT, "games"))) if f.endswith(".lua")]
	elif args == ["--skills"]:
		files = []
		skills()
	elif args:
		files = [os.path.abspath(a) for a in args]
	else:
		files = changed()
	for f in files:
		lint(f)
	if not args:
		loader_rows()
	for w in warnings:
		print("warn ", w)
	for e in errors:
		print("ERROR", e)
	print(f"check: {len(files)} file(s), {len(errors)} error(s), {len(warnings)} warning(s)")
	sys.exit(1 if errors else 0)
