#!/bin/bash

# Script para Limpar Buckets S3 Orfaos - FSx Compliance PoC
# Remove buckets que ficaram orfaos apos falhas de deploy
#
# Seguranca (fail-closed):
#   * Qualquer falha em CloudFormation list-stacks / describe-stack-resources
#     aborta o run.
#   * A posse do bucket e confirmada positivamente: TAG do projeto
#     (Project=<PROJECT_NAME>) E ausencia do bucket entre os StackResources
#     de QUALQUER stack em QUALQUER status.
#   * Cada bucket exige confirmacao individual (digitar o nome do bucket).
#   * Contagens reais de objetos e versoes sao exibidas antes da remocao.
#   * Em buckets versionados, versoes e delete markers so sao removidos
#     se --force-versions for passado explicitamente.

set -e
set -o pipefail

PROJECT_NAME="fsx-compliance-poc"
REGION="us-east-1"

FORCE_VERSIONS=false
for arg in "$@"; do
    case "$arg" in
        --force-versions)
            FORCE_VERSIONS=true
            ;;
        -h|--help)
            cat <<EOF
Uso: $0 [--force-versions]

  --force-versions   Permite remover versoes de objeto e delete markers de
                     buckets versionados classificados como orfaos.
                     Sem esta flag, buckets versionados com conteudo
                     historico NAO sao excluidos (fail-safe).
EOF
            exit 0
            ;;
    esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

success() { echo -e "${GREEN}OK${NC} $1"; }
error()   { echo -e "${RED}ERR${NC} $1"; }
warning() { echo -e "${YELLOW}WARN${NC} $1"; }
info()    { echo -e "${BLUE}INFO${NC} $1"; }

fatal() {
    error "$1"
    error "Abortando execucao por seguranca (fail-closed)."
    exit 1
}

echo "=== LIMPEZA DE BUCKETS S3 ORFAOS - FSx Compliance PoC ==="
echo ""

if ! command -v aws &> /dev/null; then
    error "AWS CLI nao encontrado. Instale o AWS CLI primeiro."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    error "jq nao encontrado. Instale o jq primeiro."
    exit 1
fi

if ! aws sts get-caller-identity &> /dev/null; then
    error "Credenciais AWS nao configuradas. Execute 'aws configure' primeiro."
    exit 1
fi

info "Regiao: $REGION"
info "Projeto: $PROJECT_NAME"
if [ "$FORCE_VERSIONS" = true ]; then
    warning "--force-versions ATIVO: versoes e delete markers de buckets versionados PODERAO ser removidos."
else
    info "--force-versions NAO ativo: buckets versionados nao terao versoes/delete markers removidos."
fi
echo ""

# ---------------------------------------------------------------------------
# 1) Listar TODAS as stacks em TODOS os status (fail-closed).
# ---------------------------------------------------------------------------
info "Listando TODAS as stacks CloudFormation (todos os status)..."

ALL_STACK_STATUSES=(
    CREATE_IN_PROGRESS CREATE_FAILED CREATE_COMPLETE
    ROLLBACK_IN_PROGRESS ROLLBACK_FAILED ROLLBACK_COMPLETE
    DELETE_IN_PROGRESS DELETE_FAILED
    UPDATE_IN_PROGRESS UPDATE_COMPLETE_CLEANUP_IN_PROGRESS UPDATE_COMPLETE
    UPDATE_FAILED
    UPDATE_ROLLBACK_IN_PROGRESS UPDATE_ROLLBACK_FAILED
    UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS UPDATE_ROLLBACK_COMPLETE
    REVIEW_IN_PROGRESS
    IMPORT_IN_PROGRESS IMPORT_COMPLETE
    IMPORT_ROLLBACK_IN_PROGRESS IMPORT_ROLLBACK_FAILED IMPORT_ROLLBACK_COMPLETE
)

set +e
stacks_output=$(aws cloudformation list-stacks \
    --region "$REGION" \
    --stack-status-filter "${ALL_STACK_STATUSES[@]}" \
    --query 'StackSummaries[].StackName' \
    --output text)
list_stacks_rc=$?
set -e

if [ "$list_stacks_rc" -ne 0 ]; then
    fatal "aws cloudformation list-stacks falhou (rc=$list_stacks_rc). Impossivel classificar buckets com seguranca."
fi

if [ -z "$stacks_output" ] || [ "$stacks_output" = "None" ]; then
    fatal "list-stacks retornou nenhuma stack. Recusando prosseguir para evitar classificar buckets em uso como orfaos."
fi

read -r -a all_stacks <<< "$stacks_output"
info "Encontradas ${#all_stacks[@]} stack(s)."

# ---------------------------------------------------------------------------
# 2) Para cada stack, coletar PhysicalResourceId dos recursos AWS::S3::Bucket.
# ---------------------------------------------------------------------------
info "Coletando recursos S3::Bucket de todas as stacks..."

declare -A stack_of_bucket=()

for stack in "${all_stacks[@]}"; do
    [ -z "$stack" ] && continue

    set +e
    resources_output=$(aws cloudformation describe-stack-resources \
        --stack-name "$stack" \
        --region "$REGION" \
        --query 'StackResources[?ResourceType==`AWS::S3::Bucket`].PhysicalResourceId' \
        --output text)
    desc_rc=$?
    set -e

    if [ "$desc_rc" -ne 0 ]; then
        fatal "aws cloudformation describe-stack-resources falhou para a stack '$stack' (rc=$desc_rc)."
    fi

    if [ -z "$resources_output" ] || [ "$resources_output" = "None" ]; then
        continue
    fi

    for bname in $resources_output; do
        [ -z "$bname" ] && continue
        [ "$bname" = "None" ] && continue
        stack_of_bucket["$bname"]="$stack"
    done
done

info "Mapeamento stack->bucket construido (${#stack_of_bucket[@]} buckets referenciados por stacks)."
echo ""

# ---------------------------------------------------------------------------
# 3) Enumerar candidatos: nome com padrao do projeto E tag Project=<PROJECT_NAME>
#    E ausente de qualquer StackResources.
# ---------------------------------------------------------------------------
info "Buscando buckets relacionados ao projeto..."

BUCKET_PATTERNS=(
    "${PROJECT_NAME}-compliance-"
    "fsx-compliance-poc-compliance-"
)

orphan_buckets=()

for pattern in "${BUCKET_PATTERNS[@]}"; do
    info "Procurando buckets com padrao: $pattern*"

    set +e
    buckets=$(aws s3api list-buckets \
        --region "$REGION" \
        --query "Buckets[?starts_with(Name, '$pattern')].Name" \
        --output text)
    lb_rc=$?
    set -e

    if [ "$lb_rc" -ne 0 ]; then
        fatal "aws s3api list-buckets falhou (rc=$lb_rc)."
    fi

    if [ -z "$buckets" ] || [ "$buckets" = "None" ]; then
        continue
    fi

    for bucket in $buckets; do
        info "Candidato: $bucket"

        # (a) Confirmar posse por TAG; distinguir NoSuchTagSet de outros erros.
        set +e
        tagging_output=$(aws s3api get-bucket-tagging \
            --bucket "$bucket" \
            --region "$REGION" \
            --query "TagSet[?Key=='Project'].Value" \
            --output text 2>/tmp/.cleanup_tag_err_$$)
        tag_rc=$?
        tag_err=$(cat /tmp/.cleanup_tag_err_$$ 2>/dev/null || true)
        rm -f /tmp/.cleanup_tag_err_$$
        set -e

        if [ "$tag_rc" -ne 0 ]; then
            if echo "$tag_err" | grep -q "NoSuchTagSet"; then
                info "  -> Bucket $bucket nao tem tags; nao e do projeto. Pulando."
                continue
            else
                fatal "get-bucket-tagging falhou para '$bucket' (rc=$tag_rc): $tag_err"
            fi
        fi

        if [ "$tagging_output" != "$PROJECT_NAME" ]; then
            info "  -> Bucket $bucket nao carrega a tag Project=$PROJECT_NAME. Pulando."
            continue
        fi

        # (b) O bucket esta referenciado por alguma stack?
        if [ -n "${stack_of_bucket[$bucket]+x}" ]; then
            info "  -> Bucket $bucket esta sendo usado pela stack: ${stack_of_bucket[$bucket]} (nao e orfao)."
            continue
        fi

        warning "Bucket orfao encontrado: $bucket"
        orphan_buckets+=("$bucket")
    done
done

echo ""

if [ ${#orphan_buckets[@]} -eq 0 ]; then
    success "Nenhum bucket orfao encontrado!"
    exit 0
fi

# ---------------------------------------------------------------------------
# 4) Preview: contagem REAL de objetos e versoes.
# ---------------------------------------------------------------------------
warning "Buckets orfaos encontrados (${#orphan_buckets[@]}):"

declare -A bucket_object_count=()
declare -A bucket_version_count=()
declare -A bucket_delete_marker_count=()
declare -A bucket_versioning=()

for bucket in "${orphan_buckets[@]}"; do
    set +e
    obj_count=$(aws s3api list-objects-v2 \
        --bucket "$bucket" \
        --region "$REGION" \
        --query 'length(Contents)' \
        --output text 2>/dev/null)
    oc_rc=$?
    set -e
    if [ "$oc_rc" -ne 0 ] || [ -z "$obj_count" ] || [ "$obj_count" = "None" ]; then
        obj_count="0"
    fi
    bucket_object_count["$bucket"]="$obj_count"

    set +e
    versioning=$(aws s3api get-bucket-versioning \
        --bucket "$bucket" \
        --region "$REGION" \
        --query 'Status' \
        --output text 2>/dev/null)
    v_rc=$?
    set -e
    if [ "$v_rc" -ne 0 ] || [ -z "$versioning" ] || [ "$versioning" = "None" ]; then
        versioning="Disabled"
    fi
    bucket_versioning["$bucket"]="$versioning"

    ver_count=0
    dm_count=0
    if [ "$versioning" = "Enabled" ] || [ "$versioning" = "Suspended" ]; then
        set +e
        lov_json=$(aws s3api list-object-versions \
            --bucket "$bucket" \
            --region "$REGION" \
            --output json 2>/dev/null)
        lov_rc=$?
        set -e
        if [ "$lov_rc" -eq 0 ] && [ -n "$lov_json" ]; then
            ver_count=$(echo "$lov_json" | jq '(.Versions // []) | length')
            dm_count=$(echo "$lov_json"  | jq '(.DeleteMarkers // []) | length')
        fi
    fi
    bucket_version_count["$bucket"]="$ver_count"
    bucket_delete_marker_count["$bucket"]="$dm_count"

    echo "  - $bucket"
    echo "      objetos atuais: $obj_count"
    echo "      versionamento:  $versioning"
    echo "      versoes:        $ver_count"
    echo "      delete markers: $dm_count"
done

echo ""
warning "ATENCAO: Esta operacao ira DELETAR os buckets listados!"
if [ "$FORCE_VERSIONS" != true ]; then
    info "Buckets versionados com historico NAO serao excluidos (use --force-versions se desejar)."
fi
echo ""

# ---------------------------------------------------------------------------
# 5) Confirmacao individual por bucket (digitar o nome exato).
# ---------------------------------------------------------------------------
for bucket in "${orphan_buckets[@]}"; do
    echo ""
    warning "Prestes a processar: $bucket"
    echo "  objetos=${bucket_object_count[$bucket]} versoes=${bucket_version_count[$bucket]} delete_markers=${bucket_delete_marker_count[$bucket]} versionamento=${bucket_versioning[$bucket]}"
    read -p "Digite o NOME EXATO do bucket para confirmar a remocao (ou ENTER para pular): " confirm

    if [ "$confirm" != "$bucket" ]; then
        info "Pulando $bucket (confirmacao nao corresponde)."
        continue
    fi

    if ! aws s3api head-bucket --bucket "$bucket" --region "$REGION" 2>/dev/null; then
        warning "Bucket $bucket nao existe ou nao e acessivel"
        continue
    fi

    versioning="${bucket_versioning[$bucket]}"
    ver_count="${bucket_version_count[$bucket]}"
    dm_count="${bucket_delete_marker_count[$bucket]}"
    obj_count="${bucket_object_count[$bucket]}"

    # Esvaziar objetos atuais
    if [ "$obj_count" != "0" ] && [ "$obj_count" != "None" ]; then
        warning "Esvaziando bucket $bucket ($obj_count objetos atuais)..."
        if aws s3 rm "s3://$bucket" --recursive --region "$REGION"; then
            success "Bucket $bucket esvaziado (versao corrente)"
        else
            error "Falha ao esvaziar bucket $bucket"
            continue
        fi
    fi

    # Versoes / delete markers: so com --force-versions
    if [ "$versioning" = "Enabled" ] || [ "$versioning" = "Suspended" ]; then
        if [ "$ver_count" != "0" ] || [ "$dm_count" != "0" ]; then
            if [ "$FORCE_VERSIONS" != true ]; then
                error "Bucket $bucket e versionado e contem $ver_count versoes e $dm_count delete markers."
                error "Recusando remover historico sem a flag --force-versions. Pulando este bucket."
                continue
            fi

            warning "Removendo versoes e delete markers de $bucket (--force-versions ativo)..."
            set +e
            aws s3api list-object-versions \
                --bucket "$bucket" \
                --region "$REGION" \
                --output json | \
            jq -r '(.Versions // []) + (.DeleteMarkers // []) | .[] | select(.Key != null) | "\(.Key)\t\(.VersionId)"' | \
            while IFS=$'\t' read -r key version_id; do
                if [ -n "$key" ] && [ -n "$version_id" ]; then
                    aws s3api delete-object \
                        --bucket "$bucket" \
                        --key "$key" \
                        --version-id "$version_id" \
                        --region "$REGION" >/dev/null
                fi
            done
            pipe_rc=$?
            set -e
            if [ "$pipe_rc" -ne 0 ]; then
                error "Falha ao remover versoes/delete markers de $bucket. Pulando delete-bucket."
                continue
            fi
        fi
    fi

    info "Deletando bucket: $bucket"
    if aws s3api delete-bucket --bucket "$bucket" --region "$REGION"; then
        success "Bucket $bucket deletado com sucesso"
    else
        error "Falha ao deletar bucket $bucket"
    fi
done

echo ""
success "Processamento concluido."

echo ""
info "Para evitar buckets orfaos no futuro:"
echo "- Use o script fix-rollback-stacks.sh para corrigir stacks problematicas"
echo "- Execute cleanup completo via deploy script (opcao 9)"
echo "- Monitore stacks em estado ROLLBACK_COMPLETE"
