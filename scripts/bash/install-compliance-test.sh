#!/bin/bash

# ============================================================================
# INSTALADOR RÁPIDO - FSx COMPLIANCE TEST PARA LINUX
# ============================================================================
# Execute este comando na instância Linux para instalar e executar o teste
# ============================================================================

set -e
# Avoid clobbering an attacker-planted file via redirection, and keep temp files private.
set -C
umask 077

echo "=== FSx COMPLIANCE TEST - INSTALADOR RÁPIDO ==="
echo "Configurando teste de compliance para Linux..."
echo ""

# Criar diretório de trabalho privado via mktemp para evitar caminhos previsíveis em /tmp
# (prevents symlink/content-substitution against a fixed /tmp/compliance-test path).
WORK_DIR="$(mktemp -d -t fsx-compliance-install.XXXXXXXX)"
chmod 700 "$WORK_DIR"
cd "$WORK_DIR"

echo "✅ Diretório criado: $WORK_DIR"

# Verificar e instalar jq se necessário
if ! command -v jq &> /dev/null; then
    echo "📦 Instalando jq..."
    sudo yum update -y
    sudo yum install -y jq
    echo "✅ jq instalado"
fi

# Criar script principal inline em caminho privado (noclobber ativo via `set -C`)
SCRIPT_PATH="$WORK_DIR/compliance-test.sh"
cat > "$SCRIPT_PATH" << 'SCRIPT_EOF'
#!/bin/bash

set -e
set -C
umask 077

# Configurações
NUM_FILES=${1:-3}
ACTION=${2:-"test"}
AWS_REGION=${AWS_REGION:-"us-east-1"}
# Diretório de trabalho privado criado por mktemp para evitar caminho previsível em /tmp.
TEST_DIR="$(mktemp -d -t fsx-compliance-test.XXXXXXXX)"
chmod 700 "$TEST_DIR"
DATA_DIR="$TEST_DIR/test-data"
mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR"
# Rastrear apenas os arquivos que este script gerar para upload (evita subir arquivos plantados).
GENERATED_FILES=()
# Cleanup automático do diretório privado.
trap 'rm -rf -- "$TEST_DIR"' EXIT INT TERM HUP

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

find_compliance_bucket() {
    log_info "Identificando bucket S3 de compliance..."
    
    local buckets=$(aws s3api list-buckets --query "Buckets[?contains(Name, 'compliance')].Name" --output text 2>/dev/null)
    
    if [ -n "$buckets" ]; then
        COMPLIANCE_BUCKET=$(echo "$buckets" | head -1)
        log_success "Bucket encontrado: $COMPLIANCE_BUCKET"
        return 0
    else
        log_warning "Bucket de compliance não encontrado automaticamente"
        echo "Buckets disponíveis:"
        aws s3 ls
        return 1
    fi
}

generate_test_data() {
    local num_files=$1
    
    log_info "Gerando $num_files arquivos com dados sensíveis fictícios..."
    # $DATA_DIR foi criado via mktemp -d acima; apenas garantir perms privadas.
    chmod 700 "$DATA_DIR"
    
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
        GENERATED_FILES+=("$filepath")
        
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
    # Enviar apenas os arquivos que este script gerou; nunca globar $DATA_DIR
    # para evitar upload de arquivos plantados por outro usuário.
    for file in "${GENERATED_FILES[@]}"; do
        if [ -f "$file" ] && [ ! -L "$file" ]; then
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
            # $TEST_DIR / $DATA_DIR foram criados via mktemp -d no topo do script.
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

# Dar permissão de execução (perms privadas: só o dono executa).
chmod 700 "$SCRIPT_PATH"

echo "✅ Script principal criado: $SCRIPT_PATH"
echo ""
echo "🚀 COMO USAR:"
echo ""
echo "# Executar teste completo (gerar 3 arquivos)"
echo "$SCRIPT_PATH 3 test"
echo ""
echo "# Criar job imediato do Macie"
echo "$SCRIPT_PATH 0 job"
echo ""
echo "# Monitorar findings"
echo "$SCRIPT_PATH 0 monitor"
echo ""
echo "✅ INSTALAÇÃO CONCLUÍDA!"
echo "Execute: $SCRIPT_PATH 3 test"
