#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'touch "$test_tmp/release" "$test_tmp/intro-done"; rm -rf "$test_tmp"' EXIT
home="$test_tmp/home"
state="$home/.local/state/omarchy/current"
themes="$home/.config/omarchy/themes"
commands="$test_tmp/bin"
log="$test_tmp/commands"
mkdir -p "$state" "$commands" "$home/.local/state/omarchy/theme-backgrounds"
for theme in alpha beta; do
  mkdir -p "$themes/$theme/backgrounds/intros"
  cp "$ROOT/themes/tokyo-night/colors.toml" "$themes/$theme/colors.toml"
  printf 'still\n' >"$themes/$theme/backgrounds/1-sky.webp"
  printf 'intro\n' >"$themes/$theme/backgrounds/intros/1-sky.mp4"
done
cp -r "$themes/alpha" "$state/theme"
printf 'alpha\n' >"$state/theme.name"
ln -s "$state/theme/backgrounds/1-sky.webp" "$state/background"

# Every retint logs its name. The browser one holds until released, standing
# in for a slow policy write, and the VS Code one fails.
cat >"$commands/retint" <<'STUB'
#!/bin/bash
name=${0##*/}
if [[ $name == omarchy-theme-set-browser ]]; then
  for attempt in {1..250}; do
    [[ ! -f $TEST_TMP/release ]] || break
    sleep 0.02
  done
fi
echo "$name" >>"$TEST_LOG"
[[ $name != omarchy-theme-set-vscode ]]
STUB
cat >"$commands/noop" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$commands/retint" "$commands/noop"
for command in "$ROOT"/bin/omarchy-restart-* "$ROOT"/bin/omarchy-theme-set-* omarchy-hook; do
  ln -sf retint "$commands/${command##*/}"
done
for command in omarchy-theme-set-templates omarchy-theme-bg-cache omarchy-theme-set-herdr-machines; do
  ln -sf noop "$commands/$command"
done
cat >"$commands/omarchy-notification-send" <<'STUB'
#!/bin/bash
echo "notify: $*" >>"$TEST_LOG"
STUB
# Hyprland's own config watch is off unless a case turns it on.
cat >"$commands/hyprctl" <<'STUB'
#!/bin/bash
if [[ $3 == "misc:disable_autoreload" ]]; then
  printf '{"bool":%s}\n' "${TEST_AUTORELOAD_OFF:-true}"
else
  printf '{"bool":true}\n'
fi
STUB
# The new theme's intro stays on screen until the test lets it finish.
cat >"$commands/omarchy-shell" <<'STUB'
#!/bin/bash
if [[ $2 == "themeIntroStatus" && $(<"$TEST_STATE/theme.name") == "beta" && ! -f $TEST_TMP/intro-done ]]; then
  echo "pending"
else
  echo "ready"
fi
STUB
cat >"$commands/owe" <<'STUB'
#!/bin/bash
[[ $1 != "render" ]]
STUB
chmod +x "$commands/omarchy-notification-send" "$commands/hyprctl" "$commands/omarchy-shell" "$commands/owe"

set_theme() {
  : >"$log"
  HOME="$home" OMARCHY_PATH="$ROOT" PATH="$commands:$ROOT/bin:$PATH" XDG_RUNTIME_DIR="$test_tmp" \
    TEST_LOG="$log" TEST_TMP="$test_tmp" TEST_STATE="$state" \
    /bin/bash "$ROOT/bin/omarchy-theme-set" "$1" </dev/null >"$test_tmp/stdout" 2>"$test_tmp/stderr" ||
    fail "theme selection completes" "$(cat "$test_tmp/stderr")"
}

wait_logged() {
  for attempt in {1..250}; do
    grep -q "$1" "$log" && return 0
    sleep 0.02
  done
  fail "$2" "$(cat "$log")"
}

wait_for_detached_work() {
  for attempt in {1..250}; do
    pgrep -f "^/bin/bash $ROOT/bin/omarchy-theme-set (alpha|beta)\$" >/dev/null || return 0
    sleep 0.02
  done
  fail "the detached retints finish"
}

set_theme beta
for command in omarchy-restart-terminal omarchy-theme-set-foot omarchy-theme-set-tmux omarchy-restart-btop; do
  grep -qx "$command" "$log" || fail "$command retints before the switch returns, while the intro plays" "$(cat "$log")"
done
! grep -qx 'omarchy-theme-set-gnome' "$log" || fail "other apps wait for the intro to finish its reveal"
! grep -qx 'omarchy-hook' "$log" || fail "the theme-set hook waits for the other retints"
touch "$test_tmp/intro-done"
wait_logged '^omarchy-theme-set-gnome$' "other apps retint once the intro has revealed"
! grep -qx 'omarchy-theme-set-browser' "$log" || fail "the held browser retint is still running"
touch "$test_tmp/release"
wait_logged '^omarchy-hook$' "the theme-set hook runs after the other retints"
wait_logged '^notify: .*omarchy-theme-set-vscode failed' "a failed detached retint is reported in a notification"
wait_for_detached_work
grep -q 'Theme retint failed: omarchy-theme-set-vscode' "$home/.local/state/omarchy/theme-set.log" ||
  fail "a failed detached retint is named in the theme-set log"
pass "terminals retint during an intro and the other apps follow without holding up the switch"

rm -f "$test_tmp/release"
OMARCHY_THEME_SKIP_BACKGROUND=1 set_theme beta
grep -qx 'omarchy-restart-hyprctl' "$log" || fail "a switch without an intro reloads Hyprland before returning"
! grep -qx 'omarchy-theme-set-browser' "$log" || fail "the browser retint does not hold up the switch"
touch "$test_tmp/release"
wait_for_detached_work
pass "a switch without an intro reloads Hyprland with the terminals"

rm -f "$test_tmp/release"
TEST_AUTORELOAD_OFF=false OMARCHY_THEME_SKIP_BACKGROUND=1 set_theme beta
! grep -qx 'omarchy-restart-hyprctl' "$log" || fail "Hyprland watching its config is left to reload itself"
touch "$test_tmp/release"
wait_for_detached_work
pass "Hyprland reloads only once when it watches its config"

rm -f "$test_tmp/release"
(sleep 0.3; touch "$test_tmp/release") &
OMARCHY_THEME_WAIT=1 OMARCHY_THEME_SKIP_BACKGROUND=1 set_theme beta
wait
for command in omarchy-theme-set-browser omarchy-hook; do
  grep -qx "$command" "$log" || fail "OMARCHY_THEME_WAIT=1 returns only after $command" "$(cat "$log")"
done
grep -q 'Theme retint failed: omarchy-theme-set-vscode' "$test_tmp/stderr" || fail "a waited-for failure is named on stderr"
! grep -q '^notify: ' "$log" || fail "a waited-for failure is not also a notification"
pass "OMARCHY_THEME_WAIT=1 waits for every retint and reports failures on stderr"
