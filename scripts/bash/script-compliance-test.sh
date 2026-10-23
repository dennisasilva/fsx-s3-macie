## Execute esse comando manualmente copiando o conteúdo direto no terminal EC2##


mkdir -p /tmp/compliance-test && cd /tmp/compliance-test && cat > test.sh << 'EOF'
#!/bin/bash

# FSx Compliance Test - Linux Version
# ----------------------------------------------------------------------------
# Pré-parse de --bucket / --project / --stack / --yes para resolver o bucket
# autoritativamente (via output da stack CloudFormation + tag Project) em vez
# de uma busca por substring de nome, que casaria qualquer bucket cujo nome
# contenha 'compliance' na conta.
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

echo "=== FSx COMPLIANCE TEST - LINUX ==="
echo "Teste de detecção de dados sensíveis"
echo ""

# Função para encontrar bucket (resolução autoritativa via stack output + tag)
find_bucket() {
    echo "🔍 Resolvendo bucket de compliance a partir da stack ${STORAGE_STACK_NAME}..."
    if [ -n "$BUCKET_NAME" ]; then
        BUCKET="$BUCKET_NAME"
        echo "ℹ️  Usando bucket informado pelo operador: $BUCKET"
    else
        BUCKET=$(aws cloudformation describe-stacks \
            --stack-name "$STORAGE_STACK_NAME" \
            --region "$AWS_REGION" \
            --query 'Stacks[0].Outputs[?OutputKey==`ComplianceBucketName`].OutputValue' \
            --output text 2>/dev/null)
        if [ -z "$BUCKET" ] || [ "$BUCKET" = "None" ]; then
            echo "❌ Não foi possível resolver o bucket a partir da stack $STORAGE_STACK_NAME"
            echo "   Passe --bucket <nome> ou defina BUCKET_NAME para resolver manualmente."
            return 1
        fi
        # --output text separa múltiplos valores com tab; recusar ambiguidade.
        local count
        count=$(printf '%s' "$BUCKET" | tr '\t' '\n' | grep -c .)
        if [ "$count" -ne 1 ]; then
            echo "❌ Stack $STORAGE_STACK_NAME retornou $count valores para ComplianceBucketName; abortando"
            return 1
        fi
    fi

    # Verificar tag Project do bucket resolvido.
    local tags project_tag
    tags=$(aws s3api get-bucket-tagging --bucket "$BUCKET" --output json 2>/dev/null) || {
        echo "❌ Não foi possível ler as tags do bucket $BUCKET; abortando"
        return 1
    }
    project_tag=$(printf '%s' "$tags" | jq -r '.TagSet[]? | select(.Key=="Project") | .Value' 2>/dev/null)
    if [ "$project_tag" != "$PROJECT_NAME" ]; then
        echo "❌ Bucket $BUCKET não possui tag Project=$PROJECT_NAME (valor atual: '${project_tag:-<ausente>}'); abortando"
        return 1
    fi

    # Ecoa o nome e exige confirmação antes de qualquer s3 cp / rm /
    # macie2 create-classification-job.
    echo "⚠️  Bucket alvo resolvido: $BUCKET (projeto: $PROJECT_NAME)"
    if [ "$CONFIRM" = "1" ] || [ "$CONFIRM" = "yes" ] || [ "$CONFIRM" = "y" ]; then
        echo "✅ CONFIRM=$CONFIRM; prosseguindo"
    else
        if [ ! -t 0 ]; then
            echo "❌ Entrada não interativa e CONFIRM não setado; abortando"
            return 1
        fi
        local reply
        read -r -p "Digite 'yes' para operar neste bucket: " reply
        if [ "$reply" != "yes" ]; then
            echo "❌ Confirmação negada; abortando"
            return 1
        fi
    fi
    echo "✅ Bucket confirmado: $BUCKET"
    return 0
}

# Monitorar findings
if [ "$ACTION" = "monitor" ]; then
    echo "🔍 Verificando findings do Macie..."
    findings=$(aws macie2 list-findings --region us-east-1 --output json 2>/dev/null)
    if [ $? -eq 0 ]; then
        count=$(echo "$findings" | jq -r '.findingIds | length' 2>/dev/null || echo "0")
        if [ "$count" -gt 0 ]; then
            echo "🎉 FINDINGS ENCONTRADOS: $count"
            echo ""
            # Mostrar detalhes dos primeiros 3
            first_three=$(echo "$findings" | jq -r '.findingIds[0:3] | @json' 2>/dev/null)
            if [ -n "$first_three" ] && [ "$first_three" != "null" ]; then
                details=$(aws macie2 get-findings --finding-ids "$first_three" --region us-east-1 --output json 2>/dev/null)
                echo "$details" | jq -r '.findings[] | "   🔍 Tipo: \(.type)\n   ⚠️  Severidade: \(.severity)\n   📅 Data: \(.createdAt)\n   📄 Arquivo: \(.resourcesAffected.s3Object.key // "N/A")\n   ────────────────────────────────────────"' 2>/dev/null || echo "Erro ao processar detalhes"
            fi
        else
            echo "ℹ️  Nenhum finding encontrado ainda"
            echo ""
            echo "💡 DICAS:"
            echo "   • Aguarde alguns minutos após criar os arquivos"
            echo "   • Crie um job manual: ./test.sh 0 job"
            echo "   • Console: https://console.aws.amazon.com/macie/"
        fi
    else
        echo "⚠️  Erro ao acessar Macie ou jq não instalado"
        echo "Tentando comando simples..."
        aws macie2 list-findings --region us-east-1 --query 'findingIds | length(@)' --output text 2>/dev/null | xargs -I {} echo "Total de findings: {}"
    fi
    exit 0
fi

# Criar job imediato
if [ "$ACTION" = "job" ]; then
    find_bucket || exit 1
    echo "🚀 Criando job de classificação imediato..."
    
    account=$(aws sts get-caller-identity --query Account --output text)
    job_name="compliance-test-$(date +%Y%m%d%H%M%S)"
    
    echo "Account ID: $account"
    echo "Job Name: $job_name"
    echo "Bucket: $BUCKET"
    
    job_result=$(aws macie2 create-classification-job \
        --job-type ONE_TIME \
        --name "$job_name" \
        --description "Job imediato para teste de compliance - dados fictícios" \
        --s3-job-definition "{
            \"bucketDefinitions\": [{
                \"accountId\": \"$account\",
                \"buckets\": [\"$BUCKET\"]
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
        --region us-east-1 \
        --output json 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        echo "✅ Job criado com sucesso!"
        echo "Job ID: $(echo "$job_result" | jq -r '.jobId' 2>/dev/null || echo 'N/A')"
        echo ""
        echo "⏰ Aguarde alguns minutos para execução..."
        echo "Monitore com: ./test.sh 0 monitor"
    else
        echo "❌ Erro ao criar job"
        echo "💡 Crie manualmente no console: https://console.aws.amazon.com/macie/"
    fi
    exit 0
fi

# Teste principal - gerar dados
echo "📄 Gerando $NUM_FILES arquivos com dados sensíveis fictícios..."

find_bucket || exit 1

# Criar diretório de dados de teste
mkdir -p /tmp/test-data

for i in $(seq 1 $NUM_FILES); do
    timestamp=$(date +%Y%m%d_%H%M%S)
    filename="TestDocument_${i}_${timestamp}.txt"
    filepath="/tmp/test-data/$filename"
    
    # Gerar dados fictícios variados
    cpf="$(printf "%03d" $((100 + i))).$(printf "%03d" $((200 + i))).$(printf "%03d" $((300 + i)))-$(printf "%02d" $((10 + i)))"
    card="4532-$(printf "%04d" $((1000 + i)))-$(printf "%04d" $((2000 + i)))-$(printf "%04d" $((3000 + i)))"
    ssn="$(printf "%03d" $((100 + i)))-$(printf "%02d" $((10 + i)))-$(printf "%04d" $((1000 + i)))"
    
    cat > "$filepath" << DOCEOF
DOCUMENTO DE TESTE - CONFIDENCIAL
=================================
Data: $(date '+%d/%m/%Y %H:%M:%S')
Documento #$i de $NUM_FILES

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
DOCEOF
    
    echo "✅ Criado: $filename"
done

echo ""
echo "📤 Enviando arquivos para S3..."

# Upload para S3
upload_count=0
for file in /tmp/test-data/*; do
    if [ -f "$file" ]; then
        filename=$(basename "$file")
        if aws s3 cp "$file" "s3://$BUCKET/fsx-sync/$filename"; then
            echo "✅ Enviado: $filename"
            ((upload_count++))
        else
            echo "❌ Erro ao enviar: $filename"
        fi
    fi
done

echo ""
echo "✅ $upload_count arquivos enviados para s3://$BUCKET/fsx-sync/"

# Verificar upload
echo ""
echo "🔍 Verificando arquivos no S3..."
file_count=$(aws s3 ls "s3://$BUCKET/fsx-sync/" --recursive | grep TestDocument | wc -l)
echo "Arquivos TestDocument no S3: $file_count"

echo ""
echo "=== TESTE CONFIGURADO COM SUCESSO ==="
echo ""
echo "📋 PRÓXIMOS PASSOS:"
echo "1. Criar job imediato: ./test.sh 0 job"
echo "2. Monitorar findings: ./test.sh 0 monitor"
echo "3. Console Macie: https://console.aws.amazon.com/macie/"
echo ""
echo "🔗 LINKS ÚTEIS:"
echo "   • Console Macie: https://console.aws.amazon.com/macie/"
echo "   • CloudWatch Logs: https://console.aws.amazon.com/cloudwatch/"
echo ""
echo "⚠️  LEMBRETE:"
echo "   Todos os dados são FICTÍCIOS para teste apenas!"
echo "   Remova após validação: rm -rf /tmp/test-data"

EOF