#!/bin/bash
set -e

# ─── Configurações ────────────────────────────────────────────────────────────
CLUSTER="cluster-bia-alb"
SERVICE="service-bia-alb"
TASK_FAMILY="task-def-bia-alb"
ECR_URI="840315891475.dkr.ecr.us-east-1.amazonaws.com/bia"
REGION="us-east-1"
CONTAINER_NAME="bia"

# ─── Helpers ──────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Uso: $(basename "$0") <comando> [opções]

Comandos:
  deploy <commit-hash>        Registra nova task definition com a imagem tagueada
                              pelo commit hash e faz deploy no serviço ECS.

  rollback <task-def-arn>     Faz deploy de uma task definition específica.
                              Ex: task-def-bia-alb:3

  history                     Lista as últimas 10 revisões da task definition
                              com a imagem associada.

  status                      Mostra a task definition ativa no serviço.

  help                        Exibe esta mensagem.

Exemplos:
  $(basename "$0") deploy a1b2c3d
  $(basename "$0") rollback task-def-bia-alb:2
  $(basename "$0") history
  $(basename "$0") status
EOF
}

log()  { echo "[INFO]  $*"; }
err()  { echo "[ERROR] $*" >&2; exit 1; }

wait_stable() {
  log "Aguardando serviço estabilizar..."
  aws ecs wait services-stable \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    --region "$REGION"
  log "Serviço estável."
}

# ─── Comandos ─────────────────────────────────────────────────────────────────
cmd_deploy() {
  local COMMIT_HASH="$1"
  [[ -z "$COMMIT_HASH" ]] && err "Informe o commit hash. Ex: deploy a1b2c3d"

  local IMAGE="${ECR_URI}:${COMMIT_HASH}"
  log "Imagem alvo: $IMAGE"

  local CURRENT_TD
  CURRENT_TD=$(aws ecs describe-services \
    --cluster "$CLUSTER" --services "$SERVICE" \
    --region "$REGION" \
    --query 'services[0].taskDefinition' --output text)

  local NEW_TD_JSON
  NEW_TD_JSON=$(aws ecs describe-task-definition \
    --task-definition "$CURRENT_TD" \
    --region "$REGION" \
    --query 'taskDefinition' \
    | jq --arg img "$IMAGE" --arg cn "$CONTAINER_NAME" \
        '.containerDefinitions |= map(if .name == $cn then .image = $img else . end)
         | {family, networkMode, containerDefinitions, volumes, placementConstraints,
            requiresCompatibilities, cpu, memory, executionRoleArn, taskRoleArn}
         | with_entries(select(.value != null and .value != ""))' )

  log "Registrando nova task definition..."
  local NEW_TD_ARN
  NEW_TD_ARN=$(aws ecs register-task-definition \
    --region "$REGION" \
    --cli-input-json "$NEW_TD_JSON" \
    --query 'taskDefinition.taskDefinitionArn' --output text)

  log "Nova task definition: $NEW_TD_ARN"
  _update_service "$NEW_TD_ARN"
}

cmd_rollback() {
  local TARGET="$1"
  [[ -z "$TARGET" ]] && err "Informe a task definition. Ex: rollback task-def-bia-alb:2"

  aws ecs describe-task-definition --task-definition "$TARGET" --region "$REGION" > /dev/null \
    || err "Task definition '$TARGET' não encontrada."

  local TD_ARN
  TD_ARN=$(aws ecs describe-task-definition \
    --task-definition "$TARGET" --region "$REGION" \
    --query 'taskDefinition.taskDefinitionArn' --output text)

  log "Rollback para: $TD_ARN"
  _update_service "$TD_ARN"
}

cmd_history() {
  log "Últimas 10 revisões de $TASK_FAMILY:"
  local ARNS
  ARNS=$(aws ecs list-task-definitions \
    --family-prefix "$TASK_FAMILY" \
    --sort DESC --max-items 10 \
    --region "$REGION" \
    --query 'taskDefinitionArns[]' --output text)

  printf "%-60s  %s\n" "TASK DEFINITION" "IMAGEM"
  printf "%-60s  %s\n" "---------------" "------"
  for ARN in $ARNS; do
    local REV IMAGE
    REV=$(echo "$ARN" | awk -F: '{print $NF}')
    IMAGE=$(aws ecs describe-task-definition \
      --task-definition "$ARN" --region "$REGION" \
      --query "taskDefinition.containerDefinitions[?name=='${CONTAINER_NAME}'].image" \
      --output text)
    printf "%-60s  %s\n" "${TASK_FAMILY}:${REV}" "$IMAGE"
  done
}

cmd_status() {
  local ACTIVE_TD
  ACTIVE_TD=$(aws ecs describe-services \
    --cluster "$CLUSTER" --services "$SERVICE" \
    --region "$REGION" \
    --query 'services[0].taskDefinition' --output text)

  local IMAGE
  IMAGE=$(aws ecs describe-task-definition \
    --task-definition "$ACTIVE_TD" --region "$REGION" \
    --query "taskDefinition.containerDefinitions[?name=='${CONTAINER_NAME}'].image" \
    --output text)

  log "Task definition ativa: $ACTIVE_TD"
  log "Imagem em uso:         $IMAGE"
}

_update_service() {
  local TD_ARN="$1"
  aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --task-definition "$TD_ARN" \
    --region "$REGION" \
    --force-new-deployment > /dev/null

  log "Serviço atualizado. Aguardando estabilização..."
  wait_stable
  log "Deploy concluído com sucesso."
}

# ─── Entrypoint ───────────────────────────────────────────────────────────────
case "${1:-}" in
  deploy)   cmd_deploy   "$2" ;;
  rollback) cmd_rollback "$2" ;;
  history)  cmd_history       ;;
  status)   cmd_status        ;;
  help|--help|-h) usage       ;;
  *) usage; exit 1            ;;
esac
