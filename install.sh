#!/usr/bin/env bash
set -euo pipefail

PACKAGE_NAME="etcd-cluster"
DEFAULT_REGISTRY="sealos.hub:5000/kube4"
DEFAULT_NAMESPACE="etcd-cluster"
DEFAULT_REPLICAS="3"
DEFAULT_STORAGE_SIZE="10Gi"
DEFAULT_WAIT_TIMEOUT="300s"
DEFAULT_SERVICE_TYPE="ClusterIP"

ACTION="${1:-help}"
if [[ $# -gt 0 ]]; then shift; fi

REGISTRY="${DEFAULT_REGISTRY}"
REGISTRY_USER=""
REGISTRY_PASS=""
NAMESPACE="${DEFAULT_NAMESPACE}"
REPLICAS="${DEFAULT_REPLICAS}"
STORAGE_SIZE="${DEFAULT_STORAGE_SIZE}"
STORAGE_CLASS=""
WAIT_TIMEOUT="${DEFAULT_WAIT_TIMEOUT}"
SERVICE_TYPE="${DEFAULT_SERVICE_TYPE}"
NODEPORT_CLIENT=""
CLUSTER_TOKEN="etcd-cluster-token"
SKIP_IMAGE_PREPARE=0
YES=0
DELETE_PVC=0
DELETE_NAMESPACE=0
WORKDIR=""
IMAGE_INDEX=""

usage() {
  cat <<USAGE
Usage:
  ./etcd-cluster-<version>-<arch>.run install [options]
  ./etcd-cluster-<version>-<arch>.run status [options]
  ./etcd-cluster-<version>-<arch>.run uninstall [options]
  ./etcd-cluster-<version>-<arch>.run help

Actions:
  install      Extract payload, load/tag/push image, render manifests, and install etcd.
  status       Show etcd resources and endpoint health.
  uninstall    Delete etcd workload resources. PVCs are kept unless --delete-pvc is set.
  help         Show this help.

Options:
  --registry <repo-prefix>       Target internal registry prefix. Default: ${DEFAULT_REGISTRY}
  --registry-user <user>         Registry username for docker login.
  --registry-pass <pass>         Registry password for docker login.
  --skip-image-prepare           Skip docker load/tag/push; still render image to --registry prefix.
  -n, --namespace <namespace>    Kubernetes namespace. Default: ${DEFAULT_NAMESPACE}
  --replicas <1|3|5|...>         Initial member count. Default: ${DEFAULT_REPLICAS}
  --storage-size <size>          PVC size per member. Default: ${DEFAULT_STORAGE_SIZE}
  --storage-class <class>        Optional StorageClass name. Omit to use cluster default.
  --service-type <type>          Client service type: ClusterIP, NodePort, or LoadBalancer. Default: ClusterIP
  --nodeport-client <port>       Optional fixed NodePort for client port 2379.
  --cluster-token <token>        etcd initial cluster token. Default: etcd-cluster-token
  --wait-timeout <duration>      kubectl rollout wait timeout. Default: ${DEFAULT_WAIT_TIMEOUT}
  --delete-pvc                   During uninstall, also delete etcd PVCs.
  --delete-namespace             During uninstall, also delete the namespace.
  -y, --yes                      Do not ask for confirmation.
  -h, --help                     Show this help.

Examples:
  ./etcd-cluster-3.6.10-amd64.run install \
    --registry sealos.hub:5000/kube4 \
    --registry-user admin \
    --registry-pass 'passw0rd' \
    -n etcd-cluster \
    --storage-class nfs-client \
    --storage-size 20Gi \
    -y

  ./etcd-cluster-3.6.10-amd64.run status -n etcd-cluster
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry) REGISTRY="${2:-}"; shift 2 ;;
    --registry-user) REGISTRY_USER="${2:-}"; shift 2 ;;
    --registry-pass) REGISTRY_PASS="${2:-}"; shift 2 ;;
    --skip-image-prepare) SKIP_IMAGE_PREPARE=1; shift ;;
    -n|--namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --replicas) REPLICAS="${2:-}"; shift 2 ;;
    --storage-size) STORAGE_SIZE="${2:-}"; shift 2 ;;
    --storage-class) STORAGE_CLASS="${2:-}"; shift 2 ;;
    --service-type) SERVICE_TYPE="${2:-}"; shift 2 ;;
    --nodeport-client) NODEPORT_CLIENT="${2:-}"; shift 2 ;;
    --cluster-token) CLUSTER_TOKEN="${2:-}"; shift 2 ;;
    --wait-timeout) WAIT_TIMEOUT="${2:-}"; shift 2 ;;
    --delete-pvc) DELETE_PVC=1; shift ;;
    --delete-namespace) DELETE_NAMESPACE=1; shift ;;
    -y|--yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "${ACTION}" in install|status|uninstall|help) ;; *) die "unknown action: ${ACTION}" ;; esac
if [[ "${ACTION}" == "help" ]]; then usage; exit 0; fi

[[ -n "${REGISTRY}" ]] || die "--registry cannot be empty"
[[ -n "${NAMESPACE}" ]] || die "--namespace cannot be empty"
[[ "${REPLICAS}" =~ ^[0-9]+$ ]] || die "--replicas must be a positive integer"
[[ "${REPLICAS}" -ge 1 ]] || die "--replicas must be >= 1"
case "${SERVICE_TYPE}" in ClusterIP|NodePort|LoadBalancer) ;; *) die "--service-type must be ClusterIP, NodePort, or LoadBalancer" ;; esac
if [[ -n "${NODEPORT_CLIENT}" && "${SERVICE_TYPE}" != "NodePort" ]]; then
  die "--nodeport-client requires --service-type NodePort"
fi

payload_start_offset() {
  local marker_line payload_offset skip_bytes byte_hex
  marker_line="$(awk '/^__PAYLOAD_BELOW__$/ { print NR; exit }' "$0")"
  [[ -n "${marker_line}" ]] || die "Payload marker not found"
  payload_offset="$(( $(head -n "${marker_line}" "$0" | wc -c | tr -d ' ') + 1 ))"
  skip_bytes=0
  while :; do
    byte_hex="$(dd if="$0" bs=1 skip="$((payload_offset + skip_bytes - 1))" count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    case "${byte_hex}" in
      0a|0d) skip_bytes=$((skip_bytes + 1)) ;;
      "") die "Payload is empty" ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$((payload_offset + skip_bytes))"
}

extract_payload() {
  WORKDIR="$(mktemp -d -t ${PACKAGE_NAME}.XXXXXX)"
  IMAGE_INDEX="${WORKDIR}/images/image-index.tsv"
  trap 'rm -rf "${WORKDIR:-}"' EXIT
  tail -c +"$(payload_start_offset)" "$0" | tar -xzf - -C "${WORKDIR}" || die "failed to extract payload"
  [[ -f "${IMAGE_INDEX}" ]] || die "payload missing images/image-index.tsv"
  [[ -f "${WORKDIR}/manifests/etcd-cluster.yaml.tmpl" ]] || die "payload missing manifests/etcd-cluster.yaml.tmpl"
}

confirm() {
  [[ "${YES}" == "1" ]] && return 0
  echo "About to ${ACTION} etcd in namespace '${NAMESPACE}'."
  if [[ "${ACTION}" == "uninstall" && "${DELETE_PVC}" == "1" ]]; then
    echo "WARNING: --delete-pvc will delete etcd data volumes."
  fi
  read -r -p "Continue? [y/N] " answer
  [[ "${answer}" == "y" || "${answer}" == "Y" ]] || die "aborted"
}

retarget_image() {
  local default_ref="$1"
  local suffix
  if [[ "${default_ref}" == sealos.hub:5000/kube4/* ]]; then
    suffix="${default_ref#sealos.hub:5000/kube4/}"
  else
    suffix="${default_ref#*/}"
  fi
  printf '%s/%s\n' "${REGISTRY%/}" "${suffix}"
}

image_ref_by_name() {
  local wanted="$1"
  awk -F'|' -v name="${wanted}" 'NR > 1 && $1 == name { print $4; exit }' "${IMAGE_INDEX}"
}

target_ref_by_name() {
  local wanted="$1" default_ref
  default_ref="$(image_ref_by_name "${wanted}")"
  [[ -n "${default_ref}" ]] || die "image not found in index: ${wanted}"
  retarget_image "${default_ref}"
}

prepare_images() {
  [[ "${SKIP_IMAGE_PREPARE}" == "1" ]] && { info "skip image prepare"; return 0; }
  need docker

  if [[ -n "${REGISTRY_USER}" || -n "${REGISTRY_PASS}" ]]; then
    [[ -n "${REGISTRY_USER}" && -n "${REGISTRY_PASS}" ]] || die "both --registry-user and --registry-pass are required for docker login"
    local login_host="${REGISTRY%%/*}"
    info "docker login ${login_host}"
    printf '%s' "${REGISTRY_PASS}" | docker login "${login_host}" -u "${REGISTRY_USER}" --password-stdin
  fi

  tail -n +2 "${IMAGE_INDEX}" | while IFS='|' read -r name tar_name load_ref default_ref platform pull dockerfile; do
    [[ -n "${name}" ]] || continue
    local tar_path="${WORKDIR}/images/${tar_name}"
    local target_ref
    [[ -f "${tar_path}" ]] || die "image tar not found: ${tar_path}"
    target_ref="$(retarget_image "${default_ref}")"
    info "docker load ${tar_name}"
    docker load -i "${tar_path}"
    if [[ "${load_ref}" != "${target_ref}" ]]; then
      info "docker tag ${load_ref} ${target_ref}"
      docker tag "${load_ref}" "${target_ref}"
    fi
    info "docker push ${target_ref}"
    docker push "${target_ref}"
  done
}

escape_sed() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

initial_cluster_string() {
  local i=0
  local cluster=""
  local member=""
  while [[ "${i}" -lt "${REPLICAS}" ]]; do
    member="etcd-${i}=http://etcd-${i}.etcd-headless.${NAMESPACE}.svc.cluster.local:2380"
    if [[ -z "${cluster}" ]]; then
      cluster="${member}"
    else
      cluster="${cluster},${member}"
    fi
    i=$((i + 1))
  done
  printf '%s\n' "${cluster}"
}

render_manifest() {
  local etcd_image rendered storage_class_line nodeport_line initial_cluster
  etcd_image="$(target_ref_by_name etcd)"
  rendered="${WORKDIR}/rendered-etcd-cluster.yaml"
  storage_class_line=""
  nodeport_line=""
  initial_cluster="$(initial_cluster_string)"

  if [[ -n "${STORAGE_CLASS}" ]]; then
    storage_class_line="    storageClassName: ${STORAGE_CLASS}"
  fi
  if [[ -n "${NODEPORT_CLIENT}" ]]; then
    nodeport_line="    nodePort: ${NODEPORT_CLIENT}"
  fi

  sed \
    -e "s/__NAMESPACE__/$(escape_sed "${NAMESPACE}")/g" \
    -e "s/__ETCD_IMAGE__/$(escape_sed "${etcd_image}")/g" \
    -e "s/__REPLICAS__/$(escape_sed "${REPLICAS}")/g" \
    -e "s/__INITIAL_CLUSTER__/$(escape_sed "${initial_cluster}")/g" \
    -e "s/__STORAGE_SIZE__/$(escape_sed "${STORAGE_SIZE}")/g" \
    -e "s/__SERVICE_TYPE__/$(escape_sed "${SERVICE_TYPE}")/g" \
    -e "s/__CLUSTER_TOKEN__/$(escape_sed "${CLUSTER_TOKEN}")/g" \
    -e "s|__STORAGE_CLASS_LINE__|$(escape_sed "${storage_class_line}")|g" \
    -e "s|__NODEPORT_CLIENT_LINE__|$(escape_sed "${nodeport_line}")|g" \
    "${WORKDIR}/manifests/etcd-cluster.yaml.tmpl" > "${rendered}"

  sed -i '/^[[:space:]]*$/d' "${rendered}"
  printf '%s\n' "${rendered}"
}

warn_replica_shape() {
  if (( REPLICAS % 2 == 0 )); then
    echo "WARNING: even replica counts are not recommended for etcd quorum. Prefer 1, 3, or 5."
  fi
  if (( REPLICAS > 5 )); then
    echo "WARNING: large etcd clusters have higher consensus overhead. 3 or 5 is usually enough."
  fi
}

install_app() {
  need kubectl
  extract_payload
  confirm
  warn_replica_shape
  prepare_images
  local rendered
  rendered="$(render_manifest)"
  info "kubectl apply -f rendered manifest"
  kubectl apply -f "${rendered}"
  info "waiting for statefulset/etcd"
  kubectl rollout status statefulset/etcd -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
  info "waiting for pods to be Ready"
  kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=etcd -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
  status_app
}

status_app() {
  need kubectl
  echo "Namespace: ${NAMESPACE}"
  kubectl get pods,svc,statefulset,pvc -n "${NAMESPACE}" -l app.kubernetes.io/name=etcd || true
  echo
  echo "etcd endpoint status from etcd-0:"
  kubectl exec -n "${NAMESPACE}" etcd-0 -- /usr/local/bin/etcdctl --endpoints=http://127.0.0.1:2379 endpoint status --cluster -w table 2>/dev/null || true
  echo
  echo "etcd endpoint health from etcd-0:"
  kubectl exec -n "${NAMESPACE}" etcd-0 -- /usr/local/bin/etcdctl --endpoints=http://127.0.0.1:2379 endpoint health --cluster 2>/dev/null || true
}

uninstall_app() {
  need kubectl
  extract_payload
  confirm
  local rendered
  rendered="$(render_manifest)"
  info "kubectl delete -f rendered manifest"
  kubectl delete -f "${rendered}" --ignore-not-found=true || true
  if [[ "${DELETE_PVC}" == "1" ]]; then
    info "delete etcd PVCs in namespace ${NAMESPACE}"
    kubectl delete pvc -n "${NAMESPACE}" -l app.kubernetes.io/name=etcd --ignore-not-found=true || true
  else
    info "PVCs kept. Use --delete-pvc only when you really want to delete etcd data."
  fi
  if [[ "${DELETE_NAMESPACE}" == "1" ]]; then
    info "delete namespace ${NAMESPACE}"
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true || true
  else
    info "namespace kept: ${NAMESPACE}"
  fi
}

case "${ACTION}" in
  install) install_app ;;
  status) status_app ;;
  uninstall) uninstall_app ;;
esac

exit 0
__PAYLOAD_BELOW__
