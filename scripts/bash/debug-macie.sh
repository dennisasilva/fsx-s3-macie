#!/bin/bash
# ============================================================================
# Gera um script temporário de debug para o Macie em um caminho privado.
# Evita paths previsíveis em /tmp (symlink/clobber via `cat >`).
# ============================================================================
set -e
set -C
umask 077

DEBUG_SCRIPT="$(mktemp -t fsx-macie-debug.XXXXXXXX.sh)"
chmod 700 "$DEBUG_SCRIPT"

cat > "$DEBUG_SCRIPT" << 'EOF'
#!/bin/bash

# FSx Compliance Test - Versão com Debug Detalhado
NUM_FILES=${1:-3}
ACTION=${2:-"test"}
AWS_REGION="us-east-1"

echo "=== FSx COMPLIANCE TEST - DEBUG VERSION ==="
echo "Região: $AWS_REGION"
echo "Ação: $ACTION"
echo ""

# Função para log com timestamp
log_debug() {
    echo "[$(date '+%H:%M:%S')] 🔍 DEBUG: $1"
}

log_info() {
    echo "[$(date '+%H:%M:%S')] ℹ️  INFO: $1"
}

log_success() {
    echo "[$(date '+%H:%M:%S')] ✅ SUCCESS: $1"
}

log_error() {
    echo "[$(date '+%H:%M:%S')] ❌ ERROR: $1"
}

# Verificar credenciais e permissões
check_permissions() {
    log_info "Verificando credenciais e permissões..."
    
    # Verificar identidade
    log_debug "Verificando identidade AWS..."
    IDENTITY=$(aws sts get-caller-identity --output json 2>/dev/null)
    if [ $? -eq 0 ]; then
        ACCOUNT_ID=$(echo "$IDENTITY" | jq -r '.Account' 2>/dev/null || echo "N/A")
        USER_ARN=$(echo "$IDENTITY" | jq -r '.Arn' 2>/dev/null || echo "N/A")
        log_success "Account ID: $ACCOUNT_ID"
        log_success "User/Role: $USER_ARN"
    else
        log_error "Falha ao obter identidade AWS"
        return 1
    fi
    
    # Verificar permissões do Macie
    log_debug "Testando permissões do Macie..."
    MACIE_STATUS=$(aws macie2 get-macie-session --region "$AWS_REGION" --output json 2>&1)
    if [ $? -eq 0 ]; then
        STATUS=$(echo "$MACIE_STATUS" | jq -r '.status' 2>/dev/null || echo "N/A")
        log_success "Macie Status: $STATUS"
    else
        log_error "Erro ao acessar Macie:"
        echo "$MACIE_STATUS" | head -3
        return 1
    fi
    
    return 0
}

# Função melhorada para encontrar bucket
find_bucket() {
    log_info "Procurando bucket de compliance..."
    
    # Listar todos os buckets primeiro
    log_debug "Listando todos os buckets..."
    ALL_BUCKETS=$(aws s3api list-buckets --query "Buckets[].Name" --output text 2>/dev/null)
    if [ $? -ne 0 ]; then
        log_error "Falha ao listar buckets"
        return 1
    fi
    
    log_debug "Buckets encontrados:"
    echo "$ALL_BUCKETS" | tr '\t' '\n' | while read bucket; do
        echo "  - $bucket"
    done
    
    # Procurar bucket de compliance
    BUCKET=$(echo "$ALL_BUCKETS" | tr '\t' '\n' | grep -i compliance | head -1)
    
    if [ -n "$BUCKET" ]; then
        log_success "Bucket de compliance: $BUCKET"
        export COMPLIANCE_BUCKET="$BUCKET"
        return 0
    else
        log_error "Nenhum bucket de compliance encontrado"
        return 1
    fi
}

# Função para criar job com mais detalhes
create_job_simple() {
    log_info "Criando job de classificação..."
    
    if [ -z "$COMPLIANCE_BUCKET" ]; then
        log_error "Bucket não definido"
        return 1
    fi
    
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    JOB_NAME="compliance-test-$(date +%Y%m%d%H%M%S)"
    
    log_debug "Account ID: $ACCOUNT_ID"
    log_debug "Bucket: $COMPLIANCE_BUCKET"
    log_debug "Job Name: $JOB_NAME"
    
    # Comando mais simples
    log_info "Executando comando de criação..."
    JOB_RESULT=$(aws macie2 create-classification-job \
        --job-type ONE_TIME \
        --name "$JOB_NAME" \
        --description "Teste de compliance" \
        --s3-job-definition "{
            \"bucketDefinitions\": [{
                \"accountId\": \"$ACCOUNT_ID\",
                \"buckets\": [\"$COMPLIANCE_BUCKET\"]
            }]
        }" \
        --region "$AWS_REGION" \
        --output json 2>&1)
    
    if [ $? -eq 0 ]; then
        JOB_ID=$(echo "$JOB_RESULT" | jq -r '.jobId' 2>/dev/null || echo "N/A")
        log_success "Job criado: $JOB_ID"
        return 0
    else
        log_error "Falha ao criar job:"
        echo "$JOB_RESULT"
        
        # Sugestões baseadas no erro
        if echo "$JOB_RESULT" | grep -q "AccessDenied"; then
            log_error "ERRO DE PERMISSÃO - A role precisa da permissão macie2:CreateClassificationJob"
        elif echo "$JOB_RESULT" | grep -q "InvalidParameter"; then
            log_error "PARÂMETRO INVÁLIDO - Verifique se o bucket existe e está acessível"
        fi
        
        return 1
    fi
}

# Função principal
main() {
    case "$ACTION" in
        "debug")
            check_permissions
            find_bucket
            ;;
        "job")
            check_permissions || exit 1
            find_bucket || exit 1
            create_job_simple
            ;;
        "monitor")
            check_permissions || exit 1
            log_info "Verificando findings..."
            
            FINDINGS=$(aws macie2 list-findings --region "$AWS_REGION" --output json 2>/dev/null)
            if [ $? -eq 0 ]; then
                COUNT=$(echo "$FINDINGS" | jq -r '.findingIds | length' 2>/dev/null || echo "0")
                log_info "Findings encontrados: $COUNT"
            else
                log_error "Erro ao verificar findings"
            fi
            ;;
        *)
            echo "Uso: $0 [NUM_FILES] [ACTION]"
            echo "Actions: debug, job, monitor"
            echo ""
            echo "Exemplos:"
            echo "  $0 0 debug    # Verificar permissões"
            echo "  $0 0 job      # Criar job"
            echo "  $0 0 monitor  # Ver findings"
            ;;
    esac
}

main "$@"
EOF

chmod 700 "$DEBUG_SCRIPT"
echo "Script de debug gerado em: $DEBUG_SCRIPT"
echo "Remova manualmente após uso: rm -f -- \"$DEBUG_SCRIPT\""
