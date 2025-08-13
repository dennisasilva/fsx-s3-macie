#!/bin/bash

# Script para Limpar Buckets S3 Órfãos - FSx Compliance PoC
# Remove buckets que ficaram órfãos após falhas de deploy

set -e

# Configurações
PROJECT_NAME="fsx-compliance-poc"
REGION="us-east-1"

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

echo "=== LIMPEZA DE BUCKETS S3 ÓRFÃOS - FSx Compliance PoC ==="
echo ""

# Verificar AWS CLI
if ! command -v aws &> /dev/null; then
    error "AWS CLI não encontrado. Instale o AWS CLI primeiro."
    exit 1
fi

# Verificar credenciais AWS
if ! aws sts get-caller-identity &> /dev/null; then
    error "Credenciais AWS não configuradas. Execute 'aws configure' primeiro."
    exit 1
fi

info "Região: $REGION"
info "Projeto: $PROJECT_NAME"
echo ""

# Buscar buckets relacionados ao projeto
info "Buscando buckets relacionados ao projeto..."

# Padrões de nome de bucket para o projeto
BUCKET_PATTERNS=(
    "${PROJECT_NAME}-compliance-"
    "fsx-compliance-poc-compliance-"
)

orphan_buckets=()

for pattern in "${BUCKET_PATTERNS[@]}"; do
    info "Procurando buckets com padrão: $pattern*"
    
    # Listar buckets que correspondem ao padrão
    buckets=$(aws s3api list-buckets \
        --region "$REGION" \
        --query "Buckets[?starts_with(Name, '$pattern')].Name" \
        --output text 2>/dev/null || echo "")
    
    if [ ! -z "$buckets" ]; then
        for bucket in $buckets; do
            info "Bucket encontrado: $bucket"
            
            # Verificar se o bucket está sendo usado por alguma stack ativa
            stack_found=false
            
            # Verificar stacks do CloudFormation
            stacks=$(aws cloudformation list-stacks \
                --region "$REGION" \
                --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE CREATE_IN_PROGRESS UPDATE_IN_PROGRESS \
                --query 'StackSummaries[].StackName' \
                --output text 2>/dev/null || echo "")
            
            for stack in $stacks; do
                # Verificar se a stack tem outputs que referenciam este bucket
                outputs=$(aws cloudformation describe-stacks \
                    --stack-name "$stack" \
                    --region "$REGION" \
                    --query 'Stacks[0].Outputs[?contains(OutputValue, `'$bucket'`)].OutputValue' \
                    --output text 2>/dev/null || echo "")
                
                if [ ! -z "$outputs" ]; then
                    info "Bucket $bucket está sendo usado pela stack: $stack"
                    stack_found=true
                    break
                fi
            done
            
            if [ "$stack_found" = false ]; then
                warning "Bucket órfão encontrado: $bucket"
                orphan_buckets+=("$bucket")
            fi
        done
    fi
done

echo ""

if [ ${#orphan_buckets[@]} -eq 0 ]; then
    success "Nenhum bucket órfão encontrado!"
    exit 0
fi

# Mostrar buckets órfãos encontrados
warning "Buckets órfãos encontrados (${#orphan_buckets[@]}):"
for bucket in "${orphan_buckets[@]}"; do
    echo "  - $bucket"
done

echo ""
warning "⚠️  ATENÇÃO: Esta operação irá DELETAR os buckets órfãos!"
echo ""
echo "Buckets que serão removidos:"
for bucket in "${orphan_buckets[@]}"; do
    # Verificar se o bucket tem objetos
    object_count=$(aws s3api list-objects-v2 \
        --bucket "$bucket" \
        --region "$REGION" \
        --query 'length(Contents)' \
        --output text 2>/dev/null || echo "0")
    
    if [ "$object_count" = "None" ]; then
        object_count="0"
    fi
    
    echo "  - $bucket (objetos: $object_count)"
done

echo ""
read -p "Digite 'DELETE' para confirmar a remoção dos buckets órfãos: " confirm

if [ "$confirm" = "DELETE" ]; then
    echo ""
    info "Iniciando limpeza de buckets órfãos..."
    
    for bucket in "${orphan_buckets[@]}"; do
        info "Processando bucket: $bucket"
        
        # Verificar se o bucket existe
        if aws s3api head-bucket --bucket "$bucket" --region "$REGION" 2>/dev/null; then
            # Verificar se tem objetos
            object_count=$(aws s3api list-objects-v2 \
                --bucket "$bucket" \
                --region "$REGION" \
                --query 'length(Contents)' \
                --output text 2>/dev/null || echo "0")
            
            if [ "$object_count" != "0" ] && [ "$object_count" != "None" ]; then
                warning "Esvaziando bucket $bucket ($object_count objetos)..."
                
                # Esvaziar bucket
                if aws s3 rm "s3://$bucket" --recursive --region "$REGION"; then
                    success "Bucket $bucket esvaziado"
                else
                    error "Falha ao esvaziar bucket $bucket"
                    continue
                fi
            fi
            
            # Verificar versionamento
            versioning=$(aws s3api get-bucket-versioning \
                --bucket "$bucket" \
                --region "$REGION" \
                --query 'Status' \
                --output text 2>/dev/null || echo "None")
            
            if [ "$versioning" = "Enabled" ]; then
                warning "Removendo versões do bucket $bucket..."
                
                # Remover todas as versões
                aws s3api list-object-versions \
                    --bucket "$bucket" \
                    --region "$REGION" \
                    --output json | \
                jq -r '.Versions[]?, .DeleteMarkers[]? | select(.Key != null) | "\(.Key) \(.VersionId)"' | \
                while read key version_id; do
                    if [ ! -z "$key" ] && [ ! -z "$version_id" ]; then
                        aws s3api delete-object \
                            --bucket "$bucket" \
                            --key "$key" \
                            --version-id "$version_id" \
                            --region "$REGION" >/dev/null 2>&1 || true
                    fi
                done
            fi
            
            # Deletar bucket
            info "Deletando bucket: $bucket"
            if aws s3api delete-bucket --bucket "$bucket" --region "$REGION"; then
                success "Bucket $bucket deletado com sucesso"
            else
                error "Falha ao deletar bucket $bucket"
            fi
        else
            warning "Bucket $bucket não existe ou não é acessível"
        fi
    done
    
    echo ""
    success "Limpeza de buckets órfãos concluída!"
    
else
    info "Limpeza cancelada pelo usuário"
fi

echo ""
info "Para evitar buckets órfãos no futuro:"
echo "• Use o script fix-rollback-stacks.sh para corrigir stacks problemáticas"
echo "• Execute cleanup completo via deploy script (opção 9)"
echo "• Monitore stacks em estado ROLLBACK_COMPLETE"
