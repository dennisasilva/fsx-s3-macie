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
    
    # Verificar permissões S3
    log_debug "Testando permissões S3..."
    if aws s3api list-buckets --output json >/dev/null 2>&1; then
        log_success "Permissões S3: OK"
    else
        log_error "Sem permissões para listar buckets S3"
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

    # Verificar tag Project do bucket resolvido antes de qualquer operação.
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

    # Verificar acesso ao bucket.
    log_debug "Testando acesso ao bucket..."
    if ! aws s3 ls "s3://$candidate/" >/dev/null 2>&1; then
        log_error "Sem permissão para acessar bucket: $candidate"
        return 1
    fi
    log_success "Acesso ao bucket: OK"

    # Verificar/criar prefixo fsx-sync.
    log_debug "Verificando prefixo fsx-sync..."
    aws s3 ls "s3://$candidate/fsx-sync/" >/dev/null 2>&1 || {
        log_info "Criando prefixo fsx-sync..."
        echo "" | aws s3 cp - "s3://$candidate/fsx-sync/.keep" 2>/dev/null || true
    }

    # Ecoar o nome e exigir confirmação do operador.
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

# Função melhorada para criar job
create_job_detailed() {
    log_info "Criando job de classificação com diagnósticos detalhados..."
    
    if [ -z "$COMPLIANCE_BUCKET" ]; then
        log_error "Bucket não definido"
        return 1
    fi
    
    # Obter informações necessárias
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    if [ -z "$ACCOUNT_ID" ]; then
        log_error "Falha ao obter Account ID"
        return 1
    fi
    
    JOB_NAME="compliance-test-$(date +%Y%m%d%H%M%S)"
    
    log_debug "Parâmetros do job:"
    log_debug "  Account ID: $ACCOUNT_ID"
    log_debug "  Bucket: $COMPLIANCE_BUCKET"
    log_debug "  Job Name: $JOB_NAME"
    log_debug "  Região: $AWS_REGION"
    
    # Verificar se já existem jobs
    log_debug "Verificando jobs existentes..."
    EXISTING_JOBS=$(aws macie2 list-classification-jobs --region "$AWS_REGION" --output json 2>/dev/null)
    if [ $? -eq 0 ]; then
        JOB_COUNT=$(echo "$EXISTING_JOBS" | jq -r '.items | length' 2>/dev/null || echo "0")
        log_debug "Jobs existentes: $JOB_COUNT"
        
        if [ "$JOB_COUNT" -gt 0 ]; then
            log_debug "Jobs atuais:"
            echo "$EXISTING_JOBS" | jq -r '.items[] | "  - \(.name): \(.jobStatus)"' 2>/dev/null || echo "  Erro ao processar jobs"
        fi
    fi
    
    # Criar arquivo temporário com a definição do job
    JOB_DEF_FILE="/tmp/macie-job-def.json"
    cat > "$JOB_DEF_FILE" << EOF
{
    "jobType": "ONE_TIME",
    "name": "$JOB_NAME",
    "description": "Job imediato para teste de compliance - dados fictícios",
    "s3JobDefinition": {
        "bucketDefinitions": [{
            "accountId": "$ACCOUNT_ID",
            "buckets": ["$COMPLIANCE_BUCKET"]
        }],
        "scoping": {
            "includes": {
                "and": [{
                    "simpleScopeTerm": {
                        "comparator": "STARTS_WITH",
                        "key": "OBJECT_KEY",
                        "values": ["fsx-sync/"]
                    }
                }]
            }
        }
    },
    "tags": {
        "Purpose": "ComplianceTest",
        "Environment": "Demo",
        "CreatedBy": "TestScript"
    }
}
EOF
    
    log_debug "Definição do job criada em: $JOB_DEF_FILE"
    log_debug "Conteúdo da definição:"
    cat "$JOB_DEF_FILE" | jq . 2>/dev/null || cat "$JOB_DEF_FILE"
    
    # Tentar criar o job
    log_info "Executando comando de criação do job..."
    JOB_RESULT=$(aws macie2 create-classification-job \
        --cli-input-json "file://$JOB_DEF_FILE" \
        --region "$AWS_REGION" \
        --output json 2>&1)
    
    JOB_EXIT_CODE=$?
    
    log_debug "Exit code: $JOB_EXIT_CODE"
    log_debug "Resultado completo:"
    echo "$JOB_RESULT"
    
    if [ $JOB_EXIT_CODE -eq 0 ]; then
        JOB_ID=$(echo "$JOB_RESULT" | jq -r '.jobId' 2>/dev/null)
        log_success "Job criado com sucesso!"
        log_success "Job ID: $JOB_ID"
        log_success "Job Name: $JOB_NAME"
        
        # Monitorar job por alguns minutos
        log_info "Monitorando status do job..."
        for i in {1..6}; do
            sleep 30
            JOB_STATUS=$(aws macie2 describe-classification-job \
                --job-id "$JOB_ID" \
                --region "$AWS_REGION" \
                --query 'jobStatus' \
                --output text 2>/dev/null)
            
            log_info "Status do job ($i/6): $JOB_STATUS"
            
            case "$JOB_STATUS" in
                "COMPLETE")
                    log_success "Job concluído!"
                    return 0
                    ;;
                "CANCELLED"|"FAILED")
                    log_error "Job falhou: $JOB_STATUS"
                    return 1
                    ;;
                "RUNNING")
                    log_info "Job em execução..."
                    ;;
            esac
        done
        
        log_info "Job ainda em execução. Continue monitorando manualmente."
        return 0
    else
        log_error "Falha ao criar job"
        log_error "Detalhes do erro:"
        echo "$JOB_RESULT" | head -10
        
        # Análise do erro
        if echo "$JOB_RESULT" | grep -q "AccessDenied"; then
            log_error "Erro de permissão - verifique as políticas IAM"
        elif echo "$JOB_RESULT" | grep -q "InvalidParameter"; then
            log_error "Parâmetro inválido - verifique a definição do job"
        elif echo "$JOB_RESULT" | grep -q "ServiceQuotaExceeded"; then
            log_error "Cota de serviço excedida - aguarde ou delete jobs antigos"
        fi
        
        return 1
    fi
    
    # Limpar arquivo temporário
    rm -f "$JOB_DEF_FILE"
}

# Função principal melhorada
main() {
    case "$ACTION" in
        "debug")
            check_permissions
            find_bucket
            ;;
        "job")
            check_permissions || exit 1
            find_bucket || exit 1
            create_job_detailed
            ;;
        "monitor")
            check_permissions || exit 1
            log_info "Verificando findings..."
            
            FINDINGS=$(aws macie2 list-findings --region "$AWS_REGION" --output json 2>/dev/null)
            if [ $? -eq 0 ]; then
                COUNT=$(echo "$FINDINGS" | jq -r '.findingIds | length' 2>/dev/null || echo "0")
                if [ "$COUNT" -gt 0 ]; then
                    log_success "Findings encontrados: $COUNT"
                    
                    # Mostrar detalhes
                    FIRST_FEW=$(echo "$FINDINGS" | jq -r '.findingIds[0:3] | @json' 2>/dev/null)
                    if [ -n "$FIRST_FEW" ] && [ "$FIRST_FEW" != "null" ]; then
                        DETAILS=$(aws macie2 get-findings --finding-ids "$FIRST_FEW" --region "$AWS_REGION" --output json 2>/dev/null)
                        echo "$DETAILS" | jq -r '.findings[] | "🔍 \(.type) - \(.severity) - \(.createdAt) - \(.resourcesAffected.s3Object.key // "N/A")"' 2>/dev/null
                    fi
                else
                    log_info "Nenhum finding encontrado ainda"
                fi
            else
                log_error "Erro ao verificar findings"
            fi
            ;;
        "test")
            check_permissions || exit 1
            find_bucket || exit 1
            
            # Gerar e enviar dados (código existente)
            log_info "Gerando $NUM_FILES arquivos de teste..."
            mkdir -p /tmp/test-data
            
            for i in $(seq 1 $NUM_FILES); do
                filename="TestDoc_${i}_$(date +%Y%m%d_%H%M%S).txt"
                cat > "/tmp/test-data/$filename" << EOF
CONFIDENCIAL - Documento $i
Data: $(date)
CPF: 123.456.789-0$i
Senha: admin$i
Cartão: 4532-1234-5678-901$i
DADOS PESSOAIS FICTÍCIOS
RESTRITO - SIGILOSO
EOF
                log_success "Criado: $filename"
            done
            
            log_info "Enviando para S3..."
            aws s3 cp /tmp/test-data/ "s3://$COMPLIANCE_BUCKET/fsx-sync/" --recursive
            log_success "Arquivos enviados!"
            
            log_info "Execute: $0 0 job (para criar job)"
            log_info "Execute: $0 0 monitor (para ver findings)"
            ;;
        *)
            echo "Uso: $0 [NUM_FILES] [ACTION]"
            echo "Actions: test, job, monitor, debug"
            ;;
    esac
}

main "$@"
