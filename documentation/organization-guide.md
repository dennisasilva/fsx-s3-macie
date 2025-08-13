# 🗂️ Guia de Organização do Projeto

Este documento descreve como o projeto FSx S3 Macie Compliance PoC está organizado e como manter essa organização.

## 📁 Estrutura de Pastas

### Organização por Tipo de Arquivo

O projeto segue uma estrutura organizada por tipo de arquivo para facilitar a navegação e manutenção:

```
fsx-s3-macie/
├── README.md                    # Documentação principal
├── ORGANIZATION-GUIDE.md        # Este guia
├── organize-project.sh          # Script de organização automática
├── scripts/                     # Scripts de automação
│   ├── powershell/             # Scripts PowerShell (.ps1)
│   │   ├── quick-compliance-test.ps1
│   │   ├── run-compliance-test.ps1
│   │   ├── monitor-compliance-findings.ps1
│   │   ├── download-scripts.ps1
│   │   └── generate-test-data.ps1
│   └── bash/                   # Scripts Shell (.sh)
│       ├── deploy-fsx-compliance-poc.sh
│       ├── cleanup-orphan-buckets.sh
│       ├── validate-files.sh
│       ├── test-debug.sh
│       ├── debug-macie.sh
│       ├── fix-rollback-stacks.sh
│       ├── test-arn-format.sh
│       ├── compliance-test-linux.sh
│       ├── script-compliance-test.sh
│       └── install-compliance-test.sh
├── cloudformation/             # Templates CloudFormation
│   ├── fsx-storage.yaml
│   ├── fsx-compliance-main.yaml
│   ├── windows-client.yaml
│   └── macie-processing.yaml
├── documentation/              # Documentação do projeto
│   ├── readme-compliance-test.md
│   ├── arn-troubleshooting.md
│   ├── rollback-handling.md
│   ├── fsx-integration-flows.md
│   ├── data-flow-diagram.md
│   ├── architecture-diagram.md
│   ├── fsx-macie-architecture.md
│   ├── fixes-applied.md
│   ├── ssm-agent-troubleshooting.md
│   ├── manual-domain-datasync-setup.md
│   ├── ami-final-update.md
│   ├── domain-datasync-improvements.md
│   ├── organization-guide.md
│   └── path-corrections-summary.md
└── config/                     # Arquivos de configuração
    ├── parameters-example.json
    ├── deployment-info.txt
    ├── steps-script-compliance-test.txt
    └── .fsx-compliance-config
```

## 🔧 Como Organizar Novos Arquivos

### Regras de Organização

1. **Scripts PowerShell (.ps1)** → `scripts/powershell/`
2. **Scripts Bash (.sh)** → `scripts/bash/`
3. **Templates CloudFormation (.yaml, .yml)** → `cloudformation/`
4. **Documentação (.md)** → `documentation/`
5. **Configurações (.json, .txt, .config)** → `config/`

### Script de Organização Automática

Para reorganizar automaticamente todos os arquivos, execute:

```bash
./organize-project.sh
```

Este script:
- Cria a estrutura de pastas necessária
- Move arquivos para as pastas corretas baseado na extensão
- Exibe um resumo da organização
- Mantém as permissões dos arquivos

### Organização Manual

Se preferir organizar manualmente:

```bash
# Criar estrutura de pastas
mkdir -p scripts/powershell scripts/bash cloudformation documentation config

# Mover arquivos PowerShell
mv *.ps1 scripts/powershell/

# Mover scripts Bash
mv *.sh scripts/bash/

# Mover templates CloudFormation
mv *.yaml *.yml cloudformation/

# Mover documentação
mv *.md documentation/

# Mover configurações
mv *.json *.txt *.config config/
mv .fsx-compliance-config config/
```

## 📋 Convenções de Nomenclatura

### Scripts PowerShell
- Use kebab-case: `quick-compliance-test.ps1`
- Prefixos comuns:
  - `run-` para execução de processos
  - `monitor-` para monitoramento
  - `generate-` para geração de dados
  - `download-` para downloads

### Scripts Bash
- Use kebab-case: `deploy-fsx-compliance-poc.sh`
- Prefixos comuns:
  - `deploy-` para deployment
  - `cleanup-` para limpeza
  - `validate-` para validação
  - `test-` para testes
  - `debug-` para debug
  - `fix-` para correções
  - `install-` para instalação

### Templates CloudFormation
- Use kebab-case: `fsx-storage.yaml`
- Nomes descritivos do componente principal
- Sempre use extensão `.yaml`

### Documentação
- Use UPPERCASE para documentos importantes: `README.md`
- Use kebab-case para documentos específicos: `data-flow-diagram.md`
- Prefixos comuns:
  - `README-` para documentação principal
  - `TROUBLESHOOTING` para resolução de problemas
  - `FIXES-` para correções aplicadas

### Configurações
- Use kebab-case: `parameters-example.json`
- Sufixos comuns:
  - `-example` para exemplos
  - `-template` para templates
  - `-info` para informações

## 🚀 Benefícios da Organização

### Facilita Navegação
- Arquivos agrupados por função
- Estrutura previsível
- Fácil localização de recursos

### Melhora Manutenção
- Separação clara de responsabilidades
- Facilita atualizações
- Reduz conflitos de merge

### Padronização
- Estrutura consistente
- Convenções claras
- Facilita colaboração

## 🔍 Verificação da Organização

Para verificar se a organização está correta:

```bash
# Verificar estrutura de pastas
ls -la

# Verificar conteúdo de cada pasta
find . -type f -name "*.ps1" | head -5
find . -type f -name "*.sh" | head -5
find . -type f -name "*.yaml" | head -5
find . -type f -name "*.md" | head -5
find . -type f -name "*.json" | head -5
```

## 📝 Manutenção Contínua

### Ao Adicionar Novos Arquivos
1. Siga as convenções de nomenclatura
2. Coloque na pasta apropriada
3. Atualize a documentação se necessário
4. Execute `./organize-project.sh` se houver dúvidas

### Revisão Periódica
- Verifique mensalmente a organização
- Remova arquivos obsoletos
- Atualize documentação conforme necessário
- Mantenha as convenções consistentes

## 🆘 Solução de Problemas

### Arquivo na Pasta Errada
```bash
# Mover arquivo para pasta correta
mv arquivo-errado.ext pasta-correta/
```

### Estrutura Desorganizada
```bash
# Executar reorganização automática
./organize-project.sh
```

### Permissões Perdidas
```bash
# Restaurar permissões de execução para scripts
chmod +x scripts/bash/*.sh
chmod +x scripts/powershell/*.ps1
```

---

**Última atualização**: 13 de agosto de 2025
**Versão**: 1.0
