#!/bin/bash

# ============================================================================
# SCRIPT PARA EXECUTAR DATASYNC FSx → S3
# ============================================================================
# Este script executa manualmente a sincronização do FSx para S3 usando DataSync
# ============================================================================

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configurações
PROJECT_NAME="fsx-compliance-poc"
REGION="us-east-1"

# Função para logging
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}✅${NC} $1"
}

error() {
    echo -e "${RED}❌${NC} $1"
}

warning() {
    echo -e "${YELLOW}⚠️${NC} $1"
}

info() {
    echo -e "${CYAN}ℹ️${NC} $1"
}

echo "=== EXECUÇÃO DO DATASYNC FSx → S3 ==="
echo ""

# Verificar se AWS CLI está configurado
if ! command -v aws &> /dev/null; then
    error "AWS CLI não encontrado. Execute 'aws configure' primeiro."
    exit 1
fi

# Obter ARN da tarefa DataSync
log "Obtendo ARN da tarefa DataSync..."
DATASYNC_TASK_ARN=$(aws cloudformation describe-stacks \
    --stack-name "${PROJECT_NAME}-storage" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`DataSyncTaskArn`].OutputValue' \
    --output text 2>/dev/null)

if [ -z "$DATASYNC_TASK_ARN" ] || [ "$DATASYNC_TASK_ARN" = "None" ]; then
    error "Não foi possível obter o ARN da tarefa DataSync. Verifique se a stack está deployada."
    exit 1
fi

success "Tarefa DataSync encontrada: $DATASYNC_TASK_ARN"

# Verificar status da tarefa
log "Verificando status da tarefa DataSync..."
TASK_STATUS=$(aws datasync describe-task \
    --task-arn "$DATASYNC_TASK_ARN" \
    --region "$REGION" \
    --query 'Status' \
    --output text)

info "Status atual da tarefa: $TASK_STATUS"

# Verificar se há execução em andamento
log "Verificando execuções em andamento..."
RUNNING_EXECUTIONS=$(aws datasync list-task-executions \
    --task-arn "$DATASYNC_TASK_ARN" \
    --region "$REGION" \
    --query 'TaskExecutions[?Status==`LAUNCHING` || Status==`PREPARING` || Status==`TRANSFERRING` || Status==`VERIFYING`]' \
    --output json)

if [ "$RUNNING_EXECUTIONS" != "[]" ]; then
    warning "Há execuções em andamento. Aguarde a conclusão antes de iniciar uma nova."
    echo "$RUNNING_EXECUTIONS" | jq -r '.[] | "  • Execução: " + .TaskExecutionArn + " - Status: " + .Status'
    exit 1
fi

# Executar a tarefa DataSync
log "Iniciando execução da tarefa DataSync..."
EXECUTION_ARN=$(aws datasync start-task-execution \
    --task-arn "$DATASYNC_TASK_ARN" \
    --region "$REGION" \
    --query 'TaskExecutionArn' \
    --output text)

if [ -n "$EXECUTION_ARN" ]; then
    success "Execução iniciada com sucesso!"
    info "ARN da execução: $EXECUTION_ARN"
    echo ""
    
    # Monitorar progresso
    log "Monitorando progresso da sincronização..."
    echo ""
    
    while true; do
        # Obter status da execução
        EXEC_INFO=$(aws datasync describe-task-execution \
            --task-execution-arn "$EXECUTION_ARN" \
            --region "$REGION" \
            --output json)
        
        STATUS=$(echo "$EXEC_INFO" | jq -r '.Status')
        
        case $STATUS in
            "LAUNCHING")
                info "🚀 Iniciando execução..."
                ;;
            "PREPARING")
                info "📋 Preparando sincronização..."
                ;;
            "TRANSFERRING")
                # Obter estatísticas de progresso
                BYTES_WRITTEN=$(echo "$EXEC_INFO" | jq -r '.BytesWritten // 0')
                BYTES_TRANSFERRED=$(echo "$EXEC_INFO" | jq -r '.BytesTransferred // 0')
                FILES_TRANSFERRED=$(echo "$EXEC_INFO" | jq -r '.FilesTransferred // 0')
                
                info "📁 Transferindo arquivos..."
                echo "   • Arquivos transferidos: $FILES_TRANSFERRED"
                echo "   • Bytes transferidos: $(numfmt --to=iec $BYTES_TRANSFERRED)"
                echo "   • Bytes escritos: $(numfmt --to=iec $BYTES_WRITTEN)"
                ;;
            "VERIFYING")
                info "🔍 Verificando integridade dos dados..."
                ;;
            "SUCCESS")
                success "🎉 Sincronização concluída com sucesso!"
                
                # Mostrar estatísticas finais
                BYTES_WRITTEN=$(echo "$EXEC_INFO" | jq -r '.BytesWritten // 0')
                BYTES_TRANSFERRED=$(echo "$EXEC_INFO" | jq -r '.BytesTransferred // 0')
                FILES_TRANSFERRED=$(echo "$EXEC_INFO" | jq -r '.FilesTransferred // 0')
                
                echo ""
                echo "📊 ESTATÍSTICAS FINAIS:"
                echo "   • Arquivos transferidos: $FILES_TRANSFERRED"
                echo "   • Bytes transferidos: $(numfmt --to=iec $BYTES_TRANSFERRED)"
                echo "   • Bytes escritos: $(numfmt --to=iec $BYTES_WRITTEN)"
                
                # Verificar bucket S3
                BUCKET_NAME=$(aws cloudformation describe-stacks \
                    --stack-name "${PROJECT_NAME}-storage" \
                    --region "$REGION" \
                    --query 'Stacks[0].Outputs[?OutputKey==`ComplianceBucketName`].OutputValue' \
                    --output text)
                
                if [ -n "$BUCKET_NAME" ]; then
                    echo ""
                    info "📦 Arquivos sincronizados no S3:"
                    aws s3 ls "s3://$BUCKET_NAME/fsx-sync/" --recursive --human-readable --summarize
                fi
                
                break
                ;;
            "ERROR")
                error "❌ Erro durante a sincronização!"
                
                # Mostrar detalhes do erro
                ERROR_CODE=$(echo "$EXEC_INFO" | jq -r '.ErrorCode // "N/A"')
                ERROR_DETAIL=$(echo "$EXEC_INFO" | jq -r '.ErrorDetail // "N/A"')
                
                echo "   • Código do erro: $ERROR_CODE"
                echo "   • Detalhes: $ERROR_DETAIL"
                exit 1
                ;;
            *)
                warning "Status desconhecido: $STATUS"
                ;;
        esac
        
        # Aguardar antes da próxima verificação
        sleep 30
    done
    
else
    error "Falha ao iniciar a execução da tarefa DataSync"
    exit 1
fi

echo ""
log "Sincronização DataSync concluída!"

# Informações adicionais
echo ""
info "🔍 Para monitorar via Console AWS:"
echo "   DataSync Console → Tasks → $DATASYNC_TASK_ARN"
echo ""
info "📊 Para verificar logs no CloudWatch:"
echo "   CloudWatch → Log Groups → /aws/datasync/$PROJECT_NAME"
echo ""
info "📦 Para verificar arquivos no S3:"
echo "   aws s3 ls s3://$BUCKET_NAME/fsx-sync/ --recursive"
