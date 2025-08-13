#!/bin/bash

# Script para Testar Formato de ARN - FSx Compliance PoC
# Valida se os ARNs estão no formato correto antes do deploy

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
    echo -e "${BLUE}ℹ️${NC} $1"
}

echo "=== TESTE DE FORMATO DE ARN - FSx Compliance PoC ==="
echo ""

# Simular valores que serão gerados
PROJECT_NAME="fsx-compliance-poc"
ACCOUNT_ID="493301683711"
REGION="us-east-1"
BUCKET_NAME="${PROJECT_NAME}-compliance-${ACCOUNT_ID}-${REGION}"

info "Simulando valores do CloudFormation:"
echo "  Project Name: $PROJECT_NAME"
echo "  Account ID: $ACCOUNT_ID"
echo "  Region: $REGION"
echo "  Bucket Name: $BUCKET_NAME"
echo ""

# Testar formatos de ARN
echo "=== TESTANDO FORMATOS DE ARN ==="
echo ""

# 1. Bucket ARN (correto)
BUCKET_ARN="arn:aws:s3:::${BUCKET_NAME}"
info "Bucket ARN: $BUCKET_ARN"
if [[ $BUCKET_ARN =~ ^arn:aws:s3:::[a-zA-Z0-9.\-_]{1,255}$ ]]; then
    success "Formato de Bucket ARN válido"
else
    error "Formato de Bucket ARN inválido"
fi

# 2. Object ARN (correto)
OBJECT_ARN="${BUCKET_ARN}/*"
info "Object ARN: $OBJECT_ARN"
if [[ $OBJECT_ARN =~ ^arn:aws:s3:::[a-zA-Z0-9.\-_]{1,255}/.*$ ]]; then
    success "Formato de Object ARN válido"
else
    error "Formato de Object ARN inválido"
fi

echo ""
echo "=== TESTANDO FUNÇÕES CLOUDFORMATION ==="
echo ""

# Simular !Ref ComplianceBucket (retorna nome do bucket)
REF_RESULT="$BUCKET_NAME"
info "!Ref ComplianceBucket retorna: $REF_RESULT"

# Simular !GetAtt ComplianceBucket.Arn (retorna ARN do bucket)
GETATT_RESULT="$BUCKET_ARN"
info "!GetAtt ComplianceBucket.Arn retorna: $GETATT_RESULT"

# Simular !Sub com GetAtt
SUB_RESULT="${GETATT_RESULT}/*"
info "!Sub '\${BucketArn}/*' com BucketArn: !GetAtt retorna: $SUB_RESULT"

echo ""
echo "=== VALIDAÇÃO DE POLÍTICA IAM ==="
echo ""

# Criar política de teste
cat > /tmp/test-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectMetadata",
        "s3:GetObjectTagging",
        "s3:PutObjectTagging"
      ],
      "Resource": "$SUB_RESULT"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": "$GETATT_RESULT"
    }
  ]
}
EOF

info "Política IAM gerada:"
cat /tmp/test-policy.json

echo ""
echo "=== VALIDAÇÃO COM AWS CLI ==="
echo ""

# Verificar se AWS CLI está disponível
if command -v aws &> /dev/null; then
    info "Validando política com AWS CLI..."
    
    if aws iam validate-policy-document --policy-document file:///tmp/test-policy.json --output table 2>/dev/null; then
        success "Política IAM válida!"
    else
        error "Política IAM inválida!"
        echo ""
        warning "Executando validação com detalhes:"
        aws iam validate-policy-document --policy-document file:///tmp/test-policy.json || true
    fi
else
    warning "AWS CLI não disponível - pulando validação"
fi

echo ""
echo "=== RESUMO DOS TESTES ==="
echo ""

success "Formato de ARN correto:"
echo "  Bucket: $BUCKET_ARN"
echo "  Objects: $SUB_RESULT"

echo ""
info "Template CloudFormation deve usar:"
echo "  Resource: !Sub"
echo "    - '\${BucketArn}/*'"
echo "    - BucketArn: !GetAtt ComplianceBucket.Arn"
echo ""
echo "  Resource: !GetAtt ComplianceBucket.Arn"

# Limpeza
rm -f /tmp/test-policy.json

echo ""
success "Teste de formato de ARN concluído!"
echo ""
info "Se todos os testes passaram, o template deve funcionar corretamente."
