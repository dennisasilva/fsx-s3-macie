cat > /tmp/test-debug.sh << 'EOF'
#!/bin/bash

# FSx Compliance Test - Versão com Debug Detalhado
# ----------------------------------------------------------------------------
# Pré-parse de --bucket / --project / --stack / --yes (ver remediação do
# finding: resolver o bucket autoritativamente via output da stack + tag).
# ----------------------------------------------------------------------------
BUCKET_NAME="${BUCKET_NAME:-}"
_CLI_PROJECT_NAME=""
_CLI_STACK_NAME=""
_CLI_CONFIRM=""
_POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --bucket)        BUCKET_NAME="${2:-}"; shift 2 ;;
        --bucket=*)      BUCKET_NAME="${1#*=}"; shift ;;
        --project)       _CLI_PROJECT_NAME="${2:-}"; shift 2 ;;
        --project=*)     _CLI_PROJECT_NAME="${1#*=}"; shift ;;
        --stack)         _CLI_STACK_NAME="${2:-}"; shift 2 ;;
        --stack=*)       _CLI_STACK_NAME="${1#*=}"; shift ;;
        --yes|-y)        _CLI_CONFIRM="1"; shift ;;
        --)              shift; while [ $# -gt 0 ]; do _POS+=("$1"); shift; done ;;
        *)               _POS+=("$1"); shift ;;
    esac
done
set -- "${_POS[@]}"

NUM_FILES=${1:-3}
ACTION=${2:-"test"}
AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${_CLI_PROJECT_NAME:-${PROJECT_NAME:-fsx-compliance-poc}}"
STORAGE_STACK_NAME="${_CLI_STACK_NAME:-${STORAGE_STACK_NAME:-${PROJECT_NAME}-storage}}"
CONFIRM="${_CLI_CONFIRM:-${CONFIRM:-}}"

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

# Função melhorada para encontrar bucket (resolve via stack output + tag Project)
find_bucket() {
    log_info "Resolvendo bucket de compliance autoritativamente..."

    local candidate=""
    if [ -n "$BUCKET_NAME" ]; then
        log_info "Usando bucket informado pelo operador: $BUCKET_NAME"
        candidate="$BUCKET_NAME"
    else
        log_debug "Lendo output 'ComplianceBucketName' da stack $STORAGE_STACK_NAME..."
        candidate=$(aws cloudformation describe-stacks \
            --stack-name "$STORAGE_STACK_NAME" \
            --region "$AWS_REGION" \
            --query 'Stacks[0].Outputs[?OutputKey==`ComplianceBucketName`].OutputValue' \
            --output text 2>/dev/null)
        if [ -z "$candidate" ] || [ "$candidate" = "None" ]; then
            log_error "Não foi possível resolver o bucket a partir da stack $STORAGE_STACK_NAME"
            log_error "Passe --bucket <nome> ou defina BUCKET_NAME para resolver manualmente"
            return 1
        fi
        local count
        count=$(printf '%s' "$candidate" | tr '\t' '\n' | grep -c .)
        if [ "$count" -ne 1 ]; then
            log_error "Stack $STORAGE_STACK_NAME retornou $count valores para ComplianceBucketName; abortando"
            return 1
        fi
    fi

    # Verificar tag Project do bucket resolvido.
    local tags project_tag
    tags=$(aws s3api get-bucket-tagging --bucket "$candidate" --output json 2>/dev/null) || {
        log_error "Não foi possível ler as tags do bucket $candidate; abortando"
        return 1
    }
    project_tag=$(printf '%s' "$tags" | jq -r '.TagSet[]? | select(.Key=="Project") | .Value' 2>/dev/null)
    if [ "$project_tag" != "$PROJECT_NAME" ]; then
        log_error "Bucket $candidate não possui tag Project=$PROJECT_NAME (valor atual: '${project_tag:-<ausente>}'); abortando"
        return 1
    fi

    # Verificar que o bucket é acessível.
    if ! aws s3 ls "s3://$candidate/" >/dev/null 2>&1; then
        log_error "Sem permissão para acessar bucket: $candidate"
        return 1
    fi

    # Ecoar e exigir confirmação do operador.
    echo "⚠️  Bucket alvo resolvido: $candidate (projeto: $PROJECT_NAME, stack: $STORAGE_STACK_NAME)"
    if [ "$CONFIRM" = "1" ] || [ "$CONFIRM" = "yes" ] || [ "$CONFIRM" = "y" ]; then
        log_info "CONFIRM=$CONFIRM; prosseguindo sem prompt"
    else
        if [ ! -t 0 ]; then
            log_error "Entrada não interativa e CONFIRM não setado; abortando"
            return 1
        fi
        local reply
        read -r -p "Digite 'yes' para operar neste bucket: " reply
        if [ "$reply" != "yes" ]; then
            log_error "Confirmação negada; abortando"
            return 1
        fi
    fi

    BUCKET="$candidate"
    export COMPLIANCE_BUCKET="$BUCKET"
    log_success "Bucket confirmado: $BUCKET"
    return 0
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