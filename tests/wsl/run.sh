#!/usr/bin/env bash
# tests/wsl/run.sh -- drive DEPLOY.md inside WSL2 in an existing checkpointed test VM.
#
# Run it inside the test VM's WSL distribution. Restore the VM's return checkpoint
# afterwards; never copy a disk or use the host's everyday distribution:
#
#   wsl -d Ubuntu-24.04 -- bash /path/to/tests/wsl/run.sh --step prereq
#   wsl -d Ubuntu-24.04 -- bash /path/to/tests/wsl/run.sh --step render
#
# One --step per call keeps a single remote call short. Every step is idempotent and
# writes $OUT/<step>.json plus $OUT/run.log, so a timeout still leaves evidence.
#
# Steps
#   prereq     record the distro, install Node 24.22.3 from nodejs.org when the distro
#              has something else (tarball + SHASUMS256.txt check, no root needed), make
#              sure git exists, install Pi 1.5.2 with npm install -g --ignore-scripts.
#   render     dry run, --apply, then a second --apply to see whether anything is
#              re-created. Placeholders point at the stub provider, never a real vendor.
#   knowledge  clone pi-knowledge at the pinned base, apply the four patches with git am,
#              npm ci, npm run build. --skip-knowledge skips only this step.
#   stub       key-free proof: isolated temporary HOME under the OS temp dir, the npm
#              package tree symlinked in, a stub models.json, scripts/stub-provider.mjs on
#              the loopback and three pi --print calls. Checks the captured request bodies
#              for the direct tool set and for resident memory injection.
#   doctor     node scripts/doctor.mjs --json, parsed into counts plus FAIL labels.
#   summary    aggregate the step JSON files.
#
# Nothing here writes outside $HOME, $OUT and the temporary stub home. The source tree,
# node_modules, the knowledge base and the Magic Context store must stay on the Linux
# filesystem: do not point --repo or --agent-dir at /mnt/c.

set -euo pipefail

step=all
repo=''
out=''
modules='core,memory'
agent_dir=''
stub_port=18899
stub_timeout=90
skip_knowledge=0
committer_name=''
committer_email=''
node_version='24.22.3'

usage() {
    cat <<'USAGE'
Usage: tests/wsl/run.sh [options]

  --step NAME            all | prereq | render | knowledge | packages | stub | doctor | summary
  --repo DIR             repository root inside the distribution (default: two levels up)
  --out DIR              evidence directory (default: <tmp>/akis-pi-wsl-<stamp>)
  --modules LIST         modules to render (default: core,memory)
  --agent-dir DIR        Pi agent directory (default: $HOME/.pi/agent)
  --stub-port N          loopback port for scripts/stub-provider.mjs (default: 18899)
  --skip-knowledge       do not clone, patch or build pi-knowledge
  --committer-name NAME  temporary Git committer name for patch application
  --committer-email MAIL temporary Git committer email for patch application
  --help                 print this text
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --step) step="${2:-}"; shift 2 ;;
        --repo) repo="${2:-}"; shift 2 ;;
        --out) out="${2:-}"; shift 2 ;;
        --modules) modules="${2:-}"; shift 2 ;;
        --agent-dir) agent_dir="${2:-}"; shift 2 ;;
        --stub-port) stub_port="${2:-}"; shift 2 ;;
        --skip-knowledge) skip_knowledge=1; shift ;;
        --committer-name) committer_name="${2:-}"; shift 2 ;;
        --committer-email) committer_email="${2:-}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$step" in
    all|prereq|render|knowledge|packages|stub|doctor|summary) ;;
    *) echo "unknown --step: $step" >&2; exit 2 ;;
esac

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ -z "$repo" ]; then
    repo=$(cd "$script_dir/../.." && pwd)
fi
if [ ! -f "$repo/scripts/render.mjs" ]; then
    echo "not a repository root: $repo" >&2
    exit 2
fi
repo=$(cd "$repo" && pwd)

stamp=$(date -u +%Y%m%d-%H%M%S)
if [ -z "$out" ]; then
    out="${TMPDIR:-/tmp}/akis-pi-wsl-$stamp"
fi
mkdir -p "$out"
out=$(cd "$out" && pwd)

if [ -z "$agent_dir" ]; then
    agent_dir="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
fi
export PI_CODING_AGENT_DIR="$agent_dir"

log_file="$out/run.log"

log() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$log_file"
}

# Minimal JSON writer: values are escaped with sed, which is enough for the ASCII paths
# and versions these steps record.
esc() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\r\n'
}

write_json() {
    name="$1"
    shift
    {
        printf '{\n'
        printf '  "step": "%s",\n' "$(esc "$name")"
        printf '  "timestamp": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        first=1
        for pair in "$@"; do
            key=${pair%%=*}
            value=${pair#*=}
            if [ $first -eq 1 ]; then first=0; else printf ',\n'; fi
            printf '  "%s": "%s"' "$(esc "$key")" "$(esc "$value")"
        done
        printf '\n}\n'
    } > "$out/$name.json"
}

ensure_node() {
    current=''
    if command -v node >/dev/null 2>&1; then
        current=$(node --version 2>/dev/null || true)
    fi
    if [ "$current" = "v$node_version" ]; then
        log "[prereq] node already v$node_version"
        return 0
    fi
    case "$(uname -m)" in
        x86_64|amd64) node_arch=x64 ;;
        aarch64|arm64) node_arch=arm64 ;;
        *) log "[prereq] unsupported machine: $(uname -m)"; return 1 ;;
    esac
    base="https://nodejs.org/dist/v$node_version"
    tarball="node-v$node_version-linux-$node_arch.tar.xz"
    work="${TMPDIR:-/tmp}/akis-pi-node-$stamp"
    mkdir -p "$work"
    log "[prereq] installing node v$node_version from $base/$tarball"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$base/$tarball" -o "$work/$tarball"
        curl -fsSL "$base/SHASUMS256.txt" -o "$work/SHASUMS256.txt"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$base/$tarball" -O "$work/$tarball"
        wget -q "$base/SHASUMS256.txt" -O "$work/SHASUMS256.txt"
    else
        log '[prereq] neither curl nor wget is available'
        return 1
    fi
    expected=$(grep " $tarball\$" "$work/SHASUMS256.txt" | awk '{print $1}')
    actual=$(sha256sum "$work/$tarball" | awk '{print $1}')
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        log "[prereq] sha256 mismatch for $tarball"
        return 1
    fi
    dest="$HOME/.local/node-v$node_version"
    mkdir -p "$HOME/.local"
    tar -xJf "$work/$tarball" -C "$HOME/.local"
    ln -sfn "$HOME/.local/node-v$node_version-linux-$node_arch" "$dest"
    export PATH="$dest/bin:$PATH"
    # Persist for later steps: each --step call is a new shell.
    printf 'export PATH=%q/bin:$PATH\n' "$dest" > "$out/env.sh"
    log "[prereq] node $(node --version) via $dest/bin"
}

load_env_file() {
    if [ -f "$out/env.sh" ]; then
        # shellcheck disable=SC1090
        . "$out/env.sh"
    fi
}

ensure_pi() {
    if command -v pi >/dev/null 2>&1 && [ "$(pi --version 2>/dev/null | tr -d '\r')" = "1.5.2" ]; then
        log '[prereq] pi already 1.5.2'
        return 0
    fi
    log '[prereq] installing pi 1.5.2 with npm -g --ignore-scripts'
    npm install -g --ignore-scripts @earendil-works/pi-coding-agent@1.5.2 >>"$log_file" 2>&1
    version=$(pi --version 2>/dev/null | tr -d '\r' || true)
    log "[prereq] pi version now: $version"
    [ "$version" = "1.5.2" ]
}

render_args() {
    printf '%s\0' \
        "$repo/scripts/render.mjs" \
        --home "$HOME" \
        --agent-dir "$agent_dir" \
        --modules "$modules" \
        --strict \
        --set PROVIDER=stub \
        --set MODEL=stub-model \
        --set MODEL_EXEC=stub-model \
        --set MODEL_REVIEW=stub-model \
        --set MODEL_PLAN=stub-model \
        --set MODEL_HISTORIAN=stub-model \
        --set 'BRAVE_KEY_REF=$BRAVE_API_KEY' \
        --set 'BOCHA_KEY_REF=$BOCHA_API_KEY'
}

step_prereq() {
    load_env_file
    log "[prereq] distro=${WSL_DISTRO_NAME:-unknown} uname=$(uname -sr) arch=$(uname -m) user=$(id -un)"
    if [ -z "${WSL_DISTRO_NAME:-}" ]; then
        log '[prereq] note: WSL_DISTRO_NAME is not set; this looks like plain Linux, which is a different target'
    fi
    if ! ensure_node; then
        write_json prereq ok=false error='node install failed'
        return 1
    fi
    load_env_file
    if ! command -v git >/dev/null 2>&1; then
        log '[prereq] git is missing; trying a non-interactive apt-get install'
        if command -v apt-get >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            sudo -n apt-get update -qq >>"$log_file" 2>&1 || true
            sudo -n apt-get install -y git >>"$log_file" 2>&1 || true
        fi
        if ! command -v git >/dev/null 2>&1; then
            write_json prereq ok=false error='git missing and it could not be installed without a password'
            return 1
        fi
    fi
    if ! ensure_pi; then
        write_json prereq ok=false error='pi install failed'
        return 1
    fi
    node_bin=$(command -v node)
    git_version=$(git --version | tr -d '\r')
    npm_version=$(npm --version 2>/dev/null | tr -d '\r' || true)
    fs_type=$(df -P -T "$HOME" 2>/dev/null | awk 'NR==2 {print $2}' || true)
    write_json prereq \
        ok=true \
        distro="${WSL_DISTRO_NAME:-plain-linux}" \
        kernel="$(uname -sr)" \
        arch="$(uname -m)" \
        node="$(node --version)" \
        node_bin="$node_bin" \
        npm="$npm_version" \
        git="$git_version" \
        pi="$(pi --version | tr -d '\r')" \
        home="$HOME" \
        home_fs="$fs_type" \
        repo="$repo"
    return 0
}

step_render() {
    load_env_file
    log '[render] dry run'
    mapfile -d '' -t args < <(render_args)
    if ! node "${args[@]}" >>"$log_file" 2>&1; then
        write_json render ok=false error='dry run failed'
        return 1
    fi
    log '[render] apply'
    if ! node "${args[@]}" --apply >>"$log_file" 2>&1; then
        write_json render ok=false error='apply failed'
        return 1
    fi
    log '[render] second apply (expect no new files)'
    node "${args[@]}" --apply > "$out/render-rerun.txt" 2>&1 || true
    creates=$(grep -c -E '^(create|update)[[:space:]]' "$out/render-rerun.txt" || true)
    missing=''
    for rel in settings.json AGENTS.md APPEND_SYSTEM.md compact-tools.json extensions/rtk.ts extensions/subagent/config.json; do
        if [ ! -e "$agent_dir/$rel" ]; then missing="$missing $rel"; fi
    done
    if printf '%s' "$modules" | grep -q memory; then
        if [ ! -e "$agent_dir/extensions/resident-memory.ts" ]; then missing="$missing extensions/resident-memory.ts"; fi
        if [ ! -e "$HOME/.config/cortexkit/magic-context.jsonc" ]; then
            missing="$missing .config/cortexkit/magic-context.jsonc"
        fi
    fi
    roles=$(ls -1 "$agent_dir/agents" 2>/dev/null | grep -c '\.md$' || true)
    if [ -n "$missing" ]; then
        write_json render ok=false error="missing files:$missing"
        return 1
    fi
    if [ "$roles" -lt 8 ]; then
        write_json render ok=false error="expected 8 role files, found $roles"
        return 1
    fi
    write_json render \
        ok=true \
        agent_dir="$agent_dir" \
        modules="$modules" \
        role_files="$roles" \
        rerun_creates="$creates"
    return 0
}

step_knowledge() {
    load_env_file
    base='558e8dd'
    if [ "$skip_knowledge" -eq 1 ] || [[ ",$modules," != *,memory,* ]]; then
        log '[knowledge] skipped; doctor still checks the explicitly selected modules'
        write_json knowledge ok=true skipped=true
        return 0
    fi
    if [ -z "$committer_name" ] || [ -z "$committer_email" ]; then
        write_json knowledge ok=false error="pass --committer-name and --committer-email for git am"
        return 1
    fi
    vendor="$HOME/.pi/vendor"
    clone="$vendor/pi-knowledge"
    mkdir -p "$vendor"
    if [ ! -d "$clone/.git" ]; then
        log "[knowledge] cloning pi-knowledge into $clone"
        if ! git clone https://github.com/nczz/pi-knowledge "$clone" >>"$log_file" 2>&1; then
            write_json knowledge ok=false error='git clone failed'
            return 1
        fi
    fi
    if ! git -C "$clone" checkout "$base" >>"$log_file" 2>&1; then
        write_json knowledge ok=false error="git checkout $base failed"
        return 1
    fi
    applied=''
    for patch in "$repo"/modules/memory/patches/*.patch; do
        name=$(basename "$patch")
        log "[knowledge] git am $name"
        if ! git -C "$clone" -c "user.name=$committer_name" -c "user.email=$committer_email" am "$patch" >>"$log_file" 2>&1; then
            git -C "$clone" am --abort >>"$log_file" 2>&1 || true
            write_json knowledge ok=false applied="$applied" error="git am failed on $name"
            return 1
        fi
        applied="$applied $name"
    done
    # Both versions ship the CPU runtime. The 1.21.0 installer used by knowledge
    # reads INSTALL_CUDA; MC 1.30.0 reads INSTALL. Keep both CPU-only install flags.
    export ONNXRUNTIME_NODE_INSTALL=skip
    export ONNXRUNTIME_NODE_INSTALL_CUDA=skip
    log '[knowledge] npm ci'
    if ! (cd "$clone" && npm ci >>"$log_file" 2>&1); then
        write_json knowledge ok=false applied="$applied" error='npm ci failed (native build tools missing?)'
        return 1
    fi
    log '[knowledge] npm run build'
    if ! (cd "$clone" && npm run build >>"$log_file" 2>&1); then
        write_json knowledge ok=false applied="$applied" error='npm run build failed'
        return 1
    fi
    if [ ! -e "$clone/dist/index.js" ]; then
        write_json knowledge ok=false applied="$applied" error='dist/index.js missing after the build'
        return 1
    fi
    version=$(node -e 'console.log(require(process.argv[1]).version)' "$clone/package.json")
    write_json knowledge ok=true path="$clone" base="$base" applied="$applied" version="$version"
    return 0
}

step_packages() {
    load_env_file
    # CPU runtimes are bundled; the two pinned ONNX versions use different flags.
    export ONNXRUNTIME_NODE_INSTALL=skip
    export ONNXRUNTIME_NODE_INSTALL_CUDA=skip
    sources=$(node -e '
const fs=require("node:fs");const m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const selected=process.argv[2].split(",");
console.log(m.components.filter((c)=>selected.includes(c.module)&&c.id!=="pi"&&c.source.startsWith("npm:")).map((c)=>c.source).join("\n"));
' "$repo/manifest.json" "$modules") || return 1
    while IFS= read -r source; do
        [ -n "$source" ] || continue
        if ! pi install "$source" >>"$log_file" 2>&1; then
            write_json packages ok=false error="pi install failed: $source"
            return 1
        fi
    done <<< "$sources"
    if [[ ",$modules," == *,memory,* ]]; then
        if ! node "$repo/scripts/deploy-check.mjs" onnx >>"$log_file" 2>&1; then
            write_json packages ok=false error='deploy-check onnx failed; see deployment log'
            return 1
        fi
    fi
    write_json packages ok=true
}

step_stub() {
    load_env_file
    temp_root=$(mktemp -d "${TMPDIR:-/tmp}/akis-pi-stub-XXXXXX")
    temp_home="$temp_root/home"
    temp_agent="$temp_home/.pi/agent"
    stub_log="$out/stub-requests.jsonl"
    if [ -f "$stub_log" ]; then rm -f "$stub_log"; fi
    mkdir -p "$temp_agent" "$temp_home/.config/cortexkit"
    # Keep the deployed MC configuration when HOME changes. Otherwise the probe
    # silently enables upstream defaults (including background embedding work).
    mc_config="${XDG_CONFIG_HOME:-$HOME/.config}/cortexkit/magic-context.jsonc"
    if [[ ",$modules," == *,memory,* ]]; then
        if [ ! -f "$mc_config" ]; then
            write_json stub ok=false error='deployed MC config missing'
            rm -rf "$temp_root"
            return 1
        fi
        cp "$mc_config" "$temp_home/.config/cortexkit/magic-context.jsonc"
    fi
    for rel in settings.json AGENTS.md APPEND_SYSTEM.md compact-tools.json; do
        if [ -f "$agent_dir/$rel" ]; then cp "$agent_dir/$rel" "$temp_agent/$rel"; fi
    done
    for dir in agents prompts extensions skills; do
        if [ -d "$agent_dir/$dir" ]; then cp -R "$agent_dir/$dir" "$temp_agent/$dir"; fi
    done
    if [ -d "$agent_dir/npm" ]; then
        ln -s "$agent_dir/npm" "$temp_agent/npm"
        log '[stub] linked the deployed npm package tree into the isolated agent dir'
    else
        log '[stub] warning: no npm package tree in the deployed agent dir; the tool check may fail'
    fi
    {
        printf '{\n'
        printf '  "providers": {\n'
        printf '    "stub": {\n'
        printf '      "baseUrl": "http://127.0.0.1:%s/v1",\n' "$stub_port"
        printf '      "api": "openai-completions",\n'
        printf '      "apiKey": "dummy",\n'
        printf '      "models": [\n'
        printf '        { "id": "stub-model", "name": "Stub", "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }, "contextWindow": 200000, "maxTokens": 1000 }\n'
        printf '      ]\n'
        printf '    }\n'
        printf '  }\n'
        printf '}\n'
    } > "$temp_agent/models.json"
    # Synthetic fixture belongs only to this temporary home; never copy user memory.
    mkdir -p "$temp_agent/memory"
    printf '%s\n' 'AKIS_STUB_RESIDENT_SENTINEL' > "$temp_agent/memory/RESIDENT.md"
    node -e '
const fs = require("node:fs");
const file = process.argv[1];
const settings = JSON.parse(fs.readFileSync(file, "utf8"));
settings.defaultProvider = "stub";
settings.defaultModel = "stub-model";
settings.enabledModels = ["stub/stub-model"];
fs.writeFileSync(file, JSON.stringify(settings, null, 2) + "\n");
' "$temp_agent/settings.json"

    node "$repo/scripts/stub-provider.mjs" --port "$stub_port" --log "$stub_log" > "$out/stub-stdout.txt" 2>&1 &
    stub_pid=$!
    cleanup_stub() {
        if kill -0 "$stub_pid" 2>/dev/null; then kill "$stub_pid" 2>/dev/null || true; fi
        wait "$stub_pid" 2>/dev/null || true
        if [ -L "$temp_agent/npm" ]; then rm -f "$temp_agent/npm"; fi
        rm -rf "$temp_root"
    }
    trap cleanup_stub EXIT
    ready=0
    elapsed=0
    while [ "$elapsed" -lt "$stub_timeout" ]; do
        if node -e '
const net = require("node:net");
const socket = net.connect(Number(process.argv[1]), "127.0.0.1");
socket.on("connect", () => { socket.destroy(); process.exit(0); });
socket.on("error", () => process.exit(1));
' "$stub_port" >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    if [ "$ready" -ne 1 ]; then
        write_json stub ok=false error="stub provider never listened on 127.0.0.1:$stub_port"
        return 1
    fi
    failures=''
    run_prompt() {
        label="$1"
        prompt="$2"
        if ! XDG_CONFIG_HOME="$temp_home/.config" XDG_DATA_HOME="$temp_home/.local/share" MAGIC_CONTEXT_STORAGE_DIR="$temp_home/.local/share/cortexkit/magic-context" MAGIC_CONTEXT_LOG_PATH="$out/pi-$label.mc.log" PI_RESIDENT_MEMORY_OFF=0 PI_RESIDENT_MEMORY_FILE="$temp_agent/memory/RESIDENT.md" PI_CODING_AGENT_DIR="$temp_agent" HOME="$temp_home" pi --provider stub --model stub-model --print --no-session "$prompt" > "$out/pi-$label.txt" 2>&1; then
            failures="$failures $label"
        elif ! grep -q 'stub-ok' "$out/pi-$label.txt"; then
            failures="$failures $label(no stub-ok)"
        fi
    }
    run_prompt smoke 'hi'
    run_prompt roles 'delegate nothing; list the subagent roles you can use'
    run_prompt tools 'answer with the number of tools you can call directly'

    tools_seen=''
    resident='false'
    if [ -f "$stub_log" ]; then
        tools_seen=$(node -e '
const fs = require("node:fs");
const rows = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
const first = rows[0] || {};
console.log((first.tools || []).map((tool) => (tool.function && tool.function.name) || "").filter(Boolean).join(","));
' "$stub_log")
        if [[ ",$modules," == *,memory,* ]]; then
            if node "$repo/scripts/deploy-check.mjs" stub-resident "$stub_log" AKIS_STUB_RESIDENT_SENTINEL > "$out/stub-resident.txt" 2>&1; then
                resident='true'
            else
                failures="$failures resident(inspect stub-resident.txt)"
            fi
        fi
    fi
    if ! node "$repo/scripts/deploy-check.mjs" stub-requests "$stub_log" > "$out/stub-tools.txt" 2>&1; then
        failures="$failures tools($tools_seen; inspect stub-tools.txt)"
    fi
    if [ -n "$failures" ]; then
        write_json stub ok=false tools="$tools_seen" resident_memory="$resident" error="failed:$failures"
        return 1
    fi
    write_json stub ok=true tools="$tools_seen" resident_memory="$resident"
    return 0
}

step_doctor() {
    load_env_file
    doctor_modules="$modules"
    # Check every selected module; an incomplete memory installation must fail.
    set +e
    node "$repo/scripts/doctor.mjs" --home "$HOME" --agent-dir "$agent_dir" --modules "$doctor_modules" --json > "$out/doctor-raw.json" 2>"$out/doctor-stderr.txt"
    doctor_exit=$?
    set -e
    if [ "$doctor_exit" -ne 0 ]; then
        write_json doctor ok=false modules="$doctor_modules" error="doctor exited $doctor_exit; inspect doctor-raw.json and doctor-stderr.txt"
        return 1
    fi
    if [ ! -s "$out/doctor-raw.json" ]; then
        write_json doctor ok=false modules="$doctor_modules" error="doctor produced no JSON (exit $doctor_exit)"
        return 1
    fi
    fails=$(node -e '
const fs = require("node:fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
console.log((data.results || []).filter((r) => r.status === "FAIL").map((r) => r.label + " :: " + (r.detail || "")).join(" | "));
' "$out/doctor-raw.json")
    counts=$(node -e '
const fs = require("node:fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
console.log([data.counts.PASS, data.counts.WARN, data.counts.FAIL].join("/"));
' "$out/doctor-raw.json")
    log "[doctor] PASS/WARN/FAIL = $counts"
    if [ -n "$fails" ]; then
        write_json doctor ok=false modules="$doctor_modules" counts="$counts" fails="$fails"
        return 1
    fi
    write_json doctor ok=true modules="$doctor_modules" counts="$counts"
    return 0
}

step_summary() {
    overall=0
    details=''
    for name in prereq render knowledge packages stub doctor; do
        file="$out/$name.json"
        if [ ! -f "$file" ]; then
            details="$details $name=not-run"
            overall=1
            continue
        fi
        if grep -q '"ok": "true"' "$file"; then
            details="$details $name=ok"
        else
            details="$details $name=failed"
            overall=1
        fi
    done
    log "[summary]$details"
    if [ "$overall" -eq 0 ]; then summary_ok=true; else summary_ok=false; fi
    write_json summary ok="$summary_ok" details="$details"
    return "$overall"
}

code=0
case "$step" in
    prereq) step_prereq || code=3 ;;
    render) step_render || code=3 ;;
    knowledge) step_knowledge || code=3 ;;
    packages) step_packages || code=3 ;;
    stub) step_stub || code=3 ;;
    doctor) step_doctor || code=3 ;;
    summary) step_summary || code=3 ;;
    all)
        code=0
        step_prereq || code=3
        if [ "$code" -eq 0 ]; then step_render || code=3; fi
        if [ "$code" -eq 0 ]; then step_knowledge || code=3; fi
        if [ "$code" -eq 0 ]; then step_packages || code=3; fi
        if [ "$code" -eq 0 ]; then step_stub || code=3; fi
        if [ "$code" -eq 0 ]; then step_doctor || code=3; fi
        if [ "$code" -eq 0 ]; then step_summary || code=3; fi
        ;;
esac
log "[done] step=$step exit=$code"
echo "RESULT=$code"
exit "$code"
