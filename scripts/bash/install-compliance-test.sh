#!/bin/bash

# ============================================================================
# INSTALADOR RÁPIDO - FSx COMPLIANCE TEST PARA LINUX
# ============================================================================
# Execute este comando na instância Linux para instalar e executar o teste
# ============================================================================

set -e

echo "=== FSx COMPLIANCE TEST - INSTALADOR RÁPIDO ==="
echo "Configurando teste de compliance para Linux..."
echo ""

# Criar diretório de trabalho
WORK_DIR="/tmp/compliance-test"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "✅ Diretório criado: $WORK_DIR"

# Verificar e instalar jq se necessário
if ! command -v jq &> /dev/null; then
    echo "📦 Instalando jq..."
    sudo yum update -y
    sudo yum install -y jq
    echo "✅ jq instalado"
fi

# Criar script principal inline
cat > compliance-test.sh << 'SCRIPT_EOF'
#!/bin/bash

# ----------------------------------------------------------------------------
# Pré-parse de --bucket / --project / --stack / --yes (ver remediação do
# finding: resolver o bucket autoritativamente, nunca por substring).
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

# Configurações
NUM_FILES=${1:-3}
ACTION=${2:-"test"}
AWS_REGION=${AWS_REGION:-"us-east-1"}
TEST_DIR="/tmp/fsx-compliance-test"
DATA_DIR="$TEST_DIR/test-data"
PROJECT_NAME="${_CLI_PROJECT_NAME:-${PROJECT_NAME:-fsx-compliance-poc}}"
STORAGE_STACK_NAME="${_CLI_STACK_NAME:-${STORAGE_STACK_NAME:-${PROJECT_NAME}-storage}}"
CONFIRM="${_CLI_CONFIRM:-${CONFIRM:-}}"

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

print_header() {
    echo -e "${CYAN}=== FSx COMPLIANCE POC - LINUX VERSION ===${NC}"
    echo -e "${YELLOW}Teste de detecção de dados sensíveis com Amazon Macie${NC}"
    echo ""
}

resolve_bucket_from_stack() {
    local stack_name="$1"
    local value
    value=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --region "$AWS_REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`ComplianceBucketName`].OutputValue' \
        --output text 2>/dev/null)
    if [ -z "$value" ] || [ "$value" = "None" ]; then
        return 1
    fi
    local count
    count=$(printf '%s' "$value" | tr '\t' '\n' | grep -c .)
    if [ "$count" -ne 1 ]; then
        log_error "Stack $stack_name retornou $count valores para ComplianceBucketName"
        return 2
    fi
    printf '%s' "$value"
}

verify_bucket_ownership() {
    local bucket="$1"
    local tags project_tag
    tags=$(aws s3api get-bucket-tagging --bucket "$bucket" --output json 2>/dev/null) || {
        log_error "Não foi possível ler as tags do bucket $bucket (inexistente ou sem permissão)"
        return 1
    }
    project_tag=$(printf '%s' "$tags" | jq -r '.TagSet[]? | select(.Key=="Project") | .Value' 2>/dev/null)
    if [ -z "$project_tag" ]; then
        log_error "Bucket $bucket não possui a tag Project; recusando operar nele"
        return 1
    fi
    if [ "$project_tag" != "$PROJECT_NAME" ]; then
        log_error "Bucket $bucket pertence ao projeto '$project_tag', esperado '$PROJECT_NAME'"
        return 1
    fi
    return 0
}

confirm_bucket() {
    local bucket="$1"
    echo ""
    echo -e "${YELLOW}>>> Bucket alvo resolvido: ${bucket}${NC}"
    echo -e "${YELLOW}>>> Projeto esperado   : ${PROJECT_NAME}${NC}"
    echo -e "${YELLOW}>>> Stack de origem    : ${STORAGE_STACK_NAME}${NC}"
    if [ "$CONFIRM" = "1" ] || [ "$CONFIRM" = "yes" ] || [ "$CONFIRM" = "y" ]; then
        log_info "CONFIRM=$CONFIRM; prosseguindo sem prompt interativo"
        return 0
    fi
    if [ ! -t 0 ]; then
        log_error "Entrada não interativa e CONFIRM não setado; abortando antes de operar em $bucket"
        return 1
    fi
    local reply
    read -r -p "Digite 'yes' para operar neste bucket: " reply
    if [ "$reply" != "yes" ]; then
        log_error "Confirmação negada; abortando"
        return 1
    fi
    return 0
}

find_compliance_bucket() {
    log_info "Identificando bucket S3 de compliance..."

    local candidate=""
    if [ -n "$BUCKET_NAME" ]; then
        log_info "Usando bucket informado pelo operador: $BUCKET_NAME"
        candidate="$BUCKET_NAME"
    else
        log_info "Lendo output 'ComplianceBucketName' da stack $STORAGE_STACK_NAME..."
        candidate=$(resolve_bucket_from_stack "$STORAGE_STACK_NAME") || {
            log_error "Falha ao resolver o bucket a partir da stack $STORAGE_STACK_NAME"
            log_error "Passe --bucket <nome> ou defina BUCKET_NAME para resolver manualmente"
            return 1
        }
    fi

    if ! verify_bucket_ownership "$candidate"; then
        log_error "Verificação de ownership falhou para $candidate; abortando"
        return 1
    fi

    if ! confirm_bucket "$candidate"; then
        return 1
    fi

    COMPLIANCE_BUCKET="$candidate"
    log_success "Bucket confirmado: $COMPLIANCE_BUCKET"
    return 0
}

generate_test_data() {
    local num_files=$1
    
    log_info "Gerando $num_files arquivos com dados sensíveis fictícios..."
    mkdir -p "$DATA_DIR"
    
    for i in $(seq 1 $num_files); do
        local timestamp=$(date +%Y%m%d_%H%M%S)
        local filename="TestDocument_${i}_${timestamp}.txt"
        local filepath="$DATA_DIR/$filename"
        
        # Gerar dados fictícios
        local cpf="$(printf "%03d" $((100 + i))).$(printf "%03d" $((200 + i))).$(printf "%03d" $((300 + i)))-$(printf "%02d" $((10 + i)))"
        local card="4532-$(printf "%04d" $((1000 + i)))-$(printf "%04d" $((2000 + i)))-$(printf "%04d" $((3000 + i)))"
        local ssn="$(printf "%03d" $((100 + i)))-$(printf "%02d" $((10 + i)))-$(printf "%04d" $((1000 + i)))"
        
        cat > "$filepath" << EOF
DOCUMENTO DE TESTE - CONFIDENCIAL
=================================
Data: $(date '+%d/%m/%Y %H:%M:%S')
Documento #$i de $num_files

⚠️  ATENÇÃO: DADOS FICTÍCIOS PARA TESTE ⚠️

DADOS SENSÍVEIS INCLUÍDOS:
- CPF: $cpf
- Senha: teste_senha_$i
- Cartão de Crédito: $card
- Email: usuario$i@empresa.com
- SSN: $ssn
- Telefone: (11) 9999-$(printf "%04d" $((1000 + i)))

INFORMAÇÕES CONFIDENCIAIS:
Este documento contém DADOS PESSOAIS fictícios.
Classificação: RESTRITO
Acesso: SIGILOSO
Nível: CONFIDENCIAL

CREDENCIAIS DE SISTEMA:
- PASSWORD do sistema: admin123_$i
- Senha do banco: db_password_$i
- Token de acesso: token_secreto_$i

PALAVRAS-CHAVE PARA DETECÇÃO:
- CONFIDENCIAL
- RESTRITO  
- SIGILOSO
- PERSONAL DATA
- CLASSIFIED
- DADOS PESSOAIS

Este arquivo foi criado para testar a detecção automática
de dados sensíveis pelo Amazon Macie. Todos os dados são
FICTÍCIOS e criados apenas para demonstração.

=== FIM DO DOCUMENTO ===
EOF
        
        log_success "Criado: $filename"
    done
}

upload_to_s3() {
    if [ -z "$COMPLIANCE_BUCKET" ]; then
        log_error "Bucket de compliance não identificado"
        return 1
    fi
    
    log_info "Enviando arquivos para S3..."
    
    local upload_count=0
    for file in "$DATA_DIR"/*; do
        if [ -f "$file" ]; then
            local filename=$(basename "$file")
            aws s3 cp "$file" "s3://$COMPLIANCE_BUCKET/fsx-sync/$filename"
            ((upload_count++))
            log_success "Enviado: $filename"
        fi
    done
    
    log_success "$upload_count arquivos enviados para s3://$COMPLIANCE_BUCKET/fsx-sync/"
}

monitor_findings() {
    log_info "Verificando findings do Amazon Macie..."
    
    local findings=$(aws macie2 list-findings --region "$AWS_REGION" --output json 2>/dev/null)
    if [ $? -ne 0 ]; then
        log_error "Erro ao acessar findings do Macie"
        return 1
    fi
    
    local finding_count=$(echo "$findings" | jq -r '.findingIds | length')
    
    if [ "$finding_count" -gt 0 ]; then
        echo ""
        echo -e "${GREEN}🎉 FINDINGS ENCONTRADOS: $finding_count${NC}"
        echo ""
        
        local first_five=$(echo "$findings" | jq -r '.findingIds[0:5] | @json')
        local details=$(aws macie2 get-findings --finding-ids "$first_five" --region "$AWS_REGION" --output json 2>/dev/null)
        
        if [ $? -eq 0 ]; then
            echo -e "${CYAN}📊 RESUMO DOS FINDINGS:${NC}"
            echo "$details" | jq -r '.findings[] | 
                "   🔍 Tipo: \(.type)
   ⚠️  Severidade: \(.severity)
   📅 Data: \(.createdAt | strptime("%Y-%m-%dT%H:%M:%S.%fZ") | strftime("%d/%m/%Y %H:%M"))
   📄 Arquivo: \(.resourcesAffected.s3Object.key // "N/A")
   " + ("─" * 50)'
        fi
    else
        echo ""
        log_info "Nenhum finding encontrado ainda"
        echo ""
        echo -e "${YELLOW}💡 DICAS:${NC}"
        echo "   • Crie um job manual no console: https://console.aws.amazon.com/macie/"
        echo "   • Aguarde alguns minutos e execute: $0 0 monitor"
    fi
}

create_immediate_job() {
    if [ -z "$COMPLIANCE_BUCKET" ]; then
        log_error "Bucket de compliance não identificado"
        return 1
    fi
    
    log_info "Criando job de classificação imediato..."
    
    local job_name="compliance-test-immediate-$(date +%Y%m%d%H%M%S)"
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    
    local job_result=$(aws macie2 create-classification-job \
        --job-type ONE_TIME \
        --name "$job_name" \
        --description "Job imediato para teste de compliance" \
        --s3-job-definition "{
            \"bucketDefinitions\": [{
                \"accountId\": \"$account_id\",
                \"buckets\": [\"$COMPLIANCE_BUCKET\"]
            }],
            \"scoping\": {
                \"includes\": {
                    \"and\": [{
                        \"simpleScopeTerm\": {
                            \"comparator\": \"STARTS_WITH\",
                            \"key\": \"OBJECT_KEY\",
                            \"values\": [\"fsx-sync/\"]
                        }
                    }]
                }
            }
        }" \
        --region "$AWS_REGION" \
        --output json 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        local job_id=$(echo "$job_result" | jq -r '.jobId')
        log_success "Job criado: $job_id"
        log_info "Aguarde alguns minutos para execução..."
    else
        log_error "Falha ao criar job imediato"
        log_warning "Crie um job manual no console: https://console.aws.amazon.com/macie/"
    fi
}

main() {
    print_header
    
    case "$ACTION" in
        "monitor")
            find_compliance_bucket
            monitor_findings
            ;;
        "job")
            find_compliance_bucket
            create_immediate_job
            ;;
        "test")
            # Verificar AWS CLI
            if ! command -v aws &> /dev/null; then
                log_error "AWS CLI não encontrado"
                exit 1
            fi
            
            find_compliance_bucket || exit 1
            mkdir -p "$TEST_DIR"
            generate_test_data "$NUM_FILES"
            upload_to_s3
            
            echo ""
            echo -e "${CYAN}=== TESTE CONFIGURADO COM SUCESSO ===${NC}"
            echo ""
            echo -e "${YELLOW}📋 PRÓXIMOS PASSOS:${NC}"
            echo "1. Crie um job imediato: $0 0 job"
            echo "2. Monitore findings: $0 0 monitor"
            echo "3. Console Macie: https://console.aws.amazon.com/macie/"
            echo ""
            echo -e "${RED}⚠️  LEMBRETE: Dados são FICTÍCIOS para teste!${NC}"
            ;;
        *)
            echo "Uso: $0 [NUM_FILES] [ACTION]"
            echo "Actions: test, monitor, job"
            ;;
    esac
}

main "$@"
SCRIPT_EOF

# Dar permissão de execução
chmod +x compliance-test.sh

echo "✅ Script principal criado: compliance-test.sh"
echo ""
echo "🚀 COMO USAR:"
echo ""
echo "# Executar teste completo (gerar 3 arquivos)"
echo "./compliance-test.sh 3 test"
echo ""
echo "# Criar job imediato do Macie"
echo "./compliance-test.sh 0 job"
echo ""
echo "# Monitorar findings"
echo "./compliance-test.sh 0 monitor"
echo ""
echo "✅ INSTALAÇÃO CONCLUÍDA!"
echo "Execute: ./compliance-test.sh 3 test"
