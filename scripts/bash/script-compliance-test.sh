## Execute esse comando manualmente copiando o conteúdo direto no terminal EC2##
## Usa mktemp para evitar caminhos previsíveis em /tmp (ataques de symlink/clobber).##


umask 077 && set -C && WORK_DIR="$(mktemp -d -t fsx-compliance.XXXXXXXX)" && chmod 700 "$WORK_DIR" && cd "$WORK_DIR" && TEST_SH="$WORK_DIR/test.sh" && cat > "$TEST_SH" << 'EOF'
#!/bin/bash

set -C
umask 077

# FSx Compliance Test - Linux Version
NUM_FILES=${1:-3}
ACTION=${2:-"test"}

echo "=== FSx COMPLIANCE TEST - LINUX ==="
echo "Teste de detecção de dados sensíveis"
echo ""

# Função para encontrar bucket
find_bucket() {
    echo "🔍 Procurando bucket de compliance..."
    BUCKET=$(aws s3api list-buckets --query "Buckets[?contains(Name, 'compliance')].Name" --output text 2>/dev/null | head -1)
    if [ -n "$BUCKET" ]; then
        echo "✅ Bucket encontrado: $BUCKET"
        return 0
    else
        echo "❌ Bucket não encontrado automaticamente"
        echo "Buckets disponíveis:"
        aws s3 ls
        return 1
    fi
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

# Criar diretório de dados de teste em caminho privado (mktemp) para evitar
# que outro usuário local plante arquivos em um caminho fixo e previsível.
DATA_DIR="$(mktemp -d -t fsx-test-data.XXXXXXXX)"
chmod 700 "$DATA_DIR"
# Rastrear arquivos gerados para o upload (nunca globar o diretório).
GENERATED_FILES=()
trap 'rm -rf -- "$DATA_DIR"' EXIT INT TERM HUP

for i in $(seq 1 $NUM_FILES); do
    timestamp=$(date +%Y%m%d_%H%M%S)
    filename="TestDocument_${i}_${timestamp}.txt"
    filepath="$DATA_DIR/$filename"
    
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
    
    GENERATED_FILES+=("$filepath")
    echo "✅ Criado: $filename"
done

echo ""
echo "📤 Enviando arquivos para S3..."

# Upload para S3 (apenas os arquivos gerados por este script).
upload_count=0
for file in "${GENERATED_FILES[@]}"; do
    if [ -f "$file" ] && [ ! -L "$file" ]; then
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
echo "   O diretório temporário ($DATA_DIR) será removido ao sair do script."

EOF

chmod 700 "$TEST_SH"
echo "Script salvo em: $TEST_SH"
echo "Execute com: \"$TEST_SH\" <num_files> <action>"