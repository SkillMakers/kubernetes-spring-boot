#!/usr/bin/env bash
# Joue chaque scénario de la vidéo sur le cluster kind « demo » et écrit les sorties dans preuves/.
# Prérequis : Docker, kind, le cluster créé par `kind create cluster --name demo --config kind-cluster.yaml`,
# et l'image construite (`./mvnw package` puis `docker build -t orders:1.0 .`).
# `ETAPE=7 ./demo.sh` rejoue seulement la mise à jour sans probe, `ETAPE=8 ./demo.sh` seulement la readiness probe
# (sur une appli déjà déployée ; la démo complète dépasse 10 minutes).
set -euo pipefail
cd "$(dirname "$0")"
# kubectl du nœud de contrôle : même version que le cluster.
k() { docker exec -i demo-control-plane kubectl "$@"; }
# Affiche la commande telle qu'on la tape, puis sa sortie.
run() { echo "\$ kubectl $*"; k "$@" 2>&1 || true; echo; }
duree() { awk -v t="$1" -v a="$2" -v b="$3" 'BEGIN{printf "# %s : %.1f s\n", t, b-a}'; }
dans_client() { k exec client -- sh -c "$1"; }
# Attend que l'appli réponde vraiment : sans probe, « disponible » pour Kubernetes ne veut pas dire « démarrée ».
# Abandonne au bout de 3 minutes plutôt que de tourner sans fin.
attendre_appli() {
  local limite=$(( $(date +%s) + 180 ))
  until dans_client "curl -sf -m 2 -o /dev/null ${1:-http://orders/info}" 2>/dev/null; do
    [ "$(date +%s)" -lt "$limite" ] || { echo "Pas de réponse de ${1:-http://orders/info} en 3 min" >&2; exit 1; }
    sleep 0.2
  done
}
# Adresses des pods de l'appli qui ne sont pas en cours d'arrêt.
pods_actifs() {
  k get pods -l app=orders -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{"|"}{.status.podIP}{"\n"}{end}' \
    | awk -F'|' '$1=="" && $2!="" {print $2}'
}
# Attend que chacun des pods actifs réponde, en l'interrogeant directement par son adresse IP.
attendre_tous() { sleep 2; for ip in $(pods_actifs); do attendre_appli "http://$ip:8080/info"; done; }
# Envoie une requête toutes les 0,1 s au Service, jusqu'à arreter_charge ; les codes HTTP vont dans /tmp/r.
lancer_charge() {
  dans_client 'rm -f /tmp/r /tmp/stop; nohup sh -c '"'"'while [ ! -f /tmp/stop ]; do curl -s -o /dev/null -m 2 -w "%{http_code}\n" http://orders/info >> /tmp/r; sleep 0.1; done'"'"' >/dev/null 2>&1 &'
}
arreter_charge() {
  dans_client 'touch /tmp/stop'; sleep 3
  echo "# Requêtes envoyées en continu pendant la mise à jour et le retour arrière (une toutes les 0,1 s) :"
  dans_client 'sort /tmp/r | uniq -c'
}
client_pret() {
  if [ "$(k get pod client -o jsonpath='{.status.phase}' 2>/dev/null)" != Running ]; then
    k delete pod client --ignore-not-found --now >/dev/null
    k run client --image=curlimages/curl:8.17.0 --restart=Never --command -- sleep infinity >/dev/null
    k wait --for=condition=Ready pod/client --timeout=120s >/dev/null
  fi
}

if [ "${ETAPE:-tout}" = tout ]; then
echo "== Préparation"
docker build -q -t orders:2.0 -f Dockerfile.v2 . >/dev/null
docker tag orders:1.0 orders:latest
kind load docker-image orders:1.0 orders:2.0 orders:latest --name demo >/dev/null
k delete deployment orders postgres essai-latest --ignore-not-found >/dev/null
k delete pod client --ignore-not-found --now >/dev/null
k delete secret orders-db --ignore-not-found >/dev/null
k delete configmap orders-config --ignore-not-found >/dev/null

echo "== 1. Le cluster"
{ run get nodes; } > preuves/01-cluster.txt

echo "== 2. Le piège du tag latest"
{
  echo "# L'image orders:latest est bien chargée sur le nœud :"
  echo "\$ docker exec demo-control-plane crictl images | grep orders"
  docker exec demo-control-plane crictl images | grep orders
  echo
  k create deployment essai-latest --image=orders:latest >/dev/null
  sleep 40
  run get pods -l app=essai-latest
  echo "\$ kubectl get deployment essai-latest -o jsonpath='{.spec.template.spec.containers[0].imagePullPolicy}'"
  k get deployment essai-latest -o jsonpath='{.spec.template.spec.containers[0].imagePullPolicy}'; echo; echo
  echo "\$ kubectl describe pod -l app=essai-latest | grep -A12 Events"
  k describe pod -l app=essai-latest | grep -A12 Events || true
  k delete deployment essai-latest >/dev/null
} > preuves/02-piege-latest.txt

echo "== 3. Secret, base et application"
{
  run create secret generic orders-db --from-literal=password=Sup3r-Secret
  run get secret orders-db -o jsonpath='{.data.password}'
  echo "\$ kubectl get secret orders-db -o jsonpath='{.data.password}' | base64 -d"
  k get secret orders-db -o jsonpath='{.data.password}' | base64 -d; echo; echo
} > preuves/03-secret.txt
k apply -f - < k8s/postgres.yaml >/dev/null
client_pret
# La base a sa readiness probe (pg_isready) : rollout status attend qu'elle accepte les connexions.
k rollout status deployment/postgres --timeout=180s >/dev/null
{
  echo "\$ kubectl apply -f k8s/orders.yaml"; k apply -f - < k8s/orders.yaml; echo
  debut=$(date +%s.%N)
  run rollout status deployment/orders --timeout=240s
  fin=$(date +%s.%N)
  duree "Du apply aux 3 pods disponibles" "$debut" "$fin"; echo
  echo "\$ curl -s http://orders/info   # aussitôt après"
  dans_client 'curl -s -m 2 http://orders/info; echo "code de sortie de curl : $?"' || true; echo
  attendre_appli
  fin2=$(date +%s.%N)
  duree "Du apply à la première réponse de l'appli" "$debut" "$fin2"; echo
  attendre_tous
  echo "\$ kubectl logs -l app=orders --prefix | grep Started"
  k logs -l app=orders --prefix | grep Started || true; echo
  run get pods -l app=orders -o wide
  run get service orders
} > preuves/04-deploiement.txt

echo "== 4. Le Service répartit les requêtes"
{
  echo "\$ for i in \$(seq 9); do curl -s http://orders/info; echo; done   # depuis un pod du cluster"
  dans_client 'for i in $(seq 9); do curl -s http://orders/info; echo; done'
  echo
  echo "\$ curl -s http://orders/commandes"
  dans_client 'curl -s http://orders/commandes'; echo
} > preuves/05-service.txt

echo "== 5. Un pod tué revient"
{
  run get pods -l app=orders
  victime=$(k get pods -l app=orders -o jsonpath='{.items[0].metadata.name}')
  debut=$(date +%s.%N)
  run delete pod "$victime" --wait=false
  # Le remplaçant : le pod le plus récent, différent de la victime, compté prêt par Kubernetes.
  limite=$(( $(date +%s) + 180 ))
  until remplacant=$(k get pods -l app=orders --sort-by=.metadata.creationTimestamp \
          -o jsonpath='{.items[-1:].metadata.name}') && [ "$remplacant" != "$victime" ] && \
        [ "$(k get pod "$remplacant" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]; do
    [ "$(date +%s)" -lt "$limite" ] || { echo "Pas de remplaçant prêt en 3 min" >&2; exit 1; }
    sleep 0.2
  done
  fin=$(date +%s.%N)
  attendre_appli "http://$(k get pod "$remplacant" -o jsonpath='{.status.podIP}'):8080/info"
  fin2=$(date +%s.%N)
  run get pods -l app=orders
  duree "Du delete au remplaçant « disponible » pour Kubernetes" "$debut" "$fin"
  duree "Du delete à la première réponse du remplaçant" "$debut" "$fin2"
} > preuves/06-pod-tue.txt

echo "== 6. Le ConfigMap modifié"
{
  echo "\$ kubectl patch configmap orders-config -p '{\"data\":{\"APP_MESSAGE\":\"Salut\"}}'"
  k patch configmap orders-config -p '{"data":{"APP_MESSAGE":"Salut"}}'; echo
  sleep 30
  echo "# 30 s plus tard :"
  echo "\$ curl -s http://orders/info"; dans_client 'curl -s http://orders/info'; echo; echo
  run rollout restart deployment/orders
  k rollout status deployment/orders --timeout=240s >/dev/null
  attendre_tous
  echo "\$ curl -s http://orders/info"; dans_client 'curl -s http://orders/info'; echo
} > preuves/07-configmap.txt

fi

if [ "${ETAPE:-tout}" = tout ] || [ "${ETAPE:-}" = 7 ]; then
echo "== 7. Mise à jour progressive et retour arrière"
client_pret
{
  lancer_charge
  sleep 3
  run set image deployment/orders orders=orders:2.0
  run rollout status deployment/orders --timeout=240s
  attendre_tous; sleep 20
  echo "\$ curl -s http://orders/info"; dans_client 'curl -s http://orders/info'; echo; echo
  run rollout history deployment/orders
  run rollout undo deployment/orders
  k rollout status deployment/orders --timeout=240s >/dev/null
  attendre_tous; sleep 20
  echo "\$ curl -s http://orders/info"; dans_client 'curl -s http://orders/info'; echo; echo
  arreter_charge
} > preuves/08-mise-a-jour.txt
fi

if [ "${ETAPE:-tout}" = tout ] || [ "${ETAPE:-}" = 8 ]; then
echo "== 8. La même mise à jour, avec une readiness probe"
client_pret
{
  echo "\$ kubectl patch deployment orders --patch-file k8s/readiness-patch.yaml"
  k patch deployment orders -p "$(cat k8s/readiness-patch.yaml)"; echo
  k rollout status deployment/orders --timeout=300s >/dev/null
  attendre_tous; sleep 5
  lancer_charge
  sleep 3
  run set image deployment/orders orders=orders:2.0
  run rollout status deployment/orders --timeout=300s
  attendre_tous; sleep 20
  run rollout undo deployment/orders
  k rollout status deployment/orders --timeout=300s >/dev/null
  attendre_tous; sleep 20
  arreter_charge
} > preuves/09-readiness.txt
fi
echo "Fini : preuves/"
