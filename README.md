# Aliber Financeiro

Plano de contas, fornecedores, contas a pagar e DRE por período para os clientes do PDV+ (Aliber Sistema).

- **sincronizador/**: programa Aliber Financeiro (com instalador) que fica no computador do caixa. Lê o banco do PDV+
  **só para leitura** e envia um resumo diário das vendas para a nuvem a cada 15 minutos.
- **docs/**: o painel online (publicado pelo GitHub Pages). O dono da loja entra com e-mail e senha.
- **painel/**: código-fonte do painel. `python painel/montar.py` gera `docs/index.html`.
- **supabase/banco.sql**: banco de dados na nuvem (tabelas, segurança por loja, plano de contas padrão).

**Baixar o instalador:** [AliberFinanceiro-Instalador.exe (última versão)](../../releases/latest/download/AliberFinanceiro-Instalador.exe)

## Publicar uma versão nova do sincronizador
1. Altere `VERSAO` em `sincronizador/financeiro.py` e descreva as mudanças em `sincronizador/NOVIDADES.txt`.
2. Envie para o ramo `main`. O GitHub compila, monta o instalador, testa a instalação e publica a versão.
3. Nos clientes, o técnico troca a versão em Configurações > Versões (técnico), com a senha do técnico
   (a mesma do Aliber Print, `sincronizador/marca.json`). Atualização sozinha só se o técnico ligar.

## Plano de contas e DRE gerencial
O plano padrão segue o modelo gerencial em três níveis (grupo, subgrupo e conta), com 18 subgrupos e 112 contas:
`1 RECEITA/FATURAMENTO`, `3 CUSTOS VARIÁVEIS`, `4 DESPESAS FIXAS`, `5 INVESTIMENTOS`,
`6.1 SAÍDAS NÃO OPERACIONAIS` e `6.2 ENTRADAS NÃO OPERACIONAIS`. Outros planos no mesmo formato
(células como `4.2.11 Contador`) entram pelo botão **Importar do Excel** na tela Plano de contas.

DRE: Receita − Custos variáveis = **Margem de contribuição** − Despesas fixas = **Resultado operacional**
− Investimentos = Resultado após investimentos + Entradas − Saídas não operacionais = **Resultado final** (geração de caixa).

- **Receita**: as vendas do PDV+ entram pela forma de pagamento (Configurações): Pix → 1.1.1, cartões → 1.1.2,
  crediário → 1.1.4, dinheiro → 1.1.7, outras → 1.1.8. Pode trocar a conta de cada forma.
- **3.1.3 Taxa de cartões**: calculada pela taxa de cada forma de pagamento.
- **3.2 Custos com insumos**: compras lançadas (padrão) ou o custo do cadastro dos produtos do PDV+.
- **Juros e descontos**: ao pagar uma conta por valor diferente, a diferença vai sozinha para 6.1.5 (juros) ou 6.2.5 (desconto obtido).
- **Competência**: vendas pela data da venda e contas pelo campo Competência.
  **Caixa**: vendas quando o dinheiro cai (cartão no prazo da maquininha, crediário quando pago) e contas pela data do pagamento.
- Recebimento de crediário (venda sem itens no PDV+) não conta como venda nova. O troco é descontado do dinheiro.

## Compras e fornecedores do PDV+ (sincronizador 1.2)
- Os fornecedores cadastrados no PDV+, e os que só aparecem nas notas, entram em Fornecedores com a etiqueta PDV+.
- Cada **entrada de nota** vira conta a pagar: uma por boleto (duplicata do XML da NF-e), com valor e vencimento.
  Sem boleto, vira uma conta só, vencendo na emissão. Entrada sem nota, mas com fornecedor, usa o total dos itens.
- Conta: a "Conta padrão" do fornecedor ou a conta padrão das compras (3.2.1). Configuração em Configurações > Compras do PDV+.
- Nota corrigida no PDV+ atualiza a conta ainda não paga; entrada excluída no PDV+ sai do painel.
  Conta paga ou excluída no painel não é tocada nem volta.
- Só entram entradas a partir da data "Importar notas com entrada a partir de" (padrão: início do mês em que a loja começou a usar).
- Ao atualizar o banco na nuvem, rode o `supabase/banco.sql` de novo no SQL Editor (pode rodar quantas vezes quiser).

## Recebíveis das vendas (versão 1.5)
- Cada pagamento de venda (tabela `recebiveis`, só a sincronização grava) com NSU, autorização e parcelas.
- O painel junta com o crediário em Contas a receber. Previsão = data da venda + prazo da forma de pagamento
  (cartão parcelado: uma linha por parcela, 30 dias entre elas se o prazo for 0). Líquido = valor − taxa da forma.

## Contas a receber (versão 1.4)
- Vêm só do crediário do PDV+ (parcelas em `conta_pagar_receber` e recebimentos em `recebimento_pagamento`).
  A cada sincronização a lista completa substitui a anterior. No painel é só consulta (o banco recusa incluir,
  alterar ou excluir); para receber, usa-se o recebimento de crediário no PDV+.
- Não muda a DRE: o crediário já entra pela forma de pagamento (competência: na venda; caixa: no recebimento).

## Backup (versão 1.3)
- O programa da loja faz um backup por dia de tudo o que a loja tem na nuvem, em `%APPDATA%\Aliber Financeiro\backups`
  (últimos 30 dias), com cópia extra opcional em outra pasta.
- No painel, a página **Backup** baixa e restaura (restaurar troca todos os dados da loja; o painel baixa uma cópia antes).
- Segurança: veja `SEGURANCA.md`.

## Caixa e bancos
Cada loja tem suas contas de caixa, banco e investimento, com saldo inicial. O saldo soma as vendas do PDV+ (já sem a taxa,
na data em que caem), as contas pagas e recebidas, as **transferências entre contas internas** e os **acertos de caixa**.
Transferências e acertos não entram na DRE.
