#!/usr/bin/env bash
set -euo pipefail

# Baut hbbs und hbbr aus den offiziellen rustdesk-server-Quellen.
#
# Warum überhaupt selbst bauen: die offiziellen Releases liefern nur Linux und
# Windows, ein macOS-Binary gibt es nirgends — auch nicht in den Forks. Die
# Quellen haben aber einen eigenen macOS-Zweig und bauen nativ.
#
# Das Ergebnis ist ein Universal-Binary (arm64 + x86_64) und wandert nach
# Vendored/. build_app.sh legt es von dort ins App-Bundle. Rust wird also nur
# zum Bauen gebraucht; die fertige App läuft ohne jede Vorbereitung.

REPO_URL="https://github.com/rustdesk/rustdesk-server.git"
# Fest auf ein Release, nicht auf master: master trägt bereits eine
# unveröffentlichte Version und ist ein bewegliches Ziel.
REPO_TAG="1.1.16"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/vendor/rustdesk-server"
OUT="${ROOT}/Vendored"

# rustup installiert nach ~/.cargo und ist von Homebrew unabhängig.
export PATH="${HOME}/.cargo/bin:${PATH}"
if ! command -v cargo >/dev/null 2>&1; then
  echo "ABBRUCH: cargo nicht gefunden. Rust-Toolchain installieren:" >&2
  echo "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path" >&2
  exit 1
fi

echo "==> Quellen holen (${REPO_TAG})…"
# hbb_common liegt als Submodul im Repo — ohne --recurse-submodules fehlt der
# halbe Workspace und cargo bricht beim Laden des Manifests ab.
if [[ -d "${SRC}/.git" ]]; then
  git -C "${SRC}" fetch --tags --depth 1 origin "refs/tags/${REPO_TAG}:refs/tags/${REPO_TAG}" 2>/dev/null || true
  git -C "${SRC}" checkout -q "tags/${REPO_TAG}"
  git -C "${SRC}" submodule update --init --recursive --depth 1
else
  mkdir -p "$(dirname "${SRC}")"
  git clone --depth 1 --recurse-submodules --shallow-submodules \
    --branch "${REPO_TAG}" "${REPO_URL}" "${SRC}"
fi

# Beide Architekturen einzeln bauen und danach zusammenlegen. cargo kennt kein
# "universal"-Ziel, das macht lipo.
TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
echo "==> Rust-Ziele bereitstellen…"
rustup target add "${TARGETS[@]}"

BUILT_TARGETS=()
for target in "${TARGETS[@]}"; do
  echo "==> Baue für ${target}…"
  if (cd "${SRC}" && cargo build --release --target "${target}" --bin hbbs --bin hbbr); then
    BUILT_TARGETS+=("${target}")
  else
    # Ein fehlgeschlagenes Zweitziel darf den Bau nicht kippen: die App läuft
    # dann eben nur auf der Architektur, die durchgelaufen ist.
    echo "WARNUNG: Bau für ${target} fehlgeschlagen — wird übersprungen." >&2
  fi
done

if [[ ${#BUILT_TARGETS[@]} -eq 0 ]]; then
  echo "ABBRUCH: kein einziges Ziel gebaut." >&2
  exit 1
fi

mkdir -p "${OUT}"
for bin in hbbs hbbr; do
  inputs=()
  for target in "${BUILT_TARGETS[@]}"; do
    inputs+=("${SRC}/target/${target}/release/${bin}")
  done
  lipo -create -output "${OUT}/${bin}" "${inputs[@]}"
  chmod 755 "${OUT}/${bin}"
done

echo ""
echo "==> Fertig:"
for bin in hbbs hbbr; do
  printf '    %-5s %s\n' "${bin}" "$(lipo -info "${OUT}/${bin}" | sed 's/.*: //')"
  # Keine Fremdbibliotheken: alles außer /usr/lib und /System/Library wäre eine
  # Laufzeitabhängigkeit und damit ein Portabilitätsfehler. Bei Fat-Binaries
  # schreibt otool je Architektur eine Kopfzeile — nur die eingerückten
  # Bibliothekszeilen zählen, sonst schlägt die Prüfung immer an.
  foreign="$(otool -L "${OUT}/${bin}" | grep -E '^[[:space:]]+/' \
             | grep -vE '^[[:space:]]+(/usr/lib/|/System/Library/)' || true)"
  if [[ -n "${foreign}" ]]; then
    echo "    WARNUNG: ${bin} verweist auf Bibliotheken außerhalb des Systems:" >&2
    printf '%s\n' "${foreign}" >&2
  fi
done
