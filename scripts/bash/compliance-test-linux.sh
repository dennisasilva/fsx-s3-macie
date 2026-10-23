#!/bin/bash

# ============================================================================
# FSx COMPLIANCE POC - TESTE COMPLETO PARA LINUX
# ============================================================================
# Script adaptado para executar na instância Linux (Amazon Linux 2)
# Testa a detecção de dados sensíveis com Amazon Macie
# ============================================================================

set -e

# ----------------------------------------------------------------------------
# Pré-parse de flags longas (--bucket NAME, --project NAME, --stack NAME, --yes)
# preservando os argumentos posicionais [NUM_FILES] [ACTION] usados pelo README.
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

# Configurações padrão
NUM_FILES=${1:-3}
ACTION=${2:-"test"}  # test, monitor, cleanup
AWS_REGION=${AWS_REGION:-"us-east-1"}
TEST_DIR="/tmp/fsx-compliance-test"
DATA_DIR="$TEST_DIR/test-data"

# Identidade do projeto usada para resolver autoritativamente o bucket de
# compliance (stack output + tag) em vez de uma busca por substring de nome.
PROJECT_NAME="${_CLI_PROJECT_NAME:-${PROJECT_NAME:-fsx-compliance-poc}}"
STORAGE_STACK_NAME="${_CLI_STACK_NAME:-${STORAGE_STACK_NAME:-${PROJECT_NAME}-storage}}"
# Confirmação não interativa opcional: CONFIRM=1 (ou --yes) para automação.
CONFIRM="${_CLI_CONFIRM:-${CONFIRM:-}}"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Funções de log
log_info() { echo -e "${CYAN}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

print_header() {
    echo -e "${CYAN}=== FSx COMPLIANCE POC - LINUX VERSION ===${NC}"
    echo -e "${YELLOW}Teste de detecção de dados sensíveis com Amazon Macie${NC}"
    echo ""
}

check_prerequisites() {
    log_info "Verificando pré-requisitos..."
    
    # Verificar AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI não encontrado"
        exit 1
    fi
    
    local aws_version=$(aws --version 2>&1 | cut -d' ' -f1)
    log_success "AWS CLI: $aws_version"
    
    # Verificar jq
    if ! command -v jq &> /dev/null; then
        log_warning "jq não encontrado, instalando..."
        sudo yum install -y jq || {
            log_error "Falha ao instalar jq"
            exit 1
        }
    fi
    log_success "jq disponível"
    
    # Verificar credenciais AWS
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "Credenciais AWS não configuradas"
        exit 1
    fi
    
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    log_success "AWS Account: $account_id"
    
    # Verificar região
    log_success "Região AWS: $AWS_REGION"
}

# Resolve o bucket a partir da saída da stack CloudFormation. Falha se o output
# não existir, estiver vazio ou retornar múltiplos valores.
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
    # --output text separa múltiplos valores por tab/nova linha; recusar ambiguidade
    local count
    count=$(printf '%s' "$value" | tr '\t' '\n' | grep -c .)
    if [ "$count" -ne 1 ]; then
        log_error "Stack $stack_name retornou $count valores para ComplianceBucketName"
        return 2
    fi
    printf '%s' "$value"
}

# Verifica que o bucket resolvido carrega a tag Project=$PROJECT_NAME antes de
# qualquer operação de escrita/scan/delete. Retorna 0 somente em caso de match.
verify_bucket_ownership() {
    local bucket="$1"
    local tags project_tag
    tags=$(aws s3api get-bucket-tagging --bucket "$bucket" --output json 2>/dev/null) || {
        log_error "Não foi possível ler as tags do bucket $bucket (bucket inexistente ou sem permissão)"
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

# Pede confirmação explícita do operador do bucket resolvido antes de qualquer
# s3 cp / s3 rm / macie2 create-classification-job. Pode ser pulada com CONFIRM=1
# (automação) depois que o nome já estiver sendo ecoado por este script.
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
    
    # Criar diretório de dados de teste
    mkdir -p "$DATA_DIR"
    
    # Templates de documentos
    local templates=(
        "Relatório Financeiro - CONFIDENCIAL"
        "Contrato de Funcionário - SIGILOSO"
        "Política de Segurança - CLASSIFIED"
        "Lista de Clientes - RESTRITO"
        "Backup de Senhas - ULTRA CONFIDENCIAL"
    )
    
    for i in $(seq 1 $num_files); do
        local template=${templates[$((i % ${#templates[@]}))]}
        local timestamp=$(date +%Y%m%d_%H%M%S)
        local filename="TestDocument_${i}_${timestamp}.txt"
        local filepath="$DATA_DIR/$filename"
        
        # Gerar CPF fictício
        local cpf="$(printf "%03d" $((100 + i))).$(printf "%03d" $((200 + i))).$(printf "%03d" $((300 + i)))-$(printf "%02d" $((10 + i)))"
        
        # Gerar cartão fictício
        local card="4532-$(printf "%04d" $((1000 + i)))-$(printf "%04d" $((2000 + i)))-$(printf "%04d" $((3000 + i)))"
        
        # Gerar SSN fictício
        local ssn="$(printf "%03d" $((100 + i)))-$(printf "%02d" $((10 + i)))-$(printf "%04d" $((1000 + i)))"
        
        cat > "$filepath" << EOF
$template
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

DADOS BANCÁRIOS FICTÍCIOS:
- Banco: 001 - Banco do Brasil
- Agência: $(printf "%04d" $((1000 + i)))-5
- Conta: $(printf "%05d" $((10000 + i)))-1

PALAVRAS-CHAVE PARA DETECÇÃO:
- CONFIDENCIAL
- RESTRITO  
- SIGILOSO
- PERSONAL DATA
- CLASSIFIED
- DADOS PESSOAIS

INFORMAÇÕES ADICIONAIS:
Este arquivo foi criado para testar a detecção automática
de dados sensíveis pelo Amazon Macie. Todos os dados são
FICTÍCIOS e criados apenas para demonstração.

Documento criado em: $(date)
Sistema: Linux - Amazon Linux 2
Finalidade: Teste de Compliance

=== FIM DO DOCUMENTO ===
EOF
        
        log_success "Criado: $filename"
    done
    
    log_success "$num_files arquivos gerados em $DATA_DIR"
}

upload_to_s3() {
    if [ -z "$COMPLIANCE_BUCKET" ]; then
        log_error "Bucket de compliance não identificado"
        return 1
    fi
    
    log_info "Enviando arquivos para S3..."
    
    # Criar prefixo fsx-sync se não existir
    aws s3api head-object --bucket "$COMPLIANCE_BUCKET" --key "fsx-sync/" 2>/dev/null || {
        log_info "Criando prefixo fsx-sync/ no bucket"
    }
    
    # Upload dos arquivos
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
    
    # Verificar upload
    log_info "Verificando arquivos no S3..."
    aws s3 ls "s3://$COMPLIANCE_BUCKET/fsx-sync/" --recursive | grep TestDocument | wc -l | xargs -I {} echo "Arquivos no S3: {}"
}

check_macie_status() {
    log_info "Verificando status do Amazon Macie..."
    
    # Verificar se Macie está habilitado
    local macie_status=$(aws macie2 get-macie-session --region "$AWS_REGION" --output json 2>/dev/null)
    if [ $? -eq 0 ]; then
        local status=$(echo "$macie_status" | jq -r '.status')
        log_success "Macie habilitado: $status"
        
        # Verificar jobs de classificação
        local jobs=$(aws macie2 list-classification-jobs --region "$AWS_REGION" --output json 2>/dev/null)
        if [ $? -eq 0 ]; then
            local job_count=$(echo "$jobs" | jq -r '.items | length')
            log_success "Jobs de classificação: $job_count"
            
            # Mostrar jobs relacionados ao compliance
            echo "$jobs" | jq -r '.items[] | select(.name | contains("compliance")) | "   • \(.name): \(.jobStatus)"' | while read line; do
                log_info "$line"
            done
        fi
    else
        log_warning "Erro ao verificar status do Macie"
    fi
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
        
        # Obter detalhes dos primeiros 5 findings
        local first_five=$(echo "$findings" | jq -r '.findingIds[0:5] | @json')
        local details=$(aws macie2 get-findings --finding-ids "$first_five" --region "$AWS_REGION" --output json 2>/dev/null)
        
        if [ $? -eq 0 ]; then
            echo -e "${CYAN}📊 RESUMO DOS FINDINGS:${NC}"
            echo "$details" | jq -r '.findings[] | 
                "   🔍 Tipo: \(.type)
   ⚠️  Severidade: \(.severity)
   📅 Data: \(.createdAt | strptime("%Y-%m-%dT%H:%M:%S.%fZ") | strftime("%d/%m/%Y %H:%M"))
   📄 Arquivo: \(.resourcesAffected.s3Object.key // "N/A")
   🪣 Bucket: \(.resourcesAffected.s3Object.bucketName // "N/A")
   " + ("─" * 50)'
            
            # Estatísticas por severidade
            echo ""
            echo -e "${YELLOW}📈 DISTRIBUIÇÃO POR SEVERIDADE:${NC}"
            echo "$details" | jq -r '.findings | group_by(.severity) | .[] | "   \(.[0].severity): \(length) findings"'
            
            # Estatísticas por tipo
            echo ""
            echo -e "${YELLOW}🏷️  DISTRIBUIÇÃO POR TIPO:${NC}"
            echo "$details" | jq -r '.findings | group_by(.type) | .[] | "   \(.[0].type): \(length) findings"'
        fi
    else
        echo ""
        log_info "Nenhum finding encontrado ainda"
        echo ""
        echo -e "${YELLOW}📋 POSSÍVEIS MOTIVOS:${NC}"
        echo "   • Job do Macie ainda não executou (agendado diariamente)"
        echo "   • Arquivos ainda não foram processados"
        echo "   • Aguarde alguns minutos e tente novamente"
        echo ""
        echo -e "${CYAN}💡 DICAS:${NC}"
        echo "   • Crie um job manual no console: https://console.aws.amazon.com/macie/"
        echo "   • Verifique se os arquivos estão no S3: aws s3 ls s3://$COMPLIANCE_BUCKET/fsx-sync/"
        echo "   • Execute novamente: $0 $NUM_FILES monitor"
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
    
    local job_definition=$(cat << EOF
{
    "jobType": "ONE_TIME",
    "name": "$job_name",
    "description": "Job imediato para teste de compliance - dados fictícios",
    "s3JobDefinition": {
        "bucketDefinitions": [{
            "accountId": "$account_id",
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
        "CreatedBy": "ComplianceTestScript"
    }
}
EOF
)
    
    local job_result=$(aws macie2 create-classification-job --region "$AWS_REGION" --cli-input-json "$job_definition" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        local job_id=$(echo "$job_result" | jq -r '.jobId')
        log_success "Job criado: $job_id"
        log_info "Nome do job: $job_name"
        log_info "Aguarde alguns minutos para execução..."
        
        # Monitorar status do job
        log_info "Monitorando status do job..."
        for i in {1..10}; do
            sleep 30
            local job_status=$(aws macie2 describe-classification-job --job-id "$job_id" --region "$AWS_REGION" --query 'jobStatus' --output text 2>/dev/null)
            log_info "Status do job ($i/10): $job_status"
            
            if [ "$job_status" = "COMPLETE" ]; then
                log_success "Job concluído! Verificando findings..."
                sleep 10
                monitor_findings
                break
            elif [ "$job_status" = "CANCELLED" ] || [ "$job_status" = "FAILED" ]; then
                log_error "Job falhou: $job_status"
                break
            fi
        done
    else
        log_error "Falha ao criar job imediato"
        log_warning "Crie um job manual no console: https://console.aws.amazon.com/macie/"
    fi
}

cleanup_test_data() {
    log_info "Limpando dados de teste..."
    
    # Remover arquivos locais
    if [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
        log_success "Arquivos locais removidos"
    fi
    
    # Remover arquivos do S3
    if [ -n "$COMPLIANCE_BUCKET" ]; then
        log_info "Removendo arquivos de teste do S3..."
        aws s3 rm "s3://$COMPLIANCE_BUCKET/fsx-sync/" --recursive --exclude "*" --include "TestDocument_*"
        log_success "Arquivos de teste removidos do S3"
    fi
    
    log_success "Limpeza concluída"
}

show_help() {
    echo "Uso: $0 [NUM_FILES] [ACTION]"
    echo ""
    echo "Parâmetros:"
    echo "  NUM_FILES    Número de arquivos de teste (padrão: 3)"
    echo "  ACTION       Ação a executar:"
    echo "               test     - Executar teste completo (padrão)"
    echo "               monitor  - Apenas monitorar findings"
    echo "               job      - Criar job imediato"
    echo "               cleanup  - Limpar dados de teste"
    echo "               help     - Mostrar esta ajuda"
    echo ""
    echo "Exemplos:"
    echo "  $0 5 test      # Gerar 5 arquivos e executar teste"
    echo "  $0 0 monitor   # Apenas verificar findings"
    echo "  $0 0 job       # Criar job imediato"
    echo "  $0 0 cleanup   # Limpar dados de teste"
}

main() {
    print_header
    
    case "$ACTION" in
        "help")
            show_help
            exit 0
            ;;
        "monitor")
            check_prerequisites
            find_compliance_bucket
            monitor_findings
            ;;
        "job")
            check_prerequisites
            find_compliance_bucket
            create_immediate_job
            ;;
        "cleanup")
            find_compliance_bucket
            cleanup_test_data
            ;;
        "test")
            check_prerequisites
            find_compliance_bucket || exit 1
            
            # Criar diretório de trabalho
            mkdir -p "$TEST_DIR"
            
            generate_test_data "$NUM_FILES"
            upload_to_s3
            check_macie_status
            
            echo ""
            echo -e "${CYAN}=== TESTE CONFIGURADO COM SUCESSO ===${NC}"
            echo ""
            echo -e "${YELLOW}📋 PRÓXIMOS PASSOS:${NC}"
            echo "1. Aguarde execução do job do Macie (agendado diariamente)"
            echo "   OU crie um job imediato: $0 0 job"
            echo ""
            echo "2. Monitore findings: $0 0 monitor"
            echo ""
            echo "3. Verifique no console: https://console.aws.amazon.com/macie/"
            echo ""
            echo -e "${BLUE}🔗 LINKS ÚTEIS:${NC}"
            echo "   • Console Macie: https://console.aws.amazon.com/macie/"
            echo "   • CloudWatch Logs: https://console.aws.amazon.com/cloudwatch/home#logsV2:log-groups"
            echo ""
            echo -e "${RED}⚠️  LEMBRETE:${NC}"
            echo "   Todos os dados são FICTÍCIOS para teste apenas!"
            echo "   Execute '$0 0 cleanup' após validação."
            ;;
        *)
            log_error "Ação inválida: $ACTION"
            show_help
            exit 1
            ;;
    esac
}

# Executar função principal
main "$@"
