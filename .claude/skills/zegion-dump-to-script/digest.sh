#!/usr/bin/env bash
# digest.sh <dump-dir> -- the first-pass scan of a dump_v2 folder, so nothing is read by eye that a grep can find.
# Prints: header, remote -> call shapes, what the server sends back, client-side gates (the check the client makes
# BEFORE it fires), monetised routes, keyword hits for high-value mechanics, config modules, unused remotes.
# It only finds candidates. Every one still has to be traced in the source and, if it matters, probed.
# Portable on purpose: macOS grep has no -P, so this is awk + grep -E only.
D="${1:?usage: digest.sh <dump-dir>}"
S="$D/scripts"
SP="$S/StarterPlayer" # the StarterPlayer copy is the live one; scripts/Players/<you>/ is a duplicate clone
sec() { printf '\n######## %s ########\n' "$1"; }

sec "HEADER (next.txt)"
head -3 "$D/next.txt" 2>/dev/null

sec "OUTBOUND REMOTES -> distinct call shapes, count first (calls.txt; admin/analytics/onboarding/poll dropped)"
# calls.txt row: Method <TAB> receiver <TAB> Script:line <TAB> (args)
awk -F'\t' '$1=="FireServer" || $1=="InvokeServer" {
	r = $2; n = r
	if (match(r, /\)\.[A-Za-z0-9_]+$/)) { print $1 "\t" substr(r, RSTART + 2) "\t" $4; next } # X:FindFirstChild("Events").Name
	if (match(r, /(WaitForChild|FindFirstChild)\("[A-Za-z0-9_]+"[^)]*\)[^"]*$/)) { n = substr(r, RSTART) }
	gsub(/.*\("/, "", n); gsub(/".*/, "", n)
	if (n == r || n == "" || n == "nil") { n = r; sub(/.*[.:]/, "", n) }
	if (n ~ /AdminActionEvent|LogAnalytics|SetOnboardingStep|Poll|SaveSettings|HitboxClass/) next
	print $1 "\t" n "\t" $4
}' "$D/calls.txt" 2>/dev/null | sort | uniq -c | sort -k3,3 -k1,1nr | cut -c1-160 | head -90

sec "SERVER -> CLIENT (listeners>0), first payload seen while playing"
awk -F'\t' '$3 ~ /listeners=[1-9]/ {print $2}' "$D/remotes.txt" 2>/dev/null | while read -r path; do
	n="${path##*.}"
	first=$(awk -F'\t' -v n="$n" '$2=="recv" && $3 ~ ("\\." n "$") {print $4; exit}' "$D/events.txt" 2>/dev/null | cut -c1-170)
	[ -n "$first" ] && printf '%-30s %s\n' "$n" "$first"
done | head -60

sec "CLIENT-SIDE GATES: a time / distance / cooldown test the client makes before firing. The server may not repeat it -> probe"
grep -rnE 'os\.time\(\)|GetServerTimeNow|Cooldown|TimerDuration|PlacedAt|MaxActivationDistance *[=<>]' "$SP" 2>/dev/null \
	| grep -v -e Admin -e _Archive -e _Old -e PlayerModule -e Rbx -e Starfall -e EventTimer -e StoreHandler -e HUDHandler \
	| sed "s|$SP/StarterPlayerScripts/||" | cut -c1-170 | head -30

sec "MONETISED ROUTES (note the remote each guards; do not wire) -- files with purchase prompts / ownership checks"
grep -rlE 'PromptProductPurchase|PromptGamePassPurchase|UserOwnsGamePass' "$SP" "$S/ReplicatedStorage/Modules" 2>/dev/null | grep -v -e _Archive -e _Old | sed "s|$S/||"
grep -rhoE 'Owns[A-Z][A-Za-z0-9]*|IsVIP|Has(Fast|Super)[A-Za-z]*' "$SP" 2>/dev/null | sort | uniq -c | sort -rn | head -12

sec "KEYWORD HITS: remote names and module names (instant, skip, auto, claim, roll, ...)"
KW='instant|skip|auto|fast|claim|complete|finish|reroll|reward|collect|hatch|open|forge|craft|rebirth|prestige|teleport|travel|sell|equip|upgrade|purchase|buy|roll|spin|quest|redeem|code|gift|force|boost|multiplier|luck'
{ awk -F'\t' '{print $2}' "$D/remotes.txt" 2>/dev/null; ls "$S/ReplicatedStorage/Modules" 2>/dev/null; } \
	| grep -iE "$KW" | grep -v -e Integrity -e RobloxReplicatedStorage -e ExpChat -e Admin -e _Archive -e _Old | sort -u | head -80

sec "CONFIG MODULES in ReplicatedStorage/Modules, biggest first -- require these, don't copy numbers"
ls -S "$S/ReplicatedStorage/Modules" 2>/dev/null | grep -v -e _Archive -e _Old | head -30 | while read -r f; do
	[ -f "$S/ReplicatedStorage/Modules/$f" ] && printf '%6s lines  %s\n' "$(wc -l < "$S/ReplicatedStorage/Modules/$f")" "$f"
done

sec "REMOTES THE CLIENT NEVER CALLS AND NOBODY LISTENS ON (unused, or server-only -- check before ignoring)"
awk -F'\t' '$1=="RemoteEvent" && $3=="listeners=0" {print $2}' "$D/remotes.txt" 2>/dev/null | while read -r path; do
	n="${path##*.}"
	grep -q "\"$n\"" "$D/calls.txt" 2>/dev/null || echo "$path"
done | grep -v -e RobloxReplicatedStorage -e Admin | head -30

echo
echo "next: trace each hit in scripts/, then run the checklist in hunt.md"
