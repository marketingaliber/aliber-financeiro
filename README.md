# Aliber Financeiro

Plano de contas, fornecedores, contas a pagar e DRE por período para os clientes do PDV+ (Aliber Sistema).

- **sincronizador/**: programa `AliberFinanceiro.exe` que fica no computador do caixa. Lê o banco do PDV+
  **só para leitura** e envia um resumo diário das vendas para a nuvem a cada 15 minutos.
- **docs/**: o painel online (publicado pelo GitHub Pages). O dono da loja entra com e-mail e senha.
- **painel/**: código-fonte do painel. `python painel/montar.py` gera `docs/index.html`.
- **supabase/banco.sql**: banco de dados na nuvem (tabelas, segurança por loja, plano de contas padrão).

**Baixar o sincronizador:** [AliberFinanceiro.exe (última versão)](../../releases/latest/download/AliberFinanceiro.exe)

## Publicar uma versão nova do sincronizador
1. Altere `VERSAO` em `sincronizador/financeiro.py` e descreva as mudanças em `sincronizador/NOVIDADES.txt`.
2. Envie para o ramo `main`. O GitHub compila o .exe e publica a versão sozinho; os programas instalados
   se atualizam ao abrir.

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

## Caixa e bancos
Cada loja tem suas contas de caixa, banco e investimento, com saldo inicial. O saldo soma as vendas do PDV+ (já sem a taxa,
na data em que caem), as contas pagas e recebidas, as **transferências entre contas internas** e os **acertos de caixa**.
Transferências e acertos não entram na DRE.
