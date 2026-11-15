#!/usr/bin/env bash
# Inventario de recursos del proyecto en Azure y AWS
#
# Parte 1: recursos con la etiqueta proyecto=<PROYECTO>, agrupados por nube y entorno.
# Parte 2: recursos etiquetados que no son de la capa base (entorno distinto de "base"). Al terminar
#          una sesión no debe quedar ninguno.
# Parte 3: servicios de costo relevante activos (AKS, bases de datos, balanceadores, NAT, etc.), consultados directamente en cada nube sin usar etiquetas.
#          Detecta lo que Kubernetes crea por su cuenta (balanceadores, discos, IP) y que Terraform no conoce.
#
# Requisitos: sesión iniciada con az y con aws, y jq instalado.
# Variables opcionales: PROYECTO (tfm-unir), AWS_REGION (us-east-1), SALIDA (prefijo del archivo de resultados).
# Código de salida: 0 si no hay residuales, 1 si los hay, 2 si falta una herramienta, 3 si alguna consulta falló y no se pudo verificar.

set -uo pipefail

PROYECTO="${PROYECTO:-tfm-unir}"
AWS_REGION="${AWS_REGION:-us-east-1}"
SALIDA="${SALIDA:-inventario-$(date +%Y%m%d-%H%M%S)}"

for herramienta in az aws jq; do
  command -v "$herramienta" >/dev/null 2>&1 || { echo "Falta la herramienta: $herramienta" >&2; exit 2; }
done

inventario="$(mktemp)"
trap 'rm -f "$inventario"' EXIT
printf 'nube\tentorno\tejecucion\ttipo\tnombre\tgrupo\n' > "$inventario"

# ---------- Parte 1: inventario por etiquetas ----------
fallos=0

echo "Consultando Azure..." >&2
if az_recursos=$(az resource list --tag "proyecto=${PROYECTO}" -o json 2>/dev/null) \
   && az_grupos=$(az group list --tag "proyecto=${PROYECTO}" -o json 2>/dev/null); then
  printf '%s\n%s\n' "$az_recursos" "$az_grupos" \
    | jq -rs '.[] | .[]? | ["azure", (.tags.entorno // "sin-entorno"), (.tags.ejecucion // "-"), .type, .name, (.resourceGroup // .name)] | @tsv' \
    >> "$inventario"
else
  echo "Aviso: no se pudo consultar Azure (revisar az login y la suscripción)." >&2
  fallos=$((fallos + 1))
fi

echo "Consultando AWS..." >&2
if aws_json=$(aws resourcegroupstaggingapi get-resources --region "$AWS_REGION" \
    --tag-filters "Key=proyecto,Values=${PROYECTO}" --output json 2>/dev/null); then
  printf '%s\n' "$aws_json" \
    | jq -r '.ResourceTagMappingList[]
        | (.Tags | map({(.Key): .Value}) | add) as $t
        | ["aws", ($t.entorno // "sin-entorno"), ($t.ejecucion // "-"),
           (.ResourceARN | split(":")[2]), (.ResourceARN | split(":")[5:] | join(":")), "-"] | @tsv' \
    >> "$inventario"
else
  echo "Aviso: no se pudo consultar AWS (revisar las credenciales y la región)." >&2
  fallos=$((fallos + 1))
fi

archivo="${SALIDA}.tsv"
cp "$inventario" "$archivo"

echo
echo "== 1. Recursos con la etiqueta proyecto=${PROYECTO} =="
total=$(($(wc -l < "$inventario") - 1))
echo "Total: ${total}"
awk -F'\t' 'NR > 1 { c[$1 "  " $2]++ } END { for (k in c) printf "  %-30s %d\n", k, c[k] }' "$inventario" | sort

# ---------- Parte 2: residuales etiquetados ----------
echo
echo "== 2. Recursos etiquetados fuera de la capa base =="
residuales=$(awk -F'\t' 'NR > 1 && $2 != "base"' "$inventario")
if [[ -n "$residuales" ]]; then
  printf '%s\n' "$residuales" | awk -F'\t' '{ printf "  %-6s %-14s %-12s %-45s %s\n", $1, $2, $3, $4, $5 }'
  n_residuales=$(printf '%s\n' "$residuales" | wc -l)
else
  echo "  Ninguno."
  n_residuales=0
fi

# ---------- Parte 3: servicios de costo relevante activos, sin usar etiquetas ----------
activos=0
revisar() {
  local descripcion="$1"; shift
  local salida errores
  errores="$(mktemp)"
  if ! salida=$("$@" 2>"$errores"); then
    echo "  Aviso: no se pudo consultar ${descripcion}: $(grep -v '^$' "$errores" | head -n 2 | tr '\n' ' ' | cut -c1-300)"
    fallos=$((fallos + 1))
    rm -f "$errores"
    return
  fi
  rm -f "$errores"
  salida=$(printf '%s\n' "$salida" | grep -v -e '^$' -e '^None$' || true)
  [[ -z "$salida" ]] && return
  while IFS= read -r linea; do
    echo "  ${descripcion}: ${linea}"
    activos=$((activos + 1))
  done <<< "$salida"
}
aws_lista() { aws "$@" --region "$AWS_REGION" --output text | tr '\t' '\n'; }

echo
echo "== 3. Servicios de costo relevante activos (la capa base no crea ninguno de estos) =="
revisar "azure aks" az aks list --query "[].name" -o tsv
revisar "azure postgresql" az postgres flexible-server list --query "[].name" -o tsv
revisar "azure balanceador" az network lb list --query "[].name" -o tsv
revisar "azure ip publica" az network public-ip list --query "[].name" -o tsv
revisar "azure nat" az network nat gateway list --query "[].name" -o tsv
revisar "azure vnet" az network vnet list --query "[].name" -o tsv
revisar "azure disco" az resource list --resource-type Microsoft.Compute/disks --query "[].name" -o tsv
revisar "aws eks" aws_lista eks list-clusters --query "clusters[]"
revisar "aws rds" aws_lista rds describe-db-instances --query "DBInstances[].DBInstanceIdentifier"
revisar "aws nat" aws_lista ec2 describe-nat-gateways --filter "Name=state,Values=pending,available" --query "NatGateways[].NatGatewayId"
revisar "aws balanceador" aws_lista elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerName"
revisar "aws balanceador clasico" aws_lista elb describe-load-balancers --query "LoadBalancerDescriptions[].LoadBalancerName"
revisar "aws ip elastica" aws_lista ec2 describe-addresses --query "Addresses[].PublicIp"
revisar "aws instancia" aws_lista ec2 describe-instances --filters "Name=instance-state-name,Values=pending,running" --query "Reservations[].Instances[].InstanceId"
revisar "aws volumen sin adjuntar" aws_lista ec2 describe-volumes --filters "Name=status,Values=available" --query "Volumes[].VolumeId"
revisar "aws vpc" aws_lista ec2 describe-vpcs --filters "Name=is-default,Values=false" --query "Vpcs[].VpcId"
[[ "$activos" -eq 0 && "$fallos" -eq 0 ]] && echo "  Ninguno."

# ---------- Resultado ----------
echo
echo "Detalle guardado en ${archivo}"
if [[ "$n_residuales" -gt 0 || "$activos" -gt 0 ]]; then
  echo "RESULTADO: hay recursos residuales (${n_residuales} etiquetados, ${activos} servicios activos)."
  exit 1
fi
if [[ "$fallos" -gt 0 ]]; then
  echo "RESULTADO: no se pudo verificar todo (${fallos} consultas fallaron). No se puede afirmar que no haya residuales."
  exit 3
fi
echo "RESULTADO: sin recursos residuales."
exit 0