#!/usr/bin/env bash
#
# Build a patched codex CLI for linux/arm64 and linux/amd64 and leave the two
# binaries in the directory you ran this from.
#
#   ./build.sh --version 0.146.0
#   ./build.sh --version 0.146.0 --arch arm64      # just one
#   ./build.sh --version 0.146.0 --keep            # leave the builders running
#
# What it does: clones codex at tag rust-v<version>, applies patches/<version>.patch,
# launches one EC2 builder per architecture, builds NATIVELY on each (no
# cross-compilation, no qemu), pulls the binaries back, and terminates
# everything -- including on Ctrl-C or error.
#
# Requires: aws cli (authenticated), ssh, scp, curl. No local Rust or Docker.
#
# Expect ~15 minutes. Most of it is the final link: codex's release profile uses
# thin LTO across ~1000 crates, so the crate counter sits still for several
# minutes at the end. That is not a hang.
set -euo pipefail

VERSION=""; ARCHES="arm64 amd64"; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --arch)    ARCHES="${2:?--arch needs a value}"; shift 2 ;;
    --keep)    KEEP=1; shift ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$VERSION" ] || { echo "error: --version is required (e.g. --version 0.146.0)" >&2; exit 2; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$PWD"                       # binaries land where you invoked the script
PATCH="$REPO_DIR/patches/${VERSION}.patch"
TAG="rust-v${VERSION}"

[ -f "$PATCH" ] || {
  echo "error: no patch for $VERSION at $PATCH" >&2
  echo "available:" >&2; ls "$REPO_DIR/patches/" 2>/dev/null | sed 's/\.patch$//' | sed 's/^/  /' >&2
  exit 1
}

RUST_IMAGE="rust:1-trixie"           # trixie = the glibc our workspaces run
declare -A ITYPE=( [arm64]=c7g.4xlarge [amd64]=c7i.4xlarge )
declare -A AMIPAT=(
  [arm64]='ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*'
  [amd64]='ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*'
)
STAMP="codex-build-$$-$(date +%s)"
PEM="$(mktemp -t codex-build-XXXXXX)"
# LogLevel=ERROR suppresses the "Permanently added ... to known hosts" warning
# that UserKnownHostsFile=/dev/null otherwise prints on every single call.
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 -i $PEM"
INSTANCE_IDS=(); SG_ID=""

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }

cleanup() {
  local rc=$?
  if [ ${#INSTANCE_IDS[@]} -gt 0 ]; then
    if [ "$KEEP" = "1" ]; then
      warn "--keep set; instances still running: ${INSTANCE_IDS[*]}"
      warn "  ssh -i $PEM ubuntu@<ip>   (key NOT deleted)"
      warn "  aws ec2 terminate-instances --instance-ids ${INSTANCE_IDS[*]}"
      trap - EXIT; exit $rc
    fi
    log "Terminating ${INSTANCE_IDS[*]}"
    aws ec2 terminate-instances --instance-ids "${INSTANCE_IDS[@]}" >/dev/null 2>&1 || true
    aws ec2 wait instance-terminated --instance-ids "${INSTANCE_IDS[@]}" 2>/dev/null || true
  fi
  [ -n "$SG_ID" ] && aws ec2 delete-security-group --group-id "$SG_ID" >/dev/null 2>&1 || true
  aws ec2 delete-key-pair --key-name "$STAMP" >/dev/null 2>&1 || true
  rm -f "$PEM"
  exit $rc
}
# Terminate on any exit path -- an idle c7i is ~$0.71/hour.
trap cleanup EXIT INT TERM

for tool in aws ssh scp curl; do
  command -v "$tool" >/dev/null || { echo "error: '$tool' not found" >&2; exit 1; }
done
aws sts get-caller-identity >/dev/null 2>&1 || {
  echo "error: aws cli is not authenticated (try 'aws configure' or set AWS_PROFILE)" >&2; exit 1; }

log "Building codex $VERSION ($TAG) for: $ARCHES"
echo "patch:  $PATCH"
echo "output: $OUT_DIR"

log "Provisioning key pair and security group"
aws ec2 create-key-pair --key-name "$STAMP" --query KeyMaterial --output text > "$PEM"
chmod 600 "$PEM"
SG_ID=$(aws ec2 create-security-group --group-name "$STAMP" \
  --description "temporary codex build" --query GroupId --output text)
MYIP=$(curl -fsS https://checkip.amazonaws.com | tr -d '\n')
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
  --protocol tcp --port 22 --cidr "${MYIP}/32" >/dev/null
echo "ssh locked to ${MYIP}/32"

USERDATA=$(mktemp)
cat > "$USERDATA" <<'EOF'
#!/bin/bash
set -eux
apt-get update -qq
# binutils: the minimal AMI has no `strip`, and unstripped binaries are ~5x larger.
apt-get install -y -qq docker.io git binutils >/dev/null
systemctl start docker
usermod -aG docker ubuntu
touch /tmp/READY
EOF

declare -A IP_OF
for arch in $ARCHES; do
  log "Launching $arch builder (${ITYPE[$arch]})"
  ami=$(aws ec2 describe-images --owners amazon \
    --filters "Name=name,Values=${AMIPAT[$arch]}" "Name=state,Values=available" \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
  iid=$(aws ec2 run-instances --image-id "$ami" --instance-type "${ITYPE[$arch]}" \
    --key-name "$STAMP" --security-group-ids "$SG_ID" \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=60,VolumeType=gp3}' \
    --user-data "file://$USERDATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$STAMP-$arch}]" \
    --query 'Instances[0].InstanceId' --output text)
  INSTANCE_IDS+=("$iid"); IP_OF[$arch]="$iid"
  echo "$arch -> $iid"
done
rm -f "$USERDATA"

log "Waiting for instances to boot"
aws ec2 wait instance-running --instance-ids "${INSTANCE_IDS[@]}"
for arch in $ARCHES; do
  IP_OF[$arch]=$(aws ec2 describe-instances --instance-ids "${IP_OF[$arch]}" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  echo "$arch -> ${IP_OF[$arch]}"
done

for arch in $ARCHES; do
  for _ in $(seq 1 40); do
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "ubuntu@${IP_OF[$arch]}" 'test -f /tmp/READY' 2>/dev/null && break
    sleep 15
  done
done
echo "builders ready"

# Start every arch before waiting on any, so they run concurrently.
for arch in $ARCHES; do
  ip="${IP_OF[$arch]}"
  log "Starting $arch build"

  # Write the remote build script here and copy it over, rather than embedding
  # it in the ssh command string. A heredoc nested inside a remote shell string
  # needs three levels of escaping, and getting it wrong is silent: an earlier
  # version emitted the literal text `BUILD_EXIT=$rc` instead of the exit code,
  # so a successful build reported itself as a failure. One level of quoting is
  # worth the extra scp.
  RUNSH=$(mktemp)
  cat > "$RUNSH" <<RUNEOF
#!/usr/bin/env bash
set -uxo pipefail
docker run --rm --platform linux/$arch \\
  -v "\$HOME/codex:/src" -v "\$HOME/cargo-reg:/usr/local/cargo/registry" \\
  -w /src/codex-rs $RUST_IMAGE bash -c '
    set -ex
    apt-get update -qq
    apt-get install -y -qq pkg-config libssl-dev cmake clang libclang-dev >/dev/null
    cargo test -p codex-tui --lib minds_
    cargo build --release -p codex-cli --bin codex
    # Smoke-test natively on the matching arch: proves the binary actually runs
    # and reports the version we built, rather than only that it linked.
    /src/codex-rs/target/release/codex --version
  '
rc=\$?
# Docker runs as root, so the artifact is root-owned; chown before we scp it.
sudo chown ubuntu:ubuntu \$HOME/codex/codex-rs/target/release/codex 2>/dev/null || true
echo "BUILD_EXIT=\$rc"
RUNEOF

  # shellcheck disable=SC2086
  scp $SSH_OPTS "$PATCH" "ubuntu@$ip:/tmp/change.patch" >/dev/null
  # shellcheck disable=SC2086
  scp $SSH_OPTS "$RUNSH" "ubuntu@$ip:run.sh" >/dev/null
  rm -f "$RUNSH"
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "ubuntu@$ip" "
    set -e
    git -c advice.detachedHead=false clone --depth=1 --branch '$TAG' -q \
      https://github.com/openai/codex.git \$HOME/codex
    cd \$HOME/codex && git apply /tmp/change.patch
    chmod +x \$HOME/run.sh
    nohup \$HOME/run.sh > \$HOME/build.log 2>&1 &
    disown
  "
done

for arch in $ARCHES; do
  ip="${IP_OF[$arch]}"
  log "Waiting on $arch"
  while true; do
    # shellcheck disable=SC2086
    st=$(ssh $SSH_OPTS "ubuntu@$ip" '
      if grep -q "^BUILD_EXIT=0" $HOME/build.log 2>/dev/null; then echo DONE
      elif grep -q "^BUILD_EXIT=" $HOME/build.log 2>/dev/null; then echo FAILED
      else c=$(grep -c Compiling $HOME/build.log 2>/dev/null || true); echo "${c:-0}"; fi' 2>/dev/null || echo "?")
    case "$st" in
      DONE)   printf '\r%s: build complete            \n' "$arch"; break ;;
      FAILED) printf '\r%s: FAILED\n' "$arch"
              # shellcheck disable=SC2086
              ssh $SSH_OPTS "ubuntu@$ip" 'tail -40 $HOME/build.log'; exit 1 ;;
      *)      printf '\r%s: %s crates compiled ' "$arch" "$st" ;;
    esac
    sleep 20
  done

  # sudo: cargo ran as root inside Docker, so target/release is root-owned and
  # strip needs to write its temp file into that directory. Do NOT silence this
  # -- an unstripped codex is 1.4GB against ~300MB stripped, and swallowing the
  # error just ships the 1.4GB one. Verify it actually shrank.
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "ubuntu@$ip" '
    set -e
    bin=$HOME/codex/codex-rs/target/release/codex
    before=$(stat -c %s "$bin")
    sudo strip -s "$bin"
    sudo chown ubuntu:ubuntu "$bin"
    after=$(stat -c %s "$bin")
    [ "$after" -lt "$before" ] || { echo "strip did not shrink the binary" >&2; exit 1; }
    echo "stripped: $((before/1000000))MB -> $((after/1000000))MB"'
  # shellcheck disable=SC2086
  scp $SSH_OPTS "ubuntu@$ip:codex/codex-rs/target/release/codex" \
    "$OUT_DIR/codex-linux-$arch" >/dev/null
  chmod +x "$OUT_DIR/codex-linux-$arch"
  # shellcheck disable=SC2086
  echo "-> $OUT_DIR/codex-linux-$arch  (reports: $(ssh $SSH_OPTS "ubuntu@$ip" \
    'grep -m1 "^codex-cli " $HOME/build.log' 2>/dev/null || echo unknown))"
done

log "Done"
cd "$OUT_DIR"
# setup_system.sh verifies every downloaded binary against a pinned sha256, so
# emit the sums here rather than making whoever cuts the release compute them.
sha256sum codex-linux-* | tee SHA256SUMS
ls -lh codex-linux-*
