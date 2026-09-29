# Every command is pinned to the research cluster context so a stale
# KUBECONFIG can never point a mutation at any other cluster.
export KUBECONFIG=/tmp/sorami-lab-cluster-kubeconfig
export AWS_REGION=ap-southeast-2
K="kubectl --context sorami-lab"
H="helm --kube-context sorami-lab"
guard(){ [ "$($K config current-context)" = sorami-lab ] && $K get ns kube-system -o jsonpath='{.metadata.uid}' >/dev/null || { echo "CONTEXT GUARD FAILED"; exit 99; }
  srv=$($K config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  exp=$(aws eks describe-cluster --name sorami-lab --query cluster.endpoint --output text)
  [ "$srv" = "$exp" ] || { echo "ENDPOINT GUARD FAILED $srv != $exp"; exit 99; }; }
log(){ local n="$1"; shift; { echo "# UTC $(date -u +%FT%TZ)"; echo "# CMD: $*"; echo; eval "$@" 2>&1; echo "# EXIT: $?"; } > "$R/$n.log"; tail -3 "$R/$n.log"; }
redact(){ sed -i '' -E 's/ASIA[A-Z0-9]{16}/ASIA****REDACTED****/g; s/AROA[A-Z0-9]{17}/AROA****REDACTED****/g; s/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/email-redacted/g; s/hf_[A-Za-z0-9]{20,}/hf_****REDACTED****/g' "$R"/*.log; }
