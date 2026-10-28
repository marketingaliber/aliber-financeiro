-- =====================================================================
-- ALIBER FINANCEIRO - banco de dados na nuvem (Supabase / PostgreSQL)
-- Cole este arquivo inteiro no Supabase: SQL Editor > New query > Run.
-- Pode rodar de novo sem perder dados (só cria o que ainda não existe
-- e atualiza as funções).
--
-- Versão 1.2: importa fornecedores e contas a pagar das entradas de nota do PDV+.
-- Versão 1.3: backup (exportar e restaurar uma loja) e travas de segurança.
-- Versão 1.4: contas a receber (crediário do PDV+), só pela sincronização.
-- Versão 1.5: recebíveis de todas as vendas (Pix, cartão, dinheiro...), só pela sincronização.
-- Versão 1.6: perdas de mercadoria pela forma de pagamento escolhida (conta 3.2.5).
--
-- Plano de contas no modelo gerencial (3 níveis):
--   1 RECEITA/FATURAMENTO      (receita)
--   3 CUSTOS VARIÁVEIS         (custo_variavel)
--   4 DESPESAS FIXAS           (despesa_fixa)
--   5 INVESTIMENTOS            (investimento)
--   6.1 SAÍDAS NÃO OPERACIONAIS  (saida_nop)
--   6.2 ENTRADAS NÃO OPERACIONAIS (entrada_nop)
-- Subgrupos (ex.: 3.1) são "sintéticos": só agrupam. Lançamentos vão nas contas (ex.: 3.1.1).
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Empresas (clientes da Aliber) e quem acessa cada uma
-- ---------------------------------------------------------------------
create table if not exists empresas (
  id            uuid primary key default gen_random_uuid(),
  nome          text not null,
  cnpj          text,
  chave_sync    text not null unique default encode(gen_random_bytes(12), 'hex'),
  ultima_sync   timestamptz,
  versao_sync   text,
  ativa         boolean not null default true,
  criado_em     timestamptz not null default now()
);

create table if not exists admins (           -- equipe Aliber: vê todas as empresas
  user_id uuid primary key references auth.users on delete cascade
);

create table if not exists membros (          -- donos / usuários de cada empresa
  empresa_id uuid not null references empresas on delete cascade,
  user_id    uuid not null references auth.users on delete cascade,
  papel      text not null default 'dono',
  primary key (empresa_id, user_id)
);

create or replace function eh_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid())
$$;

create or replace function pode_ver(e uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select eh_admin() or exists (select 1 from membros where empresa_id = e and user_id = auth.uid())
$$;

-- ---------------------------------------------------------------------
-- Plano de contas
--   automatica: contas que o sistema alimenta sozinho
--     taxas            taxa de cartões calculada pelas formas de pagamento
--     juros_pagos      diferença a mais ao pagar uma conta (juros de atraso)
--     desconto_obtido  diferença a menos ao pagar uma conta
--     juros_recebidos  diferença a mais ao receber uma entrada
-- ---------------------------------------------------------------------
create table if not exists plano_contas (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid not null references empresas on delete cascade,
  codigo      text not null,
  nome        text not null,
  grupo       text not null check (grupo in ('receita','custo_variavel','despesa_fixa','investimento','saida_nop','entrada_nop')),
  sintetica   boolean not null default false,
  automatica  text,
  ativa       boolean not null default true,
  criado_em   timestamptz not null default now(),
  unique (empresa_id, codigo)
);

-- Caixa, bancos e investimentos (onde o dinheiro está)
create table if not exists contas_financeiras (
  id            uuid primary key default gen_random_uuid(),
  empresa_id    uuid not null references empresas on delete cascade,
  nome          text not null,
  tipo          text not null default 'banco' check (tipo in ('caixa','banco','investimento')),
  saldo_inicial numeric(12,2) not null default 0,
  data_saldo    date not null default current_date,   -- saldo_inicial é o saldo no fim deste dia
  ativa         boolean not null default true,
  criado_em     timestamptz not null default now()
);

create table if not exists fornecedores (
  id              uuid primary key default gen_random_uuid(),
  empresa_id      uuid not null references empresas on delete cascade,
  nome            text not null,
  cpf_cnpj        text,
  fone            text,
  email           text,
  conta_padrao_id uuid references plano_contas on delete set null,
  obs             text,
  ativo           boolean not null default true,
  criado_em       timestamptz not null default now()
);

-- Contas a pagar e entradas avulsas a receber (o grupo da conta do plano define se é saída
-- ou entrada). Paga/recebida quando pago_em não é nulo.
create table if not exists lancamentos (
  id                  uuid primary key default gen_random_uuid(),
  empresa_id          uuid not null references empresas on delete cascade,
  descricao           text not null,
  fornecedor_id       uuid references fornecedores on delete set null,
  conta_id            uuid not null references plano_contas,
  conta_financeira_id uuid references contas_financeiras on delete set null,
  valor               numeric(12,2) not null check (valor >= 0),
  competencia         date not null,
  vencimento          date not null,
  pago_em             date,
  valor_pago          numeric(12,2),
  documento           text,
  parcela             int,
  parcelas            int,
  grupo_parcelas      uuid,
  obs                 text,
  criado_em           timestamptz not null default now(),
  criado_por          uuid default auth.uid()
);
create index if not exists lancamentos_emp_venc on lancamentos (empresa_id, vencimento);
create index if not exists lancamentos_emp_comp on lancamentos (empresa_id, competencia);

-- Versão 1.2: importação das entradas de nota e dos fornecedores do PDV+
alter table fornecedores add column if not exists razao_social text;
alter table fornecedores add column if not exists inscricao_estadual text;
alter table fornecedores add column if not exists origem text;          -- 'pdv' = veio do PDV+
alter table lancamentos  add column if not exists origem text;          -- 'pdv' = entrada de nota do PDV+
alter table lancamentos  add column if not exists origem_id text;       -- id da entrada no PDV+ + '#' + nº da parcela
create unique index if not exists lancamentos_origem on lancamentos (empresa_id, origem_id);

-- Transferências entre contas internas e acertos de caixa (não entram na DRE)
create table if not exists movimentos (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid not null references empresas on delete cascade,
  data        date not null,
  tipo        text not null check (tipo in ('transferencia','acerto')),
  origem_id   uuid references contas_financeiras on delete cascade,   -- transferência: sai daqui
  destino_id  uuid references contas_financeiras on delete cascade,   -- transferência: entra aqui / acerto: conta acertada
  valor       numeric(12,2) not null,                                 -- acerto: positivo sobra, negativo falta
  descricao   text,
  criado_em   timestamptz not null default now()
);

-- Formas de pagamento do PDV+ (código do banco): conta de receita, onde o dinheiro cai, taxa e prazo
create table if not exists formas_pagamento (
  empresa_id          uuid not null references empresas on delete cascade,
  codigo              int  not null,
  nome                text not null,
  conta_receita_id    uuid references plano_contas on delete set null,
  conta_financeira_id uuid references contas_financeiras on delete set null,
  taxa_percentual     numeric(6,3) not null default 0,
  prazo_dias          int  not null default 0,
  a_prazo             boolean not null default false,   -- crediário: só vira dinheiro quando o cliente paga
  primary key (empresa_id, codigo)
);

-- Configurações da loja para a importação das compras do PDV+
create table if not exists config_empresa (
  empresa_id        uuid primary key references empresas on delete cascade,
  importar_compras  boolean not null default true,
  conta_compras_id  uuid references plano_contas on delete set null,        -- conta padrão (3.2.1 Insumos)
  banco_compras_id  uuid references contas_financeiras on delete set null,  -- "paga com" padrão
  compras_desde     date not null default (date_trunc('month', current_date))::date  -- não importa notas mais antigas
);

-- Versão 1.6: perdas de mercadoria lançadas no PDV+ como venda numa forma de pagamento própria (ex.: vale alimentação)
alter table config_empresa add column if not exists forma_perda int;                                              -- código da forma no PDV+
alter table config_empresa add column if not exists conta_perdas_id uuid references plano_contas on delete set null;  -- vazio = 3.2.5

-- Contas importadas que o usuário excluiu no painel: não voltam na próxima sincronização
create table if not exists pdv_ignorados (
  empresa_id uuid not null references empresas on delete cascade,
  origem_id  text not null,
  primary key (empresa_id, origem_id)
);

-- Contas a receber (versão 1.4): crediário do PDV+. Só a sincronização grava; no painel é só consulta.
create table if not exists contas_receber (
  empresa_id         uuid not null references empresas on delete cascade,
  origem_id          text not null,                -- id da parcela no PDV+ (conta_pagar_receber)
  cliente            text,
  cliente_doc        text,
  cliente_fone       text,
  documento          text,                         -- ex.: 001.17-1/2 (venda 001.17, parcela 1 de 2)
  venda              text,
  competencia        date,                         -- data da venda
  vencimento         date,
  valor              numeric(12,2) not null default 0,
  valor_recebido     numeric(12,2) not null default 0,   -- com juros e multa
  principal_recebido numeric(12,2) not null default 0,
  recebido_em        date,
  situacao           text not null default 'aberta' check (situacao in ('aberta','parcial','recebida')),
  recebimentos       jsonb not null default '[]',
  atualizado_em      timestamptz not null default now(),
  primary key (empresa_id, origem_id)
);

-- Recebíveis das vendas (versão 1.5): cada pagamento (Pix, cartão, dinheiro...) com os dados da maquininha.
-- Só a sincronização grava. Taxa, prazo e situação o painel calcula pelas formas de pagamento.
create table if not exists recebiveis (
  empresa_id  uuid not null references empresas on delete cascade,
  origem_id   text not null,               -- id do pagamento no PDV+ (venda_forma_pagamento)
  data        date not null,               -- data da venda
  hora        text,
  forma       int  not null,
  valor       numeric(12,2) not null default 0,   -- dinheiro já sem o troco
  venda       text,
  tipo_venda  int,
  cliente     text,
  bandeira    int,
  nsu         text,
  autorizacao text,
  parcelas    int not null default 1,
  primary key (empresa_id, origem_id)
);
create index if not exists recebiveis_emp_data on recebiveis (empresa_id, data);
alter table recebiveis add column if not exists custo numeric(12,2);   -- 1.6: parte do custo da venda (perdas a preço de custo)

-- Resumo diário enviado pelo sincronizador (.exe) — só o sincronizador grava
create table if not exists vendas_dia (
  empresa_id       uuid not null references empresas on delete cascade,
  data             date not null,
  tipo_venda       int  not null,           -- 1 balcão, 2 delivery, 3 mesa/comanda
  qtd              int  not null default 0,
  itens            numeric(12,2) not null default 0,
  taxa_entrega     numeric(12,2) not null default 0,
  taxa_servico     numeric(12,2) not null default 0,
  acrescimos       numeric(12,2) not null default 0,
  descontos        numeric(12,2) not null default 0,
  total            numeric(12,2) not null default 0,
  custo            numeric(12,2) not null default 0,  -- custo pelo cadastro de produtos
  canceladas_qtd   int  not null default 0,
  canceladas_valor numeric(12,2) not null default 0,
  primary key (empresa_id, data, tipo_venda)
);

create table if not exists pagamentos_dia (
  empresa_id uuid not null references empresas on delete cascade,
  data       date not null,
  categoria  text not null,                  -- venda | recebimento (de crediário)
  forma      int  not null,
  qtd        int  not null default 0,
  valor      numeric(12,2) not null default 0, -- dinheiro já sem o troco
  primary key (empresa_id, data, categoria, forma)
);

-- ---------------------------------------------------------------------
-- Segurança: cada usuário só enxerga as empresas dele
-- ---------------------------------------------------------------------
alter table empresas           enable row level security;
alter table admins             enable row level security;
alter table membros            enable row level security;
alter table plano_contas       enable row level security;
alter table contas_financeiras enable row level security;
alter table fornecedores       enable row level security;
alter table lancamentos        enable row level security;
alter table movimentos         enable row level security;
alter table formas_pagamento   enable row level security;
alter table config_empresa     enable row level security;
alter table pdv_ignorados      enable row level security;
alter table contas_receber     enable row level security;
alter table recebiveis         enable row level security;
alter table vendas_dia         enable row level security;
alter table pagamentos_dia     enable row level security;

drop policy if exists ver on empresas;
create policy ver on empresas for select using (pode_ver(id));
drop policy if exists admin_edita on empresas;
create policy admin_edita on empresas for all using (eh_admin()) with check (eh_admin());

drop policy if exists ver on admins;
create policy ver on admins for select using (user_id = auth.uid() or eh_admin());

drop policy if exists ver on membros;
create policy ver on membros for select using (user_id = auth.uid() or eh_admin());
drop policy if exists admin_edita on membros;
create policy admin_edita on membros for all using (eh_admin()) with check (eh_admin());

do $$
declare t text;
begin
  foreach t in array array['plano_contas','contas_financeiras','fornecedores','lancamentos','movimentos','formas_pagamento','config_empresa','pdv_ignorados'] loop
    execute format('drop policy if exists acesso on %I', t);
    execute format('create policy acesso on %I for all using (pode_ver(empresa_id)) with check (pode_ver(empresa_id))', t);
  end loop;
  foreach t in array array['vendas_dia','pagamentos_dia','contas_receber','recebiveis'] loop
    execute format('drop policy if exists ver on %I', t);
    execute format('create policy ver on %I for select using (pode_ver(empresa_id))', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Plano de contas, caixa/banco e formas de pagamento padrão para toda empresa nova
-- ---------------------------------------------------------------------
create or replace function preparar_empresa() returns trigger
language plpgsql security definer set search_path = public as $$
declare caixa uuid; banco uuid;
begin
  insert into plano_contas (empresa_id, codigo, nome, grupo, sintetica, automatica) values
    (new.id,'1.1','RECEITA DE VENDAS','receita',true,null),
    (new.id,'1.1.1','Receita Pix','receita',false,null),
    (new.id,'1.1.2','Receita em cartões','receita',false,null),
    (new.id,'1.1.3','Receita boleto','receita',false,null),
    (new.id,'1.1.4','Receita nota de crédito','receita',false,null),
    (new.id,'1.1.6','Receita de cheque','receita',false,null),
    (new.id,'1.1.7','Receita em dinheiro','receita',false,null),
    (new.id,'1.1.8','Outras Receitas','receita',false,null),
    (new.id,'3.1','CUSTOS TRIBUTÁRIOS OU FINANCEIROS','custo_variavel',true,null),
    (new.id,'3.1.1','Simples Nacional','custo_variavel',false,null),
    (new.id,'3.1.2','ICMS Diferencial de Aliquota','custo_variavel',false,null),
    (new.id,'3.1.3','Taxa de cartões','custo_variavel',false,'taxas'),
    (new.id,'3.2','CUSTOS COM INSUMOS','custo_variavel',true,null),
    (new.id,'3.2.1','Insumos (materia prima)','custo_variavel',false,null),
    (new.id,'3.2.2','Farinhas','custo_variavel',false,null),
    (new.id,'3.2.3','Recheios','custo_variavel',false,null),
    (new.id,'3.2.4','Açucares','custo_variavel',false,null),
    (new.id,'3.3','CUSTOS COM FRETE','custo_variavel',true,null),
    (new.id,'3.3.1','Custos com Fretes Produtos','custo_variavel',false,null),
    (new.id,'3.4','CUSTOS COM MÃO DE OBRA VARIÁVEL','custo_variavel',true,null),
    (new.id,'3.4.1','Facção costureiras','custo_variavel',false,null),
    (new.id,'3.4.2','Outros serviços terceirizados','custo_variavel',false,null),
    (new.id,'3.5','CUSTOS COM VENDAS','custo_variavel',true,null),
    (new.id,'3.5.1','Comissão de vendas','custo_variavel',false,null),
    (new.id,'3.5.2','Comissões Extras','custo_variavel',false,null),
    (new.id,'4.1','DESPESAS DE PRODUÇÃO','despesa_fixa',true,null),
    (new.id,'4.1.1','Uniformes','despesa_fixa',false,null),
    (new.id,'4.1.2','Coleta de resíduos','despesa_fixa',false,null),
    (new.id,'4.1.3','SESMT/Medicina do trabalho','despesa_fixa',false,null),
    (new.id,'4.1.4','Refeitório','despesa_fixa',false,null),
    (new.id,'4.1.5','Aluguel de máquinas','despesa_fixa',false,null),
    (new.id,'4.1.6','Materiais de uso/consumo','despesa_fixa',false,null),
    (new.id,'4.1.7','Epi´s','despesa_fixa',false,null),
    (new.id,'4.1.8','Desenvolvimento de Produtos','despesa_fixa',false,null),
    (new.id,'4.1.9','Lixas e abrasivos','despesa_fixa',false,null),
    (new.id,'4.1.10','Meio Ambiente','despesa_fixa',false,null),
    (new.id,'4.1.11','Relógio de ponto','despesa_fixa',false,null),
    (new.id,'4.2','DESPESAS ADMINISTRATIVAS','despesa_fixa',true,null),
    (new.id,'4.2.1','Telefone/comunicações','despesa_fixa',false,null),
    (new.id,'4.2.2','Internet','despesa_fixa',false,null),
    (new.id,'4.2.3','Energia','despesa_fixa',false,null),
    (new.id,'4.2.4','Aluguel','despesa_fixa',false,null),
    (new.id,'4.2.5','Água/gas','despesa_fixa',false,null),
    (new.id,'4.2.6','IPTU/ taxas municipais','despesa_fixa',false,null),
    (new.id,'4.2.7','Supermercado','despesa_fixa',false,null),
    (new.id,'4.2.8','Farmacia','despesa_fixa',false,null),
    (new.id,'4.2.9','Correios','despesa_fixa',false,null),
    (new.id,'4.2.10','Cartório','despesa_fixa',false,null),
    (new.id,'4.2.11','Contador','despesa_fixa',false,null),
    (new.id,'4.2.12','Software','despesa_fixa',false,null),
    (new.id,'4.2.13','Sistema de segurança/monitoramento','despesa_fixa',false,null),
    (new.id,'4.2.14','Gráfica','despesa_fixa',false,null),
    (new.id,'4.2.15','Conect (SERASA)','despesa_fixa',false,null),
    (new.id,'4.2.16','Serviço de TI','despesa_fixa',false,null),
    (new.id,'4.2.17','Despesas comerciais (supervisão)','despesa_fixa',false,null),
    (new.id,'4.2.18','Café funcionários','despesa_fixa',false,null),
    (new.id,'4.2.19','Materiais de escritório','despesa_fixa',false,null),
    (new.id,'4.2.20','Provedor de email/site','despesa_fixa',false,null),
    (new.id,'4.2.21','Seguro padaria','despesa_fixa',false,null),
    (new.id,'4.2.22','Honorários Advocatícios','despesa_fixa',false,null),
    (new.id,'4.3','DESPESAS COM PESSOAL','despesa_fixa',true,null),
    (new.id,'4.3.1','Salários','despesa_fixa',false,null),
    (new.id,'4.3.2','Hora extra','despesa_fixa',false,null),
    (new.id,'4.3.3','Vale refeição e vale transporte','despesa_fixa',false,null),
    (new.id,'4.3.4','FGTS','despesa_fixa',false,null),
    (new.id,'4.3.5','Rescisão','despesa_fixa',false,null),
    (new.id,'4.3.6','INSS','despesa_fixa',false,null),
    (new.id,'4.3.7','13º Salário','despesa_fixa',false,null),
    (new.id,'4.3.8','Férias com 1/3 de férias','despesa_fixa',false,null),
    (new.id,'4.3.9','IRRF','despesa_fixa',false,null),
    (new.id,'4.3.10','Pró-labore','despesa_fixa',false,null),
    (new.id,'4.3.11','Plano de saúde','despesa_fixa',false,null),
    (new.id,'4.3.12','Vale Funcionários','despesa_fixa',false,null),
    (new.id,'4.3.13','Bonificação','despesa_fixa',false,null),
    (new.id,'4.3.14','Sindicatos','despesa_fixa',false,null),
    (new.id,'4.3.15','Freelancer','despesa_fixa',false,null),
    (new.id,'4.3.16','Moto boy','despesa_fixa',false,null),
    (new.id,'4.3.17','Seguro funcionarios','despesa_fixa',false,null),
    (new.id,'4.3.18','Assiduidade','despesa_fixa',false,null),
    (new.id,'4.4','DESPESAS COM MATERIAIS E EQUIPAMETOS','despesa_fixa',true,null),
    (new.id,'4.4.1','Manutenção de máquinas e equipamentos','despesa_fixa',false,null),
    (new.id,'4.4.2','Manutenção Peças e acessórios','despesa_fixa',false,null),
    (new.id,'4.4.3','Empilhadeiras','despesa_fixa',false,null),
    (new.id,'4.4.4','Manutenção predial','despesa_fixa',false,null),
    (new.id,'4.5','DESPESAS COM VEÍCULOS','despesa_fixa',true,null),
    (new.id,'4.5.1','Combustível','despesa_fixa',false,null),
    (new.id,'4.5.2','Manutenção veiculos','despesa_fixa',false,null),
    (new.id,'4.5.3','IPVA/ Licenciamento/Despachante/Seguros','despesa_fixa',false,null),
    (new.id,'4.5.4','Estacionamento/pedágio','despesa_fixa',false,null),
    (new.id,'4.5.5','Outros','despesa_fixa',false,null),
    (new.id,'4.6','DESPESAS FINANCEIRAS','despesa_fixa',true,null),
    (new.id,'4.6.1','Manutenção de conta','despesa_fixa',false,null),
    (new.id,'4.6.2','TED/DOC/PIX','despesa_fixa',false,null),
    (new.id,'4.6.3','Aluguel máquina de cartão','despesa_fixa',false,null),
    (new.id,'4.6.4','Taxa de boletos','despesa_fixa',false,null),
    (new.id,'4.6.5','Outras despesas financeiras','despesa_fixa',false,null),
    (new.id,'4.7','OUTROS','despesa_fixa',true,null),
    (new.id,'4.7.1','OUTROS','despesa_fixa',false,null),
    (new.id,'5.1','INVESTIMENTO EM MARKETING','investimento',true,null),
    (new.id,'5.1.1','Folder/cartão de visita','investimento',false,null),
    (new.id,'5.1.2','Mídeas/ propagandas','investimento',false,null),
    (new.id,'5.1.3','Realização de eventos','investimento',false,null),
    (new.id,'5.1.4','Prestadores de serviços em Marketing','investimento',false,null),
    (new.id,'5.1.5','Catálogo/mostruário','investimento',false,null),
    (new.id,'5.1.6','Outros','investimento',false,null),
    (new.id,'5.2','INVESTIMENTO EM BENS MATERIAIS','investimento',true,null),
    (new.id,'5.2.1','Compra de equipamentos adminstração','investimento',false,null),
    (new.id,'5.2.2','Compra de maquinário','investimento',false,null),
    (new.id,'5.2.3','Reforma / estrutura','investimento',false,null),
    (new.id,'5.2.4','Imobilizado','investimento',false,null),
    (new.id,'5.2.5','Compra de veículos','investimento',false,null),
    (new.id,'5.2.6','Consórcios','investimento',false,null),
    (new.id,'5.2.7','Energia solar','investimento',false,null),
    (new.id,'5.3','INVESTIMENTO EM DESENVOLVIMENTO PESSOAL','investimento',true,null),
    (new.id,'5.3.1','Consultorias','investimento',false,null),
    (new.id,'5.3.2','Treinamentos','investimento',false,null),
    (new.id,'6.1','SAÍDAS NÃO OPERACIONAIS','saida_nop',true,null),
    (new.id,'6.1.1','Pagamento de empréstimo','saida_nop',false,null),
    (new.id,'6.1.2','Pagamento de dívidas passadas','saida_nop',false,null),
    (new.id,'6.1.3','Distribuição de lucros','saida_nop',false,null),
    (new.id,'6.1.4','Júros de antecipação de recebíveis','saida_nop',false,null),
    (new.id,'6.1.5','Júros de atraso de PGTO','saida_nop',false,'juros_pagos'),
    (new.id,'6.1.6','Cheque Especial','saida_nop',false,null),
    (new.id,'6.2','ENTRADAS NÃO OPERACIONAIS','entrada_nop',true,null),
    (new.id,'6.2.1','Empréstimos obtidos','entrada_nop',false,null),
    (new.id,'6.2.2','Capitalização dos sócios','entrada_nop',false,null),
    (new.id,'6.2.3','Venda de equipamentos usados','entrada_nop',false,null),
    (new.id,'6.2.4','Venda de sucatas/outros','entrada_nop',false,null),
    (new.id,'6.2.5','Desconto Obtido','entrada_nop',false,'desconto_obtido'),
    (new.id,'6.2.6','Receita de Juros','entrada_nop',false,'juros_recebidos')
  on conflict do nothing;
  insert into plano_contas (empresa_id, codigo, nome, grupo, sintetica, automatica)
  values (new.id, '3.2.5', 'Perdas de mercadoria', 'custo_variavel', false, 'perdas')
  on conflict do nothing;

  insert into contas_financeiras (empresa_id, nome, tipo) values (new.id, 'Caixa dinheiro', 'caixa') returning id into caixa;
  insert into contas_financeiras (empresa_id, nome, tipo) values (new.id, 'Banco principal', 'banco') returning id into banco;

  insert into formas_pagamento (empresa_id, codigo, nome, conta_receita_id, conta_financeira_id, a_prazo)
  select new.id, f.codigo, f.nome, (select id from plano_contas p where p.empresa_id = new.id and p.codigo = f.conta),
         case when f.codigo = 0 then caixa when f.codigo = 2 then null else banco end, f.codigo = 2
    from (values (0,'Dinheiro','1.1.7'),(1,'Cartão de crédito','1.1.2'),(2,'Crediário','1.1.4'),
                 (3,'Pix','1.1.1'),(4,'Cartão de débito','1.1.2'),(5,'Forma 5','1.1.8'),
                 (6,'Forma 6','1.1.8'),(7,'Forma 7','1.1.8')) as f(codigo, nome, conta)
  on conflict do nothing;

  insert into config_empresa (empresa_id, conta_compras_id, banco_compras_id)
  values (new.id, (select id from plano_contas where empresa_id = new.id and codigo = '3.2.1'), banco)
  on conflict do nothing;
  return new;
end $$;

drop trigger if exists preparar_empresa on empresas;
create trigger preparar_empresa after insert on empresas
  for each row execute function preparar_empresa();

-- Lojas que já existiam antes da 1.6 ganham a conta 3.2.5 Perdas de mercadoria (se o código estiver livre)
insert into plano_contas (empresa_id, codigo, nome, grupo, sintetica, automatica)
select id, '3.2.5', 'Perdas de mercadoria', 'custo_variavel', false, 'perdas' from empresas
on conflict do nothing;

-- ---------------------------------------------------------------------
-- Sincronização: o .exe chama esta função com a chave da empresa.
-- Apaga o período enviado e grava de novo (assim vendas canceladas
-- depois também são corrigidas).
-- ---------------------------------------------------------------------
create or replace function sincronizar(chave text, dados jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  e   uuid;
  ini date := (dados->>'data_ini')::date;
  fim date := (dados->>'data_fim')::date;
  n1 int; n2 int; nu int; nr int := 0; nv int := 0; nf int := 0; nl int := 0; na int := 0; nx int := 0;
  cfg record; rf record; rp record; forn record; conta uuid;
begin
  select id into e from empresas where chave_sync = chave and ativa;
  if e is null then
    raise exception 'Chave de sincronização inválida ou empresa desativada';
  end if;
  if ini is null or fim is null or fim < ini then
    raise exception 'Período inválido';
  end if;

  delete from vendas_dia     where empresa_id = e and data between ini and fim;
  delete from pagamentos_dia where empresa_id = e and data between ini and fim;

  insert into vendas_dia (empresa_id, data, tipo_venda, qtd, itens, taxa_entrega, taxa_servico,
                          acrescimos, descontos, total, custo, canceladas_qtd, canceladas_valor)
  select e, d.data, d.tipo_venda, d.qtd, d.itens, d.taxa_entrega, d.taxa_servico,
         d.acrescimos, d.descontos, d.total, d.custo, d.canceladas_qtd, d.canceladas_valor
    from jsonb_to_recordset(coalesce(dados->'vendas_dia','[]')) as d(
         data date, tipo_venda int, qtd int, itens numeric, taxa_entrega numeric, taxa_servico numeric,
         acrescimos numeric, descontos numeric, total numeric, custo numeric,
         canceladas_qtd int, canceladas_valor numeric)
   where d.data between ini and fim;
  get diagnostics n1 = row_count;

  insert into pagamentos_dia (empresa_id, data, categoria, forma, qtd, valor)
  select e, p.data, p.categoria, p.forma, p.qtd, p.valor
    from jsonb_to_recordset(coalesce(dados->'pagamentos_dia','[]')) as p(
         data date, categoria text, forma int, qtd int, valor numeric)
   where p.data between ini and fim;
  get diagnostics n2 = row_count;

  -- forma de pagamento nova que apareceu no PDV+: cria com nome provisório
  insert into formas_pagamento (empresa_id, codigo, nome, conta_receita_id)
  select distinct e, p.forma, 'Forma ' || p.forma,
         (select id from plano_contas where empresa_id = e and codigo = '1.1.8')
    from pagamentos_dia p where p.empresa_id = e
  on conflict do nothing;

  -- ---- recebíveis das vendas: substitui o período enviado
  if dados ? 'recebiveis' then
    delete from recebiveis where empresa_id = e
       and data between coalesce((dados->>'recebiveis_ini')::date, ini) and fim;
    insert into recebiveis (empresa_id, origem_id, data, hora, forma, valor, venda, tipo_venda, cliente, bandeira, nsu, autorizacao, parcelas, custo)
    select e, x.origem_id, x.data, x.hora, x.forma, coalesce(x.valor, 0), x.venda, x.tipo_venda, x.cliente, x.bandeira, x.nsu,
           x.autorizacao, greatest(coalesce(x.parcelas, 1), 1), x.custo
      from jsonb_to_recordset(dados->'recebiveis') as x(origem_id text, data date, hora text, forma int, valor numeric, venda text,
           tipo_venda int, cliente text, bandeira int, nsu text, autorizacao text, parcelas int, custo numeric)
     where coalesce(x.origem_id, '') <> '' and x.data is not null
    on conflict (empresa_id, origem_id) do update set data = excluded.data, hora = excluded.hora, forma = excluded.forma,
           valor = excluded.valor, venda = excluded.venda, tipo_venda = excluded.tipo_venda, cliente = excluded.cliente,
           bandeira = excluded.bandeira, nsu = excluded.nsu, autorizacao = excluded.autorizacao, parcelas = excluded.parcelas,
           custo = excluded.custo;
    get diagnostics nv = row_count;
  end if;

  -- ---- contas a receber (crediário): o PDV+ manda a lista completa e ela substitui a anterior
  if dados ? 'contas_receber' then
    delete from contas_receber where empresa_id = e;
    insert into contas_receber (empresa_id, origem_id, cliente, cliente_doc, cliente_fone, documento, venda, competencia,
                                vencimento, valor, valor_recebido, principal_recebido, recebido_em, situacao, recebimentos)
    select e, x.origem_id, x.cliente, x.cliente_doc, x.cliente_fone, x.documento, x.venda, x.competencia, x.vencimento,
           coalesce(x.valor, 0), coalesce(x.valor_recebido, 0), coalesce(x.principal_recebido, 0), x.recebido_em,
           coalesce(x.situacao, 'aberta'), coalesce(x.recebimentos, '[]')
      from jsonb_to_recordset(dados->'contas_receber') as x(origem_id text, cliente text, cliente_doc text, cliente_fone text,
           documento text, venda text, competencia date, vencimento date, valor numeric, valor_recebido numeric,
           principal_recebido numeric, recebido_em date, situacao text, recebimentos jsonb)
     where coalesce(x.origem_id, '') <> ''
    on conflict do nothing;
    get diagnostics nr = row_count;
  end if;

  -- ---- fornecedores e contas a pagar das entradas de nota (sincronizador 1.2 ou mais novo)
  if dados ? 'compras' then
    insert into config_empresa (empresa_id, conta_compras_id, banco_compras_id)
    values (e, (select id from plano_contas where empresa_id = e and codigo = '3.2.1'),
               (select id from contas_financeiras where empresa_id = e and tipo = 'banco' and ativa order by criado_em limit 1))
    on conflict do nothing;
    select * into cfg from config_empresa where empresa_id = e;

    if cfg.importar_compras then
      for rf in select * from jsonb_to_recordset(coalesce(dados->'fornecedores','[]')) as x(
                 cpf_cnpj text, razao_social text, nome_fantasia text, fone text, inscricao_estadual text) loop
        continue when coalesce(rf.cpf_cnpj, '') = '';
        update fornecedores set razao_social = coalesce(nullif(rf.razao_social, ''), razao_social),
                                inscricao_estadual = coalesce(nullif(rf.inscricao_estadual, ''), inscricao_estadual),
                                fone = coalesce(nullif(fone, ''), nullif(rf.fone, ''))
         where empresa_id = e and regexp_replace(coalesce(cpf_cnpj, ''), '\D', '', 'g') = rf.cpf_cnpj;
        if not found then
          insert into fornecedores (empresa_id, nome, razao_social, cpf_cnpj, fone, inscricao_estadual, origem, obs)
          values (e, coalesce(nullif(rf.nome_fantasia, ''), rf.razao_social), rf.razao_social, rf.cpf_cnpj, rf.fone,
                  rf.inscricao_estadual, 'pdv', 'Importado do PDV+');
          nf := nf + 1;
        end if;
      end loop;

      for rp in select * from jsonb_to_recordset(coalesce(dados->'compras','[]')) as x(
                 origem_id text, cpf_cnpj text, descricao text, documento text, competencia date, vencimento date,
                 valor numeric, parcela int, parcelas int, data_entrada date) loop
        continue when rp.data_entrada < cfg.compras_desde or coalesce(rp.valor, 0) <= 0;
        continue when exists (select 1 from pdv_ignorados where empresa_id = e and origem_id = rp.origem_id);
        select id, conta_padrao_id into forn from fornecedores
         where empresa_id = e and coalesce(rp.cpf_cnpj, '') <> ''
           and regexp_replace(coalesce(cpf_cnpj, ''), '\D', '', 'g') = rp.cpf_cnpj
         order by ativo desc, criado_em limit 1;
        if exists (select 1 from lancamentos where empresa_id = e and origem_id = rp.origem_id) then
          -- nota corrigida no PDV+: acerta valor e vencimento do que ainda não foi pago
          update lancamentos set valor = rp.valor, vencimento = rp.vencimento
           where empresa_id = e and origem_id = rp.origem_id and pago_em is null
             and (valor <> rp.valor or vencimento <> rp.vencimento);
          get diagnostics nu = row_count; na := na + nu;
        else
          conta := coalesce(forn.conta_padrao_id, cfg.conta_compras_id,
                            (select id from plano_contas where empresa_id = e and codigo = '3.2.1'),
                            (select id from plano_contas where empresa_id = e and grupo = 'custo_variavel' and not sintetica order by codigo limit 1));
          insert into lancamentos (empresa_id, descricao, fornecedor_id, conta_id, conta_financeira_id, valor, competencia,
                                   vencimento, documento, parcela, parcelas, origem, origem_id, obs)
          values (e, rp.descricao, forn.id, conta, cfg.banco_compras_id, rp.valor, coalesce(rp.competencia, rp.data_entrada),
                  coalesce(rp.vencimento, rp.data_entrada), rp.documento, rp.parcela, rp.parcelas, 'pdv', rp.origem_id,
                  'Importado da entrada de nota do PDV+');
          nl := nl + 1;
        end if;
      end loop;

      -- entrada excluída no PDV+: sai daqui também, se ainda não foi paga.
      -- Trava: lista de compras vazia (banco do PDV+ trocado, restaurado ou vazio) não apaga nada.
      if jsonb_array_length(coalesce(dados->'compras','[]')) > 0 then
        delete from lancamentos l
         where l.empresa_id = e and l.origem = 'pdv' and l.pago_em is null
           and not exists (select 1 from jsonb_array_elements(dados->'compras') x where x->>'origem_id' = l.origem_id);
        get diagnostics nx = row_count;
      end if;
    end if;
  end if;

  update empresas set ultima_sync = now(), versao_sync = dados->>'versao' where id = e;
  return jsonb_build_object('empresa', (select nome from empresas where id = e),
                            'dias', n1, 'pagamentos', n2, 'fornecedores_novos', nf,
                            'contas_novas', nl, 'contas_atualizadas', na, 'contas_removidas', nx,
                            'contas_receber', nr, 'recebiveis', nv);
end $$;

revoke all on function sincronizar(text, jsonb) from public;
grant execute on function sincronizar(text, jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Backup (versão 1.3): exporta e restaura todos os dados de uma loja
--   exportar_backup(empresa)        painel (quem tem acesso à loja)
--   exportar_backup_chave(chave)    sincronizador, backup diário no computador da loja
--   restaurar_backup(empresa, dados) painel; troca TODOS os dados da loja pelos do arquivo
-- ---------------------------------------------------------------------
create or replace function backup_da_loja(e uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'formato', 'aliber-financeiro-backup', 'versao', 1, 'gerado_em', now(),
    'empresa', (select to_jsonb(x) - 'chave_sync' from empresas x where x.id = e),
    'plano_contas',       coalesce((select jsonb_agg(to_jsonb(x)) from plano_contas x where x.empresa_id = e), '[]'),
    'contas_financeiras', coalesce((select jsonb_agg(to_jsonb(x)) from contas_financeiras x where x.empresa_id = e), '[]'),
    'fornecedores',       coalesce((select jsonb_agg(to_jsonb(x)) from fornecedores x where x.empresa_id = e), '[]'),
    'formas_pagamento',   coalesce((select jsonb_agg(to_jsonb(x)) from formas_pagamento x where x.empresa_id = e), '[]'),
    'config_empresa',     coalesce((select jsonb_agg(to_jsonb(x)) from config_empresa x where x.empresa_id = e), '[]'),
    'lancamentos',        coalesce((select jsonb_agg(to_jsonb(x)) from lancamentos x where x.empresa_id = e), '[]'),
    'movimentos',         coalesce((select jsonb_agg(to_jsonb(x)) from movimentos x where x.empresa_id = e), '[]'),
    'pdv_ignorados',      coalesce((select jsonb_agg(to_jsonb(x)) from pdv_ignorados x where x.empresa_id = e), '[]'),
    'contas_receber',     coalesce((select jsonb_agg(to_jsonb(x)) from contas_receber x where x.empresa_id = e), '[]'),
    'recebiveis',         coalesce((select jsonb_agg(to_jsonb(x)) from recebiveis x where x.empresa_id = e), '[]'),
    'vendas_dia',         coalesce((select jsonb_agg(to_jsonb(x)) from vendas_dia x where x.empresa_id = e), '[]'),
    'pagamentos_dia',     coalesce((select jsonb_agg(to_jsonb(x)) from pagamentos_dia x where x.empresa_id = e), '[]'))
$$;
revoke all on function backup_da_loja(uuid) from public, anon, authenticated;

create or replace function exportar_backup(empresa uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not pode_ver(empresa) then raise exception 'Sem acesso a esta loja'; end if;
  return backup_da_loja(empresa);
end $$;

create or replace function exportar_backup_chave(chave text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e uuid;
begin
  select id into e from empresas where chave_sync = chave and ativa;
  if e is null then raise exception 'Chave de sincronização inválida ou empresa desativada'; end if;
  return backup_da_loja(e);
end $$;

create or replace function restaurar_backup(empresa uuid, dados jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n jsonb := '{}';
begin
  if not pode_ver(empresa) then raise exception 'Sem acesso a esta loja'; end if;
  if coalesce(dados->>'formato', '') <> 'aliber-financeiro-backup' then raise exception 'Este arquivo não é um backup do Aliber Financeiro'; end if;
  if dados->'empresa'->>'id' is distinct from empresa::text then
    raise exception 'Este backup é da loja "%" e não desta loja', dados->'empresa'->>'nome';
  end if;
  -- tudo ou nada: se qualquer parte falhar, nada é alterado
  delete from pdv_ignorados where empresa_id = empresa;
  delete from movimentos where empresa_id = empresa;
  delete from lancamentos where empresa_id = empresa;
  delete from config_empresa where empresa_id = empresa;
  delete from formas_pagamento where empresa_id = empresa;
  delete from fornecedores where empresa_id = empresa;
  delete from contas_financeiras where empresa_id = empresa;
  delete from plano_contas where empresa_id = empresa;
  delete from vendas_dia where empresa_id = empresa;
  delete from pagamentos_dia where empresa_id = empresa;
  delete from contas_receber where empresa_id = empresa;
  delete from recebiveis where empresa_id = empresa;
  insert into plano_contas select (jsonb_populate_record(null::plano_contas, x || jsonb_build_object('empresa_id', empresa))).* from jsonb_array_elements(coalesce(dados->'plano_contas','[]')) x;
  insert into contas_financeiras select (jsonb_populate_record(null::contas_financeiras, x || jsonb_build_object('empresa_id', empresa))).* from jsonb_array_elements(coalesce(dados->'contas_financeiras','[]')) x;
  insert into fornecedores select (jsonb_populate_record(null::fornecedores, x || jsonb_build_object('empresa_id', empresa))).* from jsonb_array_elements(coalesce(dados->'fornecedores','[]')) x;
  insert into formas_pagamento select (jsonb_populate_record(null::formas_pagamento, x || jsonb_build_object('empresa_id', empresa))).* from jsonb_array_elements(coalesce(dados->'formas_pagamento','[]')) x;
  insert into config_empresa select (jsonb_populate_record(null::config_empresa, x || jsonb_build_object('empresa_id', empresa))).* from jsonb_array_elements(coalesce(dados->'config_empresa','[]')) x;
  insert into lancamentos select (jsonb_populate_record(null::lancamentos, x || jsonb_build_object('empresa_id', empresa))).* from jsonb_array_elements(coalesce(dados->'lancamentos','[]')) x;
  insert into movimentos select (jsonb_populate_record(null::movimentos, x || jsonb_build_object('empresa_id', empresa))).* from jsonb_array_elements(coalesce(dados->'movimentos','[]')) x;
  insert into pdv_ignorados select (jsonb_populate_record(null::pdv_ignorados, x || jsonb_build_object('empresa_id', empresa))).* from jsonb_array_elements(coalesce(dados->'pdv_ignorados','[]')) x;
  insert into vendas_dia select (jsonb_populate_record(null::vendas_dia, x || jsonb_build_object('empresa_id', empresa))).* from jsonb_array_elements(coalesce(dados->'vendas_dia','[]')) x;
  insert into pagamentos_dia select (jsonb_populate_record(null::pagamentos_dia, x || jsonb_build_object('empresa_id', empresa))).* from jsonb_array_elements(coalesce(dados->'pagamentos_dia','[]')) x;
  insert into contas_receber select (jsonb_populate_record(null::contas_receber, x || jsonb_build_object('empresa_id', empresa))).* from jsonb_array_elements(coalesce(dados->'contas_receber','[]')) x;
  insert into recebiveis select (jsonb_populate_record(null::recebiveis, x || jsonb_build_object('empresa_id', empresa))).* from jsonb_array_elements(coalesce(dados->'recebiveis','[]')) x;
  select jsonb_build_object('contas_do_plano', (select count(*) from plano_contas where empresa_id = empresa),
                            'lancamentos', (select count(*) from lancamentos where empresa_id = empresa),
                            'fornecedores', (select count(*) from fornecedores where empresa_id = empresa),
                            'bancos', (select count(*) from contas_financeiras where empresa_id = empresa)) into n;
  return n;
end $$;

revoke all on function exportar_backup(uuid), restaurar_backup(uuid, jsonb), exportar_backup_chave(text) from public;
grant execute on function exportar_backup(uuid), restaurar_backup(uuid, jsonb) to authenticated;
grant execute on function exportar_backup_chave(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Funções da equipe Aliber (tela "Administração" do painel)
-- ---------------------------------------------------------------------
create or replace function vincular_usuario(empresa uuid, email_usuario text) returns text
language plpgsql security definer set search_path = public, auth as $$
declare u uuid;
begin
  if not eh_admin() then raise exception 'Apenas a equipe Aliber'; end if;
  select id into u from auth.users where lower(email) = lower(trim(email_usuario));
  if u is null then
    raise exception 'Nenhuma conta com o e-mail %. Peça para o cliente clicar em "Criar conta" no painel primeiro.', email_usuario;
  end if;
  insert into membros (empresa_id, user_id) values (empresa, u) on conflict do nothing;
  return 'ok';
end $$;

create or replace function usuarios_da_empresa(empresa uuid) returns table (email text, papel text)
language sql stable security definer set search_path = public, auth as $$
  select u.email::text, m.papel from membros m join auth.users u on u.id = m.user_id
   where m.empresa_id = empresa and eh_admin()
$$;

create or replace function desvincular_usuario(empresa uuid, email_usuario text) returns text
language plpgsql security definer set search_path = public, auth as $$
begin
  if not eh_admin() then raise exception 'Apenas a equipe Aliber'; end if;
  delete from membros where empresa_id = empresa
     and user_id = (select id from auth.users where lower(email) = lower(trim(email_usuario)));
  return 'ok';
end $$;

revoke all on function vincular_usuario(uuid, text), usuarios_da_empresa(uuid), desvincular_usuario(uuid, text),
                       eh_admin(), pode_ver(uuid), preparar_empresa() from public, anon;
grant execute on function vincular_usuario(uuid, text), usuarios_da_empresa(uuid),
                          desvincular_usuario(uuid, text), eh_admin(), pode_ver(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- PRIMEIRO ACESSO DA ALIBER: depois de criar sua conta no painel,
-- rode a linha abaixo (trocando o e-mail) para virar administrador:
--   insert into admins (user_id) select id from auth.users where email = 'marketingaliber@gmail.com';
-- ---------------------------------------------------------------------
