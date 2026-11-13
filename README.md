# Kubernetes : déployer une application Spring Boot

Code de la vidéo **Kubernetes : déployer une application Spring Boot** de la chaîne
[IT Skills Maker](https://www.youtube.com/@ItSkillsMaker), 1re vidéo de la série Kubernetes pour développeurs Java.

L'application de commandes de la vidéo Docker (Spring Boot 4.1, Java 25, PostgreSQL), déployée sur un vrai cluster
Kubernetes local. Chaque scénario de la vidéo a été joué pour de vrai : les sorties sont dans [`preuves/`](preuves/).

## Lancer

Il faut Docker, [kind](https://kind.sigs.k8s.io/) et kubectl.

```
./mvnw package
docker build -t orders:1.0 .
kind create cluster --name demo --config kind-cluster.yaml
bash demo.sh
```

`demo.sh` charge les images dans le cluster, joue chaque scénario et réécrit les fichiers de `preuves/`. Il passe par
le kubectl du nœud (`docker exec demo-control-plane kubectl`), pour avoir la même version que le cluster. La démo
complète prend plus de 10 minutes : `ETAPE=7 bash demo.sh` rejoue seulement la mise à jour sans probe, `ETAPE=8 bash demo.sh`
seulement la readiness probe (sur une application déjà déployée).

Pour tout supprimer : `kind delete cluster --name demo`.

## Les fichiers

| Fichier | Rôle |
|---|---|
| `kind-cluster.yaml` | un cluster d'un seul nœud (3 nœuds avec 3 copies de l'appli ne tenaient pas dans 16 Go de RAM) |
| `k8s/postgres.yaml` | la base : Deployment avec readiness probe `pg_isready`, et son Service |
| `k8s/orders.yaml` | l'application : ConfigMap, Deployment de 3 réplicas (mémoire demandée et limitée), Service |
| `k8s/readiness-patch.yaml` | la readiness probe sur `/actuator/health/readiness`, ajoutée par `kubectl patch` |
| `Dockerfile.v2` | la version 2 de l'image pour la mise à jour (seule la version affichée change) |
| `src/…/InfoController.java` | `GET /info` : quel pod a répondu, avec quelle version et quel message |

## Les preuves

Kubernetes 1.37.0 (kind v0.33.0, un nœud), Docker Desktop 29.3.1, le 13/11/2026.

| Fichier | Ce qu'il montre |
|---|---|
| `02-piege-latest.txt` | l'image `orders:latest` est sur le nœud, mais le pod reste en `ErrImagePull` / `ImagePullBackOff` : avec `:latest`, `imagePullPolicy` vaut `Always` |
| `03-secret.txt` | un Secret se relit en clair avec `base64 -d` : encodé, pas chiffré |
| `04-deploiement.txt` | 3 pods « disponibles » en 2,4 s, curl refusé juste après, première réponse à 49,2 s |
| `05-service.txt` | le Service répartit 9 requêtes sur les 3 pods |
| `06-pod-tue.txt` | un pod supprimé : remplaçant « disponible » en 4,7 s, il répond à 39,1 s |
| `07-configmap.txt` | un ConfigMap modifié n'est vu qu'après `rollout restart` |
| `08-mise-a-jour.txt` | mise à jour puis retour arrière sans probe : 557 requêtes en erreur sur 1 836 |
| `09-readiness.txt` | la même chose avec la readiness probe : 8 sur 1 935 |

Les durées dépendent de la machine : elles ont varié d'un passage à l'autre (démarrage de Spring Boot de 27 à 41 s).

## Ce que la démo simplifie

- **Un seul nœud.** En production, les pods sont répartis sur plusieurs machines.
- **PostgreSQL sans volume persistant.** Ses données disparaissent avec le pod. Une vraie base dans Kubernetes demande
  un StatefulSet et un volume, ou une base gérée hors du cluster.
- **`spring.jpa.hibernate.ddl-auto=update`.** Avec 3 réplicas qui démarrent ensemble, chacun tente de créer le schéma.
  En production, les migrations passent par Flyway ou Liquibase, lancées une seule fois.
- **Le Secret est créé en ligne de commande** avec un mot de passe de démo. En production : droits d'accès (RBAC),
  chiffrement au repos, ou un coffre externe.
- **Pas d'arrêt propre côté Kubernetes.** Les 8 erreurs restantes de `09-readiness.txt` viennent d'un pod retiré du
  Service au moment même où il s'arrête. La correction (`preStop`) est le sujet de la vidéo suivante.
- **La VM de Docker Desktop tournait en cgroup v1**, que le kubelet refuse par défaut depuis Kubernetes 1.35 : d'où
  `failCgroupV1: false` dans `kind-cluster.yaml`. Sur une machine en cgroup v2, cette ligne est inutile.
