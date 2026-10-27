-- =====================================================================
-- ALIBER FINANCEIRO - banco de dados na nuvem (Supabase / PostgreSQL)
-- Cole este arquivo inteiro no Supabase: SQL Editor > New query > Run.
-- Pode rodar de novo sem perder dados (só cria o que ainda não existe
-- e atualiza as funções).
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
  foreach t in array array['plano_contas','contas_financeiras','fornecedores','lancamentos','movimentos','formas_pagamento'] loop
    execute format('drop policy if exists acesso on %I', t);
    execute format('create policy acesso on %I for all using (pode_ver(empresa_id)) with check (pode_ver(empresa_id))', t);
  end loop;
  foreach t in array array['vendas_dia','pagamentos_dia'] loop
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

  insert into contas_financeiras (empresa_id, nome, tipo) values (new.id, 'Caixa dinheiro', 'caixa') returning id into caixa;
  insert into contas_financeiras (empresa_id, nome, tipo) values (new.id, 'Banco principal', 'banco') returning id into banco;

  insert into formas_pagamento (empresa_id, codigo, nome, conta_receita_id, conta_financeira_id, a_prazo)
  select new.id, f.codigo, f.nome, (select id from plano_contas p where p.empresa_id = new.id and p.codigo = f.conta),
         case when f.codigo = 0 then caixa when f.codigo = 2 then null else banco end, f.codigo = 2
    from (values (0,'Dinheiro','1.1.7'),(1,'Cartão de crédito','1.1.2'),(2,'Crediário','1.1.4'),
                 (3,'Pix','1.1.1'),(4,'Cartão de débito','1.1.2'),(5,'Forma 5','1.1.8'),
                 (6,'Forma 6','1.1.8'),(7,'Forma 7','1.1.8')) as f(codigo, nome, conta)
  on conflict do nothing;
  return new;
end $$;

drop trigger if exists preparar_empresa on empresas;
create trigger preparar_empresa after insert on empresas
  for each row execute function preparar_empresa();

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
  n1 int; n2 int;
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

  update empresas set ultima_sync = now(), versao_sync = dados->>'versao' where id = e;
  return jsonb_build_object('empresa', (select nome from empresas where id = e),
                            'dias', n1, 'pagamentos', n2);
end $$;

revoke all on function sincronizar(text, jsonb) from public;
grant execute on function sincronizar(text, jsonb) to anon, authenticated;

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

grant execute on function vincular_usuario(uuid, text), usuarios_da_empresa(uuid),
                          desvincular_usuario(uuid, text), eh_admin(), pode_ver(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- PRIMEIRO ACESSO DA ALIBER: depois de criar sua conta no painel,
-- rode a linha abaixo (trocando o e-mail) para virar administrador:
--   insert into admins (user_id) select id from auth.users where email = 'marketingaliber@gmail.com';
-- ---------------------------------------------------------------------
